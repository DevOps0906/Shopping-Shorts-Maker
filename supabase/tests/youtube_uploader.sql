-- YouTube 업로더 상태 함수(20261112280000) 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/youtube_uploader.sql
-- 한 트랜잭션으로 돌리고 ROLLBACK 한다. 선점은 전역 큐라서 시작할 때 기존 대기 행을 먼 미래로 미뤄 둔다(롤백으로 복구).
-- A = 소유자(YouTube 연결 채널 Y, Instagram 채널 I), B = 남. 프로젝트 1~9 는 A 의 1~5단계 승인 프로젝트.
begin;

-- 기존 데이터 격리(롤백됨)
update public.publications set next_attempt_at = now() + interval '100 years' where status in ('pending', 'retry_wait');
update public.publications set attempt_started_at = now() where status = 'uploading';

insert into auth.users (id, aud, role, email) values
  ('00000000-0000-4000-e000-0000000000a1', 'authenticated', 'authenticated', 'rls-test-up-a@example.com'),
  ('00000000-0000-4000-e000-0000000000b1', 'authenticated', 'authenticated', 'rls-test-up-b@example.com');
insert into public.accounts (id, user_id, platform, channel_name, status, external_channel_id) values
  ('00000000-0000-4000-e100-0000000000a1', '00000000-0000-4000-e000-0000000000a1', 'youtube', 'A 채널', 'connected',
   'UCtestchannelA000000000'),
  ('00000000-0000-4000-e100-0000000000a2', '00000000-0000-4000-e000-0000000000a1', 'instagram', 'A 인스타', 'connected', null);

-- 6/6 통과 프로젝트(p_attr = 출처 표기·고지 사용자 체크 여부)
create function pg_temp.mk_project(p_id uuid, p_account uuid, p_attr boolean) returns void language plpgsql as $$
begin
  insert into public.projects (id, user_id, account_id, name, step_status, sources_notice_ack_at, sources_notice_ack_by)
  values (p_id, '00000000-0000-4000-e000-0000000000a1', p_account, 'up-test',
          '{"1":"approved","2":"approved","3":"ready","4":"idle","5":"idle","6":"idle"}', now(),
          '00000000-0000-4000-e000-0000000000a1');
  insert into public.scripts (project_id, version, lines, approved_at) values (p_id, 1, '["좁은 틈에도 쏙 들어가요."]', now());
  insert into public.renders (project_id, version, mp4_path, duration_sec, cut_map)
  values (p_id, 1, '00000000-0000-4000-e000-0000000000a1/' || p_id || '/v1.mp4', 15,
          jsonb_build_object('cuts', jsonb_build_array(jsonb_build_object(
            'no', 1, 'source_id', '00000000-0000-4000-e300-000000000001', 'author', 'maker_a', 'platform', 'tiktok',
            'source_url', 'https://www.tiktok.com/@maker_a/video/1', 'collected_at', '2026-11-12T01:00:00Z'))));
  update public.projects
  set step_status = '{"1":"approved","2":"approved","3":"approved","4":"approved","5":"approved","6":"idle"}'
  where id = p_id;
  if p_attr then
    insert into public.policy_checks (project_id, item, result, checked_by, checked_at)
    values (p_id, 'attribution_notice', 'pass', '00000000-0000-4000-e000-0000000000a1', now());
  end if;
end $$;

-- 발행 준비 완료 행(pending). 발행 함수 대신 postgres 로 직접 만든다(guard 는 postgres 허용)
create function pg_temp.mk_pub(p_project uuid, p_account uuid, p_mode text, p_at timestamptz) returns uuid language sql as $$
  insert into public.publications (project_id, account_id, mode, scheduled_at, title, body, description, hashtags, prepared_at, status)
  values (p_project, p_account, p_mode, p_at, '압축팩 정리 꿀팁', '본문', '본문 설명', array['수납'], now(), 'pending')
  returning id;
$$;

create function pg_temp.pub(p_project uuid) returns public.publications language sql as $$
  select * from public.publications where project_id = p_project;
$$;

select pg_temp.mk_project(('00000000-0000-4000-e200-00000000000' || n)::uuid, '00000000-0000-4000-e100-0000000000a1', n <> 1)
from generate_series(1, 8) n;
select pg_temp.mk_project('00000000-0000-4000-e200-000000000009', '00000000-0000-4000-e100-0000000000a2', true);
grant execute on all functions in schema pg_temp to service_role, authenticated;

-- 1) 정책 미통과(출처 표기·고지 미체크) → 선점 거부, 발행 준비 무효화, 프로젝트 발행 대기 해제
select pg_temp.mk_pub('00000000-0000-4000-e200-000000000001', '00000000-0000-4000-e100-0000000000a1', 'now', null);
update public.projects set status = 'awaiting_publish' where id = '00000000-0000-4000-e200-000000000001';
set local role service_role;
do $$
declare v jsonb; p public.publications;
begin
  v := public.publication_claim();
  if v ->> 'reason' is distinct from 'policy_failed' or (v ->> 'claimed')::boolean then
    raise exception 'FAIL: 정책 미통과인데 선점 %', v;
  end if;
  p := pg_temp.pub('00000000-0000-4000-e200-000000000001');
  if p.status <> 'invalidated' or p.error <> 'confirm:policy_failed' then raise exception 'FAIL: 무효화 안 됨 % %', p.status, p.error; end if;
  raise notice 'PASS 1 정책 6/6 미통과면 선점·업로드 거부(invalidated)';
end $$;
reset role;
do $$
begin
  if (select status from public.projects where id = '00000000-0000-4000-e200-000000000001') <> 'in_progress' then
    raise exception 'FAIL: 프로젝트 발행 대기 유지';
  end if;
end $$;

-- 2) 선점 → uploading + 시도 토큰, 다시 부르면 대기 없음(같은 행 두 번 선점 안 됨). 발행 준비 덮어쓰기 거부
select pg_temp.mk_pub('00000000-0000-4000-e200-000000000002', '00000000-0000-4000-e100-0000000000a1', 'now', null);
set local role service_role;
do $$
declare v jsonb; v2 jsonb; p public.publications;
begin
  v := public.publication_claim();
  if not (v ->> 'claimed')::boolean or v ->> 'project_id' <> '00000000-0000-4000-e200-000000000002'
     or v ->> 'attempt_token' is null or v -> 'session' <> 'null'::jsonb
     or v ->> 'user_id' <> '00000000-0000-4000-e000-0000000000a1'
     or v ->> 'mp4_path' not like '00000000-0000-4000-e000-0000000000a1/%' then
    raise exception 'FAIL: 선점 결과 %', v;
  end if;
  p := pg_temp.pub('00000000-0000-4000-e200-000000000002');
  if p.status <> 'uploading' or p.attempt_token::text <> v ->> 'attempt_token' then raise exception 'FAIL: 선점 상태 %', p.status; end if;
  v2 := public.publication_claim();
  if (v2 ->> 'claimed')::boolean then raise exception 'FAIL: 같은 행 재선점 %', v2; end if;
  -- 틀린 시도 토큰은 기록 불가
  begin
    perform public.publication_attempt_fail(p.id, gen_random_uuid(), 'transient', 'http_503');
    raise exception 'FAIL: 다른 시도 토큰으로 기록';
  exception when sqlstate '55000' then null;
  end;
  raise notice 'PASS 2 선점 1회만(uploading·시도 토큰), 다른 토큰 기록 거부';
end $$;
reset role;
do $$
begin
  begin
    update public.publications set status = 'pending', title = '덮어쓰기'
    where project_id = '00000000-0000-4000-e200-000000000002';
    raise exception 'FAIL: uploading 행을 pending 으로 덮어씀';
  exception when sqlstate '55000' then null;
  end;
  raise notice 'PASS 3 선점 뒤 발행 준비 재저장(pending 덮어쓰기) 거부';
end $$;

-- 4) 세션 시작(쿼터 +1) → 세션 저장 → 일시 오류: 재선점 때 세션을 돌려줘 상태 조회로 이어 올림, 3회면 결과 불명(needs_check)
set local role service_role;
do $$
declare
  p public.publications := pg_temp.pub('00000000-0000-4000-e200-000000000002');
  v jsonb; used0 integer; used1 integer; i integer;
begin
  reset role;
  select coalesce((select used from public.youtube_upload_quota where day = (now() at time zone 'America/Los_Angeles')::date), 0) into used0;
  set local role service_role;
  v := public.publication_session_begin(p.id, p.attempt_token);
  if not (v ->> 'ok')::boolean then raise exception 'FAIL: 세션 시작 %', v; end if;
  reset role;
  select used into used1 from public.youtube_upload_quota where day = (now() at time zone 'America/Los_Angeles')::date;
  if used1 <> used0 + 1 then raise exception 'FAIL: 쿼터 카운터 % → %', used0, used1; end if;
  set local role service_role;
  begin
    perform public.publication_session_save(p.id, p.attempt_token, 'https://evil.example.com/upload?x=1', 1000);
    raise exception 'FAIL: 다른 호스트 세션 URI 저장';
  exception when check_violation then null;
  end;
  perform public.publication_session_save(p.id, p.attempt_token,
    'https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&upload_id=TEST', 1000);
  begin
    perform public.publication_session_begin(p.id, p.attempt_token);
    raise exception 'FAIL: 세션 있는데 새 insert 시작';
  exception when sqlstate '55000' then null;
  end;
  for i in 1..3 loop
    if i > 1 then
      reset role;
      update public.publications set next_attempt_at = now() - interval '1 second' where id = p.id;
      set local role service_role;
      v := public.publication_claim();
      if v ->> 'publication_id' <> p.id::text or v -> 'session' ->> 'total_bytes' <> '1000'
         or v -> 'session' ->> 'uri' not like 'https://www.googleapis.com/upload/%' then
        raise exception 'FAIL: 재선점에 세션 없음 %', v;
      end if;
      p.attempt_token := (v ->> 'attempt_token')::uuid;
    end if;
    v := public.publication_attempt_fail(p.id, p.attempt_token, 'transient', 'http_503');
    if i < 3 and (v ->> 'status' <> 'retry_wait' or (v ->> 'next_attempt_at')::timestamptz <= now()) then
      raise exception 'FAIL: % 회차 일시 오류 %', i, v;
    end if;
  end loop;
  if v ->> 'status' <> 'needs_check' then raise exception 'FAIL: 세션 있는 일시 오류 3회 뒤 %', v; end if;
  raise notice 'PASS 4 세션 저장 뒤 재시도는 세션 재사용(새 insert 0), 세션 있는 일시 오류 3회 → needs_check';
end $$;
reset role;

-- 5) 세션 없는 일시 오류 3회 → failed, 백오프(1분 → 4분)
select pg_temp.mk_pub('00000000-0000-4000-e200-000000000003', '00000000-0000-4000-e100-0000000000a1', 'now', null);
set local role service_role;
do $$
declare v jsonb; i integer; p public.publications; gaps interval[] := '{}';
begin
  for i in 1..3 loop
    if i > 1 then
      reset role;
      update public.publications set next_attempt_at = now() - interval '1 second'
      where project_id = '00000000-0000-4000-e200-000000000003';
      set local role service_role;
    end if;
    v := public.publication_claim();
    if v ->> 'project_id' <> '00000000-0000-4000-e200-000000000003' then raise exception 'FAIL: % 회차 선점 %', i, v; end if;
    v := public.publication_attempt_fail((v ->> 'publication_id')::uuid, (v ->> 'attempt_token')::uuid, 'transient', 'network');
    if i < 3 then gaps := gaps || ((v ->> 'next_attempt_at')::timestamptz - now()); end if;
  end loop;
  p := pg_temp.pub('00000000-0000-4000-e200-000000000003');
  if p.status <> 'failed' or p.retry_count <> 3 or p.error <> 'transient:network' then
    raise exception 'FAIL: 일시 오류 3회 뒤 % % %', p.status, p.retry_count, p.error;
  end if;
  if not (gaps[1] between interval '50 seconds' and interval '70 seconds' and gaps[2] between interval '230 seconds' and interval '250 seconds') then
    raise exception 'FAIL: 백오프 %', gaps;
  end if;
  raise notice 'PASS 5 일시 오류 3회 → failed(지수 백오프 1분·4분)';
end $$;
reset role;

-- 6) 쿼터: 전역 카운터 100 이면 insert 전에 PT 자정 이후로 미룸(횟수 미차감), quotaExceeded 는 카운터를 채움
select pg_temp.mk_pub('00000000-0000-4000-e200-000000000004', '00000000-0000-4000-e100-0000000000a1', 'now', null);
insert into public.youtube_upload_quota (day, used) values ((now() at time zone 'America/Los_Angeles')::date, 100)
on conflict (day) do update set used = 100;
set local role service_role;
do $$
declare v jsonb; c jsonb; p public.publications;
begin
  c := public.publication_claim();
  v := public.publication_session_begin((c ->> 'publication_id')::uuid, (c ->> 'attempt_token')::uuid);
  if (v ->> 'ok')::boolean or v ->> 'reason' <> 'quota' then raise exception 'FAIL: 쿼터 소진인데 시작 %', v; end if;
  p := pg_temp.pub('00000000-0000-4000-e200-000000000004');
  if p.status <> 'retry_wait' or p.retry_count <> 0 or p.next_attempt_at <= now()
     or (p.next_attempt_at at time zone 'America/Los_Angeles')::time <> '00:05' then
    raise exception 'FAIL: 쿼터 대기 % % %', p.status, p.retry_count, p.next_attempt_at;
  end if;
  raise notice 'PASS 6 전역 일일 카운터 100 → insert 전 PT 자정 이후로(재시도 횟수 미차감)';
end $$;
reset role;
update public.youtube_upload_quota set used = 0 where day = (now() at time zone 'America/Los_Angeles')::date;
update public.publications set next_attempt_at = now() - interval '1 second'
where project_id = '00000000-0000-4000-e200-000000000004';
set local role service_role;
do $$
declare v jsonb; c jsonb; p public.publications;
begin
  c := public.publication_claim();
  perform public.publication_session_begin((c ->> 'publication_id')::uuid, (c ->> 'attempt_token')::uuid);
  v := public.publication_attempt_fail((c ->> 'publication_id')::uuid, (c ->> 'attempt_token')::uuid, 'quota', 'quotaExceeded');
  p := pg_temp.pub('00000000-0000-4000-e200-000000000004');
  if p.status <> 'retry_wait' or p.retry_count <> 0 or p.next_attempt_at <= now() then
    raise exception 'FAIL: quotaExceeded 대기 % %', p.status, p.retry_count;
  end if;
  reset role;
  if (select used from public.youtube_upload_quota where day = (now() at time zone 'America/Los_Angeles')::date) <> 100 then
    raise exception 'FAIL: quotaExceeded 뒤 카운터가 차지 않음';
  end if;
  raise notice 'PASS 7 quotaExceeded → 횟수 미차감·다음 날, 오늘 카운터 소진 표시';
end $$;
reset role;
update public.youtube_upload_quota set used = 0 where day = (now() at time zone 'America/Los_Angeles')::date;

-- 8) invalid_grant → reconnect_wait(횟수 미차감), 연결 끊긴 채널은 선점 단계에서 reconnect_wait
select pg_temp.mk_pub('00000000-0000-4000-e200-000000000005', '00000000-0000-4000-e100-0000000000a1', 'now', null);
set local role service_role;
do $$
declare v jsonb; c jsonb; p public.publications;
begin
  c := public.publication_claim();
  v := public.publication_attempt_fail((c ->> 'publication_id')::uuid, (c ->> 'attempt_token')::uuid, 'reconnect', 'invalid_grant');
  p := pg_temp.pub('00000000-0000-4000-e200-000000000005');
  if p.status <> 'reconnect_wait' or p.retry_count <> 0 then raise exception 'FAIL: invalid_grant % %', p.status, p.retry_count; end if;
  raise notice 'PASS 8 invalid_grant → reconnect_wait(재시도 횟수 미차감)';
end $$;
reset role;

-- 9) 사용자 재시도: 남 거부, reconnect_wait → retry_wait. 연결 끊긴 채널이면 선점이 reconnect_wait 로
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-e000-0000000000b1","role":"authenticated"}', true);
do $$
begin
  begin
    perform public.publication_retry('00000000-0000-4000-e200-000000000005');
    raise exception 'FAIL: 남의 발행 재시도';
  exception when insufficient_privilege then null;
  end;
end $$;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-e000-0000000000a1","role":"authenticated"}', true);
do $$
declare v jsonb;
begin
  v := public.publication_retry('00000000-0000-4000-e200-000000000005');
  if v ->> 'status' <> 'retry_wait' then raise exception 'FAIL: 재시도 결과 %', v; end if;
  begin
    perform public.publication_retry('00000000-0000-4000-e200-000000000005');
    raise exception 'FAIL: retry_wait 에서 또 재시도';
  exception when sqlstate '55000' then null;
  end;
  begin
    perform public.publication_claim();
    raise exception 'FAIL: 사용자가 선점 호출';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.publication_upload_sessions;
    raise exception 'FAIL: 사용자가 세션 URI 조회';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.youtube_upload_quota;
    raise exception 'FAIL: 사용자가 쿼터 표 조회';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS 9 재시도는 소유자만(남 42501), 재시도는 retry_wait. 선점·세션·쿼터는 사용자 접근 불가';
end $$;
reset role;
update public.accounts set status = 'reconnect_required' where id = '00000000-0000-4000-e100-0000000000a1';
set local role service_role;
do $$
declare v jsonb;
begin
  v := public.publication_claim();
  if v ->> 'reason' <> 'reconnect_wait' then raise exception 'FAIL: 연결 끊긴 채널 선점 %', v; end if;
  raise notice 'PASS 10 연결 끊긴 채널 → 선점 단계에서 reconnect_wait(Google 호출 없음)';
end $$;
reset role;
update public.accounts set status = 'connected' where id = '00000000-0000-4000-e100-0000000000a1';

-- 11) 예약 시각이 지금+5분보다 이르면 업로드하지 않고 사용자 확인(invalidated, confirm:schedule_passed)
select pg_temp.mk_pub('00000000-0000-4000-e200-000000000006', '00000000-0000-4000-e100-0000000000a1', 'scheduled',
                      now() + interval '2 minutes');
set local role service_role;
do $$
declare v jsonb; p public.publications;
begin
  v := public.publication_claim();
  if v ->> 'reason' <> 'schedule_passed' then raise exception 'FAIL: 지난 예약 시각 선점 %', v; end if;
  p := pg_temp.pub('00000000-0000-4000-e200-000000000006');
  if p.status <> 'invalidated' or p.error <> 'confirm:schedule_passed' then raise exception 'FAIL: 확인 필요 상태 % %', p.status, p.error; end if;
  raise notice 'PASS 11 예약 시각 < 지금+5분 → 업로드 안 함, 사용자 확인 필요';
end $$;
reset role;
-- 다시 발행 준비하면(invalidated → pending) 이전 오류 기록이 비워진다
update public.publications set status = 'pending', scheduled_at = now() + interval '1 day'
where project_id = '00000000-0000-4000-e200-000000000006';
do $$
begin
  if (pg_temp.pub('00000000-0000-4000-e200-000000000006')).error is not null then raise exception 'FAIL: 재준비 뒤 오류 남음'; end if;
end $$;

-- 12) 예약 업로드 성공 → scheduled·영상 ID·프로젝트 상태. 이후 재업로드·채널 변경·재시도 불가
set local role service_role;
do $$
declare v jsonb; c jsonb; p public.publications;
begin
  c := public.publication_claim();
  if c ->> 'project_id' <> '00000000-0000-4000-e200-000000000006' then raise exception 'FAIL: 예약 선점 %', c; end if;
  perform public.publication_session_begin((c ->> 'publication_id')::uuid, (c ->> 'attempt_token')::uuid);
  perform public.publication_session_save((c ->> 'publication_id')::uuid, (c ->> 'attempt_token')::uuid,
    'https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&upload_id=OK', 2000);
  begin
    perform public.publication_finish((c ->> 'publication_id')::uuid, (c ->> 'attempt_token')::uuid, 'bad id!', false);
    raise exception 'FAIL: 잘못된 영상 ID 저장';
  exception when invalid_parameter_value then null;
  end;
  v := public.publication_finish((c ->> 'publication_id')::uuid, (c ->> 'attempt_token')::uuid, 'dQw4w9WgXcQ', false);
  p := pg_temp.pub('00000000-0000-4000-e200-000000000006');
  if v ->> 'status' <> 'scheduled' or p.status <> 'scheduled' or p.platform_video_id <> 'dQw4w9WgXcQ'
     or p.published_at <> p.scheduled_at then
    raise exception 'FAIL: 예약 업로드 결과 % %', v, p.status;
  end if;
end $$;
reset role;
do $$
begin
  if (select status from public.projects where id = '00000000-0000-4000-e200-000000000006') <> 'scheduled' then
    raise exception 'FAIL: 프로젝트 상태 scheduled 아님';
  end if;
  begin
    update public.publications set status = 'pending' where project_id = '00000000-0000-4000-e200-000000000006';
    raise exception 'FAIL: 업로드된 발행을 다시 대기로';
  exception when sqlstate '55000' then null;
  end;
  begin
    update public.publications set platform_video_id = 'otherVideo1' where project_id = '00000000-0000-4000-e200-000000000006';
    raise exception 'FAIL: 영상 ID 바꿈';
  exception when sqlstate '55000' then null;
  end;
  begin
    update public.publications set account_id = '00000000-0000-4000-e100-0000000000a2'
    where project_id = '00000000-0000-4000-e200-000000000006';
    raise exception 'FAIL: 발행 채널 바꿈';
  exception when sqlstate '42501' or foreign_key_violation then null;
  end;
end $$;
set local role authenticated;
do $$
begin
  begin
    perform public.publication_retry('00000000-0000-4000-e200-000000000006');
    raise exception 'FAIL: 업로드된 발행 재시도';
  exception when sqlstate '55000' then null;
  end;
  raise notice 'PASS 12 예약 업로드 성공 → scheduled·영상 ID, 이후 재업로드·다른 채널·재시도 불가';
end $$;
reset role;

-- 13) 다른 플랫폼(Instagram) 채널 프로젝트는 YouTube 로 올리지 않는다
select pg_temp.mk_pub('00000000-0000-4000-e200-000000000009', '00000000-0000-4000-e100-0000000000a2', 'now', null);
set local role service_role;
do $$
declare v jsonb;
begin
  v := public.publication_claim();
  if v ->> 'reason' <> 'channel_mismatch' then raise exception 'FAIL: 다른 채널 선점 %', v; end if;
  if (pg_temp.pub('00000000-0000-4000-e200-000000000009')).status <> 'failed' then raise exception 'FAIL: 다른 채널 상태'; end if;
  raise notice 'PASS 13 프로젝트 채널이 YouTube 가 아니면 업로드 거부';
end $$;
reset role;

-- 14) needs_check 는 다시 시도(이어 올리기 경로)로 풀 수 없다 → 영상 없음 확인(publication_confirm_absent)만. 재시작 표시 없음
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-e000-0000000000a1","role":"authenticated"}', true);
do $$
begin
  begin
    perform public.publication_retry('00000000-0000-4000-e200-000000000002');
    raise exception 'FAIL: needs_check 를 다시 시도로 풂';
  exception when sqlstate '55000' then null;
  end;
end $$;
reset role;
do $$
begin
  if (pg_temp.pub('00000000-0000-4000-e200-000000000002')).status <> 'needs_check' then raise exception 'FAIL: needs_check 아님'; end if;
  if exists (select 1 from public.publication_upload_sessions where restart_allowed) then raise exception 'FAIL: 재시작 표시 남음'; end if;
  if to_regprocedure('public.publication_session_discard(uuid,uuid)') is not null then raise exception 'FAIL: 세션 폐기 함수 남음'; end if;
  raise notice 'PASS 14 needs_check 는 publication_retry 거부, 세션 폐기 경로는 영상 없음 확인뿐';
end $$;

-- 14b) 세션·쿼터 표: RLS 켜짐, anon·authenticated 권한 0
do $$
declare t text; r text; priv text;
begin
  foreach t in array array['public.publication_upload_sessions', 'public.youtube_upload_quota'] loop
    if not (select relrowsecurity from pg_class where oid = t::regclass) then raise exception 'FAIL: % RLS 꺼짐', t; end if;
    foreach r in array array['anon', 'authenticated'] loop
      foreach priv in array array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] loop
        if has_table_privilege(r, t, priv) then raise exception 'FAIL: % 가 % 에 % 권한', r, t, priv; end if;
      end loop;
    end loop;
  end loop;
  raise notice 'PASS 14b 세션·쿼터 표 RLS 켜짐, anon·authenticated 권한 0';
end $$;

-- 15) 멈춘 시도(30분 넘은 uploading): 세션 없으면 retry_wait(1회 차감)
select pg_temp.mk_pub('00000000-0000-4000-e200-000000000007', '00000000-0000-4000-e100-0000000000a1', 'now', null);
set local role service_role;
select public.publication_claim() is not null;
reset role;
update public.publications set attempt_started_at = now() - interval '31 minutes'
where project_id = '00000000-0000-4000-e200-000000000007';
set local role service_role;
do $$
declare v jsonb; p public.publications;
begin
  v := public.publication_claim();
  p := pg_temp.pub('00000000-0000-4000-e200-000000000007');
  -- 정리 직후 next_attempt_at = now() 라서 같은 호출에서 다시 선점될 수 있다
  if not ((p.status = 'retry_wait' and p.retry_count = 1) or (p.status = 'uploading' and p.retry_count = 1)) then
    raise exception 'FAIL: 멈춘 시도 정리 % %', p.status, p.retry_count;
  end if;
  raise notice 'PASS 15 멈춘 시도(30분) 정리: 세션 없으면 일시 오류 1회로';
end $$;
reset role;

-- 16) YouTube 한도: 한글 4000자 본문(설명란 > 5000바이트)은 발행 준비 거부(PC002), 짧은 본문은 저장
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-e000-0000000000a1","role":"authenticated"}', true);
do $$
declare v jsonb;
begin
  begin
    perform public.prepare_publication('00000000-0000-4000-e200-000000000008', 'now', now(), '압축팩 정리 꿀팁',
                                       repeat('가', 4000), array['수납'], true, false);
    raise exception 'FAIL: 설명란 5000바이트 초과 저장';
  exception when sqlstate 'PC002' then null;
  end;
end $$;
do $$
declare v jsonb;
begin
  v := public.prepare_publication('00000000-0000-4000-e200-000000000008', 'now', now(), '압축팩 정리 꿀팁',
                                  repeat('가', 1000), array['수납'], true, false);
  if v ->> 'status' <> 'pending' then raise exception 'FAIL: 짧은 본문 발행 준비 %', v; end if;
  raise notice 'PASS 16 한글 4000자 본문(설명란 5000바이트 초과) 발행 준비 거부, 1000자는 저장';
end $$;
reset role;
do $$
begin
  if private.youtube_tags_length(array['a b', 'cc']) <> 8 then raise exception 'FAIL: 태그 길이 계산'; end if;
  if octet_length(repeat('가', 4000)) <= 5000 then raise exception 'FAIL: 전제'; end if;
end $$;

-- 17) 업로더 한도 거부(session_begin 전) → invalidated(confirm:description_too_long), 자동 재시도 없음
set local role service_role;
do $$
declare c jsonb; v jsonb; p public.publications;
begin
  c := public.publication_claim();
  if c ->> 'project_id' <> '00000000-0000-4000-e200-000000000008' then raise exception 'FAIL: 선점 %', c; end if;
  begin
    perform public.publication_reject_copy((c ->> 'publication_id')::uuid, (c ->> 'attempt_token')::uuid, 'other');
    raise exception 'FAIL: 잘못된 한도 코드';
  exception when invalid_parameter_value then null;
  end;
  v := public.publication_reject_copy((c ->> 'publication_id')::uuid, (c ->> 'attempt_token')::uuid, 'description_too_long');
  p := pg_temp.pub('00000000-0000-4000-e200-000000000008');
  if p.status <> 'invalidated' or p.error <> 'confirm:description_too_long' then raise exception 'FAIL: 한도 거부 % %', p.status, p.error; end if;
  if (public.publication_claim() ->> 'claimed')::boolean then raise exception 'FAIL: 한도 거부 뒤 재선점'; end if;
  raise notice 'PASS 17 업로더 한도 거부 → 발행 준비 해제(사용자가 줄여 다시 저장), 자동 재시도 없음';
end $$;
reset role;

-- 18) needs_check 출구: 남 거부, 소유자 확인 → 세션 폐기·retry_wait·감사 이벤트, 다시 부르면 거부
set local role authenticated;
do $$
begin
  perform public.prepare_publication('00000000-0000-4000-e200-000000000008', 'now', now(), '압축팩 정리 꿀팁',
                                     '본문', array['수납'], true, false);
end $$;
reset role;
set local role service_role;
do $$
declare c jsonb;
begin
  c := public.publication_claim();
  perform public.publication_session_begin((c ->> 'publication_id')::uuid, (c ->> 'attempt_token')::uuid);
  perform public.publication_session_save((c ->> 'publication_id')::uuid, (c ->> 'attempt_token')::uuid,
    'https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&upload_id=GONE', 1000);
  perform public.publication_attempt_fail((c ->> 'publication_id')::uuid, (c ->> 'attempt_token')::uuid, 'unknown', 'response_lost');
  begin
    perform public.publication_confirm_absent('00000000-0000-4000-e200-000000000008');
    raise exception 'FAIL: 서버 역할이 사용자 확인 호출';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-e000-0000000000b1","role":"authenticated"}', true);
do $$
begin
  begin
    perform public.publication_confirm_absent('00000000-0000-4000-e200-000000000008');
    raise exception 'FAIL: 남이 영상 없음 확인';
  exception when insufficient_privilege then null;
  end;
end $$;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-e000-0000000000a1","role":"authenticated"}', true);
do $$
declare v jsonb;
begin
  v := public.publication_confirm_absent('00000000-0000-4000-e200-000000000008');
  if v ->> 'status' <> 'retry_wait' then raise exception 'FAIL: 확인 결과 %', v; end if;
  begin
    perform public.publication_confirm_absent('00000000-0000-4000-e200-000000000008');
    raise exception 'FAIL: retry_wait 에서 또 확인';
  exception when sqlstate '55000' then null;
  end;
end $$;
reset role;
do $$
declare p public.publications := pg_temp.pub('00000000-0000-4000-e200-000000000008');
begin
  if p.status <> 'retry_wait' or p.retry_count <> 0 then raise exception 'FAIL: 확인 뒤 상태 %', p.status; end if;
  if exists (select 1 from public.publication_upload_sessions where publication_id = p.id) then
    raise exception 'FAIL: 세션이 남음';
  end if;
  if not exists (select 1 from public.project_events
                 where project_id = p.project_id and step = 6 and event = 'upload_absent_confirmed') then
    raise exception 'FAIL: 감사 이벤트 없음';
  end if;
  raise notice 'PASS 18 needs_check 출구: 소유자 확인만, 세션 폐기·retry_wait(새 업로드)·감사 이벤트 기록';
end $$;

-- 19) 보관 정리 경합(RT001)으로 finish 가 취소되면 deferred: 횟수 미차감·5분 뒤, 세션 유지(다음 시도는 상태 조회)
update public.publications set next_attempt_at = now() + interval '100 years'
where project_id in (select id from public.projects where user_id = '00000000-0000-4000-e000-0000000000a1')
  and status in ('pending', 'retry_wait');
select pg_temp.mk_project('00000000-0000-4000-e200-000000000010', '00000000-0000-4000-e100-0000000000a1', true);
select pg_temp.mk_pub('00000000-0000-4000-e200-000000000010', '00000000-0000-4000-e100-0000000000a1', 'now', null);
set local role service_role;
do $$
declare c jsonb; v jsonb; p public.publications;
begin
  c := public.publication_claim();
  if c ->> 'project_id' <> '00000000-0000-4000-e200-000000000010' then raise exception 'FAIL: 선점 %', c; end if;
  perform public.publication_session_begin((c ->> 'publication_id')::uuid, (c ->> 'attempt_token')::uuid);
  perform public.publication_session_save((c ->> 'publication_id')::uuid, (c ->> 'attempt_token')::uuid,
    'https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&upload_id=RT', 1000);
  v := public.publication_attempt_fail((c ->> 'publication_id')::uuid, (c ->> 'attempt_token')::uuid, 'deferred', 'RT001');
  p := pg_temp.pub('00000000-0000-4000-e200-000000000010');
  if p.status <> 'retry_wait' or p.retry_count <> 0 or p.error <> 'deferred:RT001'
     or p.next_attempt_at not between now() + interval '4 minutes' and now() + interval '6 minutes' then
    raise exception 'FAIL: deferred % % %', p.status, p.retry_count, p.next_attempt_at;
  end if;
  raise notice 'PASS 19 RT001(보관 정리 경합) → deferred: 재시도 횟수 미차감·5분 뒤, 세션 유지';
end $$;
reset role;

rollback;
