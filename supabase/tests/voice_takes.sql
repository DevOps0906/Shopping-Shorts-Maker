-- task-019 tts 워커 함수(private.tts_job_context · save_voice_take) 권한·범위 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/voice_takes.sql
-- 한 트랜잭션으로 돌리고 ROLLBACK 한다. 워커 쪽은 worker_login(= worker_role 권한)으로 실행한다.
begin;

grant worker_login to postgres with set true;

insert into auth.users (id, aud, role, email) values
  ('00000000-0000-4000-d019-00000000000a', 'authenticated', 'authenticated', 'voice-test-a@example.com');
insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-d019-00000000010a', '00000000-0000-4000-d019-00000000000a', 'youtube', 'voice-test');
-- P1: 03 승인(대본 v1 승인 · v2 미승인 초안) · P2: 다른 프로젝트
insert into public.projects (id, user_id, account_id, name, step_status) values
  ('00000000-0000-4000-d019-0000000002a1', '00000000-0000-4000-d019-00000000000a',
   '00000000-0000-4000-d019-00000000010a', 'voice P1',
   '{"1":"approved","2":"approved","3":"ready","4":"idle","5":"idle","6":"idle"}'),
  ('00000000-0000-4000-d019-0000000002a2', '00000000-0000-4000-d019-00000000000a',
   '00000000-0000-4000-d019-00000000010a', 'voice P2',
   '{"1":"approved","2":"approved","3":"approved","4":"idle","5":"idle","6":"idle"}');
insert into public.scripts (project_id, version, lines, approved_at) values
  ('00000000-0000-4000-d019-0000000002a1', 1, '["첫 문장입니다.", "둘째 문장."]', now()),
  ('00000000-0000-4000-d019-0000000002a1', 2, '["승인 안 된 초안"]', null);
update public.projects set step_status = jsonb_set(step_status, '{3}', '"approved"')
where id = '00000000-0000-4000-d019-0000000002a1';
-- 작업: J1(P1 tts running) · J2(P1 tts queued) · J3(P1 render running)
insert into public.jobs (id, project_id, step, type, status, idempotency_key) values
  ('00000000-0000-4000-d019-0000000004a1', '00000000-0000-4000-d019-0000000002a1', 4, 'tts', 'running', 'voice-test-1'),
  ('00000000-0000-4000-d019-0000000004a2', '00000000-0000-4000-d019-0000000002a1', 4, 'tts', 'queued', 'voice-test-2'),
  ('00000000-0000-4000-d019-0000000004a3', '00000000-0000-4000-d019-0000000002a1', 5, 'render', 'running', 'voice-test-3');

set local role worker_login;
do $$
declare v jsonb; id1 uuid; id2 uuid;
begin
  -- 직접 테이블 접근 불가
  begin
    perform 1 from public.voice_takes limit 1;
    raise exception 'FAIL: worker_role 이 voice_takes 를 직접 읽음';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.scripts limit 1;
    raise exception 'FAIL: worker_role 이 scripts 를 직접 읽음';
  exception when insufficient_privilege then null;
  end;

  -- 승인 대본(v1)만 돌려준다
  v := private.tts_job_context('00000000-0000-4000-d019-0000000004a1');
  if v->>'user_id' <> '00000000-0000-4000-d019-00000000000a'
     or v->'lines' <> '["첫 문장입니다.", "둘째 문장."]'::jsonb then
    raise exception 'FAIL: context %', v;
  end if;

  -- 실행 중이 아닌 작업·tts 가 아닌 작업은 거부
  foreach v in array array['"00000000-0000-4000-d019-0000000004a2"', '"00000000-0000-4000-d019-0000000004a3"']::jsonb[] loop
    begin
      perform private.tts_job_context((v #>> '{}')::uuid);
      raise exception 'FAIL: 거부해야 함 %', v;
    exception when object_not_in_prerequisite_state then null;
    end;
  end loop;

  -- 다른 프로젝트 경로·경로 조작은 거부
  foreach v in array array[
    '"00000000-0000-4000-d019-00000000000a/00000000-0000-4000-d019-0000000002a2/a.wav"',
    '"00000000-0000-4000-d019-00000000000a/00000000-0000-4000-d019-0000000002a1/../x.wav"',
    '"other/00000000-0000-4000-d019-0000000002a1/a.wav"']::jsonb[] loop
    begin
      perform private.save_voice_take('00000000-0000-4000-d019-0000000004a1', 'Leda', v #>> '{}', 3.2,
        '[]', '[]', '[]');
      raise exception 'FAIL: 경로 저장 %', v;
    exception when invalid_parameter_value then null;
    end;
  end loop;

  -- 저장 + 같은 작업 재시도는 같은 행을 덮어쓴다
  id1 := private.save_voice_take('00000000-0000-4000-d019-0000000004a1', 'Leda',
    '00000000-0000-4000-d019-00000000000a/00000000-0000-4000-d019-0000000002a1/tts-1.wav', 3.2,
    '[{"i":0,"text":"첫 문장입니다.","start":0,"end":1.5}]', '[{"s":0,"w":"첫","start":0,"end":0.4}]', '[]');
  id2 := private.save_voice_take('00000000-0000-4000-d019-0000000004a1', 'Kore',
    '00000000-0000-4000-d019-00000000000a/00000000-0000-4000-d019-0000000002a1/tts-1.wav', 3.4,
    '[]', '[]', '[]');
  if id1 is distinct from id2 then raise exception 'FAIL: 재시도 덮어쓰기 %/%', id1, id2; end if;
end $$;
reset role;

do $$
begin
  if (select count(*) from public.voice_takes where job_id = '00000000-0000-4000-d019-0000000004a1') <> 1
     or not exists (select 1 from public.voice_takes where job_id = '00000000-0000-4000-d019-0000000004a1'
                    and voice_id = 'Kore' and source = 'tts' and duration_sec = 3.4) then
    raise exception 'FAIL: 저장 결과';
  end if;
end $$;

-- authenticated 는 함수 실행·직접 쓰기 불가, 본인 테이크는 읽기
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-d019-00000000000a","role":"authenticated"}', true);
do $$
begin
  begin
    perform private.save_voice_take('00000000-0000-4000-d019-0000000004a1', 'Leda', 'x', 1, '[]', '[]', '[]');
    raise exception 'FAIL: authenticated 가 저장 함수 실행';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.voice_takes (project_id, source) values ('00000000-0000-4000-d019-0000000002a1', 'recording');
    raise exception 'FAIL: authenticated 가 voice_takes 직접 insert';
  exception when insufficient_privilege then null;
  end;
  if (select count(*) from public.voice_takes where project_id = '00000000-0000-4000-d019-0000000002a1') <> 1 then
    raise exception 'FAIL: 본인 테이크 읽기';
  end if;
end $$;
reset role;

select 'voice_takes: 통과' as result;
rollback;
