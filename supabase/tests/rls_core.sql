-- task-010 RLS·열 권한 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/rls_core.sql
-- 전체를 한 트랜잭션으로 돌리고 ROLLBACK 하므로 테스트 사용자(rls-test-*)는 남지 않는다.
-- 실패하면 'FAIL:' 예외로 중단된다. 통과 항목은 NOTICE 'PASS' 로 찍힌다.
begin;

insert into auth.users (id, aud, role, email)
values
  ('00000000-0000-4000-a000-00000000000a', 'authenticated', 'authenticated', 'rls-test-a@example.com'),
  ('00000000-0000-4000-a000-00000000000b', 'authenticated', 'authenticated', 'rls-test-b@example.com');

-- ── 사용자 A: 자기 채널·프로젝트 생성 ───────────────────────────
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-00000000000a","role":"authenticated"}', true);

insert into public.accounts (platform, channel_name, is_default) values ('youtube', 'A 채널', true);
insert into public.projects (account_id, name)
  select id, 'A 프로젝트' from public.accounts;

do $$
declare v_count int; v_status jsonb;
begin
  select count(*), max(step_status::text)::jsonb into v_count, v_status from public.projects;
  if v_count <> 1 then raise exception 'FAIL: A 본인 프로젝트 1행이어야 함 (%)', v_count; end if;
  if v_status->>'1' <> 'idle' then raise exception 'FAIL: step_status 초기값 idle 아님'; end if;
  raise notice 'PASS 1 A 본인 projects 생성·읽기, step_status 초기값 idle';
  select count(*) into v_count from public.categories;
  if v_count <> 10 then raise exception 'FAIL: categories 10행 아님 (%)', v_count; end if;
  select count(*) into v_count from public.trend_items;
  if v_count = 0 then raise exception 'FAIL: trend_items 읽기 0행'; end if;
  raise notice 'PASS 2 로그인 사용자 categories(10)·trend_items 읽기';
end $$;

-- A의 id를 B 테스트에 넘긴다(소유자 권한으로 조회)
reset role;
select set_config('test.a_project', (select id::text from public.projects
  where user_id = '00000000-0000-4000-a000-00000000000a'), true);
select set_config('test.a_account', (select id::text from public.accounts
  where user_id = '00000000-0000-4000-a000-00000000000a'), true);

-- ── 사용자 A: 함수 전용·서버 전용 열, 읽기 전용 테이블 쓰기 거부 ──
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-00000000000a","role":"authenticated"}', true);

do $$
declare
  a_project uuid := current_setting('test.a_project')::uuid;
  a_account uuid := current_setting('test.a_account')::uuid;
  n int := 2;
  stmts text[] := array[
    format('insert into public.projects (account_id, name, step_status) values (%L, %L, %L)',
           a_account, 'x', '{"1":"approved","2":"idle","3":"idle","4":"idle","5":"idle","6":"idle"}'),
    format('insert into public.projects (account_id, name, current_step) values (%L, %L, 6)', a_account, 'x'),
    format('update public.projects set step_status = jsonb_set(step_status, ''{1}'', ''"approved"'') where id = %L', a_project),
    format('update public.projects set current_step = 2 where id = %L', a_project),
    format('update public.projects set status = ''uploaded'' where id = %L', a_project),
    format('update public.accounts set status = ''connected'' where id = %L', a_account),
    format('update public.accounts set oauth_token_ref = gen_random_uuid() where id = %L', a_account),
    'select oauth_token_ref from public.accounts',
    'insert into public.categories (name) values (''해킹'')',
    'update public.categories set name = name || ''x''',
    'delete from public.categories',
    'truncate public.categories',
    'insert into public.trend_items (category_id, name, period) select id, ''x'', ''7d'' from public.categories limit 1',
    'update public.trend_items set sellable = false',
    format('insert into public.project_events (project_id, step, event) values (%L, 1, ''step_approved'')', a_project)
  ];
  s text;
begin
  foreach s in array stmts loop
    begin
      execute s;
      raise exception 'FAIL: 거부되어야 함: %', s;
    exception when insufficient_privilege then
      n := n + 1;
      raise notice 'PASS % 권한 거부: %', n, left(s, 70);
    end;
  end loop;
end $$;

-- ── 사용자 B: A의 데이터 읽기·쓰기 0행, 남의 account_id로 생성 실패 ──
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-00000000000b","role":"authenticated"}', true);

do $$
declare
  a_project uuid := current_setting('test.a_project')::uuid;
  a_account uuid := current_setting('test.a_account')::uuid;
  v_count int;
begin
  select count(*) into v_count from public.projects where id = a_project;
  if v_count <> 0 then raise exception 'FAIL: B가 A projects 읽음'; end if;
  select count(*) into v_count from public.accounts where id = a_account;
  if v_count <> 0 then raise exception 'FAIL: B가 A accounts 읽음'; end if;
  raise notice 'PASS 18 B → A projects·accounts 읽기 0행';

  update public.projects set name = 'B가 바꿈' where id = a_project;
  get diagnostics v_count = row_count;
  if v_count <> 0 then raise exception 'FAIL: B가 A projects 수정 (%행)', v_count; end if;
  delete from public.projects where id = a_project;
  get diagnostics v_count = row_count;
  if v_count <> 0 then raise exception 'FAIL: B가 A projects 삭제 (%행)', v_count; end if;
  update public.accounts set channel_name = 'B가 바꿈' where id = a_account;
  get diagnostics v_count = row_count;
  if v_count <> 0 then raise exception 'FAIL: B가 A accounts 수정 (%행)', v_count; end if;
  raise notice 'PASS 19 B → A projects 수정·삭제, accounts 수정 0행';

  begin
    insert into public.projects (account_id, name) values (a_account, 'B가 A 채널로');
    raise exception 'FAIL: B가 A account_id로 projects 생성';
  exception when foreign_key_violation then
    raise notice 'PASS 20 B가 남의 account_id로 projects INSERT 실패(복합 FK)';
  end;

  begin
    insert into public.projects (user_id, account_id, name)
      values ('00000000-0000-4000-a000-00000000000a', a_account, 'B가 A 명의로');
    raise exception 'FAIL: B가 A user_id로 projects 생성';
  exception when insufficient_privilege then
    raise notice 'PASS 21 B가 A user_id로 projects INSERT 실패(RLS)';
  end;
end $$;

-- ── 익명: 읽기 전용 테이블도 못 읽음 ──
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
do $$
begin
  begin
    perform 1 from public.categories;
    raise exception 'FAIL: anon이 categories 읽음';
  exception when insufficient_privilege then
    raise notice 'PASS 22 anon categories 읽기 거부';
  end;
  begin
    perform 1 from public.projects;
    raise exception 'FAIL: anon이 projects 읽음';
  exception when insufficient_privilege then
    raise notice 'PASS 23 anon projects 읽기 거부';
  end;
end $$;

-- ── 가입 → 본인 user_profiles 1행(트리거), 남의 프로필은 0행 ──
reset role;
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-00000000000a","role":"authenticated"}', true);
do $$
declare v_count int; v_email text;
begin
  select count(*), max(email) into v_count, v_email from public.user_profiles;
  if v_count <> 1 or v_email <> 'rls-test-a@example.com' then
    raise exception 'FAIL: 가입 후 본인 user_profiles 1행이어야 함 (%행, %)', v_count, v_email;
  end if;
  select count(*) into v_count from public.user_profiles
  where user_id = '00000000-0000-4000-a000-00000000000b';
  if v_count <> 0 then raise exception 'FAIL: A가 B user_profiles 읽음'; end if;
  raise notice 'PASS 24 가입 → 본인 user_profiles 1행, 남의 프로필 0행';
end $$;

reset role;
-- 모든 public 테이블 RLS 켬 확인
do $$
declare v_missing text;
begin
  select string_agg(relname, ', ') into v_missing
  from pg_class
  where relnamespace = 'public'::regnamespace and relkind in ('r', 'p') and not relrowsecurity;
  if v_missing is not null then raise exception 'FAIL: RLS 꺼진 테이블: %', v_missing; end if;
  raise notice 'PASS 25 public 모든 테이블 RLS 켬';
end $$;

rollback;

-- 테스트 데이터는 위 트랜잭션 안에서만 만들고 rollback으로 지운다(auth.users 직접 삭제 금지).
