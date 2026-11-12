-- 04·05 단계 산출물 검사(20261112230100) 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/step45_output_checks.sql
-- 한 트랜잭션으로 돌리고 ROLLBACK 한다(테스트 사용자 rls-test-s45-* 는 남지 않는다).
-- P = 4단계 검사용(1~3 승인), R = 4단계 승인 거부용(4 ready 강제), Q = 5단계 검사용(1~4 승인)
begin;

insert into auth.users (id, aud, role, email)
values ('00000000-0000-4000-f000-00000000000a', 'authenticated', 'authenticated', 'rls-test-s45-a@example.com');
insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-f100-00000000000a', '00000000-0000-4000-f000-00000000000a', 'youtube', 'A 채널');
insert into public.projects (id, user_id, account_id, name, step_status) values
  ('00000000-0000-4000-f200-00000000000a', '00000000-0000-4000-f000-00000000000a',
   '00000000-0000-4000-f100-00000000000a', 'P',
   '{"1":"approved","2":"approved","3":"approved","4":"idle","5":"idle","6":"idle"}'),
  ('00000000-0000-4000-f200-00000000000b', '00000000-0000-4000-f000-00000000000a',
   '00000000-0000-4000-f100-00000000000a', 'R',
   '{"1":"approved","2":"approved","3":"approved","4":"ready","5":"idle","6":"idle"}'),
  ('00000000-0000-4000-f200-00000000000c', '00000000-0000-4000-f000-00000000000a',
   '00000000-0000-4000-f100-00000000000a', 'Q',
   '{"1":"approved","2":"approved","3":"approved","4":"approved","5":"idle","6":"idle"}');

-- 쓸 수 없는 테이크(오디오 없음)만 있는 상태
insert into public.voice_takes (project_id, source, audio_path, duration_sec) values
  ('00000000-0000-4000-f200-00000000000a', 'tts', null, null),
  ('00000000-0000-4000-f200-00000000000b', 'tts', null, null);

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-f000-00000000000a","role":"authenticated"}', true);

do $$
begin
  begin
    perform public.mark_step_ready('00000000-0000-4000-f200-00000000000a', 4, 'ready');
    raise exception 'FAIL: 쓸 수 있는 음성 없이 4단계 ready';
  exception when object_not_in_prerequisite_state then
    raise notice 'PASS 1 쓸 수 있는 음성 테이크 없이 4단계 ready 거부';
  end;
  begin
    perform public.approve_step('00000000-0000-4000-f200-00000000000b', 4);
    raise exception 'FAIL: 음성 없이 4단계 승인';
  exception when object_not_in_prerequisite_state then
    raise notice 'PASS 2 음성 테이크 없이 4단계 승인 거부';
  end;
  begin
    perform public.mark_step_ready('00000000-0000-4000-f200-00000000000c', 5, 'ready');
    raise exception 'FAIL: 렌더 없이 5단계 ready';
  exception when object_not_in_prerequisite_state then
    raise notice 'PASS 3 렌더 없이 5단계 ready 거부';
  end;
end $$;

-- 산출물 준비(워커·서버 결과 = 소유자 권한): P 테이크, Q 렌더 v1 완성 · v2 미완성(최신)
reset role;
insert into public.voice_takes (project_id, source, audio_path, duration_sec) values
  ('00000000-0000-4000-f200-00000000000a', 'tts',
   '00000000-0000-4000-f000-00000000000a/00000000-0000-4000-f200-00000000000a/take.mp3', 15.2);
insert into public.renders (project_id, version, mp4_path, duration_sec) values
  ('00000000-0000-4000-f200-00000000000c', 1,
   '00000000-0000-4000-f000-00000000000a/00000000-0000-4000-f200-00000000000c/v1.mp4', 15),
  ('00000000-0000-4000-f200-00000000000c', 2, null, null);
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-f000-00000000000a","role":"authenticated"}', true);

do $$
declare v_status jsonb;
begin
  v_status := public.mark_step_ready('00000000-0000-4000-f200-00000000000a', 4, 'ready');
  if v_status ->> '4' <> 'ready' then raise exception 'FAIL: 테이크 있는데 4단계 ready 실패'; end if;
  v_status := public.approve_step('00000000-0000-4000-f200-00000000000a', 4);
  if v_status ->> '4' <> 'approved' then raise exception 'FAIL: 4단계 승인 실패'; end if;
  raise notice 'PASS 4 쓸 수 있는 테이크 있으면 4단계 ready·승인';

  begin
    perform public.mark_step_ready('00000000-0000-4000-f200-00000000000c', 5, 'ready');
    raise exception 'FAIL: 최신 렌더 미완성인데 5단계 ready';
  exception when object_not_in_prerequisite_state then
    raise notice 'PASS 5 최신 버전 렌더 미완성(이전 버전만 완성)이면 5단계 ready 거부';
  end;
end $$;

-- Q 5단계를 ready 로 강제해 승인 검사만 확인
reset role;
update public.projects set step_status = jsonb_set(step_status, '{5}', '"ready"')
where id = '00000000-0000-4000-f200-00000000000c';
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-f000-00000000000a","role":"authenticated"}', true);
do $$
begin
  begin
    perform public.approve_step('00000000-0000-4000-f200-00000000000c', 5);
    raise exception 'FAIL: 최신 렌더 미완성인데 5단계 승인';
  exception when object_not_in_prerequisite_state then
    raise notice 'PASS 6 최신 버전 렌더 미완성이면 5단계 승인 거부';
  end;
end $$;

-- 최신 렌더 완성(워커 결과), 상태는 change 로 돌려 ready 전이부터 확인
reset role;
update public.renders
set mp4_path = '00000000-0000-4000-f000-00000000000a/00000000-0000-4000-f200-00000000000c/v2.mp4',
    duration_sec = 15
where project_id = '00000000-0000-4000-f200-00000000000c' and version = 2;
update public.projects set step_status = jsonb_set(step_status, '{5}', '"change"')
where id = '00000000-0000-4000-f200-00000000000c';
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-f000-00000000000a","role":"authenticated"}', true);
do $$
declare v_status jsonb; v_events int;
begin
  v_status := public.mark_step_ready('00000000-0000-4000-f200-00000000000c', 5, 'ready');
  if v_status ->> '5' <> 'ready' then raise exception 'FAIL: 최신 렌더 완성인데 5단계 ready 실패'; end if;
  v_status := public.approve_step('00000000-0000-4000-f200-00000000000c', 5);
  if v_status ->> '5' <> 'approved' then raise exception 'FAIL: 5단계 승인 실패'; end if;
  select count(*) into v_events from public.project_events
  where project_id = '00000000-0000-4000-f200-00000000000c' and event = 'step_approved' and step = 5;
  if v_events <> 1 then raise exception 'FAIL: 5단계 step_approved 이벤트 % 건', v_events; end if;
  raise notice 'PASS 7 최신 렌더 완성이면 5단계 ready·승인, 이벤트 1건';
end $$;

rollback;
