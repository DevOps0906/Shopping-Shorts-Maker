-- task-012: 시간 초과 스위퍼(pg_cron 1분) — ADR-0001 "시간 초과 감시는 스위퍼 함수 한 곳"
-- 상한(가설, 17-5): 음성 2분 · 렌더 10분 · 분석 5분(가설, 팀장 확인) · 수집 15분 · 확장 하트비트 2분 · 확장 대기 24시간
-- - 조건부 갱신(status 조건) + release. 워커는 다음 하트비트에서 running이 아님을 보고 중단·archive 한다.
-- - 취소·실패됐는데 반환(release)이 빠진 작업(예: request_step_change 취소)도 여기서 반환한다.
-- - pg_cron은 스케줄을 등록한 역할(postgres = 테이블 소유자)로 실행된다.

create extension if not exists pg_cron;

create function private.job_time_limit(p_type text)
returns interval
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'tts' then interval '2 minutes'
    when 'render' then interval '10 minutes'
    when 'analyze' then interval '5 minutes'
    when 'collect' then interval '15 minutes'
  end;
$$;

create function private.sweep_jobs()
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
  -- 1) 실행 시간 초과
  with t as (
    update public.jobs j
    set status = 'failed', finished_at = now(), error = '시간 초과'
    where j.status = 'running'
      and j.started_at < now() - private.job_time_limit(j.type)
    returning j.id
  )
  select count(*) into v_timed_out from t;

  -- 2) 수집 중 확장 하트비트 끊김(2분)
  with t as (
    update public.jobs j
    set status = 'failed', finished_at = now(), error = '확장 연결이 끊겼습니다'
    from public.extension_connections e
    where j.status = 'running' and j.type = 'collect'
      and e.id = j.extension_id
      and coalesce(e.last_heartbeat_at, j.started_at) < now() - interval '2 minutes'
    returning j.id
  )
  select count(*) into v_stale from t;

  -- 3) 확장 대기 24시간
  with t as (
    update public.jobs j
    set status = 'failed', finished_at = now(), error = '확장 대기 시간 초과'
    where j.status = 'waiting_extension' and j.created_at < now() - interval '24 hours'
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

revoke execute on function private.job_time_limit(text) from public, anon, authenticated;
revoke execute on function private.sweep_jobs() from public, anon, authenticated;

-- 이름이 같으면 갱신(재적용 안전)
select cron.schedule('sweep-jobs', '* * * * *', 'select private.sweep_jobs()');
