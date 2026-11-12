-- task-012 작업 생성·큐·워커 전이·크레딧 원장·스위퍼 통합 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/jobs_queue.sql
-- 전체를 한 트랜잭션으로 돌리고 ROLLBACK 한다(job-test-* 사용자·작업·큐 메시지는 남지 않는다).
-- 워커 단계는 worker_login(= worker_role 권한)으로 실행한다. 워커는 원장을 읽지 못하므로
-- 워커 블록은 결과를 t_res 에 남기고, 확인은 소유자 권한 블록에서 한다.
-- 큐 메시지는 job_id 조건부 read로만 집어 다른 작업의 메시지를 건드리지 않는다.
begin;

-- 테스트 중에만 postgres가 worker_login으로 SET ROLE 할 수 있게(롤백됨)
grant worker_login to postgres with set true;

-- ── 준비(소유자 권한) ────────────────────────────────────────
insert into auth.users (id, aud, role, email)
values
  ('00000000-0000-4000-c000-00000000000a', 'authenticated', 'authenticated', 'job-test-a@example.com'),
  ('00000000-0000-4000-c000-00000000000b', 'authenticated', 'authenticated', 'job-test-b@example.com');

insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-c100-00000000000a', '00000000-0000-4000-c000-00000000000a', 'youtube', 'job-test A'),
  ('00000000-0000-4000-c100-00000000000b', '00000000-0000-4000-c000-00000000000b', 'youtube', 'job-test B');

insert into public.projects (id, user_id, account_id, name, step_status) values
  ('00000000-0000-4000-c200-00000000000a', '00000000-0000-4000-c000-00000000000a',
   '00000000-0000-4000-c100-00000000000a', 'job-test A 프로젝트',
   '{"1":"approved","2":"approved","3":"approved","4":"ready","5":"idle","6":"idle"}'),
  -- A2: 05 편집 진행 중(render), A3: 02 소스 진행 중(collect)
  ('00000000-0000-4000-c200-0000000000a2', '00000000-0000-4000-c000-00000000000a',
   '00000000-0000-4000-c100-00000000000a', 'job-test A2 프로젝트',
   '{"1":"approved","2":"approved","3":"approved","4":"approved","5":"ready","6":"idle"}'),
  ('00000000-0000-4000-c200-0000000000a3', '00000000-0000-4000-c000-00000000000a',
   '00000000-0000-4000-c100-00000000000a', 'job-test A3 프로젝트',
   '{"1":"approved","2":"ready","3":"idle","4":"idle","5":"idle","6":"idle"}'),
  ('00000000-0000-4000-c200-00000000000b', '00000000-0000-4000-c000-00000000000b',
   '00000000-0000-4000-c100-00000000000b', 'job-test B 프로젝트',
   '{"1":"approved","2":"approved","3":"approved","4":"approved","5":"ready","6":"idle"}');

-- A: 충전 200 크레딧, B: 0 크레딧
insert into public.credit_ledger (user_id, kind, delta, reason, idempotency_key) values
  ('00000000-0000-4000-c000-00000000000a', 'charge', 200, 'job-test', 'job-test-charge-a');

create temporary table t_ids (name text primary key, id uuid) on commit drop;
create temporary table t_res (k text primary key, v text) on commit drop;
grant select, insert on t_ids to authenticated, worker_role;
grant select, insert on t_res to worker_role;

create function pg_temp.balance(p_user uuid) returns int language sql as
  $$ select coalesce(sum(delta), 0)::int from public.credit_ledger where user_id = p_user $$;
create function pg_temp.job(p_name text) returns uuid language sql as
  $$ select id from t_ids where name = p_name $$;
create function pg_temp.final_count(p_job uuid) returns int language sql as
  $$ select count(*)::int from public.credit_ledger where job_id = p_job and kind in ('settle', 'release') $$;
grant execute on function pg_temp.job(text) to authenticated, worker_role;

-- ── 사용자 A 세션 ───────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-c000-00000000000a","role":"authenticated"}', true);

do $$
declare r1 jsonb; r2 jsonb; v_count int;
begin
  -- 중복 요청 1건만 생성
  r1 := public.create_job('00000000-0000-4000-c200-0000000000a2', 'render', 'job-test-render-1', '{"cut":1}');
  r2 := public.create_job('00000000-0000-4000-c200-0000000000a2', 'render', 'job-test-render-1', '{"cut":1}');
  if (r1 ->> 'id') <> (r2 ->> 'id') then raise exception 'FAIL: 같은 키인데 다른 작업'; end if;
  if (r1 ->> 'created')::boolean is not true or (r2 ->> 'created')::boolean is not false then
    raise exception 'FAIL: created 플래그 (%, %)', r1 ->> 'created', r2 ->> 'created';
  end if;
  if r1 ->> 'status' <> 'queued' or (r1 ->> 'step')::int <> 5 then raise exception 'FAIL: 초기 상태·단계 %', r1; end if;
  select count(*) into v_count from public.jobs where idempotency_key like '%:job-test-render-1';
  if v_count <> 1 then raise exception 'FAIL: 중복 요청으로 작업 % 건', v_count; end if;
  insert into t_ids values ('render1', (r1 ->> 'id')::uuid);
  raise notice 'PASS 1 같은 멱등 키 2회 → 작업 1건, 같은 id 반환';

  -- 수집은 큐에 넣지 않고 waiting_extension
  r1 := public.create_job('00000000-0000-4000-c200-0000000000a3', 'collect', 'job-test-collect-1');
  if r1 ->> 'status' <> 'waiting_extension' then raise exception 'FAIL: 수집 초기 상태 %', r1 ->> 'status'; end if;
  insert into t_ids values ('collect1', (r1 ->> 'id')::uuid);

  insert into t_ids values
    ('tts_fail', (public.create_job('00000000-0000-4000-c200-00000000000a', 'tts', 'job-test-tts-fail') ->> 'id')::uuid),
    ('render_cancel', (public.create_job('00000000-0000-4000-c200-0000000000a2', 'render', 'job-test-render-cancel') ->> 'id')::uuid),
    ('tts_retry', (public.create_job('00000000-0000-4000-c200-00000000000a', 'tts', 'job-test-tts-retry') ->> 'id')::uuid);
  raise notice 'PASS 2 수집 작업은 waiting_extension, 큐 작업 queued';

  -- 단계 위반: 앞 단계 미승인(A: 04 ready 인데 render=05), 이미 승인된 단계(A2: 04 approved 인데 tts=04)
  begin
    perform public.create_job('00000000-0000-4000-c200-00000000000a', 'render', 'job-test-step-early');
    raise exception 'FAIL: 앞 단계 미승인인데 생성';
  exception when sqlstate '55000' then null;
  end;
  begin
    perform public.create_job('00000000-0000-4000-c200-0000000000a2', 'tts', 'job-test-step-approved');
    raise exception 'FAIL: 승인된 단계에 생성';
  exception when sqlstate '55000' then null;
  end;
  -- 같은 키 재요청인데 종류·프로젝트가 다르면 거부
  begin
    perform public.create_job('00000000-0000-4000-c200-00000000000a', 'tts', 'job-test-render-1');
    raise exception 'FAIL: 같은 키로 다른 작업 생성';
  exception when sqlstate 'JK001' then null;
  end;
  -- 큐 직접 send 거부(send 는 create_job 경로만)
  begin
    perform pgmq.send('render', '{"job_id":"00000000-0000-0000-0000-000000000000"}');
    raise exception 'FAIL: authenticated 가 pgmq.send 직접 호출';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS 2b 단계 위반 55000(앞 단계 미승인·이미 승인), 키 충돌 JK001, pgmq.send 직접 호출 거부';
end $$;
reset role;

do $$
declare v_count int;
begin
  select count(*) into v_count from pgmq.q_render where message ->> 'job_id' = pg_temp.job('render1')::text;
  if v_count <> 1 then raise exception 'FAIL: render 큐 메시지 % 건(1건이어야)', v_count; end if;
  select count(*) into v_count from public.credit_ledger
  where job_id = pg_temp.job('render1') and kind = 'reserve' and delta = -30;
  if v_count <> 1 then raise exception 'FAIL: reserve 기록 % 건', v_count; end if;
  if exists (select 1 from pgmq.q_render where message ->> 'job_id' = pg_temp.job('collect1')::text) then
    raise exception 'FAIL: 수집 작업이 큐에 들어감';
  end if;
  -- 200 - render 30 - collect 0 - tts 10 - render 30 - tts 10
  if pg_temp.balance('00000000-0000-4000-c000-00000000000a') <> 120 then
    raise exception 'FAIL: 예약 후 잔액 %', pg_temp.balance('00000000-0000-4000-c000-00000000000a');
  end if;
  raise notice 'PASS 3 생성과 같은 트랜잭션에서 pgmq.send 1건 + reserve 1건, 잔액 120';
end $$;

-- ── 잔액 부족이면 시작 전 거부(B: 0 크레딧) ──────────────────
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-c000-00000000000b","role":"authenticated"}', true);
do $$
declare v_detail text;
begin
  begin
    perform public.create_job('00000000-0000-4000-c200-00000000000b', 'render', 'job-test-render-b');
    raise exception 'FAIL: 잔액 0인데 생성됨';
  exception when sqlstate 'CR001' then
    get stacked diagnostics v_detail = pg_exception_detail;
    if (v_detail::jsonb ->> 'required')::int <> 30 or (v_detail::jsonb ->> 'balance')::int <> 0 then
      raise exception 'FAIL: 부족 안내 detail %', v_detail;
    end if;
  end;
  begin
    perform public.create_job('00000000-0000-4000-c200-0000000000a2', 'render', 'job-test-render-x');
    raise exception 'FAIL: B가 A 프로젝트에 작업 생성';
  exception when insufficient_privilege then null;
  end;
  -- 키는 사용자 단위: B가 A와 같은 키를 써도 A 작업을 받지 않고 B 기준으로 판단(잔액 0 → CR001)
  begin
    perform public.create_job('00000000-0000-4000-c200-00000000000b', 'render', 'job-test-render-1');
    raise exception 'FAIL: B가 A의 멱등 키로 A 작업을 받음';
  exception when sqlstate 'CR001' then null;
  end;
  begin
    perform private.settle_job(pg_temp.job('render1'));
    raise exception 'FAIL: 사용자가 settle_job 호출';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS 4 잔액 부족 → CR001(필요 30·잔액 0), 타인 프로젝트·타인 멱등 키·사용자 정산 호출 거부';
end $$;
reset role;
do $$
begin
  if exists (select 1 from public.jobs where idempotency_key like '%:job-test-render-b') then
    raise exception 'FAIL: 거부됐는데 작업 행이 남음';
  end if;
end $$;

-- ── 워커(worker_login) 1: 성공·이중 settle, 영구 실패, 재시도 소진, 실행 중 취소 준비 ──
set local role worker_login;
do $$
declare m record; r jsonb; i int; v_job uuid;
begin
  -- 성공 → settle, 같은 작업 두 번째 성공 처리는 false
  v_job := pg_temp.job('render1');
  select * into m from pgmq.read('render', 720, 1, jsonb_build_object('job_id', v_job));
  if m.msg_id is null then raise exception 'FAIL: 워커가 메시지를 못 읽음'; end if;
  r := private.job_start('render', m.msg_id, v_job, m.read_ct);
  if r ->> 'action' <> 'run' or (r -> 'payload' ->> 'cut')::int <> 1 then raise exception 'FAIL: job_start %', r; end if;
  if (select status from public.jobs where id = v_job) <> 'running' then raise exception 'FAIL: running 전이 안 됨'; end if;
  if private.job_heartbeat('render', m.msg_id, v_job, 720) <> 'running' then raise exception 'FAIL: heartbeat'; end if;
  if not private.job_succeed('render', m.msg_id, v_job) then raise exception 'FAIL: job_succeed false'; end if;
  if private.job_succeed('render', m.msg_id, v_job) then raise exception 'FAIL: 두 번째 job_succeed true'; end if;
  if private.settle_job(v_job) then raise exception 'FAIL: 이중 settle_job true'; end if;
  if private.release_job(v_job) then raise exception 'FAIL: settle 뒤 release_job true'; end if;
  insert into t_res values ('render1_msg', m.msg_id::text);

  -- 영구 실패 → failed + release
  v_job := pg_temp.job('tts_fail');
  select * into m from pgmq.read('tts', 720, 1, jsonb_build_object('job_id', v_job));
  r := private.job_start('tts', m.msg_id, v_job, m.read_ct);
  if r ->> 'action' <> 'run' then raise exception 'FAIL: job_start %', r; end if;
  perform private.job_fail('tts', m.msg_id, v_job, '입력 오류: 지원하지 않는 목소리');

  -- 일시 오류 3회 → 4번째 읽기(read_ct>3)에서 failed + release
  v_job := pg_temp.job('tts_retry');
  for i in 1..3 loop
    select * into m from pgmq.read('tts', 720, 1, jsonb_build_object('job_id', v_job));
    if m.read_ct <> i then raise exception 'FAIL: read_ct % (기대 %)', m.read_ct, i; end if;
    r := private.job_start('tts', m.msg_id, v_job, m.read_ct);
    if r ->> 'action' <> 'run' then raise exception 'FAIL: %번째 job_start %', i, r; end if;
    if not private.job_retry('tts', m.msg_id, v_job, '일시 오류: 공급자 503', 0) then
      raise exception 'FAIL: job_retry false';
    end if;
    if (select status from public.jobs where id = v_job) <> 'queued' then raise exception 'FAIL: 재시도 대기 queued 아님'; end if;
  end loop;
  select * into m from pgmq.read('tts', 720, 1, jsonb_build_object('job_id', v_job));
  r := private.job_start('tts', m.msg_id, v_job, m.read_ct);
  if r ->> 'action' <> 'failed' then raise exception 'FAIL: 4번째 읽기 %', r; end if;

  -- 실행 중 취소 준비: running 까지
  v_job := pg_temp.job('render_cancel');
  select * into m from pgmq.read('render', 720, 1, jsonb_build_object('job_id', v_job));
  r := private.job_start('render', m.msg_id, v_job, m.read_ct);
  if r ->> 'action' <> 'run' then raise exception 'FAIL: job_start %', r; end if;
  insert into t_res values ('cancel_msg', m.msg_id::text);
end $$;
reset role;

do $$
declare v_job uuid;
begin
  v_job := pg_temp.job('render1');
  if (select status from public.jobs where id = v_job) <> 'succeeded' then raise exception 'FAIL: succeeded 아님'; end if;
  if pg_temp.final_count(v_job) <> 1 then raise exception 'FAIL: 정산 기록 1건 아님'; end if;
  -- 정산액 = 예약액: 작업 순 차감 = reserve 금액(30)
  if (select sum(delta) from public.credit_ledger where job_id = v_job) <> -30
     or (select delta from public.credit_ledger where job_id = v_job and kind = 'settle') <> 0 then
    raise exception 'FAIL: settle 금액이 예약액과 다름';
  end if;
  if exists (select 1 from pgmq.q_render where msg_id = (select v::bigint from t_res where k = 'render1_msg')) then
    raise exception 'FAIL: 성공 메시지 archive 안 됨';
  end if;
  begin
    insert into public.credit_ledger (user_id, project_id, job_id, kind, delta, idempotency_key)
    values ('00000000-0000-4000-c000-00000000000a', '00000000-0000-4000-c200-0000000000a2', v_job,
            'settle', 0, 'job-test-settle-dup');
    raise exception 'FAIL: 이중 settle 행 허용';
  exception when unique_violation then null;
  end;
  raise notice 'PASS 5 read → running → succeeded + settle 1건(정산액 = 예약 30) + archive, 이중 settle 거부';

  v_job := pg_temp.job('tts_fail');
  if (select status from public.jobs where id = v_job) <> 'failed' then raise exception 'FAIL: failed 아님'; end if;
  if (select delta from public.credit_ledger where job_id = v_job and kind = 'release') <> 10 then
    raise exception 'FAIL: 실패 release 없음';
  end if;
  raise notice 'PASS 6 영구 실패 → failed + release(+10) + archive';

  v_job := pg_temp.job('tts_retry');
  if (select status || ':' || attempts from public.jobs where id = v_job) <> 'failed:3' then
    raise exception 'FAIL: 재시도 소진 상태 %', (select status || ':' || attempts from public.jobs where id = v_job);
  end if;
  if pg_temp.final_count(v_job) <> 1 or not exists
     (select 1 from public.credit_ledger where job_id = v_job and kind = 'release') then
    raise exception 'FAIL: 재시도 소진 release 없음';
  end if;
  if exists (select 1 from pgmq.q_tts where message ->> 'job_id' = v_job::text) then
    raise exception 'FAIL: 소진 메시지 archive 안 됨';
  end if;
  raise notice 'PASS 7 일시 오류 3회 재시도(read_ct 1~3) → read_ct>3 → failed + release + archive';
end $$;

-- ── 실행 중 취소: 사용자가 앞 단계 변경 → 워커 하트비트에서 canceled 감지 → release + archive ──
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-c000-00000000000a","role":"authenticated"}', true);
select public.request_step_change('00000000-0000-4000-c200-0000000000a2', 4) is not null as step_changed;
reset role;

set local role worker_login;
do $$
declare v_job uuid := pg_temp.job('render_cancel');
        v_msg bigint := (select v::bigint from t_res where k = 'cancel_msg');
        v_status text;
begin
  v_status := private.job_heartbeat('render', v_msg, v_job, 720);
  if v_status <> 'canceled' then raise exception 'FAIL: 하트비트 상태 % (canceled여야)', v_status; end if;
  perform private.job_stop('render', v_msg, v_job);
  if private.job_succeed('render', v_msg, v_job) then raise exception 'FAIL: 취소 뒤 succeed'; end if;
end $$;
reset role;

do $$
declare v_job uuid := pg_temp.job('render_cancel');
begin
  if (select status from public.jobs where id = v_job) <> 'canceled' then raise exception 'FAIL: 취소 상태 유지 안 됨'; end if;
  if pg_temp.final_count(v_job) <> 1 or (select delta from public.credit_ledger where job_id = v_job and kind = 'release') <> 30 then
    raise exception 'FAIL: 취소 release 1건(+30) 아님';
  end if;
  raise notice 'PASS 8 실행 중 취소 → canceled 유지, 하트비트 감지 → release(+30) + archive, 이후 succeed 거부';
end $$;

-- ── 워커 권한 경계 ──────────────────────────────────────────
set local role worker_login;
do $$
begin
  begin
    insert into public.credit_ledger (user_id, job_id, kind, delta, idempotency_key)
    values ('00000000-0000-4000-c000-00000000000b', null, 'release', 1000, 'job-test-worker-release');
    raise exception 'FAIL: 워커가 원장 직접 INSERT';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.credit_ledger limit 1;
    raise exception 'FAIL: 워커가 원장 읽음';
  exception when insufficient_privilege then null;
  end;
  begin
    perform pgmq.send('render', '{"job_id":"00000000-0000-0000-0000-000000000000"}');
    raise exception 'FAIL: 워커가 send 함';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.jobs set payload = '{}' where id = pg_temp.job('collect1');
    raise exception 'FAIL: 워커가 payload 수정';
  exception when insufficient_privilege then null;
  end;
  begin
    perform project_id from public.jobs limit 1;
    raise exception 'FAIL: 워커가 허용 밖 jobs 열(project_id) 읽음';
  exception when insufficient_privilege then null;
  end;
  -- 임의 사용자 정산 불가: 함수는 job_id만 받고, running 아닌 작업·없는 작업은 거부
  if private.settle_job(pg_temp.job('collect1')) then raise exception 'FAIL: waiting 작업 settle'; end if;
  if private.settle_job('00000000-0000-4000-c000-00000000000b') then raise exception 'FAIL: 없는 작업 settle'; end if;
  if private.release_job(pg_temp.job('collect1')) then raise exception 'FAIL: waiting 작업 release'; end if;
  raise notice 'PASS 9 worker_login: 원장 INSERT·SELECT, send, payload 수정, 허용 밖 열 읽기 거부, 비대상 작업 정산·반환 거부';
end $$;
reset role;

-- ── 스위퍼: 시간 초과 running → failed + release, 확장 대기 24시간 → failed ──
do $$
declare v_job uuid; v_collect uuid := pg_temp.job('collect1'); r jsonb;
begin
  insert into public.jobs (project_id, step, type, status, idempotency_key, started_at)
  values ('00000000-0000-4000-c200-00000000000a', 4, 'tts', 'running', 'job-test-tts-timeout',
          now() - interval '3 minutes')
  returning id into v_job;
  insert into public.credit_ledger (user_id, project_id, job_id, kind, delta, idempotency_key)
  values ('00000000-0000-4000-c000-00000000000a', '00000000-0000-4000-c200-00000000000a', v_job,
          'reserve', -10, 'job-test-reserve-timeout');
  update public.jobs set created_at = now() - interval '25 hours' where id = v_collect;

  r := private.sweep_jobs();
  if (select status || ':' || error from public.jobs where id = v_job) <> 'failed:시간 초과' then
    raise exception 'FAIL: 시간 초과 처리 안 됨 %', r;
  end if;
  if (select delta from public.credit_ledger where job_id = v_job and kind = 'release') <> 10 then
    raise exception 'FAIL: 시간 초과 release 없음';
  end if;
  if (select status from public.jobs where id = v_collect) <> 'failed' then
    raise exception 'FAIL: 대기 24시간 처리 안 됨';
  end if;
  if (select count(*) from cron.job where jobname = 'sweep-jobs' and schedule = '* * * * *') <> 1 then
    raise exception 'FAIL: pg_cron 1분 스케줄 없음';
  end if;
  r := private.sweep_jobs();
  if pg_temp.final_count(v_job) <> 1 then raise exception 'FAIL: 스위퍼 반복 시 release 중복'; end if;
  raise notice 'PASS 10 스위퍼: 시간 초과·대기 만료 → failed + release(반복 실행해도 1건), pg_cron 1분 등록';

  -- 200 - render1 30(정산) = 170. 실패·취소·재시도 소진·시간 초과는 모두 반환, collect 0
  if pg_temp.balance('00000000-0000-4000-c000-00000000000a') <> 170 then
    raise exception 'FAIL: 최종 잔액 %', pg_temp.balance('00000000-0000-4000-c000-00000000000a');
  end if;
  raise notice 'PASS 11 최종 잔액 170 = 충전 200 - 성공 작업 30';
end $$;

rollback;
