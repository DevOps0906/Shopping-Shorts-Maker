-- task-034a 채널 연결 한도·회전 제한·초과 채널(20261113110000) 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/channel_slots.sql
-- 한 트랜잭션으로 돌리고 ROLLBACK 한다. 권한은 1)·7) 에서 역할별로, 판정은 postgres 로 public 래퍼를 불러 확인한다.
-- 사용자 C(한도 1: 한도·해제·중복) · D(한도 1: 만료) · E(한도 10: 회전) · F(초과 채널·프로젝트) · G·H(시드)
begin;

insert into auth.users (id, aud, role, email) values
  ('00000000-0000-4000-f034-00000000000c', 'authenticated', 'authenticated', 'slot-test-c@example.com'),
  ('00000000-0000-4000-f034-00000000000d', 'authenticated', 'authenticated', 'slot-test-d@example.com'),
  ('00000000-0000-4000-f034-00000000000e', 'authenticated', 'authenticated', 'slot-test-e@example.com'),
  ('00000000-0000-4000-f034-00000000000f', 'authenticated', 'authenticated', 'slot-test-f@example.com'),
  ('00000000-0000-4000-f034-0000000000aa', 'authenticated', 'authenticated', 'slot-test-g@example.com'),
  ('00000000-0000-4000-f034-0000000000bb', 'authenticated', 'authenticated', 'slot-test-h@example.com');
insert into public.accounts (id, user_id, platform, channel_name, is_default) values
  ('00000000-0000-4000-f034-0000000001c1', '00000000-0000-4000-f034-00000000000c', 'youtube', 'c1', false),
  ('00000000-0000-4000-f034-0000000001c2', '00000000-0000-4000-f034-00000000000c', 'youtube', 'c2', false),
  ('00000000-0000-4000-f034-0000000001c3', '00000000-0000-4000-f034-00000000000c', 'youtube', 'c3', false),
  ('00000000-0000-4000-f034-0000000001d1', '00000000-0000-4000-f034-00000000000d', 'youtube', 'd1', true),
  ('00000000-0000-4000-f034-0000000001d2', '00000000-0000-4000-f034-00000000000d', 'youtube', 'd2', false),
  ('00000000-0000-4000-f034-0000000001d3', '00000000-0000-4000-f034-00000000000d', 'youtube', 'd3', false),
  ('00000000-0000-4000-f034-0000000001e1', '00000000-0000-4000-f034-00000000000e', 'youtube', 'e1', false),
  ('00000000-0000-4000-f034-0000000001e2', '00000000-0000-4000-f034-00000000000e', 'youtube', 'e2', false),
  ('00000000-0000-4000-f034-0000000001e3', '00000000-0000-4000-f034-00000000000e', 'youtube', 'e3', false),
  ('00000000-0000-4000-f034-0000000001e4', '00000000-0000-4000-f034-00000000000e', 'youtube', 'e4', false),
  ('00000000-0000-4000-f034-0000000001f1', '00000000-0000-4000-f034-00000000000f', 'youtube', 'f1', false),
  ('00000000-0000-4000-f034-0000000001f2', '00000000-0000-4000-f034-00000000000f', 'youtube', 'f2', false),
  ('00000000-0000-4000-f034-0000000001f3', '00000000-0000-4000-f034-00000000000f', 'youtube', 'f3', false),
  ('00000000-0000-4000-f034-0000000001a1', '00000000-0000-4000-f034-0000000000aa', 'youtube', 'g1', false),
  ('00000000-0000-4000-f034-0000000001a2', '00000000-0000-4000-f034-0000000000aa', 'youtube', 'g2', false),
  ('00000000-0000-4000-f034-0000000001b1', '00000000-0000-4000-f034-0000000000bb', 'youtube', 'h1', false);

create function pg_temp.expect_fail(p_sql text, p_state text, p_label text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate <> p_state then
      raise exception 'FAIL: % → % (%)', p_label, sqlstate, sqlerrm;
    end if;
    return;
  end;
  raise exception 'FAIL: % 가 거부되지 않음', p_label;
end;
$$;

create function pg_temp.save(p_user uuid, p_acc uuid, p_ch text, p_tok text) returns text language sql as $$
  select public.youtube_save_connection(p_user, p_acc, p_ch, p_tok,
    array['https://www.googleapis.com/auth/youtube.upload',
          'https://www.googleapis.com/auth/youtube.readonly',
          'https://www.googleapis.com/auth/yt-analytics.readonly']);
$$;

create function pg_temp.events(p_acc uuid, p_kind text) returns int language sql as $$
  select count(*)::int from public.channel_slot_events where account_id = p_acc and kind = p_kind;
$$;

-- ── 1) 함수 속성·권한 · 테이블 권한 ───────────────────────────
do $$
declare f text; r text; v_ref text; v_acl text;
begin
  -- 바꾼·새 함수: SECURITY DEFINER + search_path 고정
  foreach f in array array[
    'private.youtube_save_connection(uuid,uuid,text,text,text[])', 'private.youtube_clear_token(uuid,uuid)',
    'private.youtube_expire_token(uuid,uuid)', 'private.channel_slot_status(uuid,uuid)',
    'private.channel_is_excess(uuid,uuid)', 'private.channel_slot_log(uuid,uuid,text)',
    'private.channel_slot_count(uuid)', 'private.channel_limit_of(uuid)', 'private.channel_quotas_seed()',
    'private.projects_channel_slot_guard()', 'public.channel_slot_status(uuid,uuid)'] loop
    if not (select p.prosecdef and coalesce(p.proconfig, '{}') @> array['search_path=""']
            from pg_proc p where p.oid = f::regprocedure) then
      raise exception 'FAIL: % SECURITY DEFINER·search_path', f;
    end if;
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then raise exception 'FAIL: % 가 % 실행 가능', r, f; end if;
    end loop;
    if (f like 'public.%') <> has_function_privilege('service_role', f, 'execute') then
      raise exception 'FAIL: service_role 권한 %', f;
    end if;
  end loop;
  -- 바꾼 함수의 ACL = 바꾸지 않은 같은 계열 함수의 ACL(본체 private · 래퍼 public)
  select string_agg(x, ',' order by x) into v_ref
  from unnest((select proacl from pg_proc where oid = 'private.youtube_refresh_token(uuid,uuid)'::regprocedure)::text[]) x;
  foreach f in array array['private.youtube_save_connection(uuid,uuid,text,text,text[])',
                           'private.youtube_clear_token(uuid,uuid)', 'private.youtube_expire_token(uuid,uuid)'] loop
    select string_agg(x, ',' order by x) into v_acl from unnest((select proacl from pg_proc where oid = f::regprocedure)::text[]) x;
    if v_acl is distinct from v_ref then raise exception 'FAIL: % ACL % ≠ %', f, v_acl, v_ref; end if;
  end loop;
  select string_agg(x, ',' order by x) into v_ref
  from unnest((select proacl from pg_proc where oid = 'public.youtube_refresh_token(uuid,uuid)'::regprocedure)::text[]) x;
  foreach f in array array['public.youtube_save_connection(uuid,uuid,text,text,text[])',
                           'public.youtube_clear_token(uuid,uuid)', 'public.youtube_expire_token(uuid,uuid)'] loop
    select string_agg(x, ',' order by x) into v_acl from unnest((select proacl from pg_proc where oid = f::regprocedure)::text[]) x;
    if v_acl is distinct from v_ref then raise exception 'FAIL: % ACL % ≠ %', f, v_acl, v_ref; end if;
  end loop;
  -- 테이블
  if not (select relrowsecurity from pg_class where oid = 'private.channel_quotas'::regclass)
     or not (select relrowsecurity from pg_class where oid = 'public.channel_slot_events'::regclass) then
    raise exception 'FAIL: RLS 꺼짐';
  end if;
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_table_privilege(r, 'private.channel_quotas', 'select,insert,update,delete') then
      raise exception 'FAIL: % 가 channel_quotas 접근 가능', r;
    end if;
    if has_table_privilege(r, 'public.channel_slot_events', 'insert,update,delete,truncate') then
      raise exception 'FAIL: % 가 channel_slot_events 쓰기 가능', r;
    end if;
  end loop;
  foreach r in array array['anon', 'authenticated'] loop
    if has_column_privilege(r, 'public.accounts', 'first_connected_at', 'insert,update')
       or has_column_privilege(r, 'public.accounts', 'disconnected_at', 'insert,update') then
      raise exception 'FAIL: % 가 accounts 새 서버 전용 열 쓰기 가능', r;
    end if;
  end loop;
  -- 읽기: 설정 화면이 만료 채널 해제 버튼을 보여 주려고 authenticated 만 연다(anon 은 계속 불가)
  if not has_column_privilege('authenticated', 'public.accounts', 'disconnected_at', 'select')
     or has_column_privilege('anon', 'public.accounts', 'disconnected_at', 'select') then
    raise exception 'FAIL: accounts 슬롯 시각 열 읽기 권한이 예상과 다름';
  end if;
  raise notice 'PASS 1 함수 SECURITY DEFINER·search_path·ACL 유지, 한도·이벤트 테이블·새 열은 사용자 쓰기 불가';
end $$;

-- ── 2) 한도 1: 두 번째 채널 거부(CS001) · Vault 증가 0 · 이벤트 1행 ──
do $$
declare s text; n_before int; n_after int;
begin
  s := pg_temp.save('00000000-0000-4000-f034-00000000000c', '00000000-0000-4000-f034-0000000001c1', 'UC-C1', 'rt-c1');
  if s <> 'connected' then raise exception 'FAIL: 첫 연결 %', s; end if;
  select count(*) into n_before from vault.secrets;
  s := pg_temp.save('00000000-0000-4000-f034-00000000000c', '00000000-0000-4000-f034-0000000001c2', 'UC-C2', 'rt-c2');
  select count(*) into n_after from vault.secrets;
  if s <> 'CS001' then raise exception 'FAIL: 한도 초과 연결 %', s; end if;
  if n_after <> n_before then raise exception 'FAIL: 거부인데 Vault % → %', n_before, n_after; end if;
  if (select (external_channel_id, oauth_token_ref, first_connected_at) from public.accounts
      where id = '00000000-0000-4000-f034-0000000001c2') is distinct from (null::text, null::uuid, null::timestamptz) then
    raise exception 'FAIL: 거부된 행이 바뀜';
  end if;
  if pg_temp.events('00000000-0000-4000-f034-0000000001c2', 'reject_limit') <> 1 then
    raise exception 'FAIL: reject_limit 이벤트 수';
  end if;
  if (select (slots, channel_limit) from public.channel_slot_events
      where account_id = '00000000-0000-4000-f034-0000000001c2') is distinct from (1, 1) then
    raise exception 'FAIL: 이벤트 슬롯·한도 값';
  end if;
  -- 사전 검사도 같은 판정
  if (select (allowed, code) from public.channel_slot_status('00000000-0000-4000-f034-00000000000c',
                                                             '00000000-0000-4000-f034-0000000001c2'))
     is distinct from (false, 'CS001'::text) then
    raise exception 'FAIL: 사전 검사 CS001';
  end if;
  if (select allowed from public.channel_slot_status('00000000-0000-4000-f034-00000000000c',
                                                     '00000000-0000-4000-f034-0000000001c1')) is not true then
    raise exception 'FAIL: 슬롯 보유 행 사전 검사';
  end if;
  raise notice 'PASS 2 한도 1에서 두 번째 채널 CS001, Vault 증가 0, reject_limit 1행, 사전 검사 일치';
end $$;
select pg_temp.expect_fail($q$select * from public.channel_slot_status('00000000-0000-4000-f034-00000000000d', '00000000-0000-4000-f034-0000000001c1')$q$,
  '42501', '남의 계정 사전 검사');

-- ── 3) 해제 → 다른 채널 · 재인증 · 해제 채널 재연결 · 만료 ─────
do $$
declare s text; v_ref uuid;
begin
  perform public.youtube_clear_token('00000000-0000-4000-f034-0000000001c1', '00000000-0000-4000-f034-00000000000c');
  if (select disconnected_at from public.accounts where id = '00000000-0000-4000-f034-0000000001c1') is null
     or (select external_channel_id from public.accounts where id = '00000000-0000-4000-f034-0000000001c1') <> 'UC-C1'
     or pg_temp.events('00000000-0000-4000-f034-0000000001c1', 'disconnect') <> 1 then
    raise exception 'FAIL: 해제 기록';
  end if;
  s := pg_temp.save('00000000-0000-4000-f034-00000000000c', '00000000-0000-4000-f034-0000000001c2', 'UC-C2', 'rt-c2');
  if s <> 'connected' then raise exception 'FAIL: 해제 뒤 다른 채널 %', s; end if;
  -- 한도가 꽉 찬 상태에서 슬롯 보유 행 재인증 → 통과(reconnect)
  s := pg_temp.save('00000000-0000-4000-f034-00000000000c', '00000000-0000-4000-f034-0000000001c2', 'UC-C2', 'rt-c2b');
  if s <> 'connected' or pg_temp.events('00000000-0000-4000-f034-0000000001c2', 'reconnect') <> 1 then
    raise exception 'FAIL: 재인증 %', s;
  end if;
  -- 해제했던 채널의 재연결은 한도 검사 대상
  s := pg_temp.save('00000000-0000-4000-f034-00000000000c', '00000000-0000-4000-f034-0000000001c1', 'UC-C1', 'rt-c1b');
  if s <> 'CS001' then raise exception 'FAIL: 해제 채널 재연결이 한도를 넘음 %', s; end if;

  -- D: 기본 채널 만료(invalid_grant) → 슬롯 유지
  s := pg_temp.save('00000000-0000-4000-f034-00000000000d', '00000000-0000-4000-f034-0000000001d1', 'UC-D1', 'rt-d1');
  select oauth_token_ref into v_ref from public.accounts where id = '00000000-0000-4000-f034-0000000001d1';
  if not public.youtube_expire_token('00000000-0000-4000-f034-0000000001d1', v_ref) then
    raise exception 'FAIL: 만료 처리';
  end if;
  if pg_temp.events('00000000-0000-4000-f034-0000000001d1', 'expire') <> 1
     or (select disconnected_at from public.accounts where id = '00000000-0000-4000-f034-0000000001d1') is not null then
    raise exception 'FAIL: 만료가 슬롯을 반환함';
  end if;
  s := pg_temp.save('00000000-0000-4000-f034-00000000000d', '00000000-0000-4000-f034-0000000001d2', 'UC-D2', 'rt-d2');
  if s <> 'CS001' then raise exception 'FAIL: 만료 중 다른 채널 연결 %', s; end if;
  s := pg_temp.save('00000000-0000-4000-f034-00000000000d', '00000000-0000-4000-f034-0000000001d1', 'UC-D1', 'rt-d1b');
  if s <> 'connected' then raise exception 'FAIL: 만료된 기본 채널 재연결 %', s; end if;
  raise notice 'PASS 3 해제 뒤 다른 채널 연결, 꽉 찬 한도에서 재인증 통과, 해제 채널 재연결은 CS001, 만료는 슬롯 유지';
end $$;

-- ── 4) 회전: 30일 새 채널 3개 뒤 4번째 CS002 · 같은 채널 재연결 통과 ──
insert into private.channel_quotas (user_id, channel_limit) values ('00000000-0000-4000-f034-00000000000e', 10);
do $$
declare s text; st record;
begin
  s := pg_temp.save('00000000-0000-4000-f034-00000000000e', '00000000-0000-4000-f034-0000000001e1', 'UC-E1', 'rt-e1');
  s := s || pg_temp.save('00000000-0000-4000-f034-00000000000e', '00000000-0000-4000-f034-0000000001e2', 'UC-E2', 'rt-e2');
  s := s || pg_temp.save('00000000-0000-4000-f034-00000000000e', '00000000-0000-4000-f034-0000000001e3', 'UC-E3', 'rt-e3');
  if s <> 'connectedconnectedconnected' then raise exception 'FAIL: 새 채널 3개 %', s; end if;
  update public.accounts set first_connected_at = now() - interval '10 days'
  where id = '00000000-0000-4000-f034-0000000001e1';
  s := pg_temp.save('00000000-0000-4000-f034-00000000000e', '00000000-0000-4000-f034-0000000001e4', 'UC-E4', 'rt-e4');
  if s <> 'CS002' or pg_temp.events('00000000-0000-4000-f034-0000000001e4', 'reject_rotation') <> 1 then
    raise exception 'FAIL: 4번째 새 채널 %', s;
  end if;
  select * into st from public.channel_slot_status('00000000-0000-4000-f034-00000000000e',
                                                   '00000000-0000-4000-f034-0000000001e4');
  if st.code is distinct from 'CS002' or st.recent_new <> 3
     or abs(extract(epoch from st.next_at - (now() + interval '20 days'))) > 5 then
    raise exception 'FAIL: 사전 검사 CS002 % % %', st.code, st.recent_new, st.next_at;
  end if;
  -- 같은 채널 재인증 · 해제 뒤 같은 채널 재연결은 회전 제한과 무관
  s := pg_temp.save('00000000-0000-4000-f034-00000000000e', '00000000-0000-4000-f034-0000000001e2', 'UC-E2', 'rt-e2b');
  perform public.youtube_clear_token('00000000-0000-4000-f034-0000000001e3', '00000000-0000-4000-f034-00000000000e');
  s := s || pg_temp.save('00000000-0000-4000-f034-00000000000e', '00000000-0000-4000-f034-0000000001e3', 'UC-E3', 'rt-e3b');
  if s <> 'connectedconnected' then raise exception 'FAIL: 같은 채널 재연결 %', s; end if;
  -- 30일이 지난 연결은 세지 않는다
  update public.accounts set first_connected_at = now() - interval '31 days'
  where id = '00000000-0000-4000-f034-0000000001e1';
  s := pg_temp.save('00000000-0000-4000-f034-00000000000e', '00000000-0000-4000-f034-0000000001e4', 'UC-E4', 'rt-e4');
  if s <> 'connected' then raise exception 'FAIL: 30일 지난 뒤 새 채널 %', s; end if;
  raise notice 'PASS 4 30일 새 채널 3개 뒤 4번째 CS002(다시 가능 시각 포함), 같은 채널 재연결 통과';
end $$;

-- ── 5) 본인 다른 행의 같은 채널 → CS003 · 다른 사용자 채널 → 23505 ──
do $$
declare s text;
begin
  -- C 의 c2 가 UC-C2 연결 중, c1 은 해제(채널 id 유지)
  s := pg_temp.save('00000000-0000-4000-f034-00000000000c', '00000000-0000-4000-f034-0000000001c3', 'UC-C2', 'rt-x');
  if s <> 'CS003' then raise exception 'FAIL: 연결 중 채널을 새 행에 %', s; end if;
  s := pg_temp.save('00000000-0000-4000-f034-00000000000c', '00000000-0000-4000-f034-0000000001c3', 'UC-C1', 'rt-x');
  if s <> 'CS003' then raise exception 'FAIL: 해제한 채널을 새 행에 %', s; end if;
  if pg_temp.events('00000000-0000-4000-f034-0000000001c3', 'reject_duplicate') <> 2
     or (select external_channel_id from public.accounts where id = '00000000-0000-4000-f034-0000000001c3') is not null then
    raise exception 'FAIL: CS003 기록·행 변경';
  end if;
  raise notice 'PASS 5 본인 다른 행에 있는 채널 CS003(reject_duplicate)';
end $$;
select pg_temp.expect_fail($q$select pg_temp.save('00000000-0000-4000-f034-00000000000d', '00000000-0000-4000-f034-0000000001d3', 'UC-C2', 'rt-x')$q$,
  '23505', '다른 사용자 채널 연결');

-- ── 6) 초과 채널: 새 프로젝트·채널 변경 거부(CS004), 첫 발행 뒤 변경 거부 유지 ──
insert into private.channel_quotas (user_id, channel_limit) values ('00000000-0000-4000-f034-00000000000f', 2);
select pg_temp.save('00000000-0000-4000-f034-00000000000f', '00000000-0000-4000-f034-0000000001f1', 'UC-F1', 'rt-f1');
select pg_temp.save('00000000-0000-4000-f034-00000000000f', '00000000-0000-4000-f034-0000000001f2', 'UC-F2', 'rt-f2');
update public.accounts set first_connected_at = now() - interval '1 day' where id = '00000000-0000-4000-f034-0000000001f1';
-- 다운그레이드: 한도 1 → 순위 2인 f2 가 초과
update private.channel_quotas set channel_limit = 1 where user_id = '00000000-0000-4000-f034-00000000000f';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f034-00000000000f","role":"authenticated"}', true);
insert into public.projects (account_id, name) values
  ('00000000-0000-4000-f034-0000000001f1', 'f-ok'),
  ('00000000-0000-4000-f034-0000000001f3', 'f-unconnected');
select pg_temp.expect_fail($q$insert into public.projects (account_id, name) values ('00000000-0000-4000-f034-0000000001f2', 'f-excess')$q$,
  'CS004', '초과 채널로 새 프로젝트');
select pg_temp.expect_fail($q$update public.projects set account_id = '00000000-0000-4000-f034-0000000001f2' where name like 'f-ok%'$q$,
  'CS004', '초과 채널로 프로젝트 채널 변경');
update public.projects set name = 'f-ok-renamed' where name = 'f-ok';
reset role;
insert into public.publications (project_id, account_id, mode)
select id, account_id, 'now' from public.projects where name = 'f-ok-renamed';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f034-00000000000f","role":"authenticated"}', true);
select pg_temp.expect_fail($q$update public.projects set account_id = '00000000-0000-4000-f034-0000000001f3' where name like 'f-ok%'$q$,
  '23503', '첫 발행 뒤 채널 변경');
reset role;
do $$
begin
  -- 기본 채널은 순위 1: f2 를 기본으로 하면 f1 이 초과
  update public.accounts set is_default = true where id = '00000000-0000-4000-f034-0000000001f2';
  if not private.channel_is_excess('00000000-0000-4000-f034-00000000000f', '00000000-0000-4000-f034-0000000001f1')
     or private.channel_is_excess('00000000-0000-4000-f034-00000000000f', '00000000-0000-4000-f034-0000000001f2') then
    raise exception 'FAIL: 순위(is_default 우선)';
  end if;
  update public.accounts set is_default = false where id = '00000000-0000-4000-f034-0000000001f2';
  raise notice 'PASS 6 초과 채널 새 프로젝트·채널 변경 CS004, 이름 변경·미연결 채널 프로젝트 허용, 첫 발행 뒤 변경 23503 유지';
end $$;

-- ── 6b) 034b: 초과 채널 새 발행 CS005 · 기존 예약 유지 · 한도 초과 중 is_default 변경 CS006 ──
-- (한도 1, f1 순위 1·f2 초과) 초과 전에 만든 프로젝트·예약을 준비하려고 한도를 잠시 2로 올린다
update private.channel_quotas set channel_limit = 2 where user_id = '00000000-0000-4000-f034-00000000000f';
insert into public.projects (id, user_id, account_id, name, step_status, sources_notice_ack_at, sources_notice_ack_by) values
  ('00000000-0000-4000-f034-0000000002f2', '00000000-0000-4000-f034-00000000000f', '00000000-0000-4000-f034-0000000001f2', 'f-pending',
   '{"1":"approved","2":"approved","3":"ready","4":"idle","5":"idle","6":"idle"}', now(), '00000000-0000-4000-f034-00000000000f');
insert into public.projects (user_id, account_id, name) values ('00000000-0000-4000-f034-00000000000f', '00000000-0000-4000-f034-0000000001f2', 'f-new');
insert into public.scripts (project_id, version, lines, approved_at) values ('00000000-0000-4000-f034-0000000002f2', 1, '["좁은 틈에도 쏙 들어가요."]', now());
insert into public.renders (project_id, version, mp4_path, duration_sec, cut_map) values
  ('00000000-0000-4000-f034-0000000002f2', 1, '00000000-0000-4000-f034-00000000000f/00000000-0000-4000-f034-0000000002f2/v1.mp4', 15,
   jsonb_build_object('cuts', jsonb_build_array(
     jsonb_build_object('no', 1, 'source_id', '00000000-0000-4000-f034-0000000003f1', 'author', 'maker_a',
                        'platform', 'tiktok', 'source_url', 'https://www.tiktok.com/@maker_a/video/1',
                        'collected_at', '2026-11-12T01:00:00Z'))));
update public.projects
set step_status = '{"1":"approved","2":"approved","3":"approved","4":"approved","5":"approved","6":"idle"}'
where id = '00000000-0000-4000-f034-0000000002f2';
-- 초과 전에 실제 prepare_publication 으로 첫 예약을 만든다(사용자 권한)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f034-00000000000f","role":"authenticated"}', true);
select public.confirm_policy_check('00000000-0000-4000-f034-0000000002f2', 'attribution_notice', true);
select public.prepare_publication('00000000-0000-4000-f034-0000000002f2', 'now', null, '압축팩 정리 꿀팁', '본문', '{}', true, false);
reset role;
update private.channel_quotas set channel_limit = 1 where user_id = '00000000-0000-4000-f034-00000000000f';
do $$
begin
  perform pg_temp.expect_fail($q$insert into public.publications (project_id, account_id, mode)
    select id, account_id, 'now' from public.projects where name = 'f-new'$q$, 'CS005', '초과 채널 새 발행');
  -- 기존 pending: 재준비(prepared_at)·claim 전이는 막지 않는다
  if not exists (select 1 from public.publications where project_id = '00000000-0000-4000-f034-0000000002f2' and status = 'pending') then
    raise exception 'FAIL: 초과 전 첫 예약 없음';
  end if;
  -- 한도 안 채널(f1)의 새 발행은 정상
  insert into public.projects (user_id, account_id, name) values ('00000000-0000-4000-f034-00000000000f', '00000000-0000-4000-f034-0000000001f1', 'f-ok2');
  insert into public.publications (project_id, account_id, mode)
  select id, account_id, 'now' from public.projects where name = 'f-ok2';
  raise notice 'PASS 6b-1 초과 채널 새 발행 CS005, 기존 예약 재준비·pending→uploading 전이 유지, 한도 안 채널 발행 정상';
end $$;

-- 초과 채널의 기존 행 재준비(실제 RPC, 사용자 권한): pending·invalidated 모두 성공해야 한다
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f034-00000000000f","role":"authenticated"}', true);
do $$
declare p jsonb;
begin
  p := public.prepare_publication('00000000-0000-4000-f034-0000000002f2', 'now', null, '압축팩 정리 꿀팁 2', '본문', '{}', true, false);
  if p ->> 'status' <> 'pending' then raise exception 'FAIL: 초과 채널 pending 재준비 %', p; end if;
end $$;
reset role;
update public.publications set status = 'invalidated' where project_id = '00000000-0000-4000-f034-0000000002f2';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f034-00000000000f","role":"authenticated"}', true);
do $$
declare p jsonb;
begin
  p := public.prepare_publication('00000000-0000-4000-f034-0000000002f2', 'now', null, '압축팩 정리 꿀팁 3', '본문', '{}', true, false);
  if p ->> 'status' <> 'pending' or p ->> 'title' <> '압축팩 정리 꿀팁 3' then
    raise exception 'FAIL: 초과 채널 invalidated 재준비 %', p;
  end if;
  raise notice 'PASS 6b-1b 초과 채널의 pending·invalidated 행을 prepare_publication RPC 로 재준비 성공';
end $$;
reset role;

-- 슬롯 2 > 한도 1: authenticated 의 is_default 변경 거부(설정·해제), 슬롯 없는 행은 허용
update public.accounts set is_default = true where id = '00000000-0000-4000-f034-0000000001f1';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f034-00000000000f","role":"authenticated"}', true);
select pg_temp.expect_fail($q$update public.accounts set is_default = false where id = '00000000-0000-4000-f034-0000000001f1'$q$,
  'CS006', '한도 초과 중 기본 채널 해제');
select pg_temp.expect_fail($q$update public.accounts set is_default = true where id = '00000000-0000-4000-f034-0000000001f2'$q$,
  'CS006', '한도 초과 중 기본 채널 설정');
update public.accounts set is_default = false where id = '00000000-0000-4000-f034-0000000001f3';
update public.accounts set channel_name = 'f1-renamed' where id = '00000000-0000-4000-f034-0000000001f1';
reset role;
-- 슬롯 ≤ 한도(한도 2): 허용
update private.channel_quotas set channel_limit = 2 where user_id = '00000000-0000-4000-f034-00000000000f';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f034-00000000000f","role":"authenticated"}', true);
update public.accounts set is_default = false where id = '00000000-0000-4000-f034-0000000001f1';
update public.accounts set is_default = true where id = '00000000-0000-4000-f034-0000000001f2';
-- 다른 사용자(C)는 한도 1·슬롯 1 이하라 영향 없음, F 의 헬퍼 답은 본인에게만
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f034-00000000000c","role":"authenticated"}', true);
do $$
begin
  if private.channel_over_limit_self('00000000-0000-4000-f034-00000000000f') then raise exception 'FAIL: 타인 한도 초과 여부 노출'; end if;
end $$;
reset role;
update private.channel_quotas set channel_limit = 1 where user_id = '00000000-0000-4000-f034-00000000000f';
update public.accounts set is_default = false where id = '00000000-0000-4000-f034-0000000001f2';
do $$ begin raise notice 'PASS 6b-2 한도 초과 중 is_default 변경 CS006(설정·해제), 슬롯 없는 행·슬롯≤한도·postgres 는 허용, 헬퍼는 본인만'; end $$;

-- ── 7) authenticated: 이벤트 쓰기·한도 읽기 불가, 본인 이벤트만 읽기 ──
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f034-00000000000c","role":"authenticated"}', true);
select pg_temp.expect_fail($q$insert into public.channel_slot_events (user_id, kind, slots, channel_limit) values ('00000000-0000-4000-f034-00000000000c', 'connect', 0, 1)$q$,
  '42501', 'authenticated 이벤트 쓰기');
select pg_temp.expect_fail($q$delete from public.channel_slot_events$q$, '42501', 'authenticated 이벤트 삭제');
select pg_temp.expect_fail($q$select * from private.channel_quotas$q$, '42501', 'authenticated 한도 읽기');
select pg_temp.expect_fail($q$update public.accounts set disconnected_at = null$q$, '42501', 'authenticated disconnected_at 쓰기');
do $$
begin
  if (select count(*) from public.channel_slot_events) = 0
     or exists (select 1 from public.channel_slot_events where user_id <> '00000000-0000-4000-f034-00000000000c') then
    raise exception 'FAIL: 본인 이벤트 읽기';
  end if;
  raise notice 'PASS 7 authenticated 는 이벤트 쓰기·한도 읽기 불가, 본인 이벤트만 읽기';
end $$;
reset role;

-- ── 8) 시드: 슬롯 2개 사용자 → 한도 2, 1개는 행 없음 ─────────
update public.accounts set external_channel_id = 'UC-G1' where id = '00000000-0000-4000-f034-0000000001a1';
update public.accounts set external_channel_id = 'UC-G2' where id = '00000000-0000-4000-f034-0000000001a2';
update public.accounts set external_channel_id = 'UC-H1' where id = '00000000-0000-4000-f034-0000000001b1';
do $$
begin
  perform private.channel_quotas_seed();
  if (select channel_limit from private.channel_quotas where user_id = '00000000-0000-4000-f034-0000000000aa') is distinct from 2
     or exists (select 1 from private.channel_quotas where user_id = '00000000-0000-4000-f034-0000000000bb')
     or (select channel_limit from private.channel_quotas where user_id = '00000000-0000-4000-f034-00000000000e') <> 10 then
    raise exception 'FAIL: 시드';
  end if;
  raise notice 'PASS 8 시드: 2채널 사용자 한도 2, 1채널 사용자 행 없음, 기존 한도 행 유지';
end $$;

rollback;
