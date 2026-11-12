-- 06 발행 정책 점검·발행 준비(20261112260000) 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/publish_policy.sql
-- 한 트랜잭션으로 돌리고 ROLLBACK 한다(테스트 사용자 rls-test-pub-* 는 남지 않는다).
-- A = 소유자(YouTube 채널), B = 남. P·P2 = A 의 1~5단계 승인 프로젝트(같은 채널), I = A 의 Instagram 채널 프로젝트
begin;

insert into auth.users (id, aud, role, email) values
  ('00000000-0000-4000-f000-0000000000a1', 'authenticated', 'authenticated', 'rls-test-pub-a@example.com'),
  ('00000000-0000-4000-f000-0000000000b1', 'authenticated', 'authenticated', 'rls-test-pub-b@example.com');
insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-f100-0000000000a1', '00000000-0000-4000-f000-0000000000a1', 'youtube', 'A 채널'),
  ('00000000-0000-4000-f100-0000000000a2', '00000000-0000-4000-f000-0000000000a1', 'instagram', 'A 인스타');
insert into public.projects (id, user_id, account_id, category_id, name, step_status, sources_notice_ack_at, sources_notice_ack_by) values
  ('00000000-0000-4000-f200-0000000000a1', '00000000-0000-4000-f000-0000000000a1', '00000000-0000-4000-f100-0000000000a1',
   (select id from public.categories where name = '생활·수납'), 'P',
   '{"1":"approved","2":"approved","3":"ready","4":"idle","5":"idle","6":"idle"}', now(),
   '00000000-0000-4000-f000-0000000000a1'),
  ('00000000-0000-4000-f200-0000000000a2', '00000000-0000-4000-f000-0000000000a1', '00000000-0000-4000-f100-0000000000a1',
   null, 'P2',
   '{"1":"approved","2":"approved","3":"ready","4":"idle","5":"idle","6":"idle"}', now(),
   '00000000-0000-4000-f000-0000000000a1'),
  ('00000000-0000-4000-f200-0000000000a3', '00000000-0000-4000-f000-0000000000a1', '00000000-0000-4000-f100-0000000000a2',
   null, 'I',
   '{"1":"approved","2":"approved","3":"ready","4":"idle","5":"idle","6":"idle"}', now(),
   '00000000-0000-4000-f000-0000000000a1');
insert into public.scripts (project_id, version, lines, approved_at) values
  ('00000000-0000-4000-f200-0000000000a1', 1, '["좁은 틈에도 쏙 들어가요.", "이거 하나면 정리 끝!"]', now());
insert into public.renders (project_id, version, mp4_path, duration_sec, cut_map)
select pid, 1, '00000000-0000-4000-f000-0000000000a1/' || pid || '/v1.mp4', 15,
  jsonb_build_object('cuts', jsonb_build_array(
    jsonb_build_object('no', 1, 'source_id', '00000000-0000-4000-f300-000000000001', 'author', 'maker_a',
                       'platform', 'tiktok', 'source_url', 'https://www.tiktok.com/@maker_a/video/1',
                       'collected_at', '2026-11-12T01:00:00Z'),
    jsonb_build_object('no', 2, 'source_id', '00000000-0000-4000-f300-000000000002', 'author', 'maker_b',
                       'platform', 'xiaohongshu', 'source_url', 'https://www.xiaohongshu.com/explore/2',
                       'collected_at', '2026-11-12T01:00:00Z')))
from (values ('00000000-0000-4000-f200-0000000000a1'::uuid), ('00000000-0000-4000-f200-0000000000a2'::uuid),
             ('00000000-0000-4000-f200-0000000000a3'::uuid)) v(pid);
-- 대본·렌더를 넣은 뒤 1~5단계 승인 상태로(대본 잠금 트리거 때문에 순서대로)
update public.projects
set step_status = '{"1":"approved","2":"approved","3":"approved","4":"approved","5":"approved","6":"idle"}'
where user_id = '00000000-0000-4000-f000-0000000000a1';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f000-0000000000a1","role":"authenticated"}', true);

-- 1) 제휴 없음: 출처 표기·고지 확인(사용자 체크)만 남은 5/6 → 발행 준비 거부(PC001)
do $$
declare v jsonb;
begin
  v := public.publish_policy('00000000-0000-4000-f200-0000000000a1', '압축팩 정리 꿀팁', '본문', array['수납']);
  if (v ->> 'passed')::int <> 5 or (v ->> 'total')::int <> 6 then raise exception 'FAIL: 제휴 없음 통과 수 % (5 기대)', v ->> 'passed'; end if;
  if jsonb_array_length(v -> 'items') <> 6 then raise exception 'FAIL: 항목 수 %', jsonb_array_length(v -> 'items'); end if;
  if (select r ->> 'result' from jsonb_array_elements(v -> 'items') r where r ->> 'item' = 'attribution_notice') <> 'pending' then
    raise exception 'FAIL: 출처 표기·고지 미체크인데 pending 아님';
  end if;
  if v ->> 'credits' <> '영상 출처: @maker_a(TikTok), @maker_b(小红书)' then raise exception 'FAIL: 출처 문구 %', v ->> 'credits'; end if;
  begin
    perform public.prepare_publication('00000000-0000-4000-f200-0000000000a1', 'now', null, '압축팩 정리 꿀팁', '본문',
                                       array['수납'], true, false);
    raise exception 'FAIL: 5/6 인데 발행 준비 저장';
  exception when sqlstate 'PC001' then
    raise notice 'PASS 1 6항목 중 1개(출처 표기·고지) 미통과면 발행 준비 거부';
  end;
end $$;

-- 2) 사용자 체크 → 6/6 → 발행 준비 저장, 기록자·시각은 함수가 남김
do $$
declare v jsonb; p jsonb; c record;
begin
  perform public.confirm_policy_check('00000000-0000-4000-f200-0000000000a1', 'attribution_notice', true);
  select checked_by, checked_at into c from public.policy_checks
  where project_id = '00000000-0000-4000-f200-0000000000a1' and item = 'attribution_notice';
  if c.checked_by is distinct from '00000000-0000-4000-f000-0000000000a1'::uuid or c.checked_at is null then
    raise exception 'FAIL: 사용자 체크 기록 없음';
  end if;
  v := public.publish_policy('00000000-0000-4000-f200-0000000000a1', '압축팩 정리 꿀팁', '본문', array['수납']);
  if (v ->> 'passed')::int <> 6 then raise exception 'FAIL: 체크 뒤 통과 수 %', v ->> 'passed'; end if;
  p := public.prepare_publication('00000000-0000-4000-f200-0000000000a1', 'now', null, '압축팩 정리 꿀팁', '본문',
                                  array['#수납', '수납', '압축팩'], true, false);
  if p ->> 'status' <> 'pending' or p ->> 'mode' <> 'now' then raise exception 'FAIL: 발행 행 %', p; end if;
  if p ->> 'description' <> E'본문\n\n영상 출처: @maker_a(TikTok), @maker_b(小红书)\n\n#수납 #압축팩' then
    raise exception 'FAIL: 제휴 없음 설명란 %', p ->> 'description';
  end if;
  raise notice 'PASS 2 사용자 체크 뒤 6/6 → 발행 준비 저장(해시태그 중복 제거)';
end $$;

-- 3) 함수 전용 열·서버 전용 열 직접 쓰기 거부
do $$
begin
  begin
    insert into public.publications (project_id, account_id, mode)
    values ('00000000-0000-4000-f200-0000000000a2', '00000000-0000-4000-f100-0000000000a1', 'now');
    raise exception 'FAIL: publications 직접 INSERT';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.publications set mode = 'scheduled', scheduled_at = now() + interval '1 day'
    where project_id = '00000000-0000-4000-f200-0000000000a1';
    raise exception 'FAIL: publications mode·scheduled_at 직접 UPDATE';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.policy_checks set checked_at = now(), result = 'pass'
    where project_id = '00000000-0000-4000-f200-0000000000a1';
    raise exception 'FAIL: policy_checks 직접 UPDATE';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.policy_checks (project_id, item, result)
    values ('00000000-0000-4000-f200-0000000000a2', 'purchase_path', 'pass');
    raise exception 'FAIL: policy_checks 직접 INSERT';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.affiliate_links (project_id, program, url)
    values ('00000000-0000-4000-f200-0000000000a2', 'coupang_partners', 'https://link.coupang.com/a/x');
    raise exception 'FAIL: affiliate_links.url 직접 INSERT';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.projects set status = 'uploaded' where id = '00000000-0000-4000-f200-0000000000a1';
    raise exception 'FAIL: projects.status 직접 UPDATE';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.confirm_policy_check('00000000-0000-4000-f200-0000000000a1', 'banned_terms', true);
    raise exception 'FAIL: 자동 항목 사용자 체크';
  exception when invalid_parameter_value then null;
  end;
  raise notice 'PASS 3 publications·policy_checks·affiliate_links.url·projects.status 직접 쓰기와 자동 항목 체크 거부';
end $$;

-- 4) 링크형 제휴: 링크인바이오 번호(채널별 1부터·재사용 없음) · 고지 끄면 실패 · 금지어 실패 · 등록 완료 체크 → 6/6, 설명란 순서
insert into public.affiliate_links (project_id, program, disclosed) values
  ('00000000-0000-4000-f200-0000000000a1', 'coupang_partners', true),
  ('00000000-0000-4000-f200-0000000000a2', 'coupang_partners', true),
  ('00000000-0000-4000-f200-0000000000a3', 'youtube_shopping', true);
reset role;
update public.affiliate_links set url = 'https://link.coupang.com/a/test'  -- 서버(SR)만 쓰는 열
where project_id in ('00000000-0000-4000-f200-0000000000a1', '00000000-0000-4000-f200-0000000000a2');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f000-0000000000a1","role":"authenticated"}', true);

do $$
declare v jsonb; p jsonb; n1 int; n2 int; n1b int; d text;
begin
  v := public.publish_policy('00000000-0000-4000-f200-0000000000a1', '압축팩 정리 꿀팁', '본문', '{}');
  if (select r ->> 'result' from jsonb_array_elements(v -> 'items') r where r ->> 'item' = 'purchase_path') <> 'fail' then
    raise exception 'FAIL: 번호 없는 링크형 제휴의 구매 경로가 fail 아님';
  end if;
  begin
    perform public.confirm_policy_check('00000000-0000-4000-f200-0000000000a1', 'purchase_path', true);
    raise exception 'FAIL: 번호 없이 등록 완료';
  exception when object_not_in_prerequisite_state then null;
  end;
  n1 := public.assign_bio_number('00000000-0000-4000-f200-0000000000a1', 'inpock');
  n2 := public.assign_bio_number('00000000-0000-4000-f200-0000000000a2', 'litly');
  n1b := public.assign_bio_number('00000000-0000-4000-f200-0000000000a1', 'linktree');
  if n1 <> 1 or n2 <> 2 or n1b <> 1 then raise exception 'FAIL: 번호 % % %', n1, n2, n1b; end if;
  if (select count(*) from public.bio_pages where account_id = '00000000-0000-4000-f100-0000000000a1') <> 1 then
    raise exception 'FAIL: 채널당 링크인바이오 1개 아님';
  end if;

  v := public.publish_policy('00000000-0000-4000-f200-0000000000a1', '압축팩 정리 꿀팁', '본문', '{}');
  if (select r ->> 'result' from jsonb_array_elements(v -> 'items') r where r ->> 'item' = 'purchase_path') <> 'pending' then
    raise exception 'FAIL: 등록 완료 전 구매 경로가 pending 아님';
  end if;
  perform public.confirm_policy_check('00000000-0000-4000-f200-0000000000a1', 'purchase_path', true);
  if (select bio_registered_at from public.affiliate_links where project_id = '00000000-0000-4000-f200-0000000000a1') is null then
    raise exception 'FAIL: 등록 완료 시각 없음';
  end if;

  update public.affiliate_links set disclosed = false where project_id = '00000000-0000-4000-f200-0000000000a1';
  v := public.publish_policy('00000000-0000-4000-f200-0000000000a1', '압축팩 정리 꿀팁', '본문', '{}');
  if (v ->> 'passed')::int <> 5 or v ->> 'disclosure' <> '' then raise exception 'FAIL: 고지 끔 통과 수 %', v ->> 'passed'; end if;
  begin
    perform public.prepare_publication('00000000-0000-4000-f200-0000000000a1', 'now', null, '압축팩 정리 꿀팁', '본문', '{}', true, false);
    raise exception 'FAIL: 고지 끄고 발행 준비';
  exception when sqlstate 'PC001' then null;
  end;
  update public.affiliate_links set disclosed = true where project_id = '00000000-0000-4000-f200-0000000000a1';

  begin
    perform public.prepare_publication('00000000-0000-4000-f200-0000000000a1', 'now', null, '최고의 압축팩', '본문', '{}', true, false);
    raise exception 'FAIL: 공통 금지어 제목 발행 준비';
  exception when sqlstate 'PC001' then null;
  end;
  begin
    perform public.prepare_publication('00000000-0000-4000-f200-0000000000a1', 'now', null, '압축팩', '최저가 보장 본문', '{}', true, false);
    raise exception 'FAIL: 카테고리 금지어 설명 발행 준비';
  exception when sqlstate 'PC001' then null;
  end;
  begin
    perform public.prepare_publication('00000000-0000-4000-f200-0000000000a1', 'scheduled', now() - interval '1 hour', '압축팩', '본문', '{}', true, false);
    raise exception 'FAIL: 지난 시각 예약';
  exception when invalid_parameter_value then null;
  end;

  p := public.prepare_publication('00000000-0000-4000-f200-0000000000a1', 'scheduled', now() + interval '1 day',
                                  '압축팩 정리 꿀팁', '좁은 틈에도 쏙 들어가요.', array['수납', '압축팩'], true, true);
  d := p ->> 'description';
  if not (strpos(d, '이 영상은 쿠팡 파트너스 활동의 일환') = 1
          and strpos(d, '구매 정보: 프로필 링크 1번') > strpos(d, '쿠팡 파트너스')
          and strpos(d, '좁은 틈에도') > strpos(d, '구매 정보')
          and strpos(d, '영상 출처: @maker_a') > strpos(d, '좁은 틈에도')
          and strpos(d, '#수납 #압축팩') > strpos(d, '영상 출처')) then
    raise exception 'FAIL: 설명란 순서 %', d;
  end if;
  if p ->> 'mode' <> 'scheduled' or p ->> 'scheduled_at' is null then raise exception 'FAIL: 예약 저장 %', p; end if;
  if (select body from public.publications where project_id = '00000000-0000-4000-f200-0000000000a1') <> '좁은 틈에도 쏙 들어가요.' then
    raise exception 'FAIL: 본문 원문 저장 안 됨';
  end if;
  if (select status from public.projects where id = '00000000-0000-4000-f200-0000000000a1') <> 'awaiting_publish' then
    raise exception 'FAIL: 프로젝트 상태가 발행 대기 아님';
  end if;
  if (select count(*) from public.publications where project_id = '00000000-0000-4000-f200-0000000000a1') <> 1 then
    raise exception 'FAIL: 발행 행 1개 아님';
  end if;
  raise notice 'PASS 4 번호 1·2·재사용 없음, 고지 끔·금지어 거부, 설명란 고지 → 구매 안내 → 본문 → 출처 → 해시태그';

  -- 5) 유튜브 쇼핑 태그는 YouTube 채널만
  v := public.publish_policy('00000000-0000-4000-f200-0000000000a3', '압축팩', '본문', '{}');
  if (select r ->> 'result' from jsonb_array_elements(v -> 'items') r where r ->> 'item' = 'purchase_path') <> 'fail' then
    raise exception 'FAIL: Instagram 채널 유튜브 쇼핑 태그가 통과';
  end if;
  raise notice 'PASS 5 유튜브 쇼핑 상품 태그는 YouTube 채널이 아니면 구매 경로 실패';

  -- 6) 체크 해제 → 다시 5/6
  perform public.confirm_policy_check('00000000-0000-4000-f200-0000000000a1', 'attribution_notice', false);
  v := public.publish_policy('00000000-0000-4000-f200-0000000000a1', '압축팩 정리 꿀팁', '본문', '{}');
  if (v ->> 'passed')::int <> 5 then raise exception 'FAIL: 체크 해제 뒤 통과 수 %', v ->> 'passed'; end if;
  raise notice 'PASS 6 사용자 체크 해제하면 다시 미통과';
end $$;

-- 9) 보안 리뷰: 체크 해제 → 발행 준비 무효화, 다시 준비하면 pending
do $$
declare p jsonb;
begin
  if (select status from public.publications where project_id = '00000000-0000-4000-f200-0000000000a1') <> 'invalidated'
     or (select status from public.projects where id = '00000000-0000-4000-f200-0000000000a1') <> 'in_progress' then
    raise exception 'FAIL: 체크 해제 뒤 발행 행·프로젝트 상태가 무효화되지 않음';
  end if;
  perform public.confirm_policy_check('00000000-0000-4000-f200-0000000000a1', 'attribution_notice', true);
  p := public.prepare_publication('00000000-0000-4000-f200-0000000000a1', 'now', null, '압축팩 정리 꿀팁', '본문', '{}', true, false);
  if p ->> 'status' <> 'pending' or (select status from public.projects where id = '00000000-0000-4000-f200-0000000000a1') <> 'awaiting_publish' then
    raise exception 'FAIL: 무효화 뒤 다시 발행 준비 실패';
  end if;
  -- 값이 같은 갱신은 무효화하지 않음
  update public.affiliate_links set disclosed = true, program = 'coupang_partners'
  where project_id = '00000000-0000-4000-f200-0000000000a1';
  if (select status from public.publications where project_id = '00000000-0000-4000-f200-0000000000a1') <> 'pending' then
    raise exception 'FAIL: 값이 같은 갱신에 무효화';
  end if;
  -- 사용자가 직접 바꿀 수 있는 제휴 열(disclosed) 변경은 무효화
  update public.affiliate_links set disclosed = false where project_id = '00000000-0000-4000-f200-0000000000a1';
  if (select status from public.publications where project_id = '00000000-0000-4000-f200-0000000000a1') <> 'invalidated' then
    raise exception 'FAIL: 고지 끔 뒤 무효화 안 됨';
  end if;
  update public.affiliate_links set disclosed = true where project_id = '00000000-0000-4000-f200-0000000000a1';
  perform public.prepare_publication('00000000-0000-4000-f200-0000000000a1', 'now', null, '압축팩 정리 꿀팁', '본문', '{}', true, false);
  raise notice 'PASS 9 체크 해제·제휴 변경이면 pending 발행 행 invalidated + 프로젝트 in_progress, 다시 준비하면 pending';
end $$;

-- 10) 보안 리뷰: bio 열·bio_items 직접 쓰기 거부
do $$
begin
  begin
    update public.affiliate_links set bio_no = 9 where project_id = '00000000-0000-4000-f200-0000000000a1';
    raise exception 'FAIL: affiliate_links.bio_no 직접 UPDATE';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.affiliate_links set bio_registered_at = now() where project_id = '00000000-0000-4000-f200-0000000000a2';
    raise exception 'FAIL: affiliate_links.bio_registered_at 직접 UPDATE';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.bio_items (bio_page_id, project_id, no)
    select id, '00000000-0000-4000-f200-0000000000a2', 99 from public.bio_pages
    where account_id = '00000000-0000-4000-f100-0000000000a1';
    raise exception 'FAIL: bio_items 직접 INSERT';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.bio_items set no = 1 where project_id = '00000000-0000-4000-f200-0000000000a2';
    raise exception 'FAIL: bio_items 직접 UPDATE';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.bio_items where project_id = '00000000-0000-4000-f200-0000000000a2';
    raise exception 'FAIL: bio_items 직접 DELETE';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.bio_pages set account_id = '00000000-0000-4000-f100-0000000000a2'
    where account_id = '00000000-0000-4000-f100-0000000000a1';
    raise exception 'FAIL: bio_pages 채널 직접 변경';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS 10 affiliate_links bio 열·bio_items 쓰기·bio_pages 채널 변경 직접 거부';
end $$;

-- 11) bio_items 없이 등록 완료 거부, 지운 번호 재사용 없음
reset role;
delete from public.bio_items where project_id = '00000000-0000-4000-f200-0000000000a2';
update public.affiliate_links set bio_registered_at = null where project_id = '00000000-0000-4000-f200-0000000000a2';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f000-0000000000a1","role":"authenticated"}', true);
do $$
declare v jsonb; n int;
begin
  begin
    perform public.confirm_policy_check('00000000-0000-4000-f200-0000000000a2', 'purchase_path', true);
    raise exception 'FAIL: bio_items 없이 등록 완료';
  exception when object_not_in_prerequisite_state then null;
  end;
  v := public.publish_policy('00000000-0000-4000-f200-0000000000a2', '압축팩', '본문', '{}');
  if (select r ->> 'result' from jsonb_array_elements(v -> 'items') r where r ->> 'item' = 'purchase_path') <> 'fail' then
    raise exception 'FAIL: bio_items 없는 구매 경로가 fail 아님';
  end if;
  n := public.assign_bio_number('00000000-0000-4000-f200-0000000000a2', 'inpock');
  if n <> 3 then raise exception 'FAIL: 지운 번호 재사용 또는 카운터 오류 %', n; end if;
  perform public.confirm_policy_check('00000000-0000-4000-f200-0000000000a2', 'purchase_path', true);
  raise notice 'PASS 11 bio_items 없으면 등록 완료·구매 경로 거부, 지운 번호도 재사용 없이 다음 번호(3)';
end $$;

-- 12) 업로드 직전 재판정(service_role 전용) · 5단계 변경 요청 → 무효화
do $$
begin
  begin
    perform public.publish_recheck('00000000-0000-4000-f200-0000000000a1');
    raise exception 'FAIL: authenticated publish_recheck';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set local role service_role;
do $$
declare r jsonb;
begin
  r := public.publish_recheck('00000000-0000-4000-f200-0000000000a1');
  if (r ->> 'ok')::boolean is not true then raise exception 'FAIL: 6/6 발행 행 재판정 실패 %', r; end if;
end $$;
reset role;
update public.publications set title = '최고의 압축팩' where project_id = '00000000-0000-4000-f200-0000000000a1';
set local role service_role;
do $$
declare r jsonb;
begin
  r := public.publish_recheck('00000000-0000-4000-f200-0000000000a1');
  if (r ->> 'ok')::boolean is not false or r ->> 'reason' <> 'policy_failed'
     or (select status from public.publications where project_id = '00000000-0000-4000-f200-0000000000a1') <> 'invalidated' then
    raise exception 'FAIL: 저장 문구 금지어 재판정 %', r;
  end if;
end $$;
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f000-0000000000a1","role":"authenticated"}', true);
do $$
begin
  perform public.prepare_publication('00000000-0000-4000-f200-0000000000a1', 'now', null, '압축팩 정리 꿀팁', '본문', '{}', true, false);
  perform public.request_step_change('00000000-0000-4000-f200-0000000000a1', 5);
  if (select status from public.publications where project_id = '00000000-0000-4000-f200-0000000000a1') <> 'invalidated'
     or (select status from public.projects where id = '00000000-0000-4000-f200-0000000000a1') <> 'in_progress' then
    raise exception 'FAIL: 5단계 변경 요청 뒤 무효화 안 됨';
  end if;
  raise notice 'PASS 12 업로드 직전 재판정(service_role 전용, 저장 문구 금지어면 무효화) · 5단계 변경 요청이면 무효화';
end $$;

-- 13) 제휴 URL CHECK: userinfo·유니코드·대문자 우회
reset role;
do $$
declare u text;
begin
  foreach u in array array[
    'https://coupang.com@evil.example/a',
    'https://user@link.coupang.com/a',
    'https://link.coup' || chr(1072) || 'ng.com/a',
    'https://xn--coupng-4ve.com/a',
    'https://evilcoupang.com/a',
    'https://coupang.com.evil.example/a',
    'http://link.coupang.com/a',
    'HTTP://LINK.COUPANG.COM/a',
    'https://link.coupang.com:8443/a'] loop
    begin
      update public.affiliate_links set url = u where project_id = '00000000-0000-4000-f200-0000000000a2';
      raise exception 'FAIL: 제휴 URL CHECK 우회 %', u;
    exception when check_violation then null;
    end;
  end loop;
  raise notice 'PASS 13 제휴 URL: userinfo·유니코드(키릴)·퓨니코드·위장 호스트·http·포트 거부';
end $$;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f000-0000000000a1","role":"authenticated"}', true);

-- 7) 타인 프로젝트 함수 거부
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f000-0000000000b1","role":"authenticated"}', true);
do $$
begin
  begin
    perform public.publish_policy('00000000-0000-4000-f200-0000000000a1', 't', 'b', '{}');
    raise exception 'FAIL: 타인 publish_policy';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.confirm_policy_check('00000000-0000-4000-f200-0000000000a1', 'attribution_notice', true);
    raise exception 'FAIL: 타인 confirm_policy_check';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.assign_bio_number('00000000-0000-4000-f200-0000000000a2', 'inpock');
    raise exception 'FAIL: 타인 assign_bio_number';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.prepare_publication('00000000-0000-4000-f200-0000000000a2', 'now', null, 't', 'b', '{}', true, false);
    raise exception 'FAIL: 타인 prepare_publication';
  exception when insufficient_privilege then null;
  end;
  if exists (select 1 from public.publications where project_id = '00000000-0000-4000-f200-0000000000a1') then
    raise exception 'FAIL: 타인이 발행 행을 읽음';
  end if;
  raise notice 'PASS 7 타인 프로젝트 정책·체크·번호·발행 준비 함수 거부, 발행 행 안 보임';
end $$;

-- 8) 익명·private 직접 호출 거부
reset role;
set local role anon;
do $$
begin
  begin
    perform public.publish_policy('00000000-0000-4000-f200-0000000000a1', 't', 'b', '{}');
    raise exception 'FAIL: anon publish_policy';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f000-0000000000a1","role":"authenticated"}', true);
do $$
begin
  begin
    perform private.publish_evaluate('00000000-0000-4000-f200-0000000000a1', 't', 'b', '{}');
    raise exception 'FAIL: private.publish_evaluate 직접 호출';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS 8 익명 호출·판정 본체 직접 호출 거부';
end $$;

-- 14) 06 발행 DEFINER 함수: search_path = '' · PUBLIC/anon EXECUTE 없음
reset role;
do $$
declare v_bad text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('private', 'public')
    and p.proname in ('publish_policy', 'confirm_policy_check', 'assign_bio_number', 'prepare_publication', 'publish_recheck',
                      'publish_evaluate', 'publish_owned', 'publish_invalidate', 'affiliate_links_invalidate', 'projects_publish_invalidate')
    and (not coalesce(p.proconfig, '{}') @> array['search_path=""']
         or has_function_privilege('anon', p.oid, 'execute')
         or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                    where a.grantee = 0 and a.privilege_type = 'EXECUTE'));
  if v_bad is not null then raise exception 'FAIL: search_path·EXECUTE 조건 위반 %', v_bad; end if;
  raise notice 'PASS 14 06 발행 함수 search_path 고정, PUBLIC·anon EXECUTE 없음';
end $$;

rollback;
