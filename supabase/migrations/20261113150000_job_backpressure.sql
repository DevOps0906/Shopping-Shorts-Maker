-- task-035 작업 큐 병목 대응(docs/planning.md 17-5-1)
-- 1) create_job: 같은 사용자·같은 종류의 queued·running 수가 상한을 넘으면 크레딧 예약 전에 JQ001 로 거부.
--    멱등 키가 같은 기존 작업 반환은 상한 검사보다 먼저(재시도가 막히지 않게). 상한은 private.job_queue_limit 한 곳.
-- 2) job_start: 같은 사용자의 같은 종류 다른 작업이 running 이면 시작하지 않고 vt 를 짧게 미뤄 deferred 반환.
--    미룸은 attempts 를 올리지 않고, pgmq.read 가 올린 read_ct 를 되돌려(-1) read_ct 기반 실패 판정에 섞이지 않게 한다.
-- 3) public.queue_health(): service_role 전용 큐별 적체 조회.

-- ── 상한(가설, 17-5-1) ──────────────────────────────────────
-- 큐 이름 기준(select_sources 는 analyze 큐를 같이 쓰므로 analyze 상한에 합산된다)
create function private.job_queue_limit(p_queue text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case p_queue when 'render' then 3 when 'tts' then 5 when 'analyze' then 5 end;
$$;
revoke execute on function private.job_queue_limit(text) from public, anon, authenticated;

-- ── create_job: 상한 검사 추가(나머지는 20261112240000 과 같다) ──
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

  -- 사용자 단위 잠금: 다른 프로젝트에서 같은 사용자의 잔액·대기 수 경쟁도 직렬화
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

  -- 대기 상한: 크레딧 예약 전에 거부(예약·잔액 변화 없음)
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

comment on function public.create_job(uuid, text, text, jsonb) is
  '작업 생성(17-5). 단계는 종류로 결정, 단계 위반 55000, 같은 키 재요청은 기존 작업(다른 작업이면 JK001), 종류별 대기 상한 초과 JQ001, 잔액 부족 CR001. Route Handler가 사용자 세션으로 호출';

-- ── job_start: 사용자별 동시 실행 1 ─────────────────────────
-- 워커는 projects 를 읽지 못하므로 사용자 조회·잠금·집계는 SECURITY DEFINER 보조 함수가 맡는다.
-- 잠금(사용자+종류)은 job_start 트랜잭션 끝까지 유지되어, 직후 running 전이와 한 덩어리로 경쟁을 막는다.
create function private.job_user_busy(p_job_id uuid, p_queue text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
begin
  select p.user_id into v_uid
  from public.jobs j join public.projects p on p.id = j.project_id
  where j.id = p_job_id;
  if v_uid is null then
    return false;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('jobstart:' || v_uid::text || ':' || p_queue, 0));
  return exists (
    select 1 from public.jobs j join public.projects p on p.id = j.project_id
    where p.user_id = v_uid and private.job_queue(j.type) = p_queue and j.status = 'running' and j.id <> p_job_id);
end;
$$;
revoke execute on function private.job_user_busy(uuid, text) from public, anon, authenticated, service_role;
grant execute on function private.job_user_busy(uuid, text) to worker_role;

create or replace function private.job_start(p_queue text, p_msg_id bigint, p_job_id uuid, p_read_ct integer)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_status text;
  v_max integer;
  v_type text;
  v_step smallint;
  v_attempts integer;
  v_payload jsonb;
begin
  select status, max_attempts into v_status, v_max from public.jobs where id = p_job_id;
  if v_status is null or v_status not in ('queued', 'running') then
    perform private.release_job(p_job_id);
    perform pgmq.archive(p_queue, p_msg_id);
    return jsonb_build_object('action', 'stop', 'status', v_status);
  end if;

  if p_read_ct > v_max then
    update public.jobs
    set status = 'failed', finished_at = now(), error = '재시도 횟수를 넘었습니다'
    where id = p_job_id and status in ('queued', 'running');
    perform private.release_job(p_job_id);
    perform pgmq.archive(p_queue, p_msg_id);
    return jsonb_build_object('action', 'failed');
  end if;

  -- 같은 사용자의 같은 종류가 이미 실행 중이면 미룬다. running 인 자기 자신(죽은 워커 복구)은 미루지 않는다.
  -- 미룸은 시도가 아니다: attempts 는 그대로, pgmq.read 가 올린 read_ct 는 되돌린다.
  if v_status = 'queued' and private.job_user_busy(p_job_id, p_queue) then
    execute format(
      'update pgmq.%I set vt = clock_timestamp() + interval ''20 seconds'', read_ct = greatest(read_ct - 1, 0) where msg_id = $1',
      'q_' || p_queue) using p_msg_id;
    return jsonb_build_object('action', 'deferred', 'delay', 20);
  end if;

  -- 조건부 전이. running 인데 메시지가 다시 보이면 앞선 워커가 vt 연장 없이 죽은 것(ADR-0001)
  update public.jobs
  set status = 'running', attempts = attempts + 1, started_at = now(), error = null
  where id = p_job_id and status in ('queued', 'running')
  returning type, step, attempts, payload into v_type, v_step, v_attempts, v_payload;
  if not found then
    perform pgmq.archive(p_queue, p_msg_id);
    return jsonb_build_object('action', 'stop');
  end if;

  return jsonb_build_object('action', 'run', 'type', v_type, 'step', v_step,
                            'attempts', v_attempts, 'payload', v_payload);
end;
$$;

-- ── queue_health: 서버 전용 ─────────────────────────────────
create function public.queue_health()
returns table (queue_name text, queue_length bigint, oldest_msg_age_sec integer, queued bigint, running bigint)
language sql
security definer
set search_path = ''
as $$
  select m.queue_name, m.queue_length, m.oldest_msg_age_sec,
         (select count(*) from public.jobs j where private.job_queue(j.type) = m.queue_name and j.status = 'queued'),
         (select count(*) from public.jobs j where private.job_queue(j.type) = m.queue_name and j.status = 'running')
  from pgmq.metrics_all() m
  where m.queue_name in ('render', 'tts', 'analyze')
  order by m.queue_name;
$$;
revoke execute on function public.queue_health() from public, anon, authenticated;
grant execute on function public.queue_health() to service_role;
comment on function public.queue_health() is
  '큐별 적체(17-5-1): 메시지 수·가장 오래 기다린 초·queued·running 작업 수. service_role 전용, 감시 작업이 읽는다';
