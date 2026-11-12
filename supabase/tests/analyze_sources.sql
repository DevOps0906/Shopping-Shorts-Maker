-- task-016 select_sources(02 원본 선정) 워커 함수(private.analyze_sources_context · save_source_scores) 권한·범위 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/analyze_sources.sql
-- 한 트랜잭션으로 돌리고 ROLLBACK 한다. 워커 쪽은 worker_login(= worker_role 권한)으로 실행한다.
begin;

grant worker_login to postgres with set true;

insert into auth.users (id, aud, role, email) values
  ('00000000-0000-4000-d016-00000000000a', 'authenticated', 'authenticated', 'analyze-test-a@example.com');
insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-d016-00000000010a', '00000000-0000-4000-d016-00000000000a', 'youtube', 'analyze-test');
-- P1: 02 진행 중(선정 단계) · P2: 02 승인 뒤(사용자 체크 유지)
insert into public.projects (id, user_id, account_id, name, step_status) values
  ('00000000-0000-4000-d016-0000000002a1', '00000000-0000-4000-d016-00000000000a',
   '00000000-0000-4000-d016-00000000010a', 'analyze P1',
   '{"1":"approved","2":"ready","3":"idle","4":"idle","5":"idle","6":"idle"}'),
  ('00000000-0000-4000-d016-0000000002a2', '00000000-0000-4000-d016-00000000000a',
   '00000000-0000-4000-d016-00000000010a', 'analyze P2',
   '{"1":"approved","2":"approved","3":"ready","4":"idle","5":"idle","6":"idle"}');
insert into public.sources (id, project_id, platform, url, author, file_path, checked) values
  ('00000000-0000-4000-d016-0000000003a1', '00000000-0000-4000-d016-0000000002a1', 'tiktok', 'https://e.x/1', 'a1', 'p/1.mp4', true),
  ('00000000-0000-4000-d016-0000000003a2', '00000000-0000-4000-d016-0000000002a2', 'tiktok', 'https://e.x/2', 'a2', 'p/2.mp4', true),
  ('00000000-0000-4000-d016-0000000003a3', '00000000-0000-4000-d016-0000000002a2', 'tiktok', 'https://e.x/3', 'a3', null, false);
-- 작업: J1(P1 select_sources running) · J2(P2 select_sources running) · J3(P2 select_sources queued) · J4(P2 analyze running)
insert into public.jobs (id, project_id, step, type, status, idempotency_key) values
  ('00000000-0000-4000-d016-0000000004a1', '00000000-0000-4000-d016-0000000002a1', 2, 'select_sources', 'running', 'analyze-test-1'),
  ('00000000-0000-4000-d016-0000000004a2', '00000000-0000-4000-d016-0000000002a2', 2, 'select_sources', 'running', 'analyze-test-2'),
  ('00000000-0000-4000-d016-0000000004a3', '00000000-0000-4000-d016-0000000002a2', 2, 'select_sources', 'queued', 'analyze-test-3'),
  ('00000000-0000-4000-d016-0000000004a4', '00000000-0000-4000-d016-0000000002a2', 3, 'analyze', 'running', 'analyze-test-4');

-- ── 워커(worker_login) ──────────────────────────────────────
set local role worker_login;
do $$
declare v jsonb; n int;
begin
  -- 직접 테이블 접근 불가
  begin
    perform 1 from public.sources limit 1;
    raise exception 'FAIL: worker_role 이 sources 를 직접 읽음';
  exception when insufficient_privilege then null;
  end;

  v := private.analyze_sources_context('00000000-0000-4000-d016-0000000004a2');
  if v->>'project_id' <> '00000000-0000-4000-d016-0000000002a2'
     or v->>'user_id' <> '00000000-0000-4000-d016-00000000000a'
     or jsonb_array_length(v->'sources') <> 2 then
    raise exception 'FAIL: context %', v;
  end if;

  -- 실행 중이 아닌 작업·select_sources 가 아닌 작업(03 analyze 포함)은 거부
  foreach v in array array['"00000000-0000-4000-d016-0000000004a3"', '"00000000-0000-4000-d016-0000000004a4"']::jsonb[] loop
    begin
      perform private.analyze_sources_context((v #>> '{}')::uuid);
      raise exception 'FAIL: 거부해야 함 %', v;
    exception when object_not_in_prerequisite_state then null;
    end;
  end loop;

  -- 다른 프로젝트 원본은 저장 거부(J2 로 P1 원본)
  begin
    perform private.save_source_scores('00000000-0000-4000-d016-0000000004a2',
      '[{"id":"00000000-0000-4000-d016-0000000003a1","score":50,"exclude_reason":null}]');
    raise exception 'FAIL: 다른 프로젝트 원본 저장';
  exception when invalid_parameter_value then null;
  end;
  -- 점수 범위 밖 거부
  begin
    perform private.save_source_scores('00000000-0000-4000-d016-0000000004a1',
      '[{"id":"00000000-0000-4000-d016-0000000003a1","score":101}]');
    raise exception 'FAIL: 범위 밖 점수 저장';
  exception when invalid_parameter_value then null;
  end;

  -- 선정 단계(P1): 체크 해제 / 02 승인 뒤(P2): 사용자 체크 유지
  n := private.save_source_scores('00000000-0000-4000-d016-0000000004a1',
    '[{"id":"00000000-0000-4000-d016-0000000003a1","score":88.5,"rank":1,"exclude_reason":null}]');
  if n <> 1 then raise exception 'FAIL: P1 저장 %', n; end if;
  n := private.save_source_scores('00000000-0000-4000-d016-0000000004a2',
    '[{"id":"00000000-0000-4000-d016-0000000003a2","score":40,"rank":21,"exclude_reason":"일치도 순위 20위 밖"}]');
  if n <> 1 then raise exception 'FAIL: P2 저장 %', n; end if;
end $$;
reset role;

-- ── 확인(소유자) ────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from public.sources where id = '00000000-0000-4000-d016-0000000003a1'
                 and score = 88.5 and checked = false and exclude_reason is null) then
    raise exception 'FAIL: P1 점수·체크 해제';
  end if;
  if not exists (select 1 from public.sources where id = '00000000-0000-4000-d016-0000000003a2'
                 and score = 40 and checked = true and exclude_reason = '일치도 순위 20위 밖') then
    raise exception 'FAIL: P2 점수·체크 유지';
  end if;
end $$;

-- authenticated 는 함수 실행 불가
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-d016-00000000000a","role":"authenticated"}', true);
do $$
begin
  begin
    perform private.save_source_scores('00000000-0000-4000-d016-0000000004a1', '[]');
    raise exception 'FAIL: authenticated 가 저장 함수 실행';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- create_job: select_sources = 02 단계 · 크레딧 5 · analyze 큐, analyze 는 그대로 03(02 진행 중인 P1 에서 거부)
insert into public.credit_ledger (user_id, kind, delta, reason, idempotency_key) values
  ('00000000-0000-4000-d016-00000000000a', 'charge', 20, 'analyze-test', 'analyze-test-charge');
create temporary table t_q (n bigint) on commit drop;
insert into t_q select count(*) from pgmq.q_analyze;
set local role authenticated;
do $$
declare r jsonb;
begin
  r := public.create_job('00000000-0000-4000-d016-0000000002a1', 'select_sources', 'analyze-test-create-1', '{}');
  if (r->>'step')::int <> 2 or r->>'status' <> 'queued' then
    raise exception 'FAIL: select_sources 생성 %', r;
  end if;
  begin
    perform public.create_job('00000000-0000-4000-d016-0000000002a1', 'analyze', 'analyze-test-create-2', '{}');
    raise exception 'FAIL: 02 진행 중 analyze 생성';
  exception when object_not_in_prerequisite_state then null;
  end;
end $$;
reset role;
do $$
begin
  if (select count(*) from pgmq.q_analyze) <> (select n from t_q) + 1 then
    raise exception 'FAIL: analyze 큐에 메시지 없음';
  end if;
  if (select delta from public.credit_ledger where kind = 'reserve' and job_id =
      (select id from public.jobs where idempotency_key like '%:analyze-test-create-1')) <> -5 then
    raise exception 'FAIL: select_sources 예약 크레딧';
  end if;
end $$;

select 'analyze_sources: 통과' as result;
rollback;
