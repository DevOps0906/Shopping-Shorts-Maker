-- task-020 렌더 워커 함수(private.render_job_context · save_render) 권한·범위·편집 입력 조건 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/render_worker.sql
-- 한 트랜잭션으로 돌리고 ROLLBACK 한다. 워커 쪽은 worker_login(= worker_role 권한)으로 실행한다.
begin;

grant worker_login to postgres with set true;

insert into auth.users (id, aud, role, email) values
  ('00000000-0000-4000-d020-00000000000a', 'authenticated', 'authenticated', 'render-test-a@example.com');
insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-d020-00000000010a', '00000000-0000-4000-d020-00000000000a', 'youtube', 'render-test');
-- P1: 04까지 승인(목표 15초) · P2: 다른 프로젝트
insert into public.projects (id, user_id, account_id, name, target_sec, step_status) values
  ('00000000-0000-4000-d020-0000000002a1', '00000000-0000-4000-d020-00000000000a',
   '00000000-0000-4000-d020-00000000010a', 'render P1', 15,
   '{"1":"approved","2":"approved","3":"ready","4":"idle","5":"idle","6":"idle"}'),
  ('00000000-0000-4000-d020-0000000002a2', '00000000-0000-4000-d020-00000000000a',
   '00000000-0000-4000-d020-00000000010a', 'render P2', 20,
   '{"1":"approved","2":"approved","3":"approved","4":"approved","5":"idle","6":"idle"}');
update public.projects set sources_notice_ack_at = now(), sources_notice_ack_by = '00000000-0000-4000-d020-00000000000a'
where id = '00000000-0000-4000-d020-0000000002a1';
insert into public.scripts (project_id, version, lines, approved_at) values
  ('00000000-0000-4000-d020-0000000002a1', 1, '["첫 문장.", "둘째 문장."]', now()),
  ('00000000-0000-4000-d020-0000000002a1', 2, '["승인 안 된 초안"]', null);
insert into public.voice_takes (id, project_id, voice_id, source, audio_path, duration_sec, sentences, created_at) values
  ('00000000-0000-4000-d020-0000000005a0', '00000000-0000-4000-d020-0000000002a1', 'Leda', 'tts',
   '00000000-0000-4000-d020-00000000000a/00000000-0000-4000-d020-0000000002a1/old.wav', 5, '[]', now() - interval '1 hour'),
  ('00000000-0000-4000-d020-0000000005a1', '00000000-0000-4000-d020-0000000002a1', 'Kore', 'tts',
   '00000000-0000-4000-d020-00000000000a/00000000-0000-4000-d020-0000000002a1/new.wav', 6,
   '[{"i":0,"text":"첫 문장.","start":0,"end":2},{"i":1,"text":"둘째 문장.","start":2.5,"end":5}]', now());
update public.projects set step_status = '{"1":"approved","2":"approved","3":"approved","4":"approved","5":"idle","6":"idle"}'
where id = '00000000-0000-4000-d020-0000000002a1';
-- 원본: 1 own · 2 출처 표기(고지 확인) · 3 권리 근거 없음(미확인) · 4 격리 · 5 사용 안 함 · 6 파일 삭제 · 7 P2(own)
insert into public.sources (id, project_id, platform, url, author, file_path, score) values
  ('00000000-0000-4000-d020-0000000030a1', '00000000-0000-4000-d020-0000000002a1', 'tiktok', 'https://www.tiktok.com/@a/video/1', 'own1', 'u/1.mp4', 90),
  ('00000000-0000-4000-d020-0000000030a2', '00000000-0000-4000-d020-0000000002a1', 'xiaohongshu', 'https://www.xiaohongshu.com/x/2', 'att2', 'u/2.mp4', 95),
  ('00000000-0000-4000-d020-0000000030a3', '00000000-0000-4000-d020-0000000002a1', 'tiktok', 'https://www.tiktok.com/@a/video/3', 'unk3', 'u/3.mp4', 99),
  ('00000000-0000-4000-d020-0000000030a4', '00000000-0000-4000-d020-0000000002a1', 'tiktok', 'https://www.tiktok.com/@a/video/4', 'q4', 'u/4.mp4', 98),
  ('00000000-0000-4000-d020-0000000030a5', '00000000-0000-4000-d020-0000000002a1', 'tiktok', 'https://www.tiktok.com/@a/video/5', 'n5', 'u/5.mp4', 97),
  ('00000000-0000-4000-d020-0000000030a6', '00000000-0000-4000-d020-0000000002a1', 'tiktok', 'https://www.tiktok.com/@a/video/6', 'd6', 'u/6.mp4', 96),
  ('00000000-0000-4000-d020-0000000030a7', '00000000-0000-4000-d020-0000000002a2', 'tiktok', 'https://www.tiktok.com/@a/video/7', 'p7', 'u/7.mp4', 50);
update public.sources set used = true, rights_basis = 'own', rights_confirmed_at = now()
where id in ('00000000-0000-4000-d020-0000000030a1', '00000000-0000-4000-d020-0000000030a4',
             '00000000-0000-4000-d020-0000000030a6', '00000000-0000-4000-d020-0000000030a7');
update public.sources set used = true, rights_basis = 'attribution_notice', rights_confirmed_at = now()
where id = '00000000-0000-4000-d020-0000000030a2';
update public.sources set used = true where id = '00000000-0000-4000-d020-0000000030a3';
update public.sources set rights_basis = 'own', rights_confirmed_at = now() where id = '00000000-0000-4000-d020-0000000030a5';
update public.sources set quarantined = true where id = '00000000-0000-4000-d020-0000000030a4';
update public.sources set file_deleted_at = now() where id = '00000000-0000-4000-d020-0000000030a6';
-- 작업: J1(P1 render running) · J2(P1 render queued) · J3(P1 tts running) · J4(P2 render running)
insert into public.jobs (id, project_id, step, type, status, idempotency_key) values
  ('00000000-0000-4000-d020-0000000004a1', '00000000-0000-4000-d020-0000000002a1', 5, 'render', 'running', 'render-test-1'),
  ('00000000-0000-4000-d020-0000000004a2', '00000000-0000-4000-d020-0000000002a1', 5, 'render', 'queued', 'render-test-2'),
  ('00000000-0000-4000-d020-0000000004a3', '00000000-0000-4000-d020-0000000002a1', 4, 'tts', 'running', 'render-test-3'),
  ('00000000-0000-4000-d020-0000000004a4', '00000000-0000-4000-d020-0000000002a2', 5, 'render', 'running', 'render-test-4');

-- 사용자 세션 기준 편집 입력(edit_input_sources)과 워커 입력이 같은지 비교하려고 저장
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-d020-00000000000a","role":"authenticated"}', true);
create temp table edit_ids on commit drop as
  select id from public.edit_input_sources('00000000-0000-4000-d020-0000000002a1');
reset role;
grant select on edit_ids to worker_login;

set local role worker_login;
do $$
declare v jsonb; ids text[];
begin
  -- 직접 테이블 접근 불가
  begin
    perform 1 from public.renders limit 1;
    raise exception 'FAIL: worker_role 이 renders 를 직접 읽음';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.sources limit 1;
    raise exception 'FAIL: worker_role 이 sources 를 직접 읽음';
  exception when insufficient_privilege then null;
  end;
  begin
    perform private.render_input_sources('00000000-0000-4000-d020-0000000002a1');
    raise exception 'FAIL: worker_role 이 render_input_sources 를 직접 부름';
  exception when insufficient_privilege then null;
  end;

  v := private.render_job_context('00000000-0000-4000-d020-0000000004a1');
  if v->>'user_id' <> '00000000-0000-4000-d020-00000000000a' or (v->>'target_sec')::int <> 15
     or v->'lines' <> '["첫 문장.", "둘째 문장."]'::jsonb then
    raise exception 'FAIL: context %', v;
  end if;
  if v->'take'->>'id' <> '00000000-0000-4000-d020-0000000005a1' or jsonb_array_length(v->'take'->'sentences') <> 2 then
    raise exception 'FAIL: 최신 음성 테이크 %', v->'take';
  end if;
  -- 편집 입력 후보: own1·att2 만(점수 순 att2 → own1). 미확인·격리·미사용·파일 삭제·다른 프로젝트 원본은 없음
  select array_agg(s->>'id') into ids from jsonb_array_elements(v->'sources') s;
  if ids is distinct from array['00000000-0000-4000-d020-0000000030a2', '00000000-0000-4000-d020-0000000030a1'] then
    raise exception 'FAIL: 편집 입력 후보 %', ids;
  end if;
  if exists (select 1 from jsonb_array_elements(v->'sources') s
             where s->>'id' in ('00000000-0000-4000-d020-0000000030a3', '00000000-0000-4000-d020-0000000030a4')) then
    raise exception 'FAIL: 미확인·격리 원본이 매칭 후보에 있음';
  end if;
  -- 사용자 세션의 edit_input_sources 와 같은 집합
  if (select array_agg(id::text order by id) from edit_ids)
     is distinct from (select array_agg(s->>'id' order by s->>'id') from jsonb_array_elements(v->'sources') s) then
    raise exception 'FAIL: edit_input_sources 와 워커 입력이 다름';
  end if;
  raise notice 'PASS 1 워커 입력: 승인 대본·최신 음성·편집 입력 원본(미확인·격리 제외)';

  -- 실행 중이 아닌 작업·render 가 아닌 작업은 거부
  foreach v in array array['"00000000-0000-4000-d020-0000000004a2"', '"00000000-0000-4000-d020-0000000004a3"']::jsonb[] loop
    begin
      perform private.render_job_context((v #>> '{}')::uuid);
      raise exception 'FAIL: 거부해야 함 %', v;
    exception when object_not_in_prerequisite_state then null;
    end;
  end loop;
  raise notice 'PASS 2 실행 중 render 작업만';
end $$;

-- 고지 확인을 해제하면 출처 표기 원본도 빠진다
reset role;
update public.projects set sources_notice_ack_at = null, sources_notice_ack_by = null
where id = '00000000-0000-4000-d020-0000000002a1';
set local role worker_login;
do $$
declare v jsonb;
begin
  v := private.render_job_context('00000000-0000-4000-d020-0000000004a1');
  if jsonb_array_length(v->'sources') <> 1 or v->'sources'->0->>'id' <> '00000000-0000-4000-d020-0000000030a1' then
    raise exception 'FAIL: 고지 미확인 출처 표기 원본 포함 %', v->'sources';
  end if;
  raise notice 'PASS 3 고지 미확인 출처 표기 원본 제외';
end $$;
reset role;
update public.projects set sources_notice_ack_at = now(), sources_notice_ack_by = '00000000-0000-4000-d020-00000000000a'
where id = '00000000-0000-4000-d020-0000000002a1';

set local role worker_login;
do $$
declare
  v jsonb;
  ok_path text := '00000000-0000-4000-d020-00000000000a/00000000-0000-4000-d020-0000000002a1/render-1.mp4';
  cuts jsonb := '{"cuts":[{"no":1,"source_id":"00000000-0000-4000-d020-0000000030a2"},{"no":2,"source_id":"00000000-0000-4000-d020-0000000030a1"}],"credits":"영상 출처: @att2(小红书)"}';
begin
  -- 경로: 다른 프로젝트·확장자·형식 거부
  foreach v in array array[
    '"00000000-0000-4000-d020-00000000000a/00000000-0000-4000-d020-0000000002a2/render-1.mp4"',
    '"00000000-0000-4000-d020-00000000000a/00000000-0000-4000-d020-0000000002a1/render-1.wav"',
    '"../x.mp4"']::jsonb[] loop
    begin
      perform private.save_render('00000000-0000-4000-d020-0000000004a1', v #>> '{}', 15.0, cuts);
      raise exception 'FAIL: 경로 거부해야 함 %', v;
    exception when invalid_parameter_value then null;
    end;
  end loop;
  -- 길이: 목표 ±0.1초 밖 거부
  begin
    perform private.save_render('00000000-0000-4000-d020-0000000004a1', ok_path, 15.2, cuts);
    raise exception 'FAIL: 길이 거부해야 함';
  exception when invalid_parameter_value then null;
  end;
  -- 컷에 미확인·격리 원본 → 거부
  foreach v in array array['"00000000-0000-4000-d020-0000000030a3"', '"00000000-0000-4000-d020-0000000030a4"',
                           '"00000000-0000-4000-d020-0000000030a7"']::jsonb[] loop
    begin
      perform private.save_render('00000000-0000-4000-d020-0000000004a1', ok_path, 15.0,
        jsonb_build_object('cuts', jsonb_build_array(jsonb_build_object('no', 1, 'source_id', v #>> '{}'))));
      raise exception 'FAIL: 컷 원본 거부해야 함 %', v;
    exception when insufficient_privilege then null;
    end;
  end loop;
  raise notice 'PASS 4 save_render 경로·길이·컷 원본 검사';

  v := private.save_render('00000000-0000-4000-d020-0000000004a1', ok_path, 15.02, cuts);
  if (v->>'version')::int <> 1 then raise exception 'FAIL: 첫 버전 %', v; end if;
  -- 같은 작업 재시도는 같은 행을 덮어쓴다(버전·이벤트 그대로)
  v := private.save_render('00000000-0000-4000-d020-0000000004a1', ok_path, 15.0, cuts);
  if (v->>'version')::int <> 1 then raise exception 'FAIL: 재시도 버전 %', v; end if;
  -- 다른 프로젝트 작업(J4)이 P1 경로를 쓰면 거부
  begin
    perform private.save_render('00000000-0000-4000-d020-0000000004a4', ok_path, 20.0,
      '{"cuts":[{"no":1,"source_id":"00000000-0000-4000-d020-0000000030a7"}]}');
    raise exception 'FAIL: 다른 프로젝트 경로 저장';
  exception when invalid_parameter_value then null;
  end;
  raise notice 'PASS 5 save_render 멱등·범위';
end $$;

reset role;
do $$
declare n int;
begin
  select count(*) into n from public.renders where project_id = '00000000-0000-4000-d020-0000000002a1';
  if n <> 1 then raise exception 'FAIL: renders 행 수 %', n; end if;
  if (select duration_sec from public.renders where job_id = '00000000-0000-4000-d020-0000000004a1') <> 15.0 then
    raise exception 'FAIL: 재시도 덮어쓰기';
  end if;
  select count(*) into n from public.project_events
  where project_id = '00000000-0000-4000-d020-0000000002a1' and step = 5 and event = 'render_succeeded';
  if n <> 1 then raise exception 'FAIL: render_succeeded 이벤트 수 %', n; end if;
  -- 두 번째 작업은 V2 + 이벤트 1건 더
  update public.jobs set status = 'running' where id = '00000000-0000-4000-d020-0000000004a2';
end $$;
set local role worker_login;
do $$
declare v jsonb;
begin
  v := private.save_render('00000000-0000-4000-d020-0000000004a2',
    '00000000-0000-4000-d020-00000000000a/00000000-0000-4000-d020-0000000002a1/render-2.mp4', 14.95,
    '{"cuts":[{"no":1,"source_id":"00000000-0000-4000-d020-0000000030a1"}]}');
  if (v->>'version')::int <> 2 then raise exception 'FAIL: 둘째 버전 %', v; end if;
end $$;
reset role;
do $$
begin
  if (select count(*) from public.project_events
      where project_id = '00000000-0000-4000-d020-0000000002a1' and event = 'render_succeeded') <> 2 then
    raise exception 'FAIL: 둘째 render_succeeded';
  end if;
  raise notice 'PASS 6 버전 V1·V2 + render_succeeded 이벤트';
end $$;

-- authenticated·anon 은 워커 함수를 부를 수 없다
set local role authenticated;
do $$
begin
  begin
    perform private.render_job_context('00000000-0000-4000-d020-0000000004a1');
    raise exception 'FAIL: authenticated 가 render_job_context 실행';
  exception when insufficient_privilege then null;
  end;
  begin
    perform private.save_render('00000000-0000-4000-d020-0000000004a1', 'x', 15, '{}');
    raise exception 'FAIL: authenticated 가 save_render 실행';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS 7 사용자 역할은 워커 함수 실행 불가';
end $$;

-- 컷 원본 스냅샷·설명란 문구는 DB 값(워커가 보낸 작성자·URL은 무시) — 20261112230200
reset role;
insert into public.jobs (id, project_id, step, type, status, idempotency_key) values
  ('00000000-0000-4000-d020-0000000004a5', '00000000-0000-4000-d020-0000000002a1', 5, 'render', 'running', 'render-test-5');
set local role worker_login;
do $$
declare v jsonb; m jsonb;
begin
  v := private.render_job_context('00000000-0000-4000-d020-0000000004a5');
  if v->'sources'->0->>'url' <> 'https://www.xiaohongshu.com/x/2' or v->'sources'->0->>'collected_at' is null then
    raise exception 'FAIL: context 원본 url·수집 시각 %', v->'sources'->0;
  end if;
  perform private.save_render('00000000-0000-4000-d020-0000000004a5',
    '00000000-0000-4000-d020-00000000000a/00000000-0000-4000-d020-0000000002a1/render-5.mp4', 15.0,
    '{"cuts":[{"no":1,"source_id":"00000000-0000-4000-d020-0000000030a2","author":"forged","source_url":"https://evil.example/"},
              {"no":2,"source_id":"00000000-0000-4000-d020-0000000030a1","platform":"direct"},
              {"no":3,"source_id":"00000000-0000-4000-d020-0000000030a2"}],
      "credits":"영상 출처: @forged"}');
end $$;
reset role;
do $$
declare m jsonb;
begin
  select cut_map into m from public.renders where job_id = '00000000-0000-4000-d020-0000000004a5';
  if m->'cuts'->0->>'author' <> 'att2' or m->'cuts'->0->>'source_url' <> 'https://www.xiaohongshu.com/x/2'
     or m->'cuts'->0->>'collected_at' is null or m->'cuts'->1->>'platform' <> 'tiktok'
     or m->'cuts'->1->>'source_url' <> 'https://www.tiktok.com/@a/video/1' then
    raise exception 'FAIL: 스냅샷 %', m->'cuts';
  end if;
  if m->>'credits' <> '영상 출처: @att2(小红书), @own1(TikTok)' then
    raise exception 'FAIL: 설명란 문구 %', m->>'credits';
  end if;
  raise notice 'PASS 8 컷 원본 스냅샷·설명란 문구는 DB 값';
end $$;

rollback;
