-- task-015b-1 스위퍼 보강·체크 잠금
-- 1) sweep_jobs(20261112240000 에서 출발): 파일 완료가 보고된 collect_download 는 끊김으로 waiting 되지 않음,
--    미활성(activated_at null) 10분 지난 확장 폐기, 오래된 속도 제한 창 정리.
-- 2) create_job(20261113150000 에서 출발): 활성 확장 job(collect·collect_download)이 있으면 select_sources 생성 거부(EX001),
--    활성 collect_download 가 이미 있으면 다른 키의 collect_download 생성 거부(EX001). 프로젝트 행 잠금 뒤 검사.
-- 3) set_source_checks(20261112210000 에서 출발): 활성 확장 job 이 있으면 체크 변경 거부(EX001).
comment on table private.rate_counters is '속도 제한 고정 창 카운터(함수 전용, RLS 정책 없음). 오래된 창은 스위퍼가 지운다';

-- ── 1) sweep_jobs ────────────────────────────────────────────
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
  v_ext_unactivated integer;
  v_rate_pruned integer;
begin
  with t as (
    update public.jobs j
    set status = 'failed', finished_at = now(), error = '시간 초과'
    where j.status = 'running'
      and j.started_at < now() - private.job_time_limit(j.type)
    returning j.id
  )
  select count(*) into v_timed_out from t;

  -- 하트비트 2분 끊김 → 대기. 파일 완료가 보고된 작업은 워커 재검사가 마무리하므로 제외
  with t as (
    update public.jobs j
    set status = 'waiting_extension', extension_id = null, error = '확장 연결이 끊겼습니다'
    where j.status = 'running' and j.type in ('collect', 'collect_download')
      and j.files_reported_at is null
      and not exists (select 1 from public.extension_connections e
                      where e.id = j.extension_id
                        and e.revoked_at is null
                        and greatest(e.last_heartbeat_at, j.started_at) >= now() - interval '2 minutes')
    returning j.id
  )
  select count(*) into v_stale from t;

  with t as (
    update public.jobs j
    set status = 'failed', finished_at = now(), error = '확장 대기 시간 초과'
    where j.status = 'waiting_extension'
      and coalesce(j.waiting_since, j.created_at) < now() - interval '24 hours'
    returning j.id
  )
  select count(*) into v_waiting from t;

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

  -- 발급 후 첫 하트비트 없이 10분 지난 확장 연결 폐기
  with t as (
    update public.extension_connections e
    set revoked_at = now()
    where e.revoked_at is null and e.activated_at is null
      and e.created_at < now() - interval '10 minutes'
    returning e.id
  )
  select count(*) into v_ext_unactivated from t;

  with t as (
    delete from private.rate_counters where window_start < now() - interval '1 day' returning 1
  )
  select count(*) into v_rate_pruned from t;

  return jsonb_build_object('timed_out', v_timed_out, 'heartbeat_lost', v_stale,
                            'waiting_expired', v_waiting, 'released', v_released,
                            'ext_unactivated', v_ext_unactivated, 'rate_pruned', v_rate_pruned);
end;
$$;
revoke execute on function private.sweep_jobs() from public, anon, authenticated;

-- ── 2) create_job ────────────────────────────────────────────
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

  -- 확장 job 과 체크·선정의 경쟁 차단(프로젝트 행 잠금 안에서 검사)
  if p_type = 'select_sources' and exists (
       select 1 from public.jobs j
       where j.project_id = p_project_id and j.type in ('collect', 'collect_download')
         and j.status in ('queued', 'running', 'waiting_extension')) then
    raise exception '확장 수집 작업이 진행 중입니다. 끝난 뒤 다시 시도하세요' using errcode = 'EX001';
  end if;
  if p_type = 'collect_download' and exists (
       select 1 from public.jobs j
       where j.project_id = p_project_id and j.type = 'collect_download'
         and j.status in ('queued', 'running', 'waiting_extension')) then
    raise exception '다운로드 작업이 이미 진행 중입니다' using errcode = 'EX001';
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

-- ── 3) set_source_checks ─────────────────────────────────────
create or replace function private.set_source_checks(p_project_id uuid, p_source_ids uuid[])
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
  perform private.lock_source_step(p_project_id);
  if exists (select 1 from public.jobs j
             where j.project_id = p_project_id and j.type in ('collect', 'collect_download')
               and j.status in ('queued', 'running', 'waiting_extension')) then
    raise exception '확장 수집 작업이 진행 중이라 체크를 바꿀 수 없습니다' using errcode = 'EX001';
  end if;
  if cardinality(v_ids) > 10 then
    raise exception '다운로드는 10편까지 체크할 수 있습니다' using errcode = '22023';
  end if;
  select count(*) into v_found
  from public.sources s
  where s.project_id = p_project_id and s.id = any (v_ids);
  if v_found <> (select count(distinct x) from unnest(v_ids) as x) then
    raise exception '이 프로젝트의 원본이 아닙니다' using errcode = '22023';
  end if;

  update public.sources s
  set checked = (s.id = any (v_ids))
  where s.project_id = p_project_id and s.checked is distinct from (s.id = any (v_ids));

  select count(*) into v_checked from public.sources where project_id = p_project_id and checked;
  return v_checked;
end;
$$;
