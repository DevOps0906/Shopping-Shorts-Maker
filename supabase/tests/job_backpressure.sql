-- task-035 작업 큐 병목 대응 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/job_backpressure.sql
-- 전체를 한 트랜잭션으로 돌리고 ROLLBACK 한다. 큐 메시지는 job_id 조건부 read 로만 집는다.
begin;

grant worker_login to postgres with set true;

insert into auth.users (id, aud, role, email) values
  ('00000000-0000-4000-c000-0000000000b1', 'authenticated', 'authenticated', 'bp-test-a@example.com'),
  ('00000000-0000-4000-c000-0000000000b2', 'authenticated', 'authenticated', 'bp-test-b@example.com');

insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-c100-0000000000b1', '00000000-0000-4000-c000-0000000000b1', 'youtube', 'bp-test A'),
  ('00000000-0000-4000-c100-0000000000b2', '00000000-0000-4000-c000-0000000000b2', 'youtube', 'bp-test B');

-- 사용자 A 프로젝트 4개(모두 05 편집 가능), 사용자 B 1개. render 상한 3.
insert into public.projects (id, user_id, account_id, name, step_status) values
  ('00000000-0000-4000-c200-0000000000b1', '00000000-0000-4000-c000-0000000000b1', '00000000-0000-4000-c100-0000000000b1', 'bp A1',
   '{"1":"approved","2":"approved","3":"approved","4":"approved","5":"ready","6":"idle"}'),
  ('00000000-0000-4000-c200-0000000000b2', '00000000-0000-4000-c000-0000000000b1', '00000000-0000-4000-c100-0000000000b1', 'bp A2',
   '{"1":"approved","2":"approved","3":"approved","4":"approved","5":"ready","6":"idle"}'),
  ('00000000-0000-4000-c200-0000000000b3', '00000000-0000-4000-c000-0000000000b1', '00000000-0000-4000-c100-0000000000b1', 'bp A3',
   '{"1":"approved","2":"approved","3":"approved","4":"approved","5":"ready","6":"idle"}'),
  ('00000000-0000-4000-c200-0000000000b4', '00000000-0000-4000-c000-0000000000b1', '00000000-0000-4000-c100-0000000000b1', 'bp A4',
   '{"1":"approved","2":"approved","3":"approved","4":"approved","5":"ready","6":"idle"}'),
  ('00000000-0000-4000-c200-0000000000b5', '00000000-0000-4000-c000-0000000000b2', '00000000-0000-4000-c100-0000000000b2', 'bp B1',
   '{"1":"approved","2":"approved","3":"approved","4":"approved","5":"ready","6":"idle"}');

insert into public.credit_ledger (user_id, kind, delta, reason, idempotency_key) values
  ('00000000-0000-4000-c000-0000000000b1', 'charge', 500, 'bp-test', 'bp-test-charge-a'),
  ('00000000-0000-4000-c000-0000000000b2', 'charge', 500, 'bp-test', 'bp-test-charge-b');

create temporary table t_ids (name text primary key, id uuid) on commit drop;
grant select, insert on t_ids to authenticated, worker_role;
create function pg_temp.job(p_name text) returns uuid language sql as $$ select id from t_ids where name = p_name $$;
create function pg_temp.balance(p_user uuid) returns int language sql as
  $$ select coalesce(sum(delta), 0)::int from public.credit_ledger where user_id = p_user $$;
grant execute on function pg_temp.job(text) to authenticated, worker_role;

-- ── 사용자 A: render 3건까지 생성, 4번째는 JQ001 ───────────────
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c000-0000000000b1","role":"authenticated"}', true);

do $$
declare r jsonb; v_before int; v_after int;
begin
  insert into t_ids values
    ('a1', (public.create_job('00000000-0000-4000-c200-0000000000b1', 'render', 'bp-test-render-1') ->> 'id')::uuid),
    ('a2', (public.create_job('00000000-0000-4000-c200-0000000000b2', 'render', 'bp-test-render-2') ->> 'id')::uuid),
    ('a3', (public.create_job('00000000-0000-4000-c200-0000000000b3', 'render', 'bp-test-render-3') ->> 'id')::uuid);

  select coalesce(sum(delta), 0)::int into v_before from public.credit_ledger
    where user_id = '00000000-0000-4000-c000-0000000000b1';
  begin
    perform public.create_job('00000000-0000-4000-c200-0000000000b4', 'render', 'bp-test-render-4');
    raise exception 'FAIL: 상한(3) 초과인데 생성됨';
  exception when sqlstate 'JQ001' then null;
  end;
  select coalesce(sum(delta), 0)::int into v_after from public.credit_ledger
    where user_id = '00000000-0000-4000-c000-0000000000b1';
  if v_before <> v_after then raise exception 'FAIL: JQ001 인데 크레딧 변화 % → %', v_before, v_after; end if;
  if exists (select 1 from public.jobs where idempotency_key like '%:bp-test-render-4') then
    raise exception 'FAIL: JQ001 인데 작업 행 생성됨';
  end if;
  raise notice 'PASS 1 render 상한 초과 → JQ001, 크레딧·작업 변화 0';

  r := public.create_job('00000000-0000-4000-c200-0000000000b1', 'render', 'bp-test-render-1');
  if (r ->> 'created')::boolean is not false or (r ->> 'id')::uuid <> pg_temp.job('a1') then
    raise exception 'FAIL: 상한 상태에서 같은 멱등 키가 기존 작업을 못 돌려줌 %', r;
  end if;
  raise notice 'PASS 2 상한이어도 같은 멱등 키는 기존 작업 반환';
end $$;

-- 사용자 B: A 의 대기와 무관하게 생성
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c000-0000000000b2","role":"authenticated"}', true);
do $$
begin
  insert into t_ids values
    ('b1', (public.create_job('00000000-0000-4000-c200-0000000000b5', 'render', 'bp-test-render-b1') ->> 'id')::uuid);
  raise notice 'PASS 3 다른 사용자는 상한 영향 없음';
end $$;
reset role;

-- ── 워커: 같은 사용자 두 번째 render 는 deferred ──────────────
set local role worker_login;
do $$
declare m record; r jsonb; v_attempts int; v_rc int; v_vt timestamptz; v_msg bigint;
begin
  -- a1 시작
  select * into m from pgmq.read('render', 720, 1, jsonb_build_object('job_id', pg_temp.job('a1')));
  r := private.job_start('render', m.msg_id, pg_temp.job('a1'), m.read_ct);
  if r ->> 'action' <> 'run' then raise exception 'FAIL: a1 시작 %', r; end if;

  -- a2: 같은 사용자 render running → deferred
  select * into m from pgmq.read('render', 720, 1, jsonb_build_object('job_id', pg_temp.job('a2')));
  if m.read_ct <> 1 then raise exception 'FAIL: a2 read_ct % (기대 1)', m.read_ct; end if;
  r := private.job_start('render', m.msg_id, pg_temp.job('a2'), m.read_ct);
  if r ->> 'action' <> 'deferred' then raise exception 'FAIL: a2 deferred 아님 %', r; end if;
  select attempts into v_attempts from public.jobs where id = pg_temp.job('a2');
  if v_attempts <> 0 or (select status from public.jobs where id = pg_temp.job('a2')) <> 'queued' then
    raise exception 'FAIL: deferred 인데 attempts·status 변함';
  end if;
  select read_ct, vt into v_rc, v_vt from pgmq.q_render where msg_id = m.msg_id;
  if v_rc <> 0 then raise exception 'FAIL: deferred 뒤 read_ct % (0 으로 되돌려야)', v_rc; end if;
  if v_vt < clock_timestamp() + interval '10 seconds' or v_vt > clock_timestamp() + interval '40 seconds' then
    raise exception 'FAIL: deferred vt % (약 20초 뒤여야)', v_vt;
  end if;
  raise notice 'PASS 4 같은 사용자 두 번째 render → deferred, attempts·read_ct 불변, vt 20초';

  -- 미룸이 반복돼도 read_ct 기반 실패(> max_attempts 3)로 가지 않는다
  for i in 1..6 loop
    update pgmq.q_render set vt = clock_timestamp() where msg_id = m.msg_id;
    select * into m from pgmq.read('render', 720, 1, jsonb_build_object('job_id', pg_temp.job('a2')));
    r := private.job_start('render', m.msg_id, pg_temp.job('a2'), m.read_ct);
    if r ->> 'action' <> 'deferred' then raise exception 'FAIL: %번째 재시도 %', i, r; end if;
  end loop;
  if (select status from public.jobs where id = pg_temp.job('a2')) <> 'queued' then
    raise exception 'FAIL: 반복 deferred 뒤 작업이 실패 처리됨';
  end if;
  raise notice 'PASS 5 deferred 6회 반복해도 failed 아님';

  -- 다른 사용자 render 는 시작
  select * into m from pgmq.read('render', 720, 1, jsonb_build_object('job_id', pg_temp.job('b1')));
  r := private.job_start('render', m.msg_id, pg_temp.job('b1'), m.read_ct);
  if r ->> 'action' <> 'run' then raise exception 'FAIL: 다른 사용자 render 시작 %', r; end if;
  raise notice 'PASS 6 다른 사용자 render 는 동시에 시작';

  -- a1 이 끝나면 a2 시작
  select msg_id into v_msg from pgmq.q_render where message ->> 'job_id' = pg_temp.job('a1')::text;
  if not private.job_succeed('render', v_msg, pg_temp.job('a1')) then raise exception 'FAIL: a1 성공 처리'; end if;
  update pgmq.q_render set vt = clock_timestamp() where message ->> 'job_id' = pg_temp.job('a2')::text;
  select * into m from pgmq.read('render', 720, 1, jsonb_build_object('job_id', pg_temp.job('a2')));
  r := private.job_start('render', m.msg_id, pg_temp.job('a2'), m.read_ct);
  if r ->> 'action' <> 'run' then raise exception 'FAIL: a1 종료 뒤 a2 시작 %', r; end if;
  raise notice 'PASS 7 앞 작업이 끝나면 같은 사용자의 다음 작업 시작';
end $$;
reset role;

-- ── queue_health: service_role 만 ───────────────────────────
do $$
declare v_rows int;
begin
  select count(*) into v_rows from public.queue_health();
  if v_rows <> 3 then raise exception 'FAIL: queue_health 행 % (3 이어야)', v_rows; end if;
  if not has_function_privilege('service_role', 'public.queue_health()', 'execute') then
    raise exception 'FAIL: service_role 실행 불가';
  end if;
  if has_function_privilege('authenticated', 'public.queue_health()', 'execute')
     or has_function_privilege('anon', 'public.queue_health()', 'execute') then
    raise exception 'FAIL: authenticated·anon 이 queue_health 실행 가능';
  end if;
  if (select running from public.queue_health() where queue_name = 'render') < 2 then
    raise exception 'FAIL: queue_health running 집계';
  end if;
  raise notice 'PASS 8 queue_health: service_role 만 실행, authenticated·anon 불가';
end $$;

set local role authenticated;
do $$
begin
  perform public.queue_health();
  raise exception 'FAIL: authenticated 가 queue_health 실행';
exception when insufficient_privilege then null;
end $$;
reset role;

rollback;
