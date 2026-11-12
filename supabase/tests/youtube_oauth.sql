-- task-022a YouTube OAuth·Vault(20261112270000) 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/youtube_oauth.sql
-- 한 트랜잭션으로 돌리고 ROLLBACK 한다. 서버 경로 그대로 service_role 로 public 래퍼를 부른다.
-- 사용자 A(계정 YA·YA2) · 사용자 B(계정 YB·YB2)
begin;

insert into auth.users (id, aud, role, email) values
  ('00000000-0000-4000-f022-00000000000a', 'authenticated', 'authenticated', 'yt-test-a@example.com'),
  ('00000000-0000-4000-f022-00000000000b', 'authenticated', 'authenticated', 'yt-test-b@example.com');
insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-f022-00000000010a', '00000000-0000-4000-f022-00000000000a', 'youtube', 'yt-a'),
  ('00000000-0000-4000-f022-00000000020a', '00000000-0000-4000-f022-00000000000a', 'youtube', 'yt-a2'),
  ('00000000-0000-4000-f022-00000000010b', '00000000-0000-4000-f022-00000000000b', 'youtube', 'yt-b'),
  ('00000000-0000-4000-f022-00000000020b', '00000000-0000-4000-f022-00000000000b', 'youtube', 'yt-b2');

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

create function pg_temp.h(p text) returns text language sql as $$
  select encode(extensions.digest(p, 'sha256'), 'hex');
$$;

create function pg_temp.scopes() returns text language sql as $$
  select quote_literal(array['https://www.googleapis.com/auth/youtube.upload',
                             'https://www.googleapis.com/auth/youtube.readonly',
                             'https://www.googleapis.com/auth/yt-analytics.readonly']::text) || '::text[]';
$$;

-- ── 1) 권한: anon·authenticated 는 래퍼·본체·state·vault 불가 ──
do $$
declare f text; r text;
begin
  foreach f in array array[
    'public.oauth_state_create(uuid,uuid,text,text)', 'public.oauth_state_consume(uuid,text)',
    'public.youtube_save_connection(uuid,uuid,text,text,text[])',
    'public.youtube_refresh_token(uuid,uuid)', 'public.youtube_clear_token(uuid,uuid)',
    'private.oauth_state_create(uuid,uuid,text,text)', 'private.oauth_state_consume(uuid,text)',
    'private.youtube_save_connection(uuid,uuid,text,text,text[])',
    'private.youtube_refresh_token(uuid,uuid)', 'private.youtube_clear_token(uuid,uuid)',
    'private.vault_secret_cleanup()'] loop
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then raise exception 'FAIL: % 가 % 실행 가능', r, f; end if;
    end loop;
    if f like 'private.%' and has_function_privilege('service_role', f, 'execute') then
      raise exception 'FAIL: service_role 이 private % 실행 가능', f;
    end if;
    if f like 'public.%' and not has_function_privilege('service_role', f, 'execute') then
      raise exception 'FAIL: service_role % 불가', f;
    end if;
  end loop;
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_table_privilege(r, 'public.oauth_states', 'select,insert,update,delete') then
      raise exception 'FAIL: % 가 oauth_states 접근 가능', r;
    end if;
  end loop;
  foreach r in array array['anon', 'authenticated'] loop
    if has_column_privilege(r, 'public.accounts', 'external_channel_id', 'select')
       or has_column_privilege(r, 'public.accounts', 'external_channel_id', 'update')
       or has_column_privilege(r, 'public.accounts', 'external_channel_id', 'insert')
       or has_column_privilege(r, 'public.accounts', 'oauth_token_ref', 'select') then
      raise exception 'FAIL: % 가 accounts 서버 전용 열 접근 가능', r;
    end if;
  end loop;
  if not (select relrowsecurity from pg_class where oid = 'public.oauth_states'::regclass) then
    raise exception 'FAIL: oauth_states RLS 꺼짐';
  end if;
  raise notice 'PASS 1 래퍼는 service_role 만, 본체·oauth_states·서버 전용 열은 anon·authenticated 불가';
end $$;

-- 실제 역할로 호출해도 거부(42501)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f022-00000000000a","role":"authenticated"}', true);
select pg_temp.expect_fail($q$select public.youtube_refresh_token('00000000-0000-4000-f022-00000000010a')$q$, '42501', 'authenticated 토큰 조회');
select pg_temp.expect_fail($q$select public.oauth_state_consume('00000000-0000-4000-f022-00000000000a', 'x')$q$, '42501', 'authenticated state 소모');
select pg_temp.expect_fail($q$select public.youtube_clear_token('00000000-0000-4000-f022-00000000010a')$q$, '42501', 'authenticated 해제');
select pg_temp.expect_fail($q$select * from vault.decrypted_secrets$q$, '42501', 'authenticated vault 조회');
select pg_temp.expect_fail($q$select * from public.oauth_states$q$, '42501', 'authenticated oauth_states 조회');
select pg_temp.expect_fail($q$select oauth_token_ref from public.accounts$q$, '42501', 'authenticated oauth_token_ref 조회');
select pg_temp.expect_fail($q$select external_channel_id from public.accounts$q$, '42501', 'authenticated external_channel_id 조회');
reset role;
set local role anon;
select pg_temp.expect_fail($q$select public.youtube_refresh_token('00000000-0000-4000-f022-00000000010a')$q$, '42501', 'anon 토큰 조회');
select pg_temp.expect_fail($q$select public.youtube_save_connection(null, null, 'c', 't', '{}')$q$, '42501', 'anon 연결 저장');
select pg_temp.expect_fail($q$select * from vault.decrypted_secrets$q$, '42501', 'anon vault 조회');
reset role;
do $$ begin raise notice 'PASS 2 anon·authenticated 의 RPC·vault.decrypted_secrets·oauth_states 조회 거부'; end $$;

-- 사용자가 INSERT 로 서버 전용 열을 넣어도 무시(트리거)
set local role authenticated;
insert into public.accounts (user_id, platform, channel_name)
values ('00000000-0000-4000-f022-00000000000a', 'youtube', 'yt-a3-022a');
reset role;

-- ── 3) state: 남의 계정 거부 · 1회 사용 · 만료 · 다른 사용자 ──
set local role service_role;
select pg_temp.expect_fail(format('select public.oauth_state_create(%L, %L, %L, %L)',
  '00000000-0000-4000-f022-00000000000a', '00000000-0000-4000-f022-00000000010b',
  pg_temp.h('s-other'), repeat('v', 43)), '42501', '남의 account_id 로 시작');
select public.oauth_state_create('00000000-0000-4000-f022-00000000000a', '00000000-0000-4000-f022-00000000010a',
                                 pg_temp.h('s-ok'), repeat('a', 43));
select public.oauth_state_create('00000000-0000-4000-f022-00000000000a', '00000000-0000-4000-f022-00000000010a',
                                 pg_temp.h('s-other-user'), repeat('b', 43));
select public.oauth_state_create('00000000-0000-4000-f022-00000000000a', '00000000-0000-4000-f022-00000000010a',
                                 pg_temp.h('s-expired'), repeat('c', 43));
reset role;
update public.oauth_states set expires_at = now() - interval '1 second' where state_hash = pg_temp.h('s-expired');
set local role service_role;
do $$
declare n int; v text;
begin
  -- 모르는 state
  select count(*) into n from public.oauth_state_consume('00000000-0000-4000-f022-00000000000a', pg_temp.h('nope'));
  if n <> 0 then raise exception 'FAIL: 모르는 state 통과'; end if;
  -- 다른 사용자의 콜백(B 세션이 A 의 state 제출) → 거부 + 소모되어 A 도 못 씀
  select count(*) into n from public.oauth_state_consume('00000000-0000-4000-f022-00000000000b', pg_temp.h('s-other-user'));
  if n <> 0 then raise exception 'FAIL: 다른 사용자 콜백 통과'; end if;
  select count(*) into n from public.oauth_state_consume('00000000-0000-4000-f022-00000000000a', pg_temp.h('s-other-user'));
  if n <> 0 then raise exception 'FAIL: 다른 사용자가 건드린 state 재사용'; end if;
  -- 만료
  select count(*) into n from public.oauth_state_consume('00000000-0000-4000-f022-00000000000a', pg_temp.h('s-expired'));
  if n <> 0 then raise exception 'FAIL: 만료 state 통과'; end if;
  -- 정상 1회 → 재사용 거부
  select c.code_verifier into v from public.oauth_state_consume('00000000-0000-4000-f022-00000000000a', pg_temp.h('s-ok')) c;
  if v is distinct from repeat('a', 43) then raise exception 'FAIL: 정상 state 소모 %', v; end if;
  select count(*) into n from public.oauth_state_consume('00000000-0000-4000-f022-00000000000a', pg_temp.h('s-ok'));
  if n <> 0 then raise exception 'FAIL: state 재사용 통과'; end if;
  raise notice 'PASS 3 남의 계정 시작 거부, state 불일치·만료·재사용·다른 사용자 콜백 거부';
end $$;

-- ── 4) 연결 저장: 범위 · 채널 고정 · 전역 unique · 빈 토큰 ───
select pg_temp.expect_fail(format('select public.youtube_save_connection(%L, %L, %L, %L, %L::text[])',
  '00000000-0000-4000-f022-00000000000a', '00000000-0000-4000-f022-00000000010a', 'UC-A', 'rt-a-1',
  array['https://www.googleapis.com/auth/youtube.upload', 'https://www.googleapis.com/auth/youtube.readonly']),
  'OA002', '필수 범위 누락');
select pg_temp.expect_fail(format('select public.youtube_save_connection(%L, %L, %L, %L, %s)',
  '00000000-0000-4000-f022-00000000000b', '00000000-0000-4000-f022-00000000010a', 'UC-A', 'rt-a-1', pg_temp.scopes()),
  '42501', '남의 계정에 연결 저장');
do $$
declare s text; r text;
begin
  execute format('select public.youtube_save_connection(%L, %L, %L, %L, %s)',
    '00000000-0000-4000-f022-00000000000a', '00000000-0000-4000-f022-00000000010a', 'UC-A', 'rt-a-1', pg_temp.scopes()) into s;
  if s <> 'connected' then raise exception 'FAIL: 연결 %', s; end if;
  r := public.youtube_refresh_token('00000000-0000-4000-f022-00000000010a');
  if r is distinct from 'rt-a-1' then raise exception 'FAIL: 저장 토큰'; end if;
  -- 빈 refresh_token 으로 재연결 → 기존 토큰 유지
  execute format('select public.youtube_save_connection(%L, %L, %L, %L, %s)',
    '00000000-0000-4000-f022-00000000000a', '00000000-0000-4000-f022-00000000010a', 'UC-A', '', pg_temp.scopes()) into s;
  r := public.youtube_refresh_token('00000000-0000-4000-f022-00000000010a');
  if s <> 'connected' or r is distinct from 'rt-a-1' then raise exception 'FAIL: 빈 토큰 덮어씀 % %', s, r; end if;
  execute format('select public.youtube_save_connection(%L, %L, %L, null, %s)',
    '00000000-0000-4000-f022-00000000000a', '00000000-0000-4000-f022-00000000010a', 'UC-A', pg_temp.scopes()) into s;
  if public.youtube_refresh_token('00000000-0000-4000-f022-00000000010a') is distinct from 'rt-a-1' then
    raise exception 'FAIL: null 토큰 덮어씀';
  end if;
  -- 새 토큰으로 재연결 → 새 secret(버전) 으로 교체
  execute format('select public.youtube_save_connection(%L, %L, %L, %L, %s)',
    '00000000-0000-4000-f022-00000000000a', '00000000-0000-4000-f022-00000000010a', 'UC-A', 'rt-a-2', pg_temp.scopes()) into s;
  if public.youtube_refresh_token('00000000-0000-4000-f022-00000000010a') is distinct from 'rt-a-2' then
    raise exception 'FAIL: 새 토큰 미반영';
  end if;
  -- 토큰이 한 번도 없던 계정에 빈 토큰 → 미연결
  execute format('select public.youtube_save_connection(%L, %L, %L, %L, %s)',
    '00000000-0000-4000-f022-00000000000b', '00000000-0000-4000-f022-00000000010b', 'UC-B', '', pg_temp.scopes()) into s;
  if s <> 'reconnect_required' then raise exception 'FAIL: 토큰 없이 연결됨'; end if;
  raise notice 'PASS 4 범위 누락 거부, 빈 갱신 토큰 미덮어쓰기, 새 토큰 갱신';
end $$;
select pg_temp.expect_fail(format('select public.youtube_save_connection(%L, %L, %L, %L, %s)',
  '00000000-0000-4000-f022-00000000000a', '00000000-0000-4000-f022-00000000010a', 'UC-OTHER', 'rt-x', pg_temp.scopes()),
  'OA001', '다른 채널로 재연결');
select pg_temp.expect_fail(format('select public.youtube_save_connection(%L, %L, %L, %L, %s)',
  '00000000-0000-4000-f022-00000000000a', '00000000-0000-4000-f022-00000000020a', 'UC-A', 'rt-x', pg_temp.scopes()),
  '23505', '같은 채널을 다른 계정에');
select pg_temp.expect_fail(format('select public.youtube_save_connection(%L, %L, %L, %L, %s)',
  '00000000-0000-4000-f022-00000000000b', '00000000-0000-4000-f022-00000000020b', 'UC-A', 'rt-x', pg_temp.scopes()),
  '23505', '같은 채널을 다른 사용자 계정에');
do $$
begin
  if public.youtube_refresh_token('00000000-0000-4000-f022-00000000010a') is distinct from 'rt-a-2' then
    raise exception 'FAIL: 거부된 재연결이 토큰을 바꿈';
  end if;
  raise notice 'PASS 5 다른 채널 재연결 거부, 같은 채널 다른 계정 거부(전역 unique)';
end $$;
reset role;
do $$
begin
  if (select (external_channel_id, oauth_token_ref, status) from public.accounts
      where channel_name = 'yt-a3-022a') is distinct from (null::text, null::uuid, 'reconnect_required'::text) then
    raise exception 'FAIL: 사용자 INSERT 가 서버 전용 열을 바꿈';
  end if;
  raise notice 'PASS 6 사용자 INSERT 는 서버 전용 열 초기값 강제';
end $$;

-- ── 7) 해제·invalid_grant: Vault 삭제 ─────────────────────────
set local role service_role;
select pg_temp.expect_fail($q$select public.youtube_refresh_token('00000000-0000-4000-f022-00000000010a', '00000000-0000-4000-f022-00000000000b')$q$,
  '42501', '남의 계정 토큰 조회(해제 경로)');
select pg_temp.expect_fail($q$select public.youtube_clear_token('00000000-0000-4000-f022-00000000010a', '00000000-0000-4000-f022-00000000000b')$q$,
  '42501', '남의 계정 해제');
reset role;
create temp table t_ref on commit drop as
  select oauth_token_ref as ref from public.accounts where id = '00000000-0000-4000-f022-00000000010a';
grant select on t_ref to service_role;
set local role service_role;
select public.youtube_clear_token('00000000-0000-4000-f022-00000000010a', '00000000-0000-4000-f022-00000000000a');
reset role;
do $$
begin
  if exists (select 1 from vault.secrets where id = (select ref from t_ref))
     or (select (oauth_token_ref, status) from public.accounts where id = '00000000-0000-4000-f022-00000000010a')
        is distinct from (null::uuid, 'reconnect_required'::text) then
    raise exception 'FAIL: 해제 후 Vault·상태';
  end if;
  if (select external_channel_id from public.accounts where id = '00000000-0000-4000-f022-00000000010a') <> 'UC-A' then
    raise exception 'FAIL: 해제가 채널 고정을 지움';
  end if;
  raise notice 'PASS 7 해제 시 Vault secret 삭제·재연결 필요, 채널 고정은 유지';
end $$;

-- ── 8) 행 삭제 시 Vault 정리(accounts·api_keys) ──────────────
set local role service_role;
select public.youtube_save_connection('00000000-0000-4000-f022-00000000000a', '00000000-0000-4000-f022-00000000020a',
  'UC-A2', 'rt-a2', array['https://www.googleapis.com/auth/youtube.upload',
                          'https://www.googleapis.com/auth/youtube.readonly',
                          'https://www.googleapis.com/auth/yt-analytics.readonly']);
reset role;
do $$
declare v_acc uuid; v_key uuid;
begin
  select oauth_token_ref into v_acc from public.accounts where id = '00000000-0000-4000-f022-00000000020a';
  v_key := vault.create_secret('key-test-022a', null, 'test');
  insert into public.api_keys (user_id, provider, secret_ref, last4, status)
  values ('00000000-0000-4000-f022-00000000000a', 'openai', v_key, '022a', 'registered');
  delete from public.accounts where id = '00000000-0000-4000-f022-00000000020a';
  delete from public.api_keys where secret_ref = v_key;
  if v_acc is null or exists (select 1 from vault.secrets where id in (v_acc, v_key)) then
    raise exception 'FAIL: 행 삭제 후 Vault secret 남음';
  end if;
  raise notice 'PASS 8 accounts·api_keys 행 삭제 시 Vault secret 삭제';
end $$;

-- ── 9) 본인 키 조회 응답(authenticated)에 원문·secret id 0 ─────
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f022-00000000000a","role":"authenticated"}', true);
do $$
declare v text;
begin
  select string_agg(row_to_json(a)::text, '') into v
  from (select id, user_id, platform, channel_name, status, is_default, created_at from public.accounts) a;
  if v like '%rt-a%' then raise exception 'FAIL: 계정 조회에 토큰 원문'; end if;
  raise notice 'PASS 9 본인 계정 조회 응답에 토큰 원문 없음';
end $$;
reset role;

-- ── 10) 토큰 버전·소유자 확인(20261112270200) ────────────────
do $$
declare f text; r text;
begin
  foreach f in array array['public.youtube_token_for(uuid,uuid)', 'public.youtube_expire_token(uuid,uuid)',
                           'private.youtube_token_for(uuid,uuid)', 'private.youtube_expire_token(uuid,uuid)'] loop
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then raise exception 'FAIL: % 가 % 실행 가능', r, f; end if;
    end loop;
    if (f like 'public.%') <> has_function_privilege('service_role', f, 'execute') then
      raise exception 'FAIL: service_role 권한 %', f;
    end if;
  end loop;
end $$;
set local role service_role;
select pg_temp.expect_fail($q$select * from public.youtube_token_for('00000000-0000-4000-f022-00000000000b', '00000000-0000-4000-f022-00000000010a')$q$,
  '42501', '남의 계정 access token 조회');
do $$
declare v_old uuid; v_new uuid; t text; changed boolean;
begin
  perform public.youtube_save_connection('00000000-0000-4000-f022-00000000000a', '00000000-0000-4000-f022-00000000010a',
    'UC-A', 'rt-v1', array['https://www.googleapis.com/auth/youtube.upload',
                           'https://www.googleapis.com/auth/youtube.readonly',
                           'https://www.googleapis.com/auth/yt-analytics.readonly']);
  select token_ref, refresh_token into v_old, t
  from public.youtube_token_for('00000000-0000-4000-f022-00000000000a', '00000000-0000-4000-f022-00000000010a');
  if t is distinct from 'rt-v1' then raise exception 'FAIL: 버전 조회 %', t; end if;
  -- 갱신 도중 재연결로 새 토큰(새 버전)
  perform public.youtube_save_connection('00000000-0000-4000-f022-00000000000a', '00000000-0000-4000-f022-00000000010a',
    'UC-A', 'rt-v2', array['https://www.googleapis.com/auth/youtube.upload',
                           'https://www.googleapis.com/auth/youtube.readonly',
                           'https://www.googleapis.com/auth/yt-analytics.readonly']);
  select token_ref into v_new
  from public.youtube_token_for('00000000-0000-4000-f022-00000000000a', '00000000-0000-4000-f022-00000000010a');
  if v_new = v_old then raise exception 'FAIL: 새 토큰인데 버전이 같음'; end if;
  -- 늦게 온 invalid_grant(옛 버전) → 아무것도 안 함
  changed := public.youtube_expire_token('00000000-0000-4000-f022-00000000010a', v_old);
  if changed or public.youtube_refresh_token('00000000-0000-4000-f022-00000000010a') is distinct from 'rt-v2' then
    raise exception 'FAIL: 옛 버전 invalid_grant 가 새 토큰을 지움';
  end if;
  -- 현재 버전 invalid_grant → 재연결 필요·Vault 삭제
  changed := public.youtube_expire_token('00000000-0000-4000-f022-00000000010a', v_new);
  if not changed or public.youtube_refresh_token('00000000-0000-4000-f022-00000000010a') is not null then
    raise exception 'FAIL: 현재 버전 invalid_grant 미처리';
  end if;
  raise notice 'PASS 10 access token 조회는 소유자만, invalid_grant 는 같은 버전일 때만 재연결 필요';
end $$;
reset role;
do $$
begin
  if (select status from public.accounts where id = '00000000-0000-4000-f022-00000000010a') <> 'reconnect_required'
     or exists (select 1 from vault.decrypted_secrets where decrypted_secret in ('rt-v1', 'rt-v2')) then
    raise exception 'FAIL: 이전 버전 secret 이 Vault 에 남음';
  end if;
  raise notice 'PASS 11 재연결 시 이전 버전 secret 삭제';
end $$;

rollback;
