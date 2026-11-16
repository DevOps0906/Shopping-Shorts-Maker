-- products/shorts/org/0003_queue_extension.sql — Shopping-Shorts-Maker 원본 52~59번째 마이그레이션 이식(org안)
-- 근거: task-023, products/shorts/existing.md 7절. 원본 커밋 3face90 supabase/legacy-migrations/
--   20261113150000_job_backpressure(0001 반영본 교정) · 20261113160000_job_queue_status
--   20261114100000_analyze_thumbnail_context · 20261114100100_quarantine_sticky
--   20261114110000_extension_auth · 20261114110100_extension_reports
--   20261114110200_extension_sweeper_guards · 20261114110300_extension_review_fixes
-- 같은 함수를 여러 번 바꾼 것은 최종 상태 하나로 합쳤다(create_job 은 110300, rate_hit 은 110300).
-- 이름 규칙: public → nomad_shorts, private → nomad_shorts_private, 큐 sources → shorts_sources.
-- 전제: 0001·0002 적용됨.
begin;
set local check_function_bodies = false;

-- ═══ 1) 작업 큐 병목(150000) — 0001 반영본은 큐 이름과 종류를 섞어 비교해 상한·미룸·적체가 동작하지 않았다 ═══
-- 상한은 큐 기준(select_sources 는 shorts_analyze 큐를 같이 쓰므로 analyze 상한에 합산)
drop function nomad_shorts_private.job_queue_limit(text);
create function nomad_shorts_private.job_queue_limit(p_queue text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case p_queue when 'shorts_render' then 3 when 'shorts_tts' then 5 when 'shorts_analyze' then 5 end;
$$;
revoke execute on function nomad_shorts_private.job_queue_limit(text) from public, anon, authenticated;

-- job_start 가 큐 이름(p_queue)을 넘긴다. 같은 조직의 같은 큐 running 이 있으면 true(워커 호출이라 역할 검사 없이 소유 조직으로 비교)
drop function nomad_shorts_private.job_user_busy(uuid, text);
create function nomad_shorts_private.job_user_busy(p_job_id uuid, p_queue text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
begin
  select p.organization_id into v_uid
  from nomad_shorts.jobs j join nomad_shorts.projects p on p.id = j.project_id
  where j.id = p_job_id;
  if v_uid is null then
    return false;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('jobstart:' || v_uid::text || ':' || p_queue, 0));
  return exists (
    select 1 from nomad_shorts.jobs j join nomad_shorts.projects p on p.id = j.project_id
    where p.organization_id = v_uid and nomad_shorts_private.job_queue(j.type) = p_queue
      and j.status = 'running' and j.id <> p_job_id);
end;
$$;
revoke execute on function nomad_shorts_private.job_user_busy(uuid, text) from public, anon, authenticated, service_role;
grant execute on function nomad_shorts_private.job_user_busy(uuid, text) to worker_role;

create or replace function nomad_shorts.queue_health()
returns table (queue_name text, queue_length bigint, oldest_msg_age_sec integer, queued bigint, running bigint)
language sql
security definer
set search_path = ''
as $$
  select m.queue_name, m.queue_length, m.oldest_msg_age_sec,
         (select count(*) from nomad_shorts.jobs j where nomad_shorts_private.job_queue(j.type) = m.queue_name and j.status = 'queued'),
         (select count(*) from nomad_shorts.jobs j where nomad_shorts_private.job_queue(j.type) = m.queue_name and j.status = 'running')
  from pgmq.metrics_all() m
  where m.queue_name in ('shorts_render', 'shorts_tts', 'shorts_analyze')
  order by m.queue_name;
$$;

-- ═══ 2) 대기 순번·예상 대기(160000) ═══
-- 큐별 동시 처리 수 = 워커 WORKER_CONCURRENCY_* 기본값(가설)
create function nomad_shorts_private.job_queue_slots(p_queue text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case p_queue when 'shorts_render' then 1 when 'shorts_tts' then 2 when 'shorts_analyze' then 2 end;
$$;
revoke execute on function nomad_shorts_private.job_queue_slots(text) from public, anon, authenticated, service_role;

-- 업로드 1건 예상 소요(초, 가설). 업로더는 한 번에 1건씩 처리한다
create function nomad_shorts_private.upload_est_seconds()
returns integer
language sql
immutable
set search_path = ''
as $$
  select 180;
$$;
revoke execute on function nomad_shorts_private.upload_est_seconds() from public, anon, authenticated, service_role;

create index jobs_succeeded_type_finished_idx on nomad_shorts.jobs (type, finished_at desc) where status = 'succeeded';

-- 종류별 기준 소요 초: 최근 성공 20건 중앙값, 표본 3 미만이면 시간 제한의 절반
create function nomad_shorts_private.job_eta_basis(p_type text)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select percentile_cont(0.5) within group (order by s.secs)
     from (select extract(epoch from j.finished_at - j.started_at) as secs
           from nomad_shorts.jobs j
           where j.type = p_type and j.status = 'succeeded' and j.started_at is not null and j.finished_at is not null
           order by j.finished_at desc
           limit 20) s
     having count(*) >= 3),
    extract(epoch from nomad_shorts_private.job_time_limit(p_type)) / 2);
$$;
revoke execute on function nomad_shorts_private.job_eta_basis(text) from public, anon, authenticated, service_role;

create function nomad_shorts_private.job_queue_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_prod jsonb;
  v_post jsonb;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'job_id', t.job_id, 'project_id', t.project_id, 'project_name', t.project_name,
      'step', t.step, 'type', t.type, 'queue', t.queue, 'state', t.state,
      'started_at', t.started_at,
      'position', case when t.state = 'queued' then t.ahead + 1 end,
      'eta_seconds', case when t.state = 'queued'
        then ceil(greatest(t.ahead + t.running - nomad_shorts_private.job_queue_slots(t.queue) + 1, 0)
                  * nomad_shorts_private.job_eta_basis(t.type) / nomad_shorts_private.job_queue_slots(t.queue))::integer end)
    order by t.created_at, t.job_id), '[]'::jsonb)
  into v_prod
  from (
    select j.id as job_id, j.project_id, p.name as project_name, j.step, j.type, j.created_at, j.started_at,
           nomad_shorts_private.job_queue(j.type) as queue,
           case
             when j.status = 'running' then 'running'
             when exists (select 1 from nomad_shorts.jobs j2 join nomad_shorts.projects p2 on p2.id = j2.project_id
                          where p2.organization_id = p.organization_id and j2.status = 'running' and j2.id <> j.id
                            and nomad_shorts_private.job_queue(j2.type) = nomad_shorts_private.job_queue(j.type)) then 'deferred'
             else 'queued'
           end as state,
           (select count(*) from nomad_shorts.jobs q
            where q.status = 'queued' and nomad_shorts_private.job_queue(q.type) = nomad_shorts_private.job_queue(j.type)
              and (q.created_at, q.id) < (j.created_at, j.id)
              -- 미룸 상태(그 소유자가 같은 큐에 실행 중인 작업이 있음)인 다른 조직 작업은 나보다 먼저 시작하지 못한다
              and not exists (select 1 from nomad_shorts.jobs r2
                              join nomad_shorts.projects pr2 on pr2.id = r2.project_id
                              join nomad_shorts.projects pq on pq.id = q.project_id
                              where r2.status = 'running' and pr2.organization_id = pq.organization_id
                                and nomad_shorts_private.job_queue(r2.type) = nomad_shorts_private.job_queue(j.type))) as ahead,
           (select count(*) from nomad_shorts.jobs r
            where r.status = 'running' and nomad_shorts_private.job_queue(r.type) = nomad_shorts_private.job_queue(j.type)) as running
    from nomad_shorts.jobs j
    join nomad_shorts.projects p on p.id = j.project_id
    where nomad_core.organization_role(p.organization_id) is not null
      and j.status in ('queued', 'running') and nomad_shorts_private.job_queue(j.type) is not null
  ) t;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'publication_id', t.publication_id, 'project_id', t.project_id, 'project_name', t.project_name,
      'state', t.state, 'raw_status', t.raw_status, 'scheduled_at', t.scheduled_at, 'started_at', t.attempt_started_at,
      'retry_count', t.retry_count, 'error', t.error,
      'position', case when t.state in ('pending', 'retry_wait') and t.due then t.ahead + 1 end,
      'est_start_at', case
        when t.state in ('pending', 'retry_wait') and t.due
          then now() + make_interval(secs => greatest(t.ahead + t.uploading, 0) * nomad_shorts_private.upload_est_seconds())
        when t.state = 'retry_wait' then t.next_attempt_at end)
    order by t.sort_at, t.publication_id), '[]'::jsonb)
  into v_post
  from (
    select pb.id as publication_id, pb.project_id, p.name as project_name, pb.scheduled_at, pb.attempt_started_at,
           pb.retry_count, pb.next_attempt_at,
           pb.error,
           pb.state, pb.raw_status, pb.sort_at, pb.due,
           (select count(*) from nomad_shorts.publications q
            where q.status in ('pending', 'retry_wait') and (q.next_attempt_at is null or q.next_attempt_at <= now())
              and (coalesce(q.next_attempt_at, q.prepared_at, q.created_at), q.id)
                  < (coalesce(pb.next_attempt_at, pb.prepared_at, pb.created_at), pb.id)) as ahead,
           (select count(*) from nomad_shorts.publications u where u.status = 'uploading') as uploading
    from (
      select x.*,
             case x.status when 'needs_check' then 'failed' else x.status end as state, x.status as raw_status,
             coalesce(x.next_attempt_at, x.prepared_at, x.created_at) as sort_at,
             (x.next_attempt_at is null or x.next_attempt_at <= now()) as due
      from nomad_shorts.publications x
      where x.status in ('pending', 'retry_wait', 'uploading', 'scheduled', 'failed', 'needs_check', 'reconnect_wait')
    ) pb
    join nomad_shorts.projects p on p.id = pb.project_id
    where nomad_core.organization_role(p.organization_id) is not null
  ) t;

  return jsonb_build_object('production', v_prod, 'posting', v_post, 'generated_at', now());
end;
$$;
revoke execute on function nomad_shorts_private.job_queue_status() from public, anon, service_role;
grant execute on function nomad_shorts_private.job_queue_status() to authenticated;

create function nomad_shorts.job_queue_status()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select nomad_shorts_private.job_queue_status();
$$;
revoke execute on function nomad_shorts.job_queue_status() from public, anon, service_role;
grant execute on function nomad_shorts.job_queue_status() to authenticated;
comment on function nomad_shorts.job_queue_status() is
  '내가 속한 조직의 제작 작업(대기·미룸·실행: 순번·예상 대기 초)과 포스팅 대기(순번·예상 시작·예약 시각) 조회(17-5-1). 사용자 세션으로 호출, 다른 조직 작업은 수로만 반영';

-- ═══ 3) 썸네일 점수 컨텍스트(100000) · 격리 고정(100100) ═══
create or replace function nomad_shorts_private.analyze_sources_context(p_job_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid := nomad_shorts_private.analyze_job_project(p_job_id);
  v_user uuid;
  v_sources jsonb;
begin
  select organization_id into v_user from nomad_shorts.projects where id = v_project;
  select coalesce(jsonb_agg(jsonb_build_object(
                              'id', s.id,
                              'file_path', s.file_path,
                              'thumbnail_path', case when s.thumbnail_deleted_at is null then s.thumbnail_path end)
                            order by s.collected_at, s.id), '[]'::jsonb)
    into v_sources
  from nomad_shorts.sources s
  where s.project_id = v_project and s.file_deleted_at is null;
  return jsonb_build_object('project_id', v_project, 'organization_id', v_user, 'sources', v_sources);
end;
$$;

-- 한 번 격리된 원본은 재분석으로 풀리지 않는다(quarantined = 기존 or 새 판정)
create or replace function nomad_shorts_private.save_source_scores(p_job_id uuid, p_results jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid := nomad_shorts_private.analyze_job_project(p_job_id);
  v_selecting boolean;
  v_total integer;
  v_valid integer;
  v_updated integer;
begin
  if jsonb_typeof(p_results) is distinct from 'array' then
    raise exception '결과는 배열이어야 합니다' using errcode = '22023';
  end if;

  -- 승인 함수와 직렬화(02 승인 여부를 읽는 사이 바뀌지 않게)
  select coalesce(step_status->>'2', '') <> 'approved' into v_selecting
  from nomad_shorts.projects where id = v_project
  for update;

  select count(*),
         count(*) filter (where s.id is not null
                            and (e->'score' = 'null'::jsonb
                                 or (jsonb_typeof(e->'score') = 'number' and (e->>'score')::numeric between 0 and 100))
                            and (e->'exclude_reason' is null or e->'exclude_reason' = 'null'::jsonb
                                 or (jsonb_typeof(e->'exclude_reason') = 'string'
                                     and length(e->>'exclude_reason') <= 200))
                            and (e->'quarantined' is null or jsonb_typeof(e->'quarantined') = 'boolean'))
    into v_total, v_valid
  from jsonb_array_elements(p_results) e
  left join nomad_shorts.sources s
    on s.project_id = v_project
   and s.id::text = e->>'id';
  if v_total <> v_valid then
    raise exception '저장할 수 없는 결과가 있습니다(다른 프로젝트 원본이거나 값 범위 밖)' using errcode = '22023';
  end if;

  update nomad_shorts.sources s
  set score = (e->>'score')::numeric,
      exclude_reason = e->>'exclude_reason',
      quarantined = s.quarantined or coalesce((e->>'quarantined')::boolean,
                             (e->>'score') is null and (e->>'exclude_reason') is not null),
      checked = case when v_selecting then false else s.checked end
  from jsonb_array_elements(p_results) e
  where s.project_id = v_project and s.id::text = e->>'id';
  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;

-- ═══ 4) 확장 토큰 발급·회전·폐기, 속도 제한(110000 + 110300 rate_hit) ═══
-- 토큰 원문은 앱이 SHA-256(소문자 hex 64자)으로 바꿔 해시만 보낸다. 갱신은 CAS 1건만 성공, 직전 해시 재사용 = 그 행 폐기.
alter table nomad_shorts.extension_connections
  add column prev_refresh_token_hash text,
  add column rotated_at timestamptz,
  add column activated_at timestamptz;
comment on column nomad_shorts.extension_connections.prev_refresh_token_hash is '직전 갱신 토큰 해시. 재사용 감지용(재사용 시 행 폐기). 원문 저장 금지';
comment on column nomad_shorts.extension_connections.rotated_at is '마지막 회전 시각';
comment on column nomad_shorts.extension_connections.activated_at is '발급 후 첫 하트비트 시각. null 로 10분 지나면 스위퍼가 폐기';
create index extension_connections_prev_refresh_idx on nomad_shorts.extension_connections (prev_refresh_token_hash)
  where prev_refresh_token_hash is not null;
-- 이미 쓰던 연결은 활성으로 본다(새 열이 스위퍼에 걸리지 않게). authenticated 읽기는 열 단위라 새 열은 노출되지 않는다
update nomad_shorts.extension_connections set activated_at = coalesce(last_heartbeat_at, created_at) where activated_at is null;

create table nomad_shorts_private.rate_counters (
  key text not null check (char_length(key) <= 200),
  window_start timestamptz not null,
  hits integer not null default 0,
  primary key (key, window_start)
);
alter table nomad_shorts_private.rate_counters enable row level security;
revoke all on nomad_shorts_private.rate_counters from public, anon, authenticated, service_role, worker_role;
create index rate_counters_window_idx on nomad_shorts_private.rate_counters (window_start);
comment on table nomad_shorts_private.rate_counters is '속도 제한 고정 창 카운터(함수 전용, RLS 정책 없음). 오래된 창은 스위퍼가 지운다';

-- 한도 안이면 true, 초과면 false(초과 시도도 센다). 키 접두어 ext:·user:·ip: 만
create function nomad_shorts_private.rate_hit(p_key text, p_limit integer, p_window_seconds integer)
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
  insert into nomad_shorts_private.rate_counters as c (key, window_start, hits)
  values (p_key, v_start, 1)
  on conflict (key, window_start) do update set hits = c.hits + 1
  returning c.hits into v_hits;
  return v_hits <= p_limit;
end;
$$;
revoke execute on function nomad_shorts_private.rate_hit(text, integer, integer) from public, anon, authenticated;
grant execute on function nomad_shorts_private.rate_hit(text, integer, integer) to service_role;

-- 발급: 액세스 15분 · 갱신 30일
create function nomad_shorts_private.ext_issue(p_organization_id uuid, p_access_hash text, p_refresh_hash text)
returns table (extension_id uuid, access_expires_at timestamptz, refresh_expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if p_access_hash is null or p_access_hash !~ '^[0-9a-f]{64}$'
     or p_refresh_hash is null or p_refresh_hash !~ '^[0-9a-f]{64}$'
     or p_access_hash = p_refresh_hash then
    raise exception '토큰 해시 형식이 올바르지 않습니다' using errcode = '22023';
  end if;
  return query
  insert into nomad_shorts.extension_connections as e
    (organization_id, access_token_hash, access_expires_at, refresh_token_hash, refresh_expires_at, family_id)
  values (p_organization_id, p_access_hash, now() + interval '15 minutes', p_refresh_hash, now() + interval '30 days',
          gen_random_uuid())
  returning e.id, e.access_expires_at, e.refresh_expires_at;
end;
$$;
revoke execute on function nomad_shorts_private.ext_issue(uuid, text, text) from public, anon, authenticated;
grant execute on function nomad_shorts_private.ext_issue(uuid, text, text) to service_role;

-- 액세스 토큰 검사: 유효하면 1행, 폐기·만료면 0행
create function nomad_shorts_private.ext_authenticate(p_access_hash text)
returns table (extension_id uuid, organization_id uuid)
language sql
security definer
set search_path = ''
as $$
  select e.id, e.organization_id
  from nomad_shorts.extension_connections e
  where e.access_token_hash = p_access_hash
    and e.revoked_at is null
    and e.access_expires_at > now()
    and e.refresh_expires_at > now();
$$;
revoke execute on function nomad_shorts_private.ext_authenticate(text) from public, anon, authenticated;
grant execute on function nomad_shorts_private.ext_authenticate(text) to service_role;

-- 회전(제자리). result: ok · reused(직전 해시 재사용 → 그 행 폐기) · invalid
create function nomad_shorts_private.ext_rotate(p_old_refresh_hash text, p_new_access_hash text, p_new_refresh_hash text)
returns table (result text, extension_id uuid, access_expires_at timestamptz, refresh_expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_id uuid;
  v_access timestamptz;
  v_refresh timestamptz;
begin
  if p_new_access_hash is null or p_new_access_hash !~ '^[0-9a-f]{64}$'
     or p_new_refresh_hash is null or p_new_refresh_hash !~ '^[0-9a-f]{64}$'
     or p_new_access_hash = p_new_refresh_hash then
    raise exception '토큰 해시 형식이 올바르지 않습니다' using errcode = '22023';
  end if;

  -- CAS: 같은 갱신 토큰으로 동시에 와도 1건만 갱신된다
  update nomad_shorts.extension_connections e
  set prev_refresh_token_hash = e.refresh_token_hash,
      refresh_token_hash = p_new_refresh_hash,
      access_token_hash = p_new_access_hash,
      access_expires_at = now() + interval '15 minutes',
      refresh_expires_at = now() + interval '30 days',
      rotated_at = now()
  where e.refresh_token_hash = p_old_refresh_hash
    and e.revoked_at is null
    and e.refresh_expires_at > now()
  returning e.id, e.access_expires_at, e.refresh_expires_at into v_id, v_access, v_refresh;
  if found then
    return query select 'ok'::text, v_id, v_access, v_refresh;
    return;
  end if;

  -- 이미 회전된 토큰의 재사용(유예 없음): 그 행 폐기
  update nomad_shorts.extension_connections e
  set revoked_at = now()
  where e.prev_refresh_token_hash = p_old_refresh_hash and e.revoked_at is null
  returning e.id into v_id;
  if found then
    return query select 'reused'::text, v_id, null::timestamptz, null::timestamptz;
    return;
  end if;

  return query select 'invalid'::text, null::uuid, null::timestamptz, null::timestamptz;
end;
$$;
revoke execute on function nomad_shorts_private.ext_rotate(text, text, text) from public, anon, authenticated;
grant execute on function nomad_shorts_private.ext_rotate(text, text, text) to service_role;

-- 폐기: 그 조직의 행만(호출 서버가 조직 권한을 확인한 뒤 넘긴다). 새로 폐기하면 true
create function nomad_shorts_private.ext_revoke(p_extension_id uuid, p_organization_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  update nomad_shorts.extension_connections e
  set revoked_at = now()
  where e.id = p_extension_id and e.organization_id = p_organization_id and e.revoked_at is null;
  return found;
end;
$$;
revoke execute on function nomad_shorts_private.ext_revoke(uuid, uuid) from public, anon, authenticated;
grant execute on function nomad_shorts_private.ext_revoke(uuid, uuid) to service_role;

-- 하트비트: 첫 하트비트에 activated_at 기록
create or replace function nomad_shorts_private.ext_heartbeat(p_extension_id uuid)
returns table (id uuid, type text, payload jsonb)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_user uuid;
begin
  update nomad_shorts.extension_connections e
  set last_heartbeat_at = now(),
      activated_at = coalesce(e.activated_at, now())
  where e.id = p_extension_id and e.revoked_at is null
  returning e.organization_id into v_user;
  if v_user is null then
    raise exception '확장 연결을 찾을 수 없거나 폐기됐습니다' using errcode = '42501';
  end if;

  return query
  select j.id, j.type, j.payload
  from nomad_shorts.jobs j
  join nomad_shorts.projects p on p.id = j.project_id
  where p.organization_id = v_user
    and j.status = 'waiting_extension'
    and j.type in ('collect', 'collect_download')
  order by coalesce(j.waiting_since, j.created_at), j.id
  limit 1;
end;
$$;

-- 서버(service_role) 전용 래퍼
create function nomad_shorts.extension_issue(p_organization_id uuid, p_access_hash text, p_refresh_hash text)
returns table (extension_id uuid, access_expires_at timestamptz, refresh_expires_at timestamptz)
language sql
security invoker
set search_path = ''
as $$
  select * from nomad_shorts_private.ext_issue(p_organization_id, p_access_hash, p_refresh_hash);
$$;
comment on function nomad_shorts.extension_issue(uuid, text, text) is '확장 토큰 발급(서버 전용). 해시만 저장, 액세스 15분·갱신 30일';

create function nomad_shorts.extension_authenticate(p_access_hash text)
returns table (extension_id uuid, organization_id uuid)
language sql
security invoker
set search_path = ''
as $$
  select * from nomad_shorts_private.ext_authenticate(p_access_hash);
$$;
comment on function nomad_shorts.extension_authenticate(text) is '확장 액세스 토큰 검사(서버 전용). 폐기·만료면 0행';

create function nomad_shorts.extension_rotate(p_old_refresh_hash text, p_new_access_hash text, p_new_refresh_hash text)
returns table (result text, extension_id uuid, access_expires_at timestamptz, refresh_expires_at timestamptz)
language sql
security invoker
set search_path = ''
as $$
  select * from nomad_shorts_private.ext_rotate(p_old_refresh_hash, p_new_access_hash, p_new_refresh_hash);
$$;
comment on function nomad_shorts.extension_rotate(text, text, text) is '확장 토큰 제자리 회전(서버 전용). result ok·reused(행 폐기)·invalid';

create function nomad_shorts.extension_revoke(p_extension_id uuid, p_organization_id uuid)
returns boolean
language sql
security invoker
set search_path = ''
as $$
  select nomad_shorts_private.ext_revoke(p_extension_id, p_organization_id);
$$;
comment on function nomad_shorts.extension_revoke(uuid, uuid) is '확장 연결 폐기(서버 전용). 그 조직의 행만';

create function nomad_shorts.extension_rate_hit(p_key text, p_limit integer, p_window_seconds integer)
returns boolean
language sql
security invoker
set search_path = ''
as $$
  select nomad_shorts_private.rate_hit(p_key, p_limit, p_window_seconds);
$$;
comment on function nomad_shorts.extension_rate_hit(text, integer, integer) is '속도 제한 카운터(서버 전용). 키 접두어 ext:·user:·ip:, 한도 안 true · 초과 false';

revoke execute on function nomad_shorts.extension_issue(uuid, text, text) from public, anon, authenticated;
revoke execute on function nomad_shorts.extension_authenticate(text) from public, anon, authenticated;
revoke execute on function nomad_shorts.extension_rotate(text, text, text) from public, anon, authenticated;
revoke execute on function nomad_shorts.extension_revoke(uuid, uuid) from public, anon, authenticated;
revoke execute on function nomad_shorts.extension_rate_hit(text, integer, integer) from public, anon, authenticated;
grant execute on function nomad_shorts.extension_issue(uuid, text, text) to service_role;
grant execute on function nomad_shorts.extension_authenticate(text) to service_role;
grant execute on function nomad_shorts.extension_rotate(text, text, text) to service_role;
grant execute on function nomad_shorts.extension_revoke(uuid, uuid) to service_role;
grant execute on function nomad_shorts.extension_rate_hit(text, integer, integer) to service_role;

-- ═══ 5) 확장 완료·중단 보고, 프로젝트당 활성 collect_download 1개, 재검사 큐(110100) ═══
alter table nomad_shorts.jobs add column files_reported_at timestamptz;
comment on column nomad_shorts.jobs.files_reported_at is
  'collect_download 파일 완료 보고 시각. 기록되면 확장 끊김으로 waiting 되지 않고 워커 재검사가 마무리한다';

-- 기존 데이터 안전: 같은 프로젝트에 활성 collect_download 가 둘 이상이면 오래된 쪽을 failed('superseded')로(예약은 스위퍼가 반환)
update nomad_shorts.jobs j
set status = 'failed', finished_at = now(), error = 'superseded'
where j.type = 'collect_download' and j.status in ('queued', 'running', 'waiting_extension')
  and exists (select 1 from nomad_shorts.jobs n
              where n.project_id = j.project_id and n.type = 'collect_download'
                and n.status in ('queued', 'running', 'waiting_extension')
                and (n.created_at, n.id) > (j.created_at, j.id));

create unique index jobs_one_active_collect_download_idx on nomad_shorts.jobs (project_id)
  where type = 'collect_download' and status in ('queued', 'running', 'waiting_extension');

-- 워커 큐 shorts_sources(원래 sources, 재검사): 0001 의 큐 권한과 같다
select pgmq.create('shorts_sources')
where not exists (select 1 from pgmq.meta m where m.queue_name = 'shorts_sources');
do $$
declare q text := 'shorts_sources';
begin
  execute format('alter table pgmq.%I enable row level security', 'q_' || q);
  execute format('alter table pgmq.%I enable row level security', 'a_' || q);
  execute format('revoke all on pgmq.%I from public, anon, authenticated, service_role', 'q_' || q);
  execute format('revoke all on pgmq.%I from public, anon, authenticated, service_role', 'a_' || q);
  execute format('grant select, delete on pgmq.%I to worker_role', 'q_' || q);
  execute format('grant update (vt, read_ct) on pgmq.%I to worker_role', 'q_' || q);
  execute format('grant insert on pgmq.%I to worker_role', 'a_' || q);
  execute format('grant select (msg_id) on pgmq.%I to worker_role', 'a_' || q);
  execute format('create policy worker_select on pgmq.%I for select to worker_role using (true)', 'q_' || q);
  execute format('create policy worker_update on pgmq.%I for update to worker_role using (true) with check (true)', 'q_' || q);
  execute format('create policy worker_delete on pgmq.%I for delete to worker_role using (true)', 'q_' || q);
  execute format('create policy worker_insert on pgmq.%I for insert to worker_role with check (true)', 'a_' || q);
  execute format('create policy worker_select on pgmq.%I for select to worker_role using (true)', 'a_' || q);
end
$$;

-- 보고 대상 작업 잠금: 그 확장이 claim 한 running 수집 작업. 남의 작업·폐기된 확장 42501, 상태·확장 불일치 EX409
-- 잠금 순서 projects → jobs → extension_connections
create function nomad_shorts_private.ext_report_job(p_extension_id uuid, p_job_id uuid)
returns nomad_shorts.jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pid uuid;
  v_uid uuid;
  v_job nomad_shorts.jobs;
begin
  select j.project_id into v_pid from nomad_shorts.jobs j where j.id = p_job_id;
  select p.organization_id into v_uid from nomad_shorts.projects p where p.id = v_pid for update;

  select j.* into v_job
  from nomad_shorts.jobs j
  where j.id = p_job_id and j.project_id = v_pid and j.type in ('collect', 'collect_download')
  for update;
  if not found then
    raise exception '수집 작업이 아니거나 권한이 없습니다' using errcode = '42501';
  end if;

  perform 1
  from nomad_shorts.extension_connections e
  where e.id = p_extension_id and e.revoked_at is null and e.organization_id = v_uid
  for update;
  if not found then
    raise exception '수집 작업이 아니거나 권한이 없습니다' using errcode = '42501';
  end if;

  if v_job.status <> 'running' or v_job.extension_id is distinct from p_extension_id then
    raise exception '실행 중인 이 확장의 작업이 아닙니다' using errcode = 'EX409';
  end if;
  return v_job;
end;
$$;
revoke execute on function nomad_shorts_private.ext_report_job(uuid, uuid) from public, anon, authenticated;

-- 완료 보고: collect → 'succeeded' · collect_download → 'rechecking'(최초) / 'already_reported'(재전송)
create function nomad_shorts_private.ext_report_complete(p_extension_id uuid, p_job_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job nomad_shorts.jobs := nomad_shorts_private.ext_report_job(p_extension_id, p_job_id);
begin
  if v_job.type = 'collect' then
    if not nomad_shorts_private.settle_job(p_job_id) then
      raise exception '실행 중인 이 확장의 작업이 아닙니다' using errcode = 'EX409';
    end if;
    return 'succeeded';
  end if;

  if v_job.files_reported_at is not null then
    return 'already_reported';
  end if;
  update nomad_shorts.jobs set files_reported_at = now() where id = p_job_id;
  perform pgmq.send('shorts_sources', jsonb_build_object('job_id', p_job_id));
  return 'rechecking';
end;
$$;
revoke execute on function nomad_shorts_private.ext_report_complete(uuid, uuid) from public, anon, authenticated;
grant execute on function nomad_shorts_private.ext_report_complete(uuid, uuid) to service_role;

-- 중단 보고: captcha·risk_control·login_expired → failed + 사유 코드 + 예약 반환
create function nomad_shorts_private.ext_report_abort(p_extension_id uuid, p_job_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job nomad_shorts.jobs;
begin
  if p_reason is null or p_reason not in ('captcha', 'risk_control', 'login_expired') then
    raise exception '알 수 없는 중단 사유입니다' using errcode = '22023';
  end if;
  v_job := nomad_shorts_private.ext_report_job(p_extension_id, p_job_id);
  if v_job.files_reported_at is not null then
    raise exception '이미 파일 완료가 보고된 작업입니다' using errcode = 'EX409';
  end if;
  update nomad_shorts.jobs set status = 'failed', finished_at = now(), error = p_reason where id = p_job_id;
  perform nomad_shorts_private.release_job(p_job_id);
end;
$$;
revoke execute on function nomad_shorts_private.ext_report_abort(uuid, uuid, text) from public, anon, authenticated;
grant execute on function nomad_shorts_private.ext_report_abort(uuid, uuid, text) to service_role;

create function nomad_shorts.extension_report_complete(p_extension_id uuid, p_job_id uuid)
returns text
language sql
security invoker
set search_path = ''
as $$
  select nomad_shorts_private.ext_report_complete(p_extension_id, p_job_id);
$$;
comment on function nomad_shorts.extension_report_complete(uuid, uuid) is
  '확장 완료 보고(서버 전용). collect 는 정산·succeeded, collect_download 는 running 유지 후 워커 재검사. 늦은 보고 EX409';

create function nomad_shorts.extension_report_abort(p_extension_id uuid, p_job_id uuid, p_reason text)
returns void
language sql
security invoker
set search_path = ''
as $$
  select nomad_shorts_private.ext_report_abort(p_extension_id, p_job_id, p_reason);
$$;
comment on function nomad_shorts.extension_report_abort(uuid, uuid, text) is
  '확장 중단 보고(서버 전용). 사유 captcha·risk_control·login_expired → failed + 예약 반환';

revoke execute on function nomad_shorts.extension_report_complete(uuid, uuid) from public, anon, authenticated;
revoke execute on function nomad_shorts.extension_report_abort(uuid, uuid, text) from public, anon, authenticated;
grant execute on function nomad_shorts.extension_report_complete(uuid, uuid) to service_role;
grant execute on function nomad_shorts.extension_report_abort(uuid, uuid, text) to service_role;

-- ═══ 6) 스위퍼·생성·체크 잠금(110200 · 110300) ═══
create or replace function nomad_shorts_private.sweep_jobs()
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
  v_ext_unactivated integer;
  v_rate_pruned integer;
begin
  with t as (
    update nomad_shorts.jobs j
    set status = 'failed', finished_at = now(), error = '시간 초과'
    where j.status = 'running'
      and j.started_at < now() - nomad_shorts_private.job_time_limit(j.type)
    returning j.id
  )
  select count(*) into v_timed_out from t;

  -- 하트비트 2분 끊김 → 대기. 파일 완료가 보고된 작업은 워커 재검사가 마무리하므로 제외
  with t as (
    update nomad_shorts.jobs j
    set status = 'waiting_extension', extension_id = null, error = '확장 연결이 끊겼습니다'
    where j.status = 'running' and j.type in ('collect', 'collect_download')
      and j.files_reported_at is null
      and not exists (select 1 from nomad_shorts.extension_connections e
                      where e.id = j.extension_id
                        and e.revoked_at is null
                        and greatest(e.last_heartbeat_at, j.started_at) >= now() - interval '2 minutes')
    returning j.id
  )
  select count(*) into v_stale from t;

  with t as (
    update nomad_shorts.jobs j
    set status = 'failed', finished_at = now(), error = '확장 대기 시간 초과'
    where j.status = 'waiting_extension'
      and coalesce(j.waiting_since, j.created_at) < now() - interval '24 hours'
    returning j.id
  )
  select count(*) into v_waiting from t;

  with t as (
    insert into nomad_shorts.credit_ledger (organization_id, project_id, job_id, kind, delta, reason, idempotency_key)
    select r.organization_id, r.project_id, r.job_id, 'release', -r.delta, 'sweeper:' || j.status, 'release:' || r.job_id
    from nomad_shorts.credit_ledger r
    join nomad_shorts.jobs j on j.id = r.job_id
    where r.kind = 'reserve' and j.status in ('failed', 'canceled')
      and not exists (select 1 from nomad_shorts.credit_ledger f
                      where f.job_id = r.job_id and f.kind in ('settle', 'release'))
    on conflict do nothing
    returning 1
  )
  select count(*) into v_released from t;

  -- 발급 후 첫 하트비트 없이 10분 지난 확장 연결 폐기
  with t as (
    update nomad_shorts.extension_connections e
    set revoked_at = now()
    where e.revoked_at is null and e.activated_at is null
      and e.created_at < now() - interval '10 minutes'
    returning e.id
  )
  select count(*) into v_ext_unactivated from t;

  with t as (
    delete from nomad_shorts_private.rate_counters where window_start < now() - interval '1 day' returning 1
  )
  select count(*) into v_rate_pruned from t;

  return jsonb_build_object('timed_out', v_timed_out, 'heartbeat_lost', v_stale,
                            'waiting_expired', v_waiting, 'released', v_released,
                            'ext_unactivated', v_ext_unactivated, 'rate_pruned', v_rate_pruned);
end;
$$;

-- create_job(조직 단위 잔액·대기 수·잠금, 멱등 키 접두는 사용자): 큐 기준 대기 상한(JQ001), 프로젝트당 활성 확장 job 1개(EX001), collect_download 도 확장 대기로 시작
create or replace function nomad_shorts_private.create_job(
  p_project_id uuid, p_type text, p_idempotency_key text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_key text;
  v_step smallint := nomad_shorts_private.job_step(p_type);
  v_status jsonb;
  v_job nomad_shorts.jobs;
  v_cost integer;
  v_balance bigint;
  v_queue text := nomad_shorts_private.job_queue(p_type);
  v_limit integer := nomad_shorts_private.job_queue_limit(nomad_shorts_private.job_queue(p_type));
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

  select step_status, organization_id into v_status, v_org
  from nomad_shorts.projects
  where id = p_project_id and nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')
  for update;
  if not found then
    raise exception '프로젝트를 찾을 수 없거나 권한이 없습니다' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('credit:' || v_org::text, 0));

  select j.* into v_job from nomad_shorts.jobs j where j.idempotency_key = v_key;
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
  if p_type in ('collect', 'collect_download', 'select_sources') and exists (
       select 1 from nomad_shorts.jobs j
       where j.project_id = p_project_id and j.type in ('collect', 'collect_download')
         and j.status in ('queued', 'running', 'waiting_extension')) then
    raise exception '확장 수집 작업이 진행 중입니다. 끝난 뒤 다시 시도하세요' using errcode = 'EX001';
  end if;

  -- 대기 상한: 크레딧 예약 전에 거부
  if v_limit is not null then
    select count(*)::integer into v_active
    from nomad_shorts.jobs j
    join nomad_shorts.projects p on p.id = j.project_id
    where p.organization_id = v_org and nomad_shorts_private.job_queue(j.type) = v_queue and j.status in ('queued', 'running');
    if v_active >= v_limit then
      raise exception '진행 중인 % 작업이 너무 많습니다. 끝난 뒤 다시 시도하세요', v_queue
        using errcode = 'JQ001',
              detail = jsonb_build_object('queue', v_queue, 'limit', v_limit, 'active', v_active)::text;
    end if;
  end if;

  v_cost := nomad_shorts_private.job_cost(p_type);
  select coalesce(sum(delta), 0) into v_balance from nomad_shorts.credit_ledger where organization_id = v_org;
  if v_balance < v_cost then
    raise exception '크레딧이 부족합니다'
      using errcode = 'CR001',
            detail = jsonb_build_object('required', v_cost, 'balance', v_balance)::text;
  end if;

  insert into nomad_shorts.jobs (project_id, step, type, status, idempotency_key, payload)
  values (p_project_id, v_step, p_type,
          case when p_type in ('collect', 'collect_download') then 'waiting_extension' else 'queued' end,
          v_key, coalesce(p_payload, '{}'::jsonb))
  returning * into v_job;

  insert into nomad_shorts.credit_ledger (organization_id, project_id, job_id, kind, delta, reason, idempotency_key)
  values (v_org, p_project_id, v_job.id, 'reserve', -v_cost, p_type, 'reserve:' || v_job.id);

  if v_queue is not null then
    perform pgmq.send(v_queue, jsonb_build_object('job_id', v_job.id));
  end if;

  return to_jsonb(v_job) - 'payload' - 'idempotency_key' || jsonb_build_object('created', true);
end;
$$;
comment on function nomad_shorts.create_job(uuid, text, text, jsonb) is
  '작업 생성(17-5). 단계는 종류로 결정, 단계 위반 55000, 같은 키 재요청은 기존 작업(다른 작업이면 JK001), 활성 확장 작업 중 수집·선정 EX001, 큐별 대기 상한 초과 JQ001, 잔액 부족 CR001. 사용자 세션으로 호출';

-- set_source_checks: 활성 확장 job 이 있으면 체크 변경 거부(EX001)
create or replace function nomad_shorts_private.set_source_checks(p_project_id uuid, p_source_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ids uuid[] := coalesce(p_source_ids, '{}');
  v_found integer;
  v_checked integer;
begin
  perform nomad_shorts_private.lock_source_step(p_project_id);
  if exists (select 1 from nomad_shorts.jobs j
             where j.project_id = p_project_id and j.type in ('collect', 'collect_download')
               and j.status in ('queued', 'running', 'waiting_extension')) then
    raise exception '확장 수집 작업이 진행 중이라 체크를 바꿀 수 없습니다' using errcode = 'EX001';
  end if;
  if cardinality(v_ids) > 10 then
    raise exception '다운로드는 10편까지 체크할 수 있습니다' using errcode = '22023';
  end if;
  select count(*) into v_found
  from nomad_shorts.sources s
  where s.project_id = p_project_id and s.id = any (v_ids);
  if v_found <> (select count(distinct x) from unnest(v_ids) as x) then
    raise exception '이 프로젝트의 원본이 아닙니다' using errcode = '22023';
  end if;

  update nomad_shorts.sources s
  set checked = (s.id = any (v_ids))
  where s.project_id = p_project_id and s.checked is distinct from (s.id = any (v_ids));

  select count(*) into v_checked from nomad_shorts.sources where project_id = p_project_id and checked;
  return v_checked;
end;
$$;

-- ext_collect_download: 파일 완료가 보고된 작업은 기록 거부(EX409)
create or replace function nomad_shorts_private.ext_collect_download(p_extension_id uuid, p_job_id uuid, p_files jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job record := nomad_shorts_private.ext_job_project(p_extension_id, p_job_id, 'collect_download');
  v_prefix text;
  v_total integer;
  v_valid integer;
  v_updated integer;
begin
  v_prefix := v_job.organization_id::text || '/' || v_job.project_id::text || '/';
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

  -- 파일 완료가 이미 보고된 작업은 기록 불가(워커 재검사 중 경로 변경 차단)
  if exists (select 1 from nomad_shorts.jobs j where j.id = p_job_id and j.files_reported_at is not null) then
    raise exception '이미 파일 완료가 보고된 작업입니다' using errcode = 'EX409';
  end if;

  -- 대상 원본 행 잠금(체크 해제·격리와 직렬화)
  perform 1
  from nomad_shorts.sources s
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
  left join nomad_shorts.sources s
    on s.project_id = v_job.project_id
   and s.id::text = e->>'id';
  if v_total <> v_valid
     or v_total <> (select count(distinct e->>'id') from jsonb_array_elements(p_files) e) then
    raise exception '기록할 수 없는 파일이 있습니다(체크하지 않은 원본이거나 경로가 다름)' using errcode = '22023';
  end if;

  -- 최종 갱신에도 작업·확장·원본 조건을 다시 건다
  update nomad_shorts.sources s
  set file_path = e->>'file_path'
  from jsonb_array_elements(p_files) e, nomad_shorts.jobs j, nomad_shorts.extension_connections x
  where s.project_id = v_job.project_id and s.id::text = e->>'id'
    and s.checked and not s.quarantined and s.file_deleted_at is null
    and j.id = p_job_id and j.type = 'collect_download' and j.status = 'running'
    and j.extension_id = p_extension_id and j.files_reported_at is null
    and x.id = p_extension_id and x.revoked_at is null and x.organization_id = v_job.organization_id;
  get diagnostics v_updated = row_count;
  if v_updated <> v_total then
    raise exception '작업 상태가 바뀌어 기록하지 않았습니다' using errcode = '40001';
  end if;
  return v_updated;
end;
$$;

commit;
