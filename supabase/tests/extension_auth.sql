-- task-015b-1 확장 토큰·완료/중단 보고·속도 제한·체크 잠금(20261114110000~110200) 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/extension_auth.sql
-- 한 트랜잭션으로 돌리고 ROLLBACK 한다. 서버 경로(service_role → public 래퍼) 그대로 실행한다.
begin;

insert into auth.users (id, aud, role, email) values
  ('00000000-0000-4000-f016-00000000000a', 'authenticated', 'authenticated', 'ext-auth-a@example.com'),
  ('00000000-0000-4000-f016-00000000000b', 'authenticated', 'authenticated', 'ext-auth-b@example.com');
insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-f016-00000000010a', '00000000-0000-4000-f016-00000000000a', 'youtube', 'ext-auth-a'),
  ('00000000-0000-4000-f016-00000000010b', '00000000-0000-4000-f016-00000000000b', 'youtube', 'ext-auth-b');
insert into public.projects (id, user_id, account_id, name, step_status) values
  ('00000000-0000-4000-f016-00000000020a', '00000000-0000-4000-f016-00000000000a',
   '00000000-0000-4000-f016-00000000010a', 'PA',
   '{"1":"approved","2":"idle","3":"idle","4":"idle","5":"idle","6":"idle"}'),
  ('00000000-0000-4000-f016-00000000020b', '00000000-0000-4000-f016-00000000000b',
   '00000000-0000-4000-f016-00000000010b', 'PB',
   '{"1":"approved","2":"idle","3":"idle","4":"idle","5":"idle","6":"idle"}');

insert into public.credit_ledger (user_id, kind, delta, reason, idempotency_key) values
  ('00000000-0000-4000-f016-00000000000a', 'charge', 200, 'ext-auth-test', 'ext-auth-charge-a');

create function pg_temp.h(p text) returns text language sql immutable as $$
  select encode(sha256(convert_to(p, 'utf8')), 'hex');
$$;
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
grant execute on function pg_temp.h(text) to service_role;
grant execute on function pg_temp.expect_fail(text, text, text) to service_role;

-- 서버가 쓰는 확장 행 id 보관
create temp table t_ext (name text primary key, id uuid);
grant select, insert, update on t_ext to service_role;

-- ── 1) 권한 ─────────────────────────────────────────────────
do $$
declare f text; r text;
begin
  foreach f in array array[
    'public.extension_issue(uuid,text,text)', 'public.extension_authenticate(text)',
    'public.extension_rotate(text,text,text)', 'public.extension_revoke(uuid,uuid)',
    'public.extension_rate_hit(text,integer,integer)', 'public.extension_report_complete(uuid,uuid)',
    'public.extension_report_abort(uuid,uuid,text)',
    'private.ext_issue(uuid,text,text)', 'private.ext_authenticate(text)', 'private.ext_rotate(text,text,text)',
    'private.ext_revoke(uuid,uuid)', 'private.rate_hit(text,integer,integer)',
    'private.ext_report_job(uuid,uuid)', 'private.ext_report_complete(uuid,uuid)',
    'private.ext_report_abort(uuid,uuid,text)'] loop
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then raise exception 'FAIL: % 가 % 실행 가능', r, f; end if;
    end loop;
  end loop;
  if has_function_privilege('service_role', 'private.ext_report_job(uuid,uuid)', 'execute') then
    raise exception 'FAIL: service_role 이 보고 잠금 보조 함수 실행 가능';
  end if;
  if has_column_privilege('authenticated', 'public.extension_connections', 'prev_refresh_token_hash', 'SELECT')
     or has_column_privilege('authenticated', 'public.extension_connections', 'refresh_token_hash', 'SELECT')
     or has_column_privilege('authenticated', 'public.extension_connections', 'activated_at', 'UPDATE')
     or has_table_privilege('service_role', 'private.rate_counters', 'SELECT')
     or has_table_privilege('authenticated', 'private.rate_counters', 'SELECT') then
    raise exception 'FAIL: 새 열·테이블 권한 노출';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'private.rate_counters'::regclass) then
    raise exception 'FAIL: rate_counters RLS 꺼짐';
  end if;
  raise notice 'PASS 1 새 함수 anon·authenticated 실행 불가, 새 열·카운터 테이블 노출 없음';
end $$;

-- ── 2) 발급·검사 ────────────────────────────────────────────
set local role service_role;
do $$
declare r record; v_id uuid;
begin
  select * into r from public.extension_issue('00000000-0000-4000-f016-00000000000a', pg_temp.h('a1'), pg_temp.h('r1'));
  v_id := r.extension_id;
  insert into t_ext values ('A1', v_id);
  if r.access_expires_at > now() + interval '15 minutes 1 second' or r.access_expires_at < now() + interval '14 minutes'
     or r.refresh_expires_at < now() + interval '29 days' then
    raise exception 'FAIL: 만료 시각 %', r;
  end if;
  perform pg_temp.expect_fail($q$select * from public.extension_issue('00000000-0000-4000-f016-00000000000a', 'raw-token', 'raw-refresh')$q$,
                              '22023', '원문(해시 아님) 거부');
  select * into r from public.extension_authenticate(pg_temp.h('a1'));
  if r.extension_id is distinct from v_id or r.user_id <> '00000000-0000-4000-f016-00000000000a' then
    raise exception 'FAIL: 유효 토큰 검사 %', r;
  end if;
  if exists (select 1 from public.extension_authenticate(pg_temp.h('nope'))) then
    raise exception 'FAIL: 없는 토큰 통과';
  end if;
  raise notice 'PASS 2 발급(해시만)·유효 토큰 검사·해시 형식 아님 거부';
end $$;
reset role;

do $$
begin
  -- 저장된 값은 해시뿐: 원문 문자열이 어느 열에도 없음, 발급 직후 activated_at 은 null
  if exists (select 1 from public.extension_connections
             where access_token_hash in ('a1', 'raw-token') or refresh_token_hash in ('r1', 'raw-refresh')
                or char_length(access_token_hash) <> 64 or char_length(refresh_token_hash) <> 64) then
    raise exception 'FAIL: 해시가 아닌 값 저장';
  end if;
  if (select activated_at from public.extension_connections where id = (select id from t_ext where name = 'A1')) is not null then
    raise exception 'FAIL: 발급 직후 activated_at';
  end if;
  raise notice 'PASS 3 DB 에는 SHA-256 해시만 저장, 미활성 상태로 시작';
end $$;

-- ── 4) 회전: CAS 1건만 성공, prev 재사용 시 행 폐기 ──────────
set local role service_role;
do $$
declare r record; v_id uuid := (select id from t_ext where name = 'A1');
begin
  select * into r from public.extension_rotate(pg_temp.h('r1'), pg_temp.h('a2'), pg_temp.h('r2'));
  if r.result <> 'ok' or r.extension_id <> v_id then raise exception 'FAIL: 회전 %', r; end if;
  if (select count(*) from public.extension_connections where user_id = '00000000-0000-4000-f016-00000000000a') <> 1 then
    raise exception 'FAIL: 새 행이 생김(제자리 회전이어야 함)';
  end if;
  if exists (select 1 from public.extension_authenticate(pg_temp.h('a1'))) then
    raise exception 'FAIL: 회전 전 액세스 토큰 통과';
  end if;
  if not exists (select 1 from public.extension_authenticate(pg_temp.h('a2'))) then
    raise exception 'FAIL: 새 액세스 토큰 거부';
  end if;
  -- 같은 옛 갱신 토큰으로 다시: 성공은 1건뿐, 두 번째는 재사용으로 행 폐기
  select * into r from public.extension_rotate(pg_temp.h('r1'), pg_temp.h('a3'), pg_temp.h('r3'));
  if r.result <> 'reused' or r.extension_id <> v_id then raise exception 'FAIL: 재사용 감지 %', r; end if;
  if exists (select 1 from public.extension_authenticate(pg_temp.h('a2'))) then
    raise exception 'FAIL: 재사용 감지 뒤에도 새 액세스 토큰 통과';
  end if;
  select * into r from public.extension_rotate(pg_temp.h('r2'), pg_temp.h('a4'), pg_temp.h('r4'));
  if r.result <> 'invalid' then raise exception 'FAIL: 폐기된 행 현재 갱신 토큰 %', r; end if;
  select * into r from public.extension_rotate(pg_temp.h('unknown'), pg_temp.h('a5'), pg_temp.h('r5'));
  if r.result <> 'invalid' then raise exception 'FAIL: 모르는 갱신 토큰 %', r; end if;
  raise notice 'PASS 4 제자리 회전, 옛 액세스 즉시 무효, prev 재사용 → 행 폐기, 폐기·미지 토큰 invalid';
end $$;
reset role;

do $$
begin
  if (select revoked_at from public.extension_connections where id = (select id from t_ext where name = 'A1')) is null
     or (select prev_refresh_token_hash from public.extension_connections where id = (select id from t_ext where name = 'A1')) <> pg_temp.h('r1')
     or (select rotated_at from public.extension_connections where id = (select id from t_ext where name = 'A1')) is null then
    raise exception 'FAIL: 회전·폐기 기록';
  end if;
  raise notice 'PASS 5 prev 해시·rotated_at·revoked_at 기록';
end $$;

-- ── 6) 만료·폐기 토큰 거부, 폐기 소유자 검사 ─────────────────
set local role service_role;
do $$
declare r record; v_id uuid; v_other uuid;
begin
  select * into r from public.extension_issue('00000000-0000-4000-f016-00000000000a', pg_temp.h('a6'), pg_temp.h('r6'));
  v_id := r.extension_id;
  insert into t_ext values ('A6', v_id);
  select * into r from public.extension_issue('00000000-0000-4000-f016-00000000000b', pg_temp.h('b1'), pg_temp.h('rb1'));
  insert into t_ext values ('B1', r.extension_id);
  v_other := r.extension_id;
  if public.extension_revoke(v_id, '00000000-0000-4000-f016-00000000000b') then
    raise exception 'FAIL: 남의 확장 폐기됨';
  end if;
  if not public.extension_revoke(v_other, '00000000-0000-4000-f016-00000000000b') then
    raise exception 'FAIL: 본인 확장 폐기 실패';
  end if;
  if public.extension_revoke(v_other, '00000000-0000-4000-f016-00000000000b') then
    raise exception 'FAIL: 이미 폐기된 확장 재폐기가 true';
  end if;
  if exists (select 1 from public.extension_authenticate(pg_temp.h('b1'))) then
    raise exception 'FAIL: 폐기 토큰 통과';
  end if;
  raise notice 'PASS 6a 폐기는 본인 행만, 폐기 토큰 거부';
end $$;
reset role;

update public.extension_connections set access_expires_at = now() - interval '1 second'
  where id = (select id from t_ext where name = 'A6');
set local role service_role;
do $$
declare r record;
begin
  if exists (select 1 from public.extension_authenticate(pg_temp.h('a6'))) then
    raise exception 'FAIL: 만료 액세스 토큰 통과';
  end if;
  -- 갱신 토큰은 살아 있으니 회전 가능, 갱신 만료면 invalid
  select * into r from public.extension_rotate(pg_temp.h('r6'), pg_temp.h('a7'), pg_temp.h('r7'));
  if r.result <> 'ok' then raise exception 'FAIL: 액세스 만료 후 회전 %', r; end if;
  raise notice 'PASS 6b 만료 액세스 거부, 갱신 토큰으로 회전';
end $$;
reset role;
update public.extension_connections set refresh_expires_at = now() - interval '1 second'
  where id = (select id from t_ext where name = 'A6');
set local role service_role;
do $$
declare r record;
begin
  if exists (select 1 from public.extension_authenticate(pg_temp.h('a7'))) then
    raise exception 'FAIL: 갱신 만료 행의 액세스 통과';
  end if;
  select * into r from public.extension_rotate(pg_temp.h('r7'), pg_temp.h('a8'), pg_temp.h('r8'));
  if r.result <> 'invalid' then raise exception 'FAIL: 만료 갱신 토큰 회전 %', r; end if;
  raise notice 'PASS 6c 갱신 만료 행 거부';
end $$;
reset role;

-- ── 7) 스위퍼: 미활성 10분 행 폐기, 활성·최근 행 유지, 속도 제한 창 정리 ──
set local role service_role;
do $$
declare r record;
begin
  select * into r from public.extension_issue('00000000-0000-4000-f016-00000000000a', pg_temp.h('sw-old'), pg_temp.h('sw-old-r'));
  insert into t_ext values ('SWOLD', r.extension_id);
  select * into r from public.extension_issue('00000000-0000-4000-f016-00000000000a', pg_temp.h('sw-new'), pg_temp.h('sw-new-r'));
  insert into t_ext values ('SWNEW', r.extension_id);
  select * into r from public.extension_issue('00000000-0000-4000-f016-00000000000a', pg_temp.h('sw-act'), pg_temp.h('sw-act-r'));
  insert into t_ext values ('SWACT', r.extension_id);
  perform * from public.extension_heartbeat(r.extension_id);   -- 활성화
  perform public.extension_rate_hit('ext:test-sweep', 5, 60);
end $$;
reset role;
update public.extension_connections set created_at = now() - interval '11 minutes'
  where id in (select id from t_ext where name in ('SWOLD', 'SWACT'));
update private.rate_counters set window_start = now() - interval '2 days' where key = 'ext:test-sweep';
do $$
declare v jsonb;
begin
  v := private.sweep_jobs();
  if (v ->> 'ext_unactivated')::int < 1 or (v ->> 'rate_pruned')::int < 1 then raise exception 'FAIL: 스위퍼 결과 %', v; end if;
  if (select revoked_at from public.extension_connections where id = (select id from t_ext where name = 'SWOLD')) is null then
    raise exception 'FAIL: 미활성 10분 행 미폐기';
  end if;
  if exists (select 1 from public.extension_connections
             where id in (select id from t_ext where name in ('SWNEW', 'SWACT')) and revoked_at is not null) then
    raise exception 'FAIL: 최근·활성 행 폐기됨';
  end if;
  if exists (select 1 from private.rate_counters where key = 'ext:test-sweep') then
    raise exception 'FAIL: 오래된 속도 제한 창 미정리';
  end if;
  raise notice 'PASS 7 스위퍼: 미활성 10분 행 폐기, 활성·신규 유지, 오래된 속도 제한 창 정리';
end $$;

-- ── 8) 속도 제한 ────────────────────────────────────────────
set local role service_role;
do $$
begin
  if not public.extension_rate_hit('ext:test-rl', 2, 60) or not public.extension_rate_hit('ext:test-rl', 2, 60) then
    raise exception 'FAIL: 한도 안인데 false';
  end if;
  if public.extension_rate_hit('ext:test-rl', 2, 60) or public.extension_rate_hit('ext:test-rl', 2, 60) then
    raise exception 'FAIL: 한도 초과인데 true';
  end if;
  if not public.extension_rate_hit('ext:test-rl-other', 2, 60) then raise exception 'FAIL: 다른 키가 영향받음'; end if;
  perform pg_temp.expect_fail($q$select public.extension_rate_hit('', 2, 60)$q$, '22023', '빈 키');
  perform pg_temp.expect_fail($q$select public.extension_rate_hit('other:k', 2, 60)$q$, '22023', '허용 밖 접두어');
  perform pg_temp.expect_fail($q$select public.extension_rate_hit('ext:k', 0, 60)$q$, '22023', '한도 0');
  perform pg_temp.expect_fail($q$select public.extension_rate_hit('ext:k', 2, 0)$q$, '22023', '창 0');
  if not public.extension_rate_hit('user:u1:connect', 1, 60) or not public.extension_rate_hit('ip:abc:auth', 1, 60) then
    raise exception 'FAIL: user·ip 접두어 거부';
  end if;
  raise notice 'PASS 8 rate_hit: 한도 안 true, 초과 false, 키 분리, 인자 검증';
end $$;
reset role;

-- ── 9) 작업 생성(사용자 A): collect 3개 + collect_download ────
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-f016-00000000000a","role":"authenticated"}', true);
create temp table t_jobs (name text primary key, id uuid);
grant select, insert on t_jobs to authenticated, service_role;
do $$
begin
  insert into t_jobs select 'C1', (public.create_job('00000000-0000-4000-f016-00000000020a', 'collect', 'ext-auth-c1') ->> 'id')::uuid;
  -- 두 번째 활성 collect 는 create_job 이 거부(EX001)
  perform pg_temp.expect_fail($q$select public.create_job('00000000-0000-4000-f016-00000000020a', 'collect', 'ext-auth-c2')$q$,
                              'EX001', '활성 collect 중 collect 생성');
end $$;
reset role;
-- 보고 시나리오용 C2·C3 는 직접 삽입(기존 데이터에 여러 활성 job 이 있는 경우를 흉내)
do $$
declare v_id uuid;
begin
  for v_id in
    insert into public.jobs (project_id, step, type, status, idempotency_key)
    values ('00000000-0000-4000-f016-00000000020a', 2, 'collect', 'waiting_extension', 'ext-auth-c2-direct'),
           ('00000000-0000-4000-f016-00000000020a', 2, 'collect', 'waiting_extension', 'ext-auth-c3-direct')
    returning id loop
    insert into public.credit_ledger (user_id, project_id, job_id, kind, delta, reason, idempotency_key)
    values ('00000000-0000-4000-f016-00000000000a', '00000000-0000-4000-f016-00000000020a', v_id, 'reserve',
            -private.job_cost('collect'), 'collect', 'reserve:' || v_id);
  end loop;
  insert into t_jobs select 'C2', id from public.jobs where idempotency_key = 'ext-auth-c2-direct';
  insert into t_jobs select 'C3', id from public.jobs where idempotency_key = 'ext-auth-c3-direct';
end $$;

-- ── 10) 완료·중단 보고(collect) ─────────────────────────────
set local role service_role;
do $$
declare v_ea uuid := (select id from t_ext where name = 'SWACT');
        v_eb uuid := (select id from t_ext where name = 'B1');
        c1 uuid := (select id from t_jobs where name = 'C1');
        c3 uuid := (select id from t_jobs where name = 'C3');
        n int;
begin
  -- claim 전(waiting) 보고는 409, 남의 확장은 403 계열
  perform pg_temp.expect_fail(format('select public.extension_report_complete(%L, %L)', v_ea, c1), 'EX409', 'claim 전 완료 보고');
  select count(*) into n from public.extension_claim_job(v_ea, c1);
  if n <> 1 then raise exception 'FAIL: claim'; end if;
  perform pg_temp.expect_fail(format('select public.extension_report_complete(%L, %L)', v_eb, c1), '42501', '남의 확장 완료 보고');
  perform pg_temp.expect_fail(format('select public.extension_report_abort(%L, %L, %L)', v_ea, c1, 'bogus'), '22023', '알 수 없는 사유');
  if public.extension_report_complete(v_ea, c1) <> 'succeeded' then raise exception 'FAIL: collect 완료'; end if;
  perform pg_temp.expect_fail(format('select public.extension_report_complete(%L, %L)', v_ea, c1), 'EX409', '완료 후 재보고');
  perform pg_temp.expect_fail(format('select public.extension_report_abort(%L, %L, %L)', v_ea, c1, 'captcha'), 'EX409', '완료 후 중단 보고');

  -- 중단: failed + 사유 코드 + 예약 반환
  select count(*) into n from public.extension_claim_job(v_ea, c3);
  if n <> 1 then raise exception 'FAIL: claim C3'; end if;
  perform public.extension_report_abort(v_ea, c3, 'captcha');
  raise notice 'PASS 9 완료 보고(collect)·재보고 409·남의 확장 거부·중단 사유 검증';
end $$;
reset role;

do $$
declare c1 uuid := (select id from t_jobs where name = 'C1');
        c3 uuid := (select id from t_jobs where name = 'C3');
begin
  if (select status from public.jobs where id = c1) <> 'succeeded'
     or (select count(*) from public.credit_ledger where job_id = c1 and kind = 'settle') <> 1
     or (select count(*) from public.credit_ledger where job_id = c1 and kind = 'release') <> 0 then
    raise exception 'FAIL: 완료 정산 1회';
  end if;
  if (select (status, error) from public.jobs where id = c3) is distinct from ('failed'::text, 'captcha'::text)
     or (select finished_at from public.jobs where id = c3) is null
     or (select count(*) from public.credit_ledger where job_id = c3 and kind = 'release') <> 1
     or (select count(*) from public.credit_ledger where job_id = c3 and kind = 'settle') <> 0 then
    raise exception 'FAIL: 중단 보고 상태·반환';
  end if;
  raise notice 'PASS 10 완료 정산 정확히 1회, 중단은 failed(captcha)+예약 반환 1회';
end $$;

-- ── 11) 스위퍼가 waiting 으로 돌린 job 의 늦은 보고 거부 ──────
set local role service_role;
do $$
declare v_ea uuid := (select id from t_ext where name = 'SWACT');
        c2 uuid := (select id from t_jobs where name = 'C2'); n int;
begin
  select count(*) into n from public.extension_claim_job(v_ea, c2);
  if n <> 1 then raise exception 'FAIL: claim C2'; end if;
end $$;
reset role;
update public.extension_connections set last_heartbeat_at = now() - interval '3 minutes'
  where id = (select id from t_ext where name = 'SWACT');
update public.jobs set started_at = now() - interval '3 minutes' where id = (select id from t_jobs where name = 'C2');
do $$
declare v jsonb := private.sweep_jobs();
begin
  if (select status from public.jobs where id = (select id from t_jobs where name = 'C2')) <> 'waiting_extension' then
    raise exception 'FAIL: 끊김 스위프 %', v;
  end if;
end $$;
set local role service_role;
do $$
begin
  perform pg_temp.expect_fail(format('select public.extension_report_complete(%L, %L)',
    (select id from t_ext where name = 'SWACT'), (select id from t_jobs where name = 'C2')), 'EX409', '늦은 완료 보고');
  perform pg_temp.expect_fail(format('select public.extension_report_abort(%L, %L, %L)',
    (select id from t_ext where name = 'SWACT'), (select id from t_jobs where name = 'C2'), 'risk_control'), 'EX409', '늦은 중단 보고');
  raise notice 'PASS 11 스위퍼가 대기로 돌린 job 의 늦은 완료·중단 보고 거부';
end $$;
reset role;
do $$
begin
  if (select status from public.jobs where id = (select id from t_jobs where name = 'C2')) <> 'waiting_extension'
     or exists (select 1 from public.credit_ledger where job_id = (select id from t_jobs where name = 'C2') and kind in ('settle', 'release')) then
    raise exception 'FAIL: 늦은 보고가 상태·원장을 바꿈';
  end if;
end $$;

-- 남은 수집 작업 정리(활성 job 없음 상태로)
update public.jobs set status = 'failed', finished_at = now(), error = 'test' where id = (select id from t_jobs where name = 'C2');

-- ── 12) collect_download: running 유지 + files_reported_at + sources 큐 ──
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-f016-00000000000a","role":"authenticated"}', true);
do $$
begin
  insert into t_jobs select 'D1', (public.create_job('00000000-0000-4000-f016-00000000020a', 'collect_download', 'ext-auth-d1') ->> 'id')::uuid;
  -- 프로젝트당 활성 확장 job 1개: 활성 collect(없음)·collect_download(D1) 있으면 둘 다 거부
  perform pg_temp.expect_fail($q$select public.create_job('00000000-0000-4000-f016-00000000020a', 'collect', 'ext-auth-c9')$q$,
                              'EX001', '활성 확장 job 중 collect 생성');
  -- 프로젝트당 활성 collect_download 1개: 다른 키는 거부, 같은 키는 기존 작업 반환
  perform pg_temp.expect_fail($q$select public.create_job('00000000-0000-4000-f016-00000000020a', 'collect_download', 'ext-auth-d2')$q$,
                              'EX001', '두 번째 활성 collect_download');
  if (public.create_job('00000000-0000-4000-f016-00000000020a', 'collect_download', 'ext-auth-d1') ->> 'created')::boolean then
    raise exception 'FAIL: 같은 키 재요청이 새로 생성';
  end if;
end $$;
reset role;

set local role service_role;
do $$
declare v_ea uuid := (select id from t_ext where name = 'SWACT');
        d1 uuid := (select id from t_jobs where name = 'D1'); n int;
begin
  select count(*) into n from public.extension_claim_job(v_ea, d1);
  if n <> 1 then raise exception 'FAIL: claim D1'; end if;
  if public.extension_report_complete(v_ea, d1) <> 'rechecking' then raise exception 'FAIL: collect_download 완료'; end if;
  if public.extension_report_complete(v_ea, d1) <> 'already_reported' then raise exception 'FAIL: 재전송'; end if;
  perform pg_temp.expect_fail(format('select public.extension_report_abort(%L, %L, %L)', v_ea, d1, 'captcha'), 'EX409', '파일 보고 뒤 중단');
  perform pg_temp.expect_fail(format('select public.extension_collect_download(%L, %L, %L::jsonb)', v_ea, d1,
    '[{"id":"00000000-0000-4000-f016-0000000005a1","file_path":"x/y/z.mp4"}]'), 'EX409', '보고 뒤 파일 경로 변경');
end $$;
reset role;

do $$
declare d1 uuid := (select id from t_jobs where name = 'D1');
begin
  if (select (status, files_reported_at is not null) from public.jobs where id = d1) is distinct from ('running'::text, true) then
    raise exception 'FAIL: collect_download 완료 후 상태';
  end if;
  if (select count(*) from pgmq.q_sources where message ->> 'job_id' = d1::text) <> 1 then
    raise exception 'FAIL: sources 큐 메시지 정확히 1건';
  end if;
  if exists (select 1 from public.credit_ledger where job_id = d1 and kind in ('settle', 'release')) then
    raise exception 'FAIL: 워커 재검사 전 정산됨';
  end if;
  -- 하트비트가 끊겨도 파일 보고된 작업은 waiting 으로 돌리지 않는다
  update public.extension_connections set last_heartbeat_at = now() - interval '3 minutes'
    where id = (select id from t_ext where name = 'SWACT');
  update public.jobs set started_at = now() - interval '3 minutes' where id = d1;
  perform private.sweep_jobs();
  if (select status from public.jobs where id = d1) <> 'running' then
    raise exception 'FAIL: 파일 보고된 작업이 끊김으로 대기됨';
  end if;
  raise notice 'PASS 12 collect_download 완료: running 유지·files_reported_at·sources 큐 1건·정산 없음·끊김 스위프 제외';
end $$;

-- ── 13) 활성 확장 job 이 있으면 체크·select_sources 생성 거부 ──
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-f016-00000000000a","role":"authenticated"}', true);
do $$
begin
  perform pg_temp.expect_fail($q$select public.set_source_checks('00000000-0000-4000-f016-00000000020a', '{}')$q$,
                              'EX001', '활성 확장 job 중 체크 변경');
  perform pg_temp.expect_fail($q$select public.create_job('00000000-0000-4000-f016-00000000020a', 'select_sources', 'ext-auth-s1')$q$,
                              'EX001', '활성 확장 job 중 select_sources 생성');
end $$;
reset role;

-- 워커가 끝낸 것으로 보고 풀면 다시 허용
update public.jobs set status = 'succeeded', finished_at = now() where id = (select id from t_jobs where name = 'D1');
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-f016-00000000000a","role":"authenticated"}', true);
do $$
begin
  if public.set_source_checks('00000000-0000-4000-f016-00000000020a', '{}') <> 0 then raise exception 'FAIL: 체크 변경 허용'; end if;
  perform public.create_job('00000000-0000-4000-f016-00000000020a', 'select_sources', 'ext-auth-s1');
  raise notice 'PASS 13 활성 확장 job 중 set_source_checks·select_sources 생성 거부(EX001), 종료 후 허용';
end $$;
reset role;

rollback;
