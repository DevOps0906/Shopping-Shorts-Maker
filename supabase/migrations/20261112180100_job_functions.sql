-- task-012: 작업 생성(멱등·잔액 확인·reserve·pgmq.send 한 트랜잭션)과 워커 상태 전이 함수
-- 근거: docs/planning.md 17-5, ADR-0001(조건부 전이, credit_ledger unique·settle/release 1건, 결과·settle·archive 한 트랜잭션)
-- - 잔액 = credit_ledger.delta 합(정수 크레딧). reserve = -예상치, settle = 예약분 - 실제 사용량, release = +예약분.
-- - create_job: 사용자 세션으로 부르는 SECURITY DEFINER(private) + public 래퍼(05 문서 1절 규칙, approve_step과 같은 형태).
--   예상 크레딧은 서버가 정하고(private.job_cost), 브라우저 입력을 받지 않는다.
-- - 워커 함수(private.job_*): SECURITY INVOKER라 worker_role 권한·RLS 그대로 실행된다. worker_role에만 EXECUTE.

-- ── 공용: 예상 크레딧(가설값, 17-5 확정 전) ─────────────────
create function private.job_cost(p_type text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'render' then 30
    when 'tts' then 10
    when 'analyze' then 5
    else 0
  end;
$$;

-- ── 공용: 예약분 반환. 이미 settle·release가 있으면 아무것도 하지 않는다(부분 unique 인덱스) ──
create function private.release_job_credits(p_job_id uuid, p_reason text)
returns void
language sql
security invoker
set search_path = ''
as $$
  insert into public.credit_ledger (user_id, project_id, job_id, kind, delta, reason, idempotency_key)
  select r.user_id, r.project_id, r.job_id, 'release', -r.delta, p_reason, 'release:' || r.job_id
  from public.credit_ledger r
  where r.job_id = p_job_id and r.kind = 'reserve'
  on conflict do nothing;
$$;

-- ── 작업 생성(사용자) ────────────────────────────────────────
create function private.create_job(
  p_project_id uuid, p_step integer, p_type text, p_idempotency_key text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_job public.jobs;
  v_owner uuid;
  v_cost integer;
  v_balance bigint;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  if p_type is null or p_type not in ('render', 'tts', 'analyze', 'collect') then
    raise exception '알 수 없는 작업 종류입니다: %', p_type using errcode = '22023';
  end if;
  if p_idempotency_key is null or length(p_idempotency_key) not between 8 and 200 then
    raise exception '멱등 키가 올바르지 않습니다' using errcode = '22023';
  end if;

  perform 1 from public.projects where id = p_project_id and user_id = v_uid;
  if not found then
    raise exception '프로젝트를 찾을 수 없거나 권한이 없습니다' using errcode = '42501';
  end if;

  -- 사용자 단위 잠금: 같은 사용자의 동시 생성(같은 키 중복·잔액 경쟁)을 직렬화
  perform pg_advisory_xact_lock(hashtextextended('credit:' || v_uid::text, 0));

  select j.* into v_job from public.jobs j where j.idempotency_key = p_idempotency_key;
  if found then
    select p.user_id into v_owner from public.projects p where p.id = v_job.project_id;
    if v_owner is distinct from v_uid then
      raise exception '이미 사용된 멱등 키입니다' using errcode = '42501';
    end if;
    return to_jsonb(v_job) - 'payload' || jsonb_build_object('created', false);
  end if;

  v_cost := private.job_cost(p_type);
  select coalesce(sum(delta), 0) into v_balance from public.credit_ledger where user_id = v_uid;
  if v_balance < v_cost then
    raise exception '크레딧이 부족합니다'
      using errcode = 'CR001',
            detail = jsonb_build_object('required', v_cost, 'balance', v_balance)::text;
  end if;

  insert into public.jobs (project_id, step, type, status, idempotency_key, payload)
  values (p_project_id, p_step, p_type,
          case when p_type = 'collect' then 'waiting_extension' else 'queued' end,
          p_idempotency_key, coalesce(p_payload, '{}'::jsonb))
  returning * into v_job;

  insert into public.credit_ledger (user_id, project_id, job_id, kind, delta, reason, idempotency_key)
  values (v_uid, p_project_id, v_job.id, 'reserve', -v_cost, p_type, 'reserve:' || v_job.id);

  -- 수집은 확장이 가져간다(ADR-0003). 나머지는 같은 트랜잭션에서 큐에 job_id만 넣는다.
  if p_type <> 'collect' then
    perform pgmq.send(p_type, jsonb_build_object('job_id', v_job.id));
  end if;

  return to_jsonb(v_job) - 'payload' || jsonb_build_object('created', true);
end;
$$;

revoke execute on function private.job_cost(text) from public, anon, authenticated;
revoke execute on function private.release_job_credits(uuid, text) from public, anon, authenticated;
revoke execute on function private.create_job(uuid, integer, text, text, jsonb) from public, anon, authenticated;
grant execute on function private.create_job(uuid, integer, text, text, jsonb) to authenticated;

create function public.create_job(
  p_project_id uuid, p_step integer, p_type text, p_idempotency_key text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.create_job(p_project_id, p_step, p_type, p_idempotency_key, p_payload);
$$;

comment on function public.create_job(uuid, integer, text, text, jsonb) is
  '작업 생성(17-5). 같은 멱등 키면 기존 작업, 잔액 부족이면 CR001. Route Handler가 사용자 세션으로 호출';
revoke execute on function public.create_job(uuid, integer, text, text, jsonb) from public, anon;
grant execute on function public.create_job(uuid, integer, text, text, jsonb) to authenticated;

-- ── 워커 상태 전이(SECURITY INVOKER, worker_role) ────────────
-- 메시지를 읽은 뒤 호출. 반환 action: run(실행) · stop(이미 끝났거나 취소, archive함) · failed(재시도 소진)
create function private.job_start(p_queue text, p_msg_id bigint, p_job_id uuid, p_read_ct integer)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_job public.jobs;
begin
  select * into v_job from public.jobs where id = p_job_id;
  if not found or v_job.status not in ('queued', 'running') then
    if found and v_job.status in ('failed', 'canceled') then
      perform private.release_job_credits(p_job_id, v_job.status);
    end if;
    perform pgmq.archive(p_queue, p_msg_id);
    return jsonb_build_object('action', 'stop', 'status', v_job.status);
  end if;

  if p_read_ct > v_job.max_attempts then
    update public.jobs
    set status = 'failed', finished_at = now(),
        error = coalesce(error, '재시도 횟수를 넘었습니다')
    where id = p_job_id and status in ('queued', 'running');
    perform private.release_job_credits(p_job_id, 'retry_exhausted');
    perform pgmq.archive(p_queue, p_msg_id);
    return jsonb_build_object('action', 'failed');
  end if;

  -- 조건부 전이. running 인데 메시지가 다시 보이면 앞선 워커가 vt 연장 없이 죽은 것(ADR-0001)
  update public.jobs
  set status = 'running', attempts = attempts + 1, started_at = now(), error = null
  where id = p_job_id and status in ('queued', 'running')
  returning * into v_job;
  if not found then
    perform pgmq.archive(p_queue, p_msg_id);
    return jsonb_build_object('action', 'stop');
  end if;

  return jsonb_build_object('action', 'run', 'type', v_job.type, 'step', v_job.step,
                            'attempts', v_job.attempts, 'payload', v_job.payload);
end;
$$;

-- 성공: 결과 기록 · settle · archive 한 트랜잭션. 이미 running이 아니면(취소·시간 초과) 결과를 버리고 false
create function private.job_succeed(p_queue text, p_msg_id bigint, p_job_id uuid, p_actual_cost integer default null)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_reserve public.credit_ledger;
begin
  if p_actual_cost is not null and p_actual_cost < 0 then
    raise exception '사용량은 0 이상이어야 합니다' using errcode = '22023';
  end if;

  update public.jobs
  set status = 'succeeded', finished_at = now(), error = null
  where id = p_job_id and status = 'running';
  if not found then
    perform private.release_job_credits(p_job_id, 'not_running');
    perform pgmq.archive(p_queue, p_msg_id);
    return false;
  end if;

  select * into v_reserve from public.credit_ledger where job_id = p_job_id and kind = 'reserve';
  if found then
    insert into public.credit_ledger (user_id, project_id, job_id, kind, delta, reason, idempotency_key)
    values (v_reserve.user_id, v_reserve.project_id, p_job_id, 'settle',
            -v_reserve.delta - coalesce(p_actual_cost, -v_reserve.delta), 'succeeded', 'settle:' || p_job_id);
  end if;

  perform pgmq.archive(p_queue, p_msg_id);
  return true;
end;
$$;

-- 영구 실패(입력·권한 오류): failed · release · archive 한 트랜잭션
create function private.job_fail(p_queue text, p_msg_id bigint, p_job_id uuid, p_error text)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_changed boolean;
begin
  update public.jobs
  set status = 'failed', finished_at = now(), error = left(p_error, 500)
  where id = p_job_id and status = 'running';
  v_changed := found;
  perform private.release_job_credits(p_job_id, 'failed');
  perform pgmq.archive(p_queue, p_msg_id);
  return v_changed;
end;
$$;

-- 일시 오류: queued로 되돌리고 vt를 백오프 초만큼 미룬다. 이미 running이 아니면 release · archive 후 false
create function private.job_retry(p_queue text, p_msg_id bigint, p_job_id uuid, p_error text, p_delay_seconds integer)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update public.jobs
  set status = 'queued', error = left(p_error, 500)
  where id = p_job_id and status = 'running';
  if not found then
    perform private.release_job_credits(p_job_id, 'not_running');
    perform pgmq.archive(p_queue, p_msg_id);
    return false;
  end if;
  perform pgmq.set_vt(p_queue, p_msg_id, greatest(p_delay_seconds, 0));
  return true;
end;
$$;

-- 실행 중 1분마다: vt 연장 후 현재 상태 반환. running이 아니면 워커가 job_stop을 부른다
create function private.job_heartbeat(p_queue text, p_msg_id bigint, p_job_id uuid, p_vt_seconds integer)
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_status text;
begin
  select status into v_status from public.jobs where id = p_job_id;
  if v_status = 'running' then
    perform pgmq.set_vt(p_queue, p_msg_id, p_vt_seconds);
  end if;
  return v_status;
end;
$$;

-- 취소·시간 초과로 중단: 결과를 버리고 release(이미 있으면 무시) · archive
create function private.job_stop(p_queue text, p_msg_id bigint, p_job_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if exists (select 1 from public.jobs where id = p_job_id and status in ('failed', 'canceled')) then
    perform private.release_job_credits(p_job_id, 'stopped');
  end if;
  perform pgmq.archive(p_queue, p_msg_id);
end;
$$;

revoke execute on function private.job_start(text, bigint, uuid, integer) from public, anon, authenticated;
revoke execute on function private.job_succeed(text, bigint, uuid, integer) from public, anon, authenticated;
revoke execute on function private.job_fail(text, bigint, uuid, text) from public, anon, authenticated;
revoke execute on function private.job_retry(text, bigint, uuid, text, integer) from public, anon, authenticated;
revoke execute on function private.job_heartbeat(text, bigint, uuid, integer) from public, anon, authenticated;
revoke execute on function private.job_stop(text, bigint, uuid) from public, anon, authenticated;

grant usage on schema private to worker_role;
grant execute on function private.release_job_credits(uuid, text) to worker_role;
grant execute on function private.job_start(text, bigint, uuid, integer) to worker_role;
grant execute on function private.job_succeed(text, bigint, uuid, integer) to worker_role;
grant execute on function private.job_fail(text, bigint, uuid, text) to worker_role;
grant execute on function private.job_retry(text, bigint, uuid, text, integer) to worker_role;
grant execute on function private.job_heartbeat(text, bigint, uuid, integer) to worker_role;
grant execute on function private.job_stop(text, bigint, uuid) to worker_role;
