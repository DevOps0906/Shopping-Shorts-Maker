-- task-012 보안 리뷰 반영: 워커의 원장 직접 쓰기·읽기 회수, 정산·반환은 SECURITY DEFINER 함수로만
-- - private.settle_job / private.release_job: 사용자·프로젝트·금액을 그 작업의 reserve 행에서 도출,
--   jobs 행 FOR UPDATE 잠금 안에서 상태 확인. settle은 running→succeeded 전이와 함께, release는 failed·canceled만.
--   같은 작업에 settle·release는 합쳐 1건(부분 unique 인덱스 + 잠금). EXECUTE는 worker_role만.
-- - 정산액 = 예약액(MVP는 차감 기록만, D3): settle 행 delta = 0 으로 예약 차감을 그대로 확정한다.
--   잔액 = credit_ledger.delta 합 이므로 실제 사용량이 다르면 settle delta 로 차액을 돌려주는 방식으로 확장한다(후속).
-- - jobs 는 워커가 처리에 필요한 열만 읽는다.

-- ── 워커 원장 권한 회수 ─────────────────────────────────────
drop policy if exists credit_ledger_insert_worker on public.credit_ledger;
drop policy if exists credit_ledger_select_worker on public.credit_ledger;
revoke all on public.credit_ledger from worker_role;

-- ── jobs 열 단위 읽기 ───────────────────────────────────────
revoke select on public.jobs from worker_role;
grant select (id, step, type, status, attempts, max_attempts, payload) on public.jobs to worker_role;

-- ── 정산·반환(SECURITY DEFINER) ─────────────────────────────
create function private.settle_job(p_job_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
  v_reserve public.credit_ledger;
begin
  select status into v_status from public.jobs where id = p_job_id for update;
  if v_status is distinct from 'running' then
    return false;
  end if;

  select * into v_reserve from public.credit_ledger where job_id = p_job_id and kind = 'reserve';
  if not found then
    raise exception '예약 기록이 없는 작업입니다' using errcode = '55000';
  end if;

  update public.jobs set status = 'succeeded', finished_at = now(), error = null where id = p_job_id;

  insert into public.credit_ledger (user_id, project_id, job_id, kind, delta, reason, idempotency_key)
  values (v_reserve.user_id, v_reserve.project_id, p_job_id, 'settle', 0,
          'succeeded:' || (-v_reserve.delta), 'settle:' || p_job_id);
  return true;
end;
$$;

create function private.release_job(p_job_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
  v_count integer;
begin
  select status into v_status from public.jobs where id = p_job_id for update;
  if v_status is null or v_status not in ('failed', 'canceled') then
    return false;
  end if;

  insert into public.credit_ledger (user_id, project_id, job_id, kind, delta, reason, idempotency_key)
  select r.user_id, r.project_id, r.job_id, 'release', -r.delta, v_status, 'release:' || r.job_id
  from public.credit_ledger r
  where r.job_id = p_job_id and r.kind = 'reserve'
  on conflict do nothing;
  get diagnostics v_count = row_count;
  return v_count > 0;
end;
$$;

revoke execute on function private.settle_job(uuid) from public, anon, authenticated, service_role;
revoke execute on function private.release_job(uuid) from public, anon, authenticated, service_role;
grant execute on function private.settle_job(uuid) to worker_role;
grant execute on function private.release_job(uuid) to worker_role;

-- ── 워커 전이 함수 교체: 원장은 위 두 함수로만, jobs 는 허용 열만 ──
drop function private.job_succeed(text, bigint, uuid, integer);
drop function private.release_job_credits(uuid, text);

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

-- 성공: succeeded 전이 · settle · archive 한 트랜잭션. 이미 running이 아니면(취소·시간 초과) 결과를 버리고 false
create function private.job_succeed(p_queue text, p_msg_id bigint, p_job_id uuid)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_ok boolean;
begin
  v_ok := private.settle_job(p_job_id);
  if not v_ok then
    perform private.release_job(p_job_id);
  end if;
  perform pgmq.archive(p_queue, p_msg_id);
  return v_ok;
end;
$$;

create or replace function private.job_fail(p_queue text, p_msg_id bigint, p_job_id uuid, p_error text)
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
  perform private.release_job(p_job_id);
  perform pgmq.archive(p_queue, p_msg_id);
  return v_changed;
end;
$$;

create or replace function private.job_retry(
  p_queue text, p_msg_id bigint, p_job_id uuid, p_error text, p_delay_seconds integer)
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
    perform private.release_job(p_job_id);
    perform pgmq.archive(p_queue, p_msg_id);
    return false;
  end if;
  perform pgmq.set_vt(p_queue, p_msg_id, greatest(p_delay_seconds, 0));
  return true;
end;
$$;

create or replace function private.job_stop(p_queue text, p_msg_id bigint, p_job_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform private.release_job(p_job_id);
  perform pgmq.archive(p_queue, p_msg_id);
end;
$$;

revoke execute on function private.job_succeed(text, bigint, uuid) from public, anon, authenticated;
grant execute on function private.job_succeed(text, bigint, uuid) to worker_role;
