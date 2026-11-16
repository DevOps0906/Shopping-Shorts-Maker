-- task-015b-1 리뷰 반영(110000~110200 은 미병합이지만 보강은 새 파일로)
-- 1) create_job: 활성 확장 job(collect·collect_download)이 있으면 collect·collect_download·select_sources 생성 거부(EX001)
-- 2) ext_collect_download: files_reported_at 이 있으면 파일 기록 거부(EX409)
-- 3) rate_hit: 키 접두어 ext:·user:·ip: 만 허용

-- ── 1) create_job(20261114110200 에서 출발) ─────────────────────
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
  v_queue text := private.job_queue(p_type);
  v_limit integer := private.job_queue_limit(private.job_queue(p_type));
  v_active integer;
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

  -- 프로젝트당 활성(queued·running·waiting_extension) 확장 job 1개: 수집·다운로드 생성과 select_sources 생성 공통
  -- (프로젝트 행 잠금 안에서 검사. 멱등 재요청은 위에서 기존 job 을 이미 돌려줬다)
  if p_type in ('collect', 'collect_download', 'select_sources') and exists (
       select 1 from public.jobs j
       where j.project_id = p_project_id and j.type in ('collect', 'collect_download')
         and j.status in ('queued', 'running', 'waiting_extension')) then
    raise exception '확장 수집 작업이 진행 중입니다. 끝난 뒤 다시 시도하세요' using errcode = 'EX001';
  end if;

  if v_limit is not null then
    select count(*)::integer into v_active
    from public.jobs j
    join public.projects p on p.id = j.project_id
    where p.user_id = v_uid and private.job_queue(j.type) = v_queue and j.status in ('queued', 'running');
    if v_active >= v_limit then
      raise exception '진행 중인 % 작업이 너무 많습니다. 끝난 뒤 다시 시도하세요', v_queue
        using errcode = 'JQ001',
              detail = jsonb_build_object('queue', v_queue, 'limit', v_limit, 'active', v_active)::text;
    end if;
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

  if v_queue is not null then
    perform pgmq.send(v_queue, jsonb_build_object('job_id', v_job.id));
  end if;

  return to_jsonb(v_job) - 'payload' - 'idempotency_key' || jsonb_build_object('created', true);
end;
$$;

-- ── 2) ext_collect_download ──────────────────────────────────
create or replace function private.ext_collect_download(p_extension_id uuid, p_job_id uuid, p_files jsonb)
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

  -- 파일 완료가 이미 보고된 작업은 기록 불가(워커 재검사 중 경로 변경 차단). ext_job_project 의 프로젝트 행 잠금으로 보고와 직렬화
  if exists (select 1 from public.jobs j where j.id = p_job_id and j.files_reported_at is not null) then
    raise exception '이미 파일 완료가 보고된 작업입니다' using errcode = 'EX409';
  end if;

  -- 대상 원본 행 잠금(체크 해제·격리와 직렬화)
  perform 1
  from public.sources s
  where s.project_id = v_job.project_id
    and s.id::text in (select e->>'id' from jsonb_array_elements(p_files) e)
  order by s.id
  for update;

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

  -- 최종 갱신에도 작업·확장·원본 조건을 다시 건다
  update public.sources s
  set file_path = e->>'file_path'
  from jsonb_array_elements(p_files) e, public.jobs j, public.extension_connections x
  where s.project_id = v_job.project_id and s.id::text = e->>'id'
    and s.checked and not s.quarantined and s.file_deleted_at is null
    and j.id = p_job_id and j.type = 'collect_download' and j.status = 'running'
    and j.extension_id = p_extension_id and j.files_reported_at is null
    and x.id = p_extension_id and x.revoked_at is null and x.user_id = v_job.user_id;
  get diagnostics v_updated = row_count;
  if v_updated <> v_total then
    raise exception '작업 상태가 바뀌어 기록하지 않았습니다' using errcode = '40001';
  end if;
  return v_updated;
end;
$$;

-- ── 3) rate_hit: 키 접두어 제한 ──────────────────────────────
create or replace function private.rate_hit(p_key text, p_limit integer, p_window_seconds integer)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_start timestamptz;
  v_hits integer;
begin
  if p_key is null or char_length(p_key) not between 1 and 200 or p_key !~ '^(ext|user|ip):'
     or p_limit is null or p_limit not between 1 and 100000
     or p_window_seconds is null or p_window_seconds not between 1 and 86400 then
    raise exception '속도 제한 인자가 올바르지 않습니다' using errcode = '22023';
  end if;
  v_start := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  insert into private.rate_counters as c (key, window_start, hits)
  values (p_key, v_start, 1)
  on conflict (key, window_start) do update set hits = c.hits + 1
  returning c.hits into v_hits;
  return v_hits <= p_limit;
end;
$$;
