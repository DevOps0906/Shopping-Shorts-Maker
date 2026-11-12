-- task-021 제작 파트너 사전 확인 제안(chat_proposals)·탐색 회차(chat_start_collect) 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/chat_proposals.sql
-- 한 트랜잭션으로 돌리고 ROLLBACK 한다. 실패하면 'FAIL:' 예외로 중단, 통과 항목은 NOTICE 'PASS'.
-- 병렬 확인(3회 초과 0건)은 chat_proposals_concurrency.sh.
begin;

insert into auth.users (id, aud, role, email) values
  ('00000000-0000-4000-c121-00000000000a', 'authenticated', 'authenticated', 'proposal-test-a@example.com'),
  ('00000000-0000-4000-c121-00000000000b', 'authenticated', 'authenticated', 'proposal-test-b@example.com');
insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-c121-00000000010a', '00000000-0000-4000-c121-00000000000a', 'youtube', 'proposal-test');
insert into public.projects (id, user_id, account_id, name, step_status) values
  ('00000000-0000-4000-c121-0000000002a1', '00000000-0000-4000-c121-00000000000a',
   '00000000-0000-4000-c121-00000000010a', 'proposal P1',
   '{"1":"approved","2":"idle","3":"idle","4":"idle","5":"idle","6":"idle"}');

-- 서버(service_role)가 제안 4개 생성: 정상 · 만료용 · 버전 변경용 · B 시도용
set local role service_role;
select set_config('test.p_ok', public.chat_create_proposal('00000000-0000-4000-c121-00000000000a',
  '00000000-0000-4000-c121-0000000002a1', 'replace_cut', '{"cut_no":2}')::text, true);
select set_config('test.p_exp', public.chat_create_proposal('00000000-0000-4000-c121-00000000000a',
  '00000000-0000-4000-c121-0000000002a1', 'render_mp4', '{}')::text, true);
select set_config('test.p_ver', public.chat_create_proposal('00000000-0000-4000-c121-00000000000a',
  '00000000-0000-4000-c121-0000000002a1', 'synthesize_voice', '{"voice_id":"Charon"}')::text, true);
select set_config('test.p_b', public.chat_create_proposal('00000000-0000-4000-c121-00000000000a',
  '00000000-0000-4000-c121-0000000002a1', 'render_mp4', '{}')::text, true);
do $$
begin
  perform public.chat_create_proposal('00000000-0000-4000-c121-00000000000b',
    '00000000-0000-4000-c121-0000000002a1', 'render_mp4', '{}');
  raise exception 'FAIL: 남의 프로젝트로 제안 생성';
exception when insufficient_privilege then
  raise notice 'PASS 1 제안 생성은 프로젝트 소유자로만';
end $$;
reset role;
update public.chat_proposals set expires_at = now() - interval '1 second' where id = current_setting('test.p_exp')::uuid;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c121-00000000000a","role":"authenticated"}', true);

do $$
declare r jsonb;
begin
  r := public.chat_consume_proposal(gen_random_uuid());
  if r ->> 'error' is distinct from 'invalid' then raise exception 'FAIL: 없는 제안 소비 %', r; end if;
  raise notice 'PASS 2 제안 없이 확인 거부';

  r := public.chat_consume_proposal(current_setting('test.p_ok')::uuid);
  if r ->> 'tool' is distinct from 'replace_cut' or r -> 'args' is distinct from '{"cut_no":2}'::jsonb then
    raise exception 'FAIL: 정상 소비 %', r;
  end if;
  raise notice 'PASS 3 저장된 tool·args 로 1회 소비';

  r := public.chat_consume_proposal(current_setting('test.p_ok')::uuid);
  if r ->> 'error' is distinct from 'invalid' then raise exception 'FAIL: 재사용 %', r; end if;
  raise notice 'PASS 4 같은 제안 재사용 거부';

  r := public.chat_consume_proposal(current_setting('test.p_exp')::uuid);
  if r ->> 'error' is distinct from 'invalid' then raise exception 'FAIL: 만료 %', r; end if;
  raise notice 'PASS 5 만료 제안 거부';
end $$;

-- 입력 버전 변경: 제안 뒤 step_status 가 바뀜 → stale, 그리고 다시 쓸 수 없음
reset role;
update public.projects set step_status = '{"1":"approved","2":"ready","3":"idle","4":"idle","5":"idle","6":"idle"}'
where id = '00000000-0000-4000-c121-0000000002a1';
set local role authenticated;
do $$
declare r jsonb;
begin
  r := public.chat_consume_proposal(current_setting('test.p_ver')::uuid);
  if r ->> 'error' is distinct from 'stale' then raise exception 'FAIL: 버전 변경 %', r; end if;
  r := public.chat_consume_proposal(current_setting('test.p_ver')::uuid);
  if r ->> 'error' is distinct from 'invalid' then raise exception 'FAIL: stale 뒤 재사용 %', r; end if;
  raise notice 'PASS 6 입력 버전 변경 거부(소비된 채로 재사용 불가)';
end $$;

-- 표 직접 접근·제안 생성 함수는 사용자에게 막힘(도구·입력 바꿔치기 불가)
do $$ begin
  perform 1 from public.chat_proposals;
  raise exception 'FAIL: 사용자가 제안 표를 읽음';
exception when insufficient_privilege then raise notice 'PASS 7 제안 표 읽기 거부'; end $$;
do $$ begin
  update public.chat_proposals set tool = 'render_mp4', args = '{}';
  raise exception 'FAIL: 사용자가 제안을 바꿈';
exception when insufficient_privilege then raise notice 'PASS 8 제안 도구·입력 바꾸기 거부'; end $$;
do $$ begin
  perform public.chat_create_proposal('00000000-0000-4000-c121-00000000000a',
    '00000000-0000-4000-c121-0000000002a1', 'render_mp4', '{}');
  raise exception 'FAIL: 사용자가 제안을 만듦';
exception when insufficient_privilege then raise notice 'PASS 9 사용자 제안 생성 거부(service_role 전용)'; end $$;

-- B: A의 제안 소비 불가, A 프로젝트 수집 불가
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c121-00000000000b","role":"authenticated"}', true);
do $$
declare r jsonb;
begin
  r := public.chat_consume_proposal(current_setting('test.p_b')::uuid);
  if r ->> 'error' is distinct from 'invalid' then raise exception 'FAIL: B가 A 제안 소비 %', r; end if;
  raise notice 'PASS 10 남의 제안 소비 거부';
end $$;
do $$ begin
  perform public.chat_start_collect('00000000-0000-4000-c121-0000000002a1', 'tiktok', 'x', 'proposal-test-b-1');
  raise exception 'FAIL: B가 A 프로젝트 수집';
exception when insufficient_privilege then raise notice 'PASS 11 남의 프로젝트 수집 거부'; end $$;

-- A: 탐색 회차 3회까지, 4번째 CR003, 같은 키 재요청은 기존 작업, 허용 밖 플랫폼 거부
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c121-00000000000a","role":"authenticated"}', true);
do $$
declare n int;
begin
  for n in 1..3 loop
    perform public.chat_start_collect('00000000-0000-4000-c121-0000000002a1', 'tiktok', '압축팩', 'proposal-test-a-' || n);
  end loop;
end $$;
do $$ begin
  perform public.chat_start_collect('00000000-0000-4000-c121-0000000002a1', 'xiaohongshu', '압축팩', 'proposal-test-a-4');
  raise exception 'FAIL: 4번째 회차 생성';
exception when sqlstate 'CR003' then raise notice 'PASS 12 탐색 회차 3회 초과 거부(CR003)'; end $$;
do $$
declare r jsonb; n int;
begin
  r := public.chat_start_collect('00000000-0000-4000-c121-0000000002a1', 'tiktok', '압축팩', 'proposal-test-a-3');
  if (r ->> 'created')::boolean then raise exception 'FAIL: 재요청이 새 작업 생성'; end if;
  select count(*) into n from public.jobs where project_id = '00000000-0000-4000-c121-0000000002a1' and type = 'collect';
  if n <> 3 then raise exception 'FAIL: collect 작업 %건', n; end if;
  raise notice 'PASS 13 같은 멱등 키 재요청은 기존 작업(총 3건)';
end $$;
do $$ begin
  perform public.chat_start_collect('00000000-0000-4000-c121-0000000002a1', 'youtube', 'x', 'proposal-test-a-5');
  raise exception 'FAIL: 허용 밖 플랫폼';
exception when invalid_parameter_value then raise notice 'PASS 14 허용 밖 플랫폼 거부'; end $$;

reset role;
rollback;
