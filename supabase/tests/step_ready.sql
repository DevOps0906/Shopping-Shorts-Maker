-- mark_step_ready 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/step_ready.sql
-- 한 트랜잭션으로 돌리고 ROLLBACK 한다(테스트 사용자 rls-test-ready-* 는 남지 않는다).
begin;

insert into auth.users (id, aud, role, email)
values
  ('00000000-0000-4000-c000-00000000000a', 'authenticated', 'authenticated', 'rls-test-ready-a@example.com'),
  ('00000000-0000-4000-c000-00000000000b', 'authenticated', 'authenticated', 'rls-test-ready-b@example.com');
insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-c100-00000000000a', '00000000-0000-4000-c000-00000000000a', 'youtube', 'A 채널');
insert into public.projects (id, user_id, account_id, name, step_status) values
  ('00000000-0000-4000-c200-00000000000a', '00000000-0000-4000-c000-00000000000a',
   '00000000-0000-4000-c100-00000000000a', 'A 프로젝트',
   '{"1":"approved","2":"running","3":"idle","4":"idle","5":"idle","6":"idle"}');

-- ── 사용자 B: 타인 프로젝트 거부 ───────────────────────────
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-c000-00000000000b","role":"authenticated"}', true);
do $$
begin
  begin
    perform public.mark_step_ready('00000000-0000-4000-c200-00000000000a', 1, 'ready');
    raise exception 'FAIL: B가 A 프로젝트 단계 변경';
  exception when insufficient_privilege then
    raise notice 'PASS 1 B → A 프로젝트 mark_step_ready 거부';
  end;
end $$;

-- ── 사용자 A ─────────────────────────────────────────────
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-c000-00000000000a","role":"authenticated"}', true);
do $$
declare v_status jsonb;
begin
  begin
    perform public.mark_step_ready('00000000-0000-4000-c200-00000000000a', 3, 'approved');
    raise exception 'FAIL: approved 로 전이됨';
  exception when invalid_parameter_value then
    raise notice 'PASS 2 approved 로 전이 거부';
  end;
  begin
    perform public.mark_step_ready('00000000-0000-4000-c200-00000000000a', 1, 'ready');
    raise exception 'FAIL: approved 단계가 ready 로 되돌아감';
  exception when object_not_in_prerequisite_state then
    raise notice 'PASS 3 approved 단계(1) 전이 거부';
  end;
  begin
    perform public.mark_step_ready('00000000-0000-4000-c200-00000000000a', 2, 'ready');
    raise exception 'FAIL: running 단계 전이됨';
  exception when object_not_in_prerequisite_state then
    raise notice 'PASS 4 running 단계(2) 전이 거부';
  end;
  begin
    perform public.mark_step_ready('00000000-0000-4000-c200-00000000000a', 3, 'suggested');
    raise exception 'FAIL: 앞 단계(2) 미승인인데 3단계 전이됨';
  exception when object_not_in_prerequisite_state then
    raise notice 'PASS 5 앞 단계 미승인 시 거부';
  end;
end $$;

-- 2단계를 승인 상태로(소유자 권한) 만든 뒤 정상 전이
reset role;
update public.projects set step_status = jsonb_set(step_status, '{2}', '"approved"')
where id = '00000000-0000-4000-c200-00000000000a';
-- 3단계 ready 는 대본 산출물이 있어야 한다(20261112200300)
insert into public.scripts (project_id, version, lines)
values ('00000000-0000-4000-c200-00000000000a', 1, '["첫 문장"]');
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-c000-00000000000a","role":"authenticated"}', true);
do $$
declare v_status jsonb; v_events int;
begin
  v_status := public.mark_step_ready('00000000-0000-4000-c200-00000000000a', 3, 'suggested');
  if v_status ->> '3' <> 'suggested' then raise exception 'FAIL: suggested 아님 %', v_status; end if;
  v_status := public.mark_step_ready('00000000-0000-4000-c200-00000000000a', 3, 'ready');
  if v_status ->> '3' <> 'ready' then raise exception 'FAIL: ready 아님 %', v_status; end if;
  v_status := public.mark_step_ready('00000000-0000-4000-c200-00000000000a', 3, 'ready');
  if v_status ->> '3' <> 'ready' or v_status ->> '1' <> 'approved' or v_status ->> '4' <> 'idle' then
    raise exception 'FAIL: 멱등 호출 결과 이상 %', v_status;
  end if;
  select count(*) into v_events from public.project_events
  where project_id = '00000000-0000-4000-c200-00000000000a';
  if v_events <> 0 then raise exception 'FAIL: project_events 가 기록됨 (%)', v_events; end if;
  raise notice 'PASS 6 정상 전이 idle→suggested→ready, 같은 상태 재호출 멱등, 이벤트 기록 없음';
end $$;

-- 익명 실행 거부
reset role;
set local role anon;
do $$
begin
  begin
    perform public.mark_step_ready('00000000-0000-4000-c200-00000000000a', 3, 'ready');
    raise exception 'FAIL: anon 실행됨';
  exception when insufficient_privilege then
    raise notice 'PASS 7 anon mark_step_ready 실행 거부';
  end;
end $$;

rollback;
