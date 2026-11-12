-- task-011 제작·발행 테이블 RLS·버킷·단계 승인 함수·원장 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/rls_production.sql
-- 전체를 한 트랜잭션으로 돌리고 ROLLBACK 한다(테스트 사용자 rls-test-prod-* 는 남지 않는다).
-- 실패하면 'FAIL:' 예외로 중단, 통과 항목은 NOTICE 'PASS' 로 찍힌다.
begin;

-- ── 준비(소유자 권한) ────────────────────────────────────────
insert into auth.users (id, aud, role, email)
values
  ('00000000-0000-4000-b000-00000000000a', 'authenticated', 'authenticated', 'rls-test-prod-a@example.com'),
  ('00000000-0000-4000-b000-00000000000b', 'authenticated', 'authenticated', 'rls-test-prod-b@example.com');

insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-b100-00000000000a', '00000000-0000-4000-b000-00000000000a', 'youtube', 'A 채널'),
  ('00000000-0000-4000-b100-00000000000b', '00000000-0000-4000-b000-00000000000b', 'youtube', 'B 채널');

insert into public.projects (id, user_id, account_id, name, step_status) values
  ('00000000-0000-4000-b200-00000000000a', '00000000-0000-4000-b000-00000000000a',
   '00000000-0000-4000-b100-00000000000a', 'A 프로젝트',
   '{"1":"ready","2":"ready","3":"idle","4":"idle","5":"idle","6":"idle"}');

insert into public.sources (id, project_id, platform, url, author, file_path, used) values
  ('00000000-0000-4000-b300-00000000000a', '00000000-0000-4000-b200-00000000000a', 'tiktok',
   'https://www.tiktok.com/@seller/video/1', '@seller',
   '00000000-0000-4000-b000-00000000000a/00000000-0000-4000-b200-00000000000a/a.mp4', true);
-- 02 승인 조건(20261112210000·210100): 사용 원본 5편 + 고지 확인. 출처 표기(attribution_notice)라 워터마크 제거 거부(PASS 30)는 그대로
insert into public.sources (project_id, platform, url, author, file_path, used)
select '00000000-0000-4000-b200-00000000000a', 'tiktok', 'https://www.tiktok.com/@seller/video/' || n, '@seller',
       '00000000-0000-4000-b000-00000000000a/00000000-0000-4000-b200-00000000000a/' || n || '.mp4', true
from generate_series(2, 5) n;
update public.sources set rights_basis = 'attribution_notice', rights_confirmed_at = now()
where project_id = '00000000-0000-4000-b200-00000000000a';
update public.projects set sources_notice_ack_at = now(), sources_notice_ack_by = '00000000-0000-4000-b000-00000000000a'
where id = '00000000-0000-4000-b200-00000000000a';

insert into storage.objects (bucket_id, name, owner_id)
values ('sources',
        '00000000-0000-4000-b000-00000000000a/00000000-0000-4000-b200-00000000000a/a.mp4',
        '00000000-0000-4000-b000-00000000000a');

insert into public.affiliate_links (id, project_id, program, url, short_url) values
  ('00000000-0000-4000-b400-00000000000a', '00000000-0000-4000-b200-00000000000a', 'coupang_partners',
   'https://link.coupang.com/a/test', 'https://s.example/rls-test');
insert into public.link_clicks (affiliate_link_id, short_url, platform)
values ('00000000-0000-4000-b400-00000000000a', 'https://s.example/rls-test', 'youtube');

insert into public.jobs (id, project_id, step, type, status, idempotency_key) values
  ('00000000-0000-4000-b500-00000000000a', '00000000-0000-4000-b200-00000000000a', 5, 'render', 'running',
   'rls-test-job-render');
insert into public.credit_ledger (user_id, project_id, job_id, kind, delta, idempotency_key) values
  ('00000000-0000-4000-b000-00000000000a', '00000000-0000-4000-b200-00000000000a',
   '00000000-0000-4000-b500-00000000000a', 'reserve', -30, 'rls-test-reserve');

do $$
declare v_count int;
begin
  select count(*) into v_count from storage.buckets
  where id in ('sources', 'voices', 'renders') and not public
    and file_size_limit is not null and allowed_mime_types is not null;
  if v_count <> 3 then raise exception 'FAIL: 비공개 버킷 3개(상한·MIME 포함) 아님 (%)', v_count; end if;
  select count(*) into v_count from public.user_profiles
  where user_id in ('00000000-0000-4000-b000-00000000000a', '00000000-0000-4000-b000-00000000000b');
  if v_count <> 2 then raise exception 'FAIL: 가입 트리거 프로필 2행 아님'; end if;
  raise notice 'PASS 1 sources·voices·renders 비공개(상한·MIME), 가입 프로필 생성';
end $$;

-- ── 사용자 B: 타인 원본 객체·행 접근, 타인 프로젝트 승인 ──────
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-b000-00000000000b","role":"authenticated"}', true);

do $$
declare v_count int;
begin
  select count(*) into v_count from storage.objects where bucket_id = 'sources';
  if v_count <> 0 then raise exception 'FAIL: B가 A 원본 객체를 봄 (%)', v_count; end if;
  raise notice 'PASS 2 B → A 원본 객체(storage.objects) 다운로드·목록 0행';

  select count(*) into v_count from public.sources;
  if v_count <> 0 then raise exception 'FAIL: B가 A sources 읽음'; end if;
  select count(*) into v_count from public.jobs;
  if v_count <> 0 then raise exception 'FAIL: B가 A jobs 읽음'; end if;
  select count(*) into v_count from public.link_clicks;
  if v_count <> 0 then raise exception 'FAIL: B가 A link_clicks 읽음'; end if;
  select count(*) into v_count from public.credit_ledger;
  if v_count <> 0 then raise exception 'FAIL: B가 A credit_ledger 읽음'; end if;
  raise notice 'PASS 3 B → A sources·jobs·link_clicks·credit_ledger 0행';

  begin
    perform public.approve_step('00000000-0000-4000-b200-00000000000a', 1);
    raise exception 'FAIL: B가 A 프로젝트 승인';
  exception when insufficient_privilege then
    raise notice 'PASS 4 B → A 프로젝트 approve_step 거부';
  end;
  begin
    perform public.request_step_change('00000000-0000-4000-b200-00000000000a', 1);
    raise exception 'FAIL: B가 A 프로젝트 변경 요청';
  exception when insufficient_privilege then
    raise notice 'PASS 5 B → A 프로젝트 request_step_change 거부';
  end;
end $$;

-- ── 사용자 A: 본인 객체도 직접 다운로드 불가(서명 URL만), 승인 순서 ──
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-b000-00000000000a","role":"authenticated"}', true);

do $$
declare v_count int; v_status jsonb;
begin
  select count(*) into v_count from storage.objects;
  if v_count <> 0 then raise exception 'FAIL: A가 직접 객체를 봄(서명 URL만이어야 함)'; end if;
  raise notice 'PASS 6 A 본인 객체도 직접 접근 0행(서명 URL만)';

  select count(*) into v_count from public.link_clicks;
  if v_count <> 1 then raise exception 'FAIL: A 본인 link_clicks 1행 아님 (%)', v_count; end if;
  raise notice 'PASS 7 A 본인 link_clicks(affiliate_links 경유) 1행';

  begin
    perform public.approve_step('00000000-0000-4000-b200-00000000000a', 2);
    raise exception 'FAIL: 미승인 앞 단계로 다음 단계 승인됨';
  exception when object_not_in_prerequisite_state then
    raise notice 'PASS 8 앞 단계(1) 미승인 상태에서 2단계 승인 거부';
  end;

  v_status := public.approve_step('00000000-0000-4000-b200-00000000000a', 1);
  v_status := public.approve_step('00000000-0000-4000-b200-00000000000a', 2);
  if v_status ->> '1' <> 'approved' or v_status ->> '2' <> 'approved' then
    raise exception 'FAIL: 1·2단계 승인 결과 이상 %', v_status;
  end if;
  select count(*) into v_count from public.project_events
  where project_id = '00000000-0000-4000-b200-00000000000a' and event = 'step_approved';
  if v_count <> 2 then raise exception 'FAIL: step_approved 이벤트 2건 아님 (%)', v_count; end if;
  raise notice 'PASS 9 1→2단계 순서 승인, project_events step_approved 2건';

  begin
    perform public.approve_step('00000000-0000-4000-b200-00000000000a', 3);
    raise exception 'FAIL: ready 아닌 단계 승인됨';
  exception when object_not_in_prerequisite_state then
    raise notice 'PASS 10 ready 아닌 단계(3, idle) 승인 거부';
  end;

  insert into public.scripts (project_id, version, lines) values
    ('00000000-0000-4000-b200-00000000000a', 1, '["첫 문장"]');
  begin
    update public.scripts set approved_at = now()
    where project_id = '00000000-0000-4000-b200-00000000000a';
    raise exception 'FAIL: scripts.approved_at 직접 수정됨';
  exception when insufficient_privilege then
    raise notice 'PASS 11 scripts.approved_at 직접 UPDATE 거부';
  end;

  begin
    insert into public.chat_messages (project_id, role, text)
    values ('00000000-0000-4000-b200-00000000000a', 'ai', '사칭');
    raise exception 'FAIL: chat role=ai INSERT 됨';
  exception when insufficient_privilege then
    raise notice 'PASS 12 chat_messages role=ai INSERT 거부';
  end;
  insert into public.chat_messages (project_id, role, text)
  values ('00000000-0000-4000-b200-00000000000a', 'user', '안녕하세요');
  raise notice 'PASS 13 chat_messages role=user INSERT 허용';

  begin
    perform secret_ref from public.api_keys;
    raise exception 'FAIL: api_keys.secret_ref 읽힘';
  exception when insufficient_privilege then
    raise notice 'PASS 14 api_keys.secret_ref 읽기 거부';
  end;
  begin
    perform access_token_hash from public.extension_connections;
    raise exception 'FAIL: extension_connections 해시 읽힘';
  exception when insufficient_privilege then
    raise notice 'PASS 15 extension_connections 해시 읽기 거부';
  end;
  begin
    update public.sources set rights_basis = 'own';
    raise exception 'FAIL: sources 권리 열 직접 수정됨';
  exception when insufficient_privilege then
    raise notice 'PASS 16 sources 권리 열 직접 UPDATE 거부';
  end;
end $$;

-- 준비: 3·4단계 ready, 5단계 작업 running (소유자 권한)
reset role;
update public.projects
set step_status = jsonb_set(jsonb_set(step_status, '{3}', '"ready"'), '{4}', '"ready"')
where id = '00000000-0000-4000-b200-00000000000a';

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-b000-00000000000a","role":"authenticated"}', true);

do $$
declare v_status jsonb; v_step int; v_approved timestamptz; v_job text; v_count int;
begin
  perform public.approve_step('00000000-0000-4000-b200-00000000000a', 3);
  select approved_at into v_approved from public.scripts
  where project_id = '00000000-0000-4000-b200-00000000000a';
  if v_approved is null then raise exception 'FAIL: 3단계 승인 후 scripts.approved_at 없음'; end if;
  perform public.approve_step('00000000-0000-4000-b200-00000000000a', 4);
  raise notice 'PASS 17 3단계 승인 시 scripts.approved_at 기록, 4단계 승인';

  begin
    update public.scripts set lines = '["몰래 바꾼 문장"]'
    where project_id = '00000000-0000-4000-b200-00000000000a';
    raise exception 'FAIL: 승인된 대본 lines 수정됨';
  exception when object_not_in_prerequisite_state then
    raise notice 'PASS 17-1 승인된 대본 lines UPDATE 거부';
  end;
  begin
    insert into public.scripts (project_id, version, lines)
    values ('00000000-0000-4000-b200-00000000000a', 2, '["새 버전"]');
    raise exception 'FAIL: 3단계 승인 중 새 대본 INSERT 됨';
  exception when object_not_in_prerequisite_state then
    raise notice 'PASS 17-2 3단계 승인 중 새 대본 INSERT 거부';
  end;

  v_status := public.request_step_change('00000000-0000-4000-b200-00000000000a', 2);
  select current_step into v_step from public.projects where id = '00000000-0000-4000-b200-00000000000a';
  if v_status <> '{"1":"approved","2":"change","3":"idle","4":"idle","5":"idle","6":"idle"}'::jsonb
     or v_step <> 2 then
    raise exception 'FAIL: 앞 단계 변경 후 초기화 이상 % / current_step %', v_status, v_step;
  end if;
  select approved_at into v_approved from public.scripts
  where project_id = '00000000-0000-4000-b200-00000000000a';
  select status into v_job from public.jobs where id = '00000000-0000-4000-b500-00000000000a';
  if v_approved is not null then raise exception 'FAIL: 대본 승인이 풀리지 않음'; end if;
  if v_job <> 'canceled' then raise exception 'FAIL: 뒤 단계 작업 취소 안 됨 (%)', v_job; end if;
  select count(*) into v_count from public.project_events
  where project_id = '00000000-0000-4000-b200-00000000000a' and event = 'step_change_requested';
  if v_count <> 1 then raise exception 'FAIL: step_change_requested 이벤트 없음'; end if;
  raise notice 'PASS 18 2단계 변경 → 3~6단계 idle, current_step 2, 대본 승인 해제, 5단계 작업 취소, 이벤트 기록';

  update public.scripts set lines = '["고친 문장"]'
  where project_id = '00000000-0000-4000-b200-00000000000a';
  insert into public.scripts (project_id, version, lines)
  values ('00000000-0000-4000-b200-00000000000a', 2, '["새 버전"]');
  raise notice 'PASS 18-1 승인 해제 뒤 대본 수정·새 버전 INSERT 허용';
end $$;

-- ── 익명: link_clicks·승인 함수 ─────────────────────────────
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
do $$
declare v_count int;
begin
  begin
    select count(*) into v_count from public.link_clicks;
    if v_count <> 0 then raise exception 'FAIL: anon이 link_clicks % 행 읽음', v_count; end if;
    raise notice 'PASS 19 anon link_clicks 0행';
  exception when insufficient_privilege then
    raise notice 'PASS 19 anon link_clicks 읽기 거부(0행)';
  end;
  begin
    perform public.approve_step('00000000-0000-4000-b200-00000000000a', 1);
    raise exception 'FAIL: anon이 approve_step 실행';
  exception when insufficient_privilege then
    raise notice 'PASS 20 anon approve_step 실행 거부';
  end;
  begin
    insert into public.link_clicks (affiliate_link_id) values ('00000000-0000-4000-b400-00000000000a');
    raise exception 'FAIL: anon이 link_clicks 기록';
  exception when insufficient_privilege then
    raise notice 'PASS 21 anon link_clicks INSERT 거부(서버만 기록)';
  end;
end $$;

-- ── 워커(worker_role): credit_ledger 이중 정산 거부 ─────────
reset role;
grant worker_role to postgres;  -- 트랜잭션 ROLLBACK 으로 함께 취소된다
set local role worker_role;
do $$
begin
  -- 20261112180300 이후 워커는 원장에 직접 쓰지 못하고 private.settle_job/release_job만 쓴다.
  -- 이중 settle·settle 뒤 release 거부는 supabase/tests/jobs_queue.sql에서 함수 경로로 검사한다.
  begin
    insert into public.credit_ledger (user_id, project_id, job_id, kind, delta, idempotency_key)
    values ('00000000-0000-4000-b000-00000000000a', '00000000-0000-4000-b200-00000000000a',
            '00000000-0000-4000-b500-00000000000a', 'settle', -25, 'rls-test-settle-1');
    raise exception 'FAIL: 워커 settle 직접 INSERT 허용됨';
  exception when insufficient_privilege then
    raise notice 'PASS 22 워커 settle 직접 INSERT 거부(정산 함수만)';
  end;
  begin
    insert into public.credit_ledger (user_id, project_id, job_id, kind, delta, idempotency_key)
    values ('00000000-0000-4000-b000-00000000000a', '00000000-0000-4000-b200-00000000000a',
            '00000000-0000-4000-b500-00000000000a', 'release', 30, 'rls-test-release-1');
    raise exception 'FAIL: 워커 release 직접 INSERT 허용됨';
  exception when insufficient_privilege then
    raise notice 'PASS 23 워커 release 직접 INSERT 거부(정산 함수만)';
  end;
  begin
    perform 1 from public.credit_ledger limit 1;
    raise exception 'FAIL: 워커 원장 조회 허용됨';
  exception when insufficient_privilege then
    raise notice 'PASS 24 워커 원장 조회 거부';
  end;
  begin
    insert into public.credit_ledger (user_id, kind, delta, idempotency_key)
    values ('00000000-0000-4000-b000-00000000000a', 'reserve', -10, 'rls-test-worker-reserve');
    raise exception 'FAIL: 워커 reserve 허용됨';
  exception when insufficient_privilege then
    raise notice 'PASS 25 워커 reserve INSERT 거부(settle·release만)';
  end;
  begin
    update public.credit_ledger set delta = 0;
    raise exception 'FAIL: 워커가 원장 수정';
  exception when insufficient_privilege then
    raise notice 'PASS 26 워커 원장 UPDATE 거부';
  end;
end $$;

-- ── 서버(service_role): 원장 추가 전용, 권리 열·워터마크 제거 규칙 ──
reset role;
set local role service_role;
do $$
begin
  begin
    update public.credit_ledger set delta = 0;
    raise exception 'FAIL: service_role이 원장 수정';
  exception when insufficient_privilege then
    raise notice 'PASS 27 service_role 원장 UPDATE 거부(추가 전용)';
  end;
  begin
    delete from public.credit_ledger;
    raise exception 'FAIL: service_role이 원장 삭제';
  exception when insufficient_privilege then
    raise notice 'PASS 28 service_role 원장 DELETE 거부(추가 전용)';
  end;
  begin
    update public.sources set rights_basis = 'own';
    raise exception 'FAIL: service_role이 권리 열 수정';
  exception when insufficient_privilege then
    raise notice 'PASS 29 service_role 권리 열 UPDATE 거부(함수 전용)';
  end;
  begin
    insert into public.renders (project_id, version, clean_status)
    values ('00000000-0000-4000-b200-00000000000a', 1, 'queued');
    raise exception 'FAIL: 권리 미확인 원본으로 워터마크 제거 요청됨';
  exception when insufficient_privilege then
    raise notice 'PASS 30 권리 미확인 원본 워터마크 제거 거부';
  end;
  begin
    insert into public.publications (project_id, account_id, mode)
    values ('00000000-0000-4000-b200-00000000000a', '00000000-0000-4000-b100-00000000000a', 'now');
    raise exception 'FAIL: service_role이 발행 행 생성';
  exception when insufficient_privilege then
    raise notice 'PASS 31 발행 행 직접 생성 거부(함수 전용)';
  end;
  begin
    insert into public.affiliate_links (project_id, program, url)
    values ('00000000-0000-4000-b200-00000000000a', 'coupang_partners', 'https://evil.example.com/x');
    raise exception 'FAIL: 미등록 제휴 도메인 허용';
  exception when check_violation then
    raise notice 'PASS 32 미등록 제휴 도메인 URL 거부';
  end;
end $$;

-- 발행 행이 있으면 프로젝트 채널 변경 불가(소유자 권한으로 발행 행을 만든 뒤 확인)
reset role;
insert into public.publications (project_id, account_id, mode)
values ('00000000-0000-4000-b200-00000000000a', '00000000-0000-4000-b100-00000000000a', 'now');
insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-b100-0000000000aa', '00000000-0000-4000-b000-00000000000a', 'tiktok', 'A 두번째');
do $$
begin
  begin
    update public.projects set account_id = '00000000-0000-4000-b100-0000000000aa'
    where id = '00000000-0000-4000-b200-00000000000a';
    raise exception 'FAIL: 발행 뒤 채널 변경됨';
  exception when foreign_key_violation then
    raise notice 'PASS 33 발행 뒤 projects.account_id 변경 거부';
  end;
end $$;

-- 모든 public 테이블 RLS 켬
do $$
declare v_missing text;
begin
  select string_agg(relname, ', ') into v_missing
  from pg_class
  where relnamespace = 'public'::regnamespace and relkind in ('r', 'p') and not relrowsecurity;
  if v_missing is not null then raise exception 'FAIL: RLS 꺼진 테이블: %', v_missing; end if;
  raise notice 'PASS 34 public 모든 테이블 RLS 켬';
end $$;

rollback;
