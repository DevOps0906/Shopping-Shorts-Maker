-- task-015a 확장 수집 DB: 3단계 작업·전이 정본·claim·하트비트·수집 입력 검증·버킷
-- 근거: docs/adr/0003-extension-server-auth.md 보강(2026-11-12) ①②③⑤, docs/planning.md 17-5, tasks/task-015.md 잠정 결정
-- - 작업 종류: collect(확장, 목록·썸네일) + collect_download(확장, 체크된 원본 파일). 둘 다 큐 없이 waiting_extension 으로 시작.
-- - jobs.waiting_since: running → waiting_extension 재진입 시각(트리거). 생성 직후 대기는 null = created_at 기준.
-- - sweep_jobs 교체: 하트비트 2분 끊김 → waiting_extension(진행분 보존, extension_id null) · 대기 24시간(waiting_since) → failed.
--   수집 15분 상한은 claim 마다 새로 센다(claim 이 started_at 을 다시 쓴다, 대기 시간 제외).
-- - 확장 함수 4개(하트비트·claim·목록 입력·다운로드 입력)는 Route Handler(서버, service_role)가 확장 토큰을 검사한 뒤
--   extension_connections.id 로 부른다. anon·authenticated EXECUTE 없음.
-- - 수집 입력 위조 방지: platform 은 정규화 URL 호스트로 서버가 결정, collected_at 은 서버 now(), 틱톡 @handle = author,
--   필드 허용 목록, 한 번에 60행, 프로젝트당 100편, 검사 함수는 직접 추가와 같은 private.has_unsafe_chars.
-- - 버킷: sources 상한 200MiB 로 통일(ADR-0003), 썸네일 전용 비공개 버킷 thumbnails(512KiB, image/jpeg·webp).
-- - 미선정 원본 썸네일 보존 7일(collected_at 기준, 체크·사용 안 한 원본). 삭제 실행은 파일 정리 작업에서 한다.

-- ── 1) 작업 종류 collect_download ─────────────────────────────
alter table public.jobs drop constraint jobs_type_check;
alter table public.jobs add constraint jobs_type_check
  check (type in ('render', 'tts', 'analyze', 'collect', 'select_sources', 'collect_download'));

create or replace function private.job_time_limit(p_type text)
returns interval
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'tts' then interval '2 minutes'
    when 'render' then interval '10 minutes'
    when 'analyze' then interval '5 minutes'
    when 'select_sources' then interval '5 minutes'
    when 'collect' then interval '15 minutes'
    when 'collect_download' then interval '15 minutes'
  end;
$$;

create or replace function private.job_step(p_type text)
returns smallint
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'collect' then 2
    when 'collect_download' then 2
    when 'select_sources' then 2
    when 'analyze' then 3
    when 'tts' then 4
    when 'render' then 5
  end::smallint;
$$;

-- 종류 → 큐. 확장 작업(collect·collect_download)은 큐 없음(null)
create or replace function private.job_queue(p_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'render' then 'render'
    when 'tts' then 'tts'
    when 'analyze' then 'analyze'
    when 'select_sources' then 'analyze'
    when 'collect' then null
    when 'collect_download' then null
  end;
$$;

-- 20261112200100 그대로, 확장 작업 두 종류를 waiting_extension 으로 시작
create or replace function private.create_job(
  p_project_id uuid, p_type text, p_idempotency_key text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_key text;
  v_step smallint := private.job_step(p_type);
  v_status jsonb;
  v_job public.jobs;
  v_cost integer;
  v_balance bigint;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  if v_step is null then
    raise exception '알 수 없는 작업 종류입니다: %', p_type using errcode = '22023';
  end if;
  if p_idempotency_key is null or length(p_idempotency_key) not between 8 and 200 then
    raise exception '멱등 키가 올바르지 않습니다' using errcode = '22023';
  end if;
  v_key := v_uid::text || ':' || p_idempotency_key;

  select step_status into v_status
  from public.projects
  where id = p_project_id and user_id = v_uid
  for update;
  if not found then
    raise exception '프로젝트를 찾을 수 없거나 권한이 없습니다' using errcode = '42501';
  end if;

  -- 사용자 단위 잠금: 다른 프로젝트에서 같은 사용자의 잔액 경쟁도 직렬화
  perform pg_advisory_xact_lock(hashtextextended('credit:' || v_uid::text, 0));

  select j.* into v_job from public.jobs j where j.idempotency_key = v_key;
  if found then
    if v_job.project_id <> p_project_id or v_job.type <> p_type then
      raise exception '같은 멱등 키가 다른 작업에 이미 쓰였습니다' using errcode = 'JK001';
    end if;
    return to_jsonb(v_job) - 'payload' - 'idempotency_key' || jsonb_build_object('created', false);
  end if;

  if exists (select 1 from generate_series(1, v_step - 1) as g(n)
             where v_status ->> g.n::text is distinct from 'approved') then
    raise exception '앞 단계가 승인되지 않았습니다' using errcode = '55000';
  end if;
  if v_status ->> v_step::text = 'approved' then
    raise exception '이미 승인된 단계입니다. 변경 요청 후 다시 시도하세요' using errcode = '55000';
  end if;

  v_cost := private.job_cost(p_type);
  select coalesce(sum(delta), 0) into v_balance from public.credit_ledger where user_id = v_uid;
  if v_balance < v_cost then
    raise exception '크레딧이 부족합니다'
      using errcode = 'CR001',
            detail = jsonb_build_object('required', v_cost, 'balance', v_balance)::text;
  end if;

  insert into public.jobs (project_id, step, type, status, idempotency_key, payload)
  values (p_project_id, v_step, p_type,
          case when p_type in ('collect', 'collect_download') then 'waiting_extension' else 'queued' end,
          v_key, coalesce(p_payload, '{}'::jsonb))
  returning * into v_job;

  insert into public.credit_ledger (user_id, project_id, job_id, kind, delta, reason, idempotency_key)
  values (v_uid, p_project_id, v_job.id, 'reserve', -v_cost, p_type, 'reserve:' || v_job.id);

  if private.job_queue(p_type) is not null then
    perform pgmq.send(private.job_queue(p_type), jsonb_build_object('job_id', v_job.id));
  end if;

  return to_jsonb(v_job) - 'payload' - 'idempotency_key' || jsonb_build_object('created', true);
end;
$$;

revoke execute on function private.create_job(uuid, text, text, jsonb) from public, anon, authenticated;
grant execute on function private.create_job(uuid, text, text, jsonb) to authenticated;

-- ── 2) waiting_since ────────────────────────────────────────
alter table public.jobs add column waiting_since timestamptz;
comment on column public.jobs.waiting_since is
  '확장 대기(waiting_extension) 재진입 시각(트리거). null 이면 생성 시 대기 = created_at. 대기 24시간 기준';

create function private.jobs_waiting_since()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'waiting_extension' and old.status is distinct from 'waiting_extension' then
    new.waiting_since := now();
  end if;
  return new;
end;
$$;
revoke execute on function private.jobs_waiting_since() from public, anon, authenticated;

create trigger jobs_waiting_since
  before update of status on public.jobs
  for each row execute function private.jobs_waiting_since();

-- ── 3) sweep_jobs 교체(20261112180200 에서 출발) ─────────────
create or replace function private.sweep_jobs()
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_timed_out integer;
  v_stale integer;
  v_waiting integer;
  v_released integer;
begin
  -- 1) 실행 시간 초과. 확장 작업은 claim 마다 started_at 을 새로 쓰므로 claim 마다 15분
  with t as (
    update public.jobs j
    set status = 'failed', finished_at = now(), error = '시간 초과'
    where j.status = 'running'
      and j.started_at < now() - private.job_time_limit(j.type)
    returning j.id
  )
  select count(*) into v_timed_out from t;

  -- 2) 확장 하트비트 2분 끊김(폐기·삭제된 확장 포함) → 대기로 되돌림. 이미 받은 행·파일은 그대로 둔다(진행분 보존)
  with t as (
    update public.jobs j
    set status = 'waiting_extension', extension_id = null, error = '확장 연결이 끊겼습니다'
    where j.status = 'running' and j.type in ('collect', 'collect_download')
      and not exists (select 1 from public.extension_connections e
                      where e.id = j.extension_id
                        and e.revoked_at is null
                        and greatest(e.last_heartbeat_at, j.started_at) >= now() - interval '2 minutes')
    returning j.id
  )
  select count(*) into v_stale from t;

  -- 3) 확장 대기 24시간: 대기 진입 시각(waiting_since, 없으면 생성 시각) 기준
  with t as (
    update public.jobs j
    set status = 'failed', finished_at = now(), error = '확장 대기 시간 초과'
    where j.status = 'waiting_extension'
      and coalesce(j.waiting_since, j.created_at) < now() - interval '24 hours'
    returning j.id
  )
  select count(*) into v_waiting from t;

  -- 4) 실패·취소인데 반환이 없는 예약분 반환
  with t as (
    insert into public.credit_ledger (user_id, project_id, job_id, kind, delta, reason, idempotency_key)
    select r.user_id, r.project_id, r.job_id, 'release', -r.delta, 'sweeper:' || j.status, 'release:' || r.job_id
    from public.credit_ledger r
    join public.jobs j on j.id = r.job_id
    where r.kind = 'reserve' and j.status in ('failed', 'canceled')
      and not exists (select 1 from public.credit_ledger f
                      where f.job_id = r.job_id and f.kind in ('settle', 'release'))
    on conflict do nothing
    returning 1
  )
  select count(*) into v_released from t;

  return jsonb_build_object('timed_out', v_timed_out, 'heartbeat_lost', v_stale,
                            'waiting_expired', v_waiting, 'released', v_released);
end;
$$;

revoke execute on function private.sweep_jobs() from public, anon, authenticated;

-- ── 4) sources.thumbnail_path ───────────────────────────────
alter table public.sources add column thumbnail_path text;
comment on column public.sources.thumbnail_path is
  '비공개 버킷 thumbnails 의 객체 경로(<user_id>/<project_id>/<파일명>). 미선정(체크·사용 안 함) 원본은 수집 7일 뒤 파일 삭제';

-- ── 5) 버킷: 원본 200MiB 통일, 썸네일 버킷 ──────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('sources', 'sources', false, 209715200,             -- 200 MiB (ADR-0003 업로드 크기)
   array['video/mp4', 'video/quicktime', 'video/webm']),
  ('thumbnails', 'thumbnails', false, 524288,          -- 512 KiB
   array['image/jpeg', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ── 6) 수집 URL 정규화 ──────────────────────────────────────
-- 정규형(잠정, 실측 후 확정): 틱톡 https://www.tiktok.com/@<handle 소문자>/video/<숫자>
--                            샤오홍슈 https://www.xiaohongshu.com/explore/<24자리 16진 소문자>
-- 쿼리·조각·끝 슬래시 제거, 호스트 소문자, userinfo(@)·포트·그 외 호스트 거부(direct 불가)
create function private.normalize_collect_url(p_url text, out url text, out platform text, out handle text)
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_url text := btrim(coalesce(p_url, ''));
  v_authority text;
  v_host text;
  v_path text;
  m text[];
begin
  if char_length(v_url) > 2000 or v_url !~* '^https?://[^\s/?#]+[^\s]*$' or private.has_unsafe_chars(v_url) then
    raise exception 'http(s) URL이 아닙니다' using errcode = '22023';
  end if;
  v_authority := substring(v_url from '^[A-Za-z]+://([^/?#]*)');
  if v_authority like '%@%' then
    raise exception 'URL에 사용자 정보(@)를 넣을 수 없습니다' using errcode = '22023';
  end if;
  v_host := lower(v_authority);
  v_path := regexp_replace(substring(v_url from '^[A-Za-z]+://[^/?#]*([^?#]*)'), '/+$', '');

  if v_host ~ '^(www\.|m\.)?tiktok\.com$' then
    m := regexp_match(v_path, '^/@([A-Za-z0-9._]{1,64})/video/([0-9]{1,30})$');
    if m is null then
      raise exception '틱톡 영상 주소 형식이 아닙니다' using errcode = '22023';
    end if;
    platform := 'tiktok';
    handle := lower(m[1]);
    url := 'https://www.tiktok.com/@' || handle || '/video/' || m[2];
  elsif v_host ~ '^(www\.)?xiaohongshu\.com$' then
    m := regexp_match(v_path, '^/(explore|discovery/item)/([0-9A-Fa-f]{24})$');
    if m is null then
      raise exception '샤오홍슈 노트 주소 형식이 아닙니다' using errcode = '22023';
    end if;
    platform := 'xiaohongshu';
    url := 'https://www.xiaohongshu.com/explore/' || lower(m[2]);
  else
    raise exception '틱톡·샤오홍슈 주소만 수집할 수 있습니다' using errcode = '22023';
  end if;
end;
$$;
revoke execute on function private.normalize_collect_url(text) from public, anon, authenticated;

-- 실행 중인 확장 작업의 프로젝트(잠금). 확장 = 그 작업을 claim 한 확장 · 폐기 전 · 프로젝트 소유자
create function private.ext_job_project(p_extension_id uuid, p_job_id uuid, p_type text,
                                        out project_id uuid, out user_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
begin
  select p.id, p.user_id into project_id, user_id
  from public.jobs j
  join public.projects p on p.id = j.project_id
  join public.extension_connections e on e.id = j.extension_id
  where j.id = p_job_id and j.type = p_type and j.status = 'running'
    and j.extension_id = p_extension_id
    and e.revoked_at is null and e.user_id = p.user_id
  for update of p;
  if project_id is null then
    raise exception '실행 중인 수집 작업이 아니거나 권한이 없습니다' using errcode = '42501';
  end if;
end;
$$;
revoke execute on function private.ext_job_project(uuid, uuid, text) from public, anon, authenticated;

-- ── 7) 하트비트: 연결 시각 갱신 + 그 사용자의 대기 확장 작업 1건 ──
create function private.ext_heartbeat(p_extension_id uuid)
returns table (id uuid, type text, payload jsonb)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_user uuid;
begin
  update public.extension_connections e
  set last_heartbeat_at = now()
  where e.id = p_extension_id and e.revoked_at is null
  returning e.user_id into v_user;
  if v_user is null then
    raise exception '확장 연결을 찾을 수 없거나 폐기됐습니다' using errcode = '42501';
  end if;

  return query
  select j.id, j.type, j.payload
  from public.jobs j
  join public.projects p on p.id = j.project_id
  where p.user_id = v_user
    and j.status = 'waiting_extension'
    and j.type in ('collect', 'collect_download')
  order by coalesce(j.waiting_since, j.created_at), j.id
  limit 1;
end;
$$;
revoke execute on function private.ext_heartbeat(uuid) from public, anon, authenticated;

-- ── 8) claim: 원자적 waiting_extension → running. 성공 시 1행, 아니면 0행 ──
create function private.ext_claim_job(p_extension_id uuid, p_job_id uuid)
returns table (id uuid, type text, payload jsonb)
language sql
security definer
set search_path = ''
as $$
  with c as (
    update public.jobs j
    set status = 'running', extension_id = p_extension_id, started_at = now(), error = null
    from public.projects p, public.extension_connections e
    where j.id = p_job_id
      and j.status = 'waiting_extension'
      and j.type in ('collect', 'collect_download')
      and p.id = j.project_id
      and e.id = p_extension_id
      and e.user_id = p.user_id
      and e.revoked_at is null
    returning j.id, j.type, j.payload
  ), h as (
    -- claim 직후 스위퍼가 끊김으로 보지 않게 연결 시각도 갱신
    update public.extension_connections e
    set last_heartbeat_at = now()
    where e.id = p_extension_id and exists (select 1 from c)
  )
  select c.id, c.type, c.payload from c;
$$;
revoke execute on function private.ext_claim_job(uuid, uuid) from public, anon, authenticated;

-- ── 9) 목록 입력(collect): 행 허용 키 url·author·title·thumbnail_path·platform ──
-- platform 은 넣어도 저장에 쓰지 않고, 정규화 URL 호스트와 다르면 거부한다. 반환: {inserted, ids}
create function private.ext_collect_list(p_extension_id uuid, p_job_id uuid, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job record := private.ext_job_project(p_extension_id, p_job_id, 'collect');
  v_prefix text;
  v_item jsonb;
  v_norm record;
  v_author text;
  v_title text;
  v_thumb text;
  v_urls text[] := '{}';
  v_ids uuid[] := '{}';
  v_id uuid;
  v_n integer;
begin
  v_prefix := v_job.user_id::text || '/' || v_job.project_id::text || '/';
  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception '목록은 배열이어야 합니다' using errcode = '22023';
  end if;
  v_n := jsonb_array_length(p_items);
  if v_n not between 1 and 60 then
    raise exception '한 번에 1~60편까지 보낼 수 있습니다' using errcode = '22023';
  end if;
  if (select count(*) from public.sources where project_id = v_job.project_id) + v_n > 100 then
    raise exception '원본은 프로젝트당 100편까지 모을 수 있습니다' using errcode = '22023';
  end if;

  for v_item in select e from jsonb_array_elements(p_items) e loop
    if jsonb_typeof(v_item) is distinct from 'object'
       or exists (select 1 from jsonb_object_keys(v_item) k
                  where k not in ('url', 'author', 'title', 'thumbnail_path', 'platform'))
       or jsonb_typeof(v_item -> 'url') is distinct from 'string'
       or jsonb_typeof(v_item -> 'author') is distinct from 'string'
       or coalesce(jsonb_typeof(v_item -> 'title'), 'null') not in ('string', 'null')
       or coalesce(jsonb_typeof(v_item -> 'thumbnail_path'), 'null') not in ('string', 'null')
       or coalesce(jsonb_typeof(v_item -> 'platform'), 'null') not in ('string', 'null') then
      raise exception '허용되지 않은 필드나 형식이 있습니다' using errcode = '22023';
    end if;

    v_norm := private.normalize_collect_url(v_item ->> 'url');
    if v_item ->> 'platform' is not null and v_item ->> 'platform' <> v_norm.platform then
      raise exception '플랫폼이 URL 호스트와 다릅니다' using errcode = '22023';
    end if;

    v_author := btrim(v_item ->> 'author');
    if char_length(v_author) not between 1 and 100 or private.has_unsafe_chars(v_author) then
      raise exception '작성자를 확인해 주세요' using errcode = '22023';
    end if;
    if v_norm.platform = 'tiktok' and lower(regexp_replace(v_author, '^@', '')) <> v_norm.handle then
      raise exception '작성자가 URL의 @계정과 다릅니다' using errcode = '22023';
    end if;

    v_title := nullif(btrim(coalesce(v_item ->> 'title', '')), '');
    if v_title is not null and (char_length(v_title) > 200 or private.has_unsafe_chars(v_title)) then
      raise exception '제목을 확인해 주세요' using errcode = '22023';
    end if;

    v_thumb := v_item ->> 'thumbnail_path';
    if v_thumb is not null
       and (left(v_thumb, char_length(v_prefix)) <> v_prefix
            or substr(v_thumb, char_length(v_prefix) + 1) !~ '^[A-Za-z0-9_-][A-Za-z0-9._-]{0,199}$') then
      raise exception '썸네일 경로가 이 프로젝트 경로가 아닙니다' using errcode = '22023';
    end if;

    if v_norm.url = any (v_urls)
       or exists (select 1 from public.sources where project_id = v_job.project_id and url = v_norm.url) then
      raise exception '이미 수집한 URL입니다' using errcode = '23505';
    end if;
    v_urls := v_urls || v_norm.url;

    insert into public.sources (project_id, platform, url, author, title, thumbnail_path, collected_at)
    values (v_job.project_id, v_norm.platform, v_norm.url, v_author, v_title, v_thumb, now())
    returning id into v_id;
    v_ids := v_ids || v_id;
  end loop;

  return jsonb_build_object('inserted', cardinality(v_ids), 'ids', to_jsonb(v_ids));
end;
$$;
revoke execute on function private.ext_collect_list(uuid, uuid, jsonb) from public, anon, authenticated;

-- ── 10) 다운로드 입력(collect_download): 행 허용 키 id·file_path, 체크된 원본에만 기록 ──
create function private.ext_collect_download(p_extension_id uuid, p_job_id uuid, p_files jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job record := private.ext_job_project(p_extension_id, p_job_id, 'collect_download');
  v_prefix text;
  v_total integer;
  v_valid integer;
  v_updated integer;
begin
  v_prefix := v_job.user_id::text || '/' || v_job.project_id::text || '/';
  if jsonb_typeof(p_files) is distinct from 'array' then
    raise exception '파일 목록은 배열이어야 합니다' using errcode = '22023';
  end if;
  if jsonb_array_length(p_files) not between 1 and 60 then
    raise exception '한 번에 1~60개까지 보낼 수 있습니다' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_files) e
             where jsonb_typeof(e) is distinct from 'object'
                or exists (select 1 from jsonb_object_keys(e) k where k not in ('id', 'file_path'))
                or jsonb_typeof(e -> 'id') is distinct from 'string'
                or jsonb_typeof(e -> 'file_path') is distinct from 'string') then
    raise exception '허용되지 않은 필드나 형식이 있습니다' using errcode = '22023';
  end if;

  select count(*),
         count(*) filter (where s.id is not null
                            and s.checked
                            and not s.quarantined
                            and s.file_deleted_at is null
                            and left(e->>'file_path', char_length(v_prefix)) = v_prefix
                            and substr(e->>'file_path', char_length(v_prefix) + 1)
                                ~ '^[A-Za-z0-9_-][A-Za-z0-9._-]{0,199}$')
    into v_total, v_valid
  from jsonb_array_elements(p_files) e
  left join public.sources s
    on s.project_id = v_job.project_id
   and s.id::text = e->>'id';
  if v_total <> v_valid
     or v_total <> (select count(distinct e->>'id') from jsonb_array_elements(p_files) e) then
    raise exception '기록할 수 없는 파일이 있습니다(체크하지 않은 원본이거나 경로가 다름)' using errcode = '22023';
  end if;

  update public.sources s
  set file_path = e->>'file_path'
  from jsonb_array_elements(p_files) e
  where s.project_id = v_job.project_id and s.id::text = e->>'id';
  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;
revoke execute on function private.ext_collect_download(uuid, uuid, jsonb) from public, anon, authenticated;

-- ── 11) 서버(service_role) 전용 래퍼 ─────────────────────────
-- 확장은 Supabase 세션이 없다. Route Handler 가 확장 토큰(해시)으로 extension_connections.id 를 찾은 뒤 부른다.
grant usage on schema private to service_role;
grant execute on function private.ext_heartbeat(uuid) to service_role;
grant execute on function private.ext_claim_job(uuid, uuid) to service_role;
grant execute on function private.ext_collect_list(uuid, uuid, jsonb) to service_role;
grant execute on function private.ext_collect_download(uuid, uuid, jsonb) to service_role;

create function public.extension_heartbeat(p_extension_id uuid)
returns table (id uuid, type text, payload jsonb)
language sql
security invoker
set search_path = ''
as $$
  select * from private.ext_heartbeat(p_extension_id);
$$;
comment on function public.extension_heartbeat(uuid) is '확장 하트비트(서버 전용). 대기 수집 작업 1건을 돌려준다';

create function public.extension_claim_job(p_extension_id uuid, p_job_id uuid)
returns table (id uuid, type text, payload jsonb)
language sql
security invoker
set search_path = ''
as $$
  select * from private.ext_claim_job(p_extension_id, p_job_id);
$$;
comment on function public.extension_claim_job(uuid, uuid) is '확장 작업 claim(서버 전용). 성공 1행, 실패 0행';

create function public.extension_collect_list(p_extension_id uuid, p_job_id uuid, p_items jsonb)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.ext_collect_list(p_extension_id, p_job_id, p_items);
$$;
comment on function public.extension_collect_list(uuid, uuid, jsonb) is '확장 목록 수집 입력(서버 전용). platform·수집 시각은 서버가 정한다';

create function public.extension_collect_download(p_extension_id uuid, p_job_id uuid, p_files jsonb)
returns integer
language sql
security invoker
set search_path = ''
as $$
  select private.ext_collect_download(p_extension_id, p_job_id, p_files);
$$;
comment on function public.extension_collect_download(uuid, uuid, jsonb) is '확장 다운로드 파일 기록(서버 전용). 체크된 원본에만';

revoke execute on function public.extension_heartbeat(uuid) from public, anon, authenticated;
revoke execute on function public.extension_claim_job(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.extension_collect_list(uuid, uuid, jsonb) from public, anon, authenticated;
revoke execute on function public.extension_collect_download(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.extension_heartbeat(uuid) to service_role;
grant execute on function public.extension_claim_job(uuid, uuid) to service_role;
grant execute on function public.extension_collect_list(uuid, uuid, jsonb) to service_role;
grant execute on function public.extension_collect_download(uuid, uuid, jsonb) to service_role;
