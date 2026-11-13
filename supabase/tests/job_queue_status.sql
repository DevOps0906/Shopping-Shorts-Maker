-- task-035b 대기 순번·예상 대기 시간 조회 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/job_queue_status.sql
-- 전체를 한 트랜잭션으로 돌리고 ROLLBACK 한다.
begin;

insert into auth.users (id, aud, role, email) values
  ('00000000-0000-4000-c000-0000000000d1', 'authenticated', 'authenticated', 'qs-test-a@example.com'),
  ('00000000-0000-4000-c000-0000000000d2', 'authenticated', 'authenticated', 'qs-test-b@example.com'),
  ('00000000-0000-4000-c000-0000000000d3', 'authenticated', 'authenticated', 'qs-test-c@example.com');

insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-c100-0000000000d1', '00000000-0000-4000-c000-0000000000d1', 'youtube', 'qs-test A'),
  ('00000000-0000-4000-c100-0000000000d2', '00000000-0000-4000-c000-0000000000d2', 'youtube', 'qs-test B'),
  ('00000000-0000-4000-c100-0000000000d3', '00000000-0000-4000-c000-0000000000d3', 'youtube', 'qs-test C');

-- 사용자 A 프로젝트 6개, 사용자 B 3개
insert into public.projects (id, user_id, account_id, name) values
  ('00000000-0000-4000-c200-0000000000d1', '00000000-0000-4000-c000-0000000000d1', '00000000-0000-4000-c100-0000000000d1', 'qs A1'),
  ('00000000-0000-4000-c200-0000000000d2', '00000000-0000-4000-c000-0000000000d1', '00000000-0000-4000-c100-0000000000d1', 'qs A2'),
  ('00000000-0000-4000-c200-0000000000d3', '00000000-0000-4000-c000-0000000000d1', '00000000-0000-4000-c100-0000000000d1', 'qs A3'),
  ('00000000-0000-4000-c200-0000000000d4', '00000000-0000-4000-c000-0000000000d1', '00000000-0000-4000-c100-0000000000d1', 'qs A4'),
  ('00000000-0000-4000-c200-0000000000d5', '00000000-0000-4000-c000-0000000000d1', '00000000-0000-4000-c100-0000000000d1', 'qs A5'),
  ('00000000-0000-4000-c200-0000000000d6', '00000000-0000-4000-c000-0000000000d1', '00000000-0000-4000-c100-0000000000d1', 'qs A6'),
  ('00000000-0000-4000-c200-0000000000e1', '00000000-0000-4000-c000-0000000000d2', '00000000-0000-4000-c100-0000000000d2', 'qs SECRET B1'),
  ('00000000-0000-4000-c200-0000000000e2', '00000000-0000-4000-c000-0000000000d2', '00000000-0000-4000-c100-0000000000d2', 'qs SECRET B2'),
  ('00000000-0000-4000-c200-0000000000e3', '00000000-0000-4000-c000-0000000000d2', '00000000-0000-4000-c100-0000000000d2', 'qs SECRET B3'),
  ('00000000-0000-4000-c200-0000000000f1', '00000000-0000-4000-c000-0000000000d3', '00000000-0000-4000-c100-0000000000d3', 'qs SECRET C1');

-- 제작: B 렌더 1 실행·1 대기(B 본인 실행 중이라 미룸), C 렌더 1 대기(미룸 아님), A 렌더 3 대기, A 음성 1 실행·1 대기(미룸)
insert into public.jobs (id, project_id, step, type, status, idempotency_key, started_at, created_at) values
  ('00000000-0000-4000-c300-0000000000e1', '00000000-0000-4000-c200-0000000000e1', 5, 'render', 'running', 'qs-b-run-1', now() - interval '1 minute', now() - interval '60 minutes'),
  ('00000000-0000-4000-c300-0000000000e2', '00000000-0000-4000-c200-0000000000e2', 5, 'render', 'queued', 'qs-b-q-1', null, now() - interval '50 minutes'),
  ('00000000-0000-4000-c300-0000000000f1', '00000000-0000-4000-c200-0000000000f1', 5, 'render', 'queued', 'qs-c-q-1', null, now() - interval '45 minutes'),
  ('00000000-0000-4000-c300-0000000000d1', '00000000-0000-4000-c200-0000000000d1', 5, 'render', 'queued', 'qs-a-r-1', null, now() - interval '40 minutes'),
  ('00000000-0000-4000-c300-0000000000d2', '00000000-0000-4000-c200-0000000000d2', 5, 'render', 'queued', 'qs-a-r-2', null, now() - interval '30 minutes'),
  ('00000000-0000-4000-c300-0000000000d3', '00000000-0000-4000-c200-0000000000d3', 5, 'render', 'queued', 'qs-a-r-3', null, now() - interval '20 minutes'),
  ('00000000-0000-4000-c300-0000000000d4', '00000000-0000-4000-c200-0000000000d1', 4, 'tts', 'running', 'qs-a-t-1', now() - interval '30 seconds', now() - interval '10 minutes'),
  ('00000000-0000-4000-c300-0000000000d5', '00000000-0000-4000-c200-0000000000d2', 4, 'tts', 'queued', 'qs-a-t-2', null, now() - interval '9 minutes');

-- 포스팅: B 업로드 대기(가장 먼저)·재시도 대기(기한 지남), A 5건 + 확인 필요 1건
insert into public.publications (id, project_id, account_id, mode, status, prepared_at, next_attempt_at, scheduled_at, retry_count, error) values
  ('00000000-0000-4000-c400-0000000000e1', '00000000-0000-4000-c200-0000000000e1', '00000000-0000-4000-c100-0000000000d2', 'now', 'pending', now() - interval '100 minutes', null, null, 0, null),
  ('00000000-0000-4000-c400-0000000000e2', '00000000-0000-4000-c200-0000000000e2', '00000000-0000-4000-c100-0000000000d2', 'now', 'retry_wait', now() - interval '200 minutes', now() - interval '10 minutes', null, 1, 'transient:http_503'),
  ('00000000-0000-4000-c400-0000000000d1', '00000000-0000-4000-c200-0000000000d1', '00000000-0000-4000-c100-0000000000d1', 'now', 'pending', now() - interval '50 minutes', null, null, 0, null),
  ('00000000-0000-4000-c400-0000000000d2', '00000000-0000-4000-c200-0000000000d2', '00000000-0000-4000-c100-0000000000d1', 'now', 'pending', now() - interval '5 minutes', null, null, 0, null),
  ('00000000-0000-4000-c400-0000000000d3', '00000000-0000-4000-c200-0000000000d3', '00000000-0000-4000-c100-0000000000d1', 'now', 'retry_wait', now() - interval '90 minutes', now() + interval '30 minutes', null, 2, 'quota:daily_limit'),
  ('00000000-0000-4000-c400-0000000000d4', '00000000-0000-4000-c200-0000000000d4', '00000000-0000-4000-c100-0000000000d1', 'scheduled', 'scheduled', now() - interval '3 hours', null, now() + interval '1 day', 0, null),
  ('00000000-0000-4000-c400-0000000000d5', '00000000-0000-4000-c200-0000000000d5', '00000000-0000-4000-c100-0000000000d1', 'now', 'reconnect_wait', now() - interval '3 hours', null, null, 0, 'reconnect:reconnect_required'),
  ('00000000-0000-4000-c400-0000000000d6', '00000000-0000-4000-c200-0000000000d6', '00000000-0000-4000-c100-0000000000d1', 'now', 'needs_check', now() - interval '3 hours', null, null, 3, 'unknown:stale_attempt');

create temporary table t_res (name text primary key, body jsonb) on commit drop;
grant select, insert on t_res to authenticated;

-- ── 사용자 A ────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c000-0000000000d1","role":"authenticated"}', true);
insert into t_res values ('a1', public.job_queue_status());
reset role;

do $$
declare b jsonb := (select body from t_res where name = 'a1'); p jsonb; x jsonb;
begin
  p := b -> 'production';
  if jsonb_array_length(p) <> 5 then raise exception 'FAIL: A 제작 % 건(5 이어야)', jsonb_array_length(p); end if;
  if b::text like '%SECRET%' or b::text like '%00000000-0000-4000-c300-0000000000e%'
     or b::text like '%00000000-0000-4000-c400-0000000000e%' or b::text like '%00000000-0000-4000-c200-0000000000e%' then
    raise exception 'FAIL: 남의 작업·프로젝트·발행이 노출됨';
  end if;

  -- 렌더 순번: 앞선 대기 = C 1건(B 의 미룸 대기는 나보다 먼저 시작하지 못하므로 제외) → A1 은 2번째, A2 3번째, A3 4번째. 표본 없음 → 시간 제한 600초의 절반 300초 ÷ 동시 1
  select e into x from jsonb_array_elements(p) e where e ->> 'job_id' = '00000000-0000-4000-c300-0000000000d1';
  if x ->> 'state' <> 'queued' or (x ->> 'position')::int <> 2 or (x ->> 'eta_seconds')::int <> 600 then
    raise exception 'FAIL: A1 %', x;
  end if;
  select e into x from jsonb_array_elements(p) e where e ->> 'job_id' = '00000000-0000-4000-c300-0000000000d3';
  if (x ->> 'position')::int <> 4 or (x ->> 'eta_seconds')::int <> 1200 then raise exception 'FAIL: A3 %', x; end if;

  -- 음성: 실행 중 1건 + 미룸 1건(순번·예상 없음)
  select e into x from jsonb_array_elements(p) e where e ->> 'job_id' = '00000000-0000-4000-c300-0000000000d4';
  if x ->> 'state' <> 'running' or x ->> 'position' is not null or x ->> 'started_at' is null then
    raise exception 'FAIL: 실행 중 음성 %', x;
  end if;
  select e into x from jsonb_array_elements(p) e where e ->> 'job_id' = '00000000-0000-4000-c300-0000000000d5';
  if x ->> 'state' <> 'deferred' or x ->> 'position' is not null or x ->> 'eta_seconds' is not null then
    raise exception 'FAIL: 미룸 음성 %', x;
  end if;
  raise notice 'PASS 1 제작: 본인만, 순번(앞선 대기+1)·예상(표본 없으면 제한의 절반), 미룸·실행 중은 순번 없음';

  p := b -> 'posting';
  if jsonb_array_length(p) <> 6 then raise exception 'FAIL: A 포스팅 % 건(6 이어야)', jsonb_array_length(p); end if;
  -- claim 정렬: B 대기(-100분) 뒤 A d1 → 2번째, B 재시도(-10분)·A d2(-5분) 기준 A d2 는 앞 3건 → 4번째
  select e into x from jsonb_array_elements(p) e where e ->> 'publication_id' = '00000000-0000-4000-c400-0000000000d1';
  if x ->> 'state' <> 'pending' or (x ->> 'position')::int <> 2 or x ->> 'est_start_at' is null then
    raise exception 'FAIL: 업로드 대기 d1 %', x;
  end if;
  select e into x from jsonb_array_elements(p) e where e ->> 'publication_id' = '00000000-0000-4000-c400-0000000000d2';
  if (x ->> 'position')::int <> 4 then raise exception 'FAIL: 업로드 대기 d2 %', x; end if;
  -- 아직 때가 안 된 재시도: 순번 없이 예상 시작 = next_attempt_at
  select e into x from jsonb_array_elements(p) e where e ->> 'publication_id' = '00000000-0000-4000-c400-0000000000d3';
  if x ->> 'state' <> 'retry_wait' or x ->> 'position' is not null or x ->> 'est_start_at' is null then
    raise exception 'FAIL: 재시도 대기 d3 %', x;
  end if;
  select e into x from jsonb_array_elements(p) e where e ->> 'publication_id' = '00000000-0000-4000-c400-0000000000d4';
  if x ->> 'state' <> 'scheduled' or x ->> 'scheduled_at' is null then raise exception 'FAIL: 예약됨 %', x; end if;
  select e into x from jsonb_array_elements(p) e where e ->> 'publication_id' = '00000000-0000-4000-c400-0000000000d5';
  if x ->> 'state' <> 'reconnect_wait' then raise exception 'FAIL: 재연결 필요 %', x; end if;
  select e into x from jsonb_array_elements(p) e where e ->> 'publication_id' = '00000000-0000-4000-c400-0000000000d6';
  if x ->> 'state' <> 'failed' then raise exception 'FAIL: needs_check 는 실패로 표시 %', x; end if;
  raise notice 'PASS 2 포스팅: 본인만, claim 정렬 기준 순번·예상 시작, 재시도·예약·재연결·실패 상태';
end $$;

-- 표본 3건(60·120·180초) 성공 → 중앙값 120초 로 예상이 바뀐다
insert into public.jobs (project_id, step, type, status, idempotency_key, started_at, finished_at) values
  ('00000000-0000-4000-c200-0000000000e3', 5, 'render', 'succeeded', 'qs-s-1', now() - interval '10 minutes', now() - interval '9 minutes'),
  ('00000000-0000-4000-c200-0000000000e3', 5, 'render', 'succeeded', 'qs-s-2', now() - interval '20 minutes', now() - interval '18 minutes'),
  ('00000000-0000-4000-c200-0000000000e3', 5, 'render', 'succeeded', 'qs-s-3', now() - interval '30 minutes', now() - interval '27 minutes');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c000-0000000000d1","role":"authenticated"}', true);
insert into t_res values ('a2', public.job_queue_status());
reset role;
do $$
declare x jsonb;
begin
  select e into x from jsonb_array_elements((select body from t_res where name = 'a2') -> 'production') e
   where e ->> 'job_id' = '00000000-0000-4000-c300-0000000000d3';
  if (x ->> 'eta_seconds')::int <> 480 then raise exception 'FAIL: 중앙값 120 x (앞 3 + 실행 1) = 480 이어야 %', x; end if;
  raise notice 'PASS 3 예상 = 앞선 수 x 최근 성공 소요 중앙값 / 큐 동시 처리 수';
end $$;

-- ── 사용자 B 는 자기 것만 ───────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c000-0000000000d2","role":"authenticated"}', true);
insert into t_res values ('b', public.job_queue_status());
reset role;
do $$
declare b jsonb := (select body from t_res where name = 'b'); x jsonb;
begin
  if jsonb_array_length(b -> 'production') <> 2 or jsonb_array_length(b -> 'posting') <> 2 then
    raise exception 'FAIL: B 건수 %', b;
  end if;
  if b::text like '%qs A%' or b::text like '%00000000-0000-4000-c300-0000000000d%' then
    raise exception 'FAIL: B 에게 A 의 작업이 보임';
  end if;
  -- B 의 대기 작업은 자기 실행 중 작업 때문에 미룸: 순번·예상 없음
  select e into x from jsonb_array_elements(b -> 'production') e
   where e ->> 'job_id' = '00000000-0000-4000-c300-0000000000e2';
  if x is null or x ->> 'state' is distinct from 'deferred' or x ->> 'position' is not null or x ->> 'eta_seconds' is not null then
    raise exception 'FAIL: B 대기 작업은 deferred(순번·예상 없음) %', x;
  end if;
  raise notice 'PASS 4 사용자별 격리, 미룸은 순번 없음';
end $$;

-- ── 사용자 C: 앞 대기 0(B 의 미룸 대기 제외) · 실행 중 1 · 슬롯 1 → 1번째, eta = 중앙값(120초) ──
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c000-0000000000d3","role":"authenticated"}', true);
insert into t_res values ('c', public.job_queue_status());
reset role;
do $$
declare c jsonb := (select body from t_res where name = 'c'); x jsonb;
begin
  if jsonb_array_length(c -> 'production') <> 1 or jsonb_array_length(c -> 'posting') <> 0 then
    raise exception 'FAIL: C 건수 %', c;
  end if;
  x := c -> 'production' -> 0;
  if x ->> 'state' is distinct from 'queued' or (x ->> 'position')::int is distinct from 1
     or (x ->> 'eta_seconds')::int is distinct from 120 then
    raise exception 'FAIL: 앞 대기 0·실행 1·슬롯 1 이면 1번째·eta = 중앙값 %', x;
  end if;
  raise notice 'PASS 4b 앞 대기 0·실행 중 1·슬롯 1 → eta = 중앙값, 남의 미룸 대기는 앞에서 제외';
end $$;

-- ── 권한: anon·미인증 거부, service_role 직접 호출 불가 ──────
do $$
begin
  if has_function_privilege('anon', 'public.job_queue_status()', 'execute')
     or has_function_privilege('anon', 'private.job_queue_status()', 'execute')
     or has_function_privilege('service_role', 'public.job_queue_status()', 'execute')
     or has_function_privilege('authenticated', 'private.job_queue_slots(text)', 'execute')
     or has_function_privilege('authenticated', 'private.job_eta_basis(text)', 'execute')
     or has_function_privilege('service_role', 'private.job_queue_status()', 'execute')
     or has_function_privilege('authenticated', 'private.upload_est_seconds()', 'execute') then
    raise exception 'FAIL: 실행 권한이 넓음';
  end if;
  if not has_function_privilege('authenticated', 'public.job_queue_status()', 'execute') then
    raise exception 'FAIL: authenticated 실행 불가';
  end if;
end $$;

set local role anon;
do $$
begin
  perform public.job_queue_status();
  raise exception 'FAIL: anon 이 조회함';
exception when insufficient_privilege then null;
end $$;
reset role;

set local role authenticated;
select set_config('request.jwt.claims', '', true);
do $$
begin
  perform public.job_queue_status();
  raise exception 'FAIL: 로그인 없이 조회함';
exception when insufficient_privilege then null;
end $$;
reset role;
do $$ begin raise notice 'PASS 5 anon·미로그인 거부, 보조 함수는 authenticated 실행 불가'; end $$;

rollback;
