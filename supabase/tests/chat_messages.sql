-- task-021 제작 파트너 대화(chat_messages) RLS·열 권한 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/chat_messages.sql
-- 한 트랜잭션으로 돌리고 ROLLBACK 한다. 실패하면 'FAIL:' 예외로 중단, 통과 항목은 NOTICE 'PASS'.
-- 확인: 사용자는 본인 프로젝트에 role=user 만 쓴다. AI 메시지(role=ai)·남의 프로젝트·수정·삭제는 거부. AI 메시지는 서버(service_role)만.
begin;

insert into auth.users (id, aud, role, email) values
  ('00000000-0000-4000-c021-00000000000a', 'authenticated', 'authenticated', 'chat-test-a@example.com'),
  ('00000000-0000-4000-c021-00000000000b', 'authenticated', 'authenticated', 'chat-test-b@example.com');
insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-c021-00000000010a', '00000000-0000-4000-c021-00000000000a', 'youtube', 'chat-test');
insert into public.projects (id, user_id, account_id, name) values
  ('00000000-0000-4000-c021-0000000002a1', '00000000-0000-4000-c021-00000000000a',
   '00000000-0000-4000-c021-00000000010a', 'chat P1');

-- 서버 경로(service_role): AI 메시지 쓰기
set local role service_role;
insert into public.chat_messages (project_id, role, kind, text, payload)
values ('00000000-0000-4000-c021-0000000002a1', 'ai', 'ai', '서버가 쓴 응답', '{"tool":"draft_script"}');
reset role;

-- ── 사용자 A ─────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c021-00000000000a","role":"authenticated"}', true);

do $$
declare
  p uuid := '00000000-0000-4000-c021-0000000002a1';
  v_count int;
begin
  insert into public.chat_messages (project_id, role, kind, text) values (p, 'user', 'text', '대본을 더 짧게');
  select count(*) into v_count from public.chat_messages where project_id = p;
  if v_count <> 2 then raise exception 'FAIL: A 본인 대화 2행이어야 함 (%)', v_count; end if;
  raise notice 'PASS 1 A 본인 프로젝트 role=user 쓰기 · AI 메시지 포함 읽기';

  begin
    insert into public.chat_messages (project_id, role, kind, text) values (p, 'ai', 'ai', '위조 AI 응답');
    raise exception 'FAIL: A가 role=ai 를 썼음';
  exception when insufficient_privilege then
    raise notice 'PASS 2 A role=ai 쓰기 거부(RLS)';
  end;

end $$;

-- 거부 기대 연산은 블록마다 하나씩(다른 문장의 권한 오류를 PASS로 오인하지 않게)
do $$
begin
  update public.chat_messages set text = '바꿈' where project_id = '00000000-0000-4000-c021-0000000002a1';
  raise exception 'FAIL: A가 대화를 수정';
exception when insufficient_privilege then
  raise notice 'PASS 3 A 대화 수정 거부(열 권한)';
end $$;

do $$
begin
  delete from public.chat_messages;
  raise exception 'FAIL: A가 대화를 삭제';
exception when insufficient_privilege then
  raise notice 'PASS 4 A 대화 삭제 거부';
end $$;

-- ── 사용자 B: A의 대화 읽기 0행, A 프로젝트에 쓰기 거부 ──
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c021-00000000000b","role":"authenticated"}', true);

do $$
declare
  p uuid := '00000000-0000-4000-c021-0000000002a1';
  v_count int;
begin
  select count(*) into v_count from public.chat_messages where project_id = p;
  if v_count <> 0 then raise exception 'FAIL: B가 A 대화를 읽음 (%)', v_count; end if;
  raise notice 'PASS 5 B → A 대화 읽기 0행';
  begin
    insert into public.chat_messages (project_id, role, kind, text) values (p, 'user', 'text', '남의 프로젝트');
    raise exception 'FAIL: B가 A 프로젝트에 메시지를 씀';
  exception when insufficient_privilege then
    raise notice 'PASS 6 B → A 프로젝트 쓰기 거부';
  end;
end $$;

reset role;
rollback;
