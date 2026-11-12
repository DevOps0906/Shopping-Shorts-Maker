-- 단계 산출물 검사(20261112200300) 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/step_output_checks.sql
-- 한 트랜잭션으로 돌리고 ROLLBACK 한다(테스트 사용자 rls-test-chk-* 는 남지 않는다). 시드 카테고리 '뷰티'(금지어 '피부 재생')를 쓴다.
begin;

insert into auth.users (id, aud, role, email)
values ('00000000-0000-4000-d000-00000000000a', 'authenticated', 'authenticated', 'rls-test-chk-a@example.com');
insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-d100-00000000000a', '00000000-0000-4000-d000-00000000000a', 'youtube', 'A 채널');
insert into public.projects (id, user_id, account_id, category_id, name, step_status)
select v.id, '00000000-0000-4000-d000-00000000000a', '00000000-0000-4000-d100-00000000000a', c.id, v.name, v.status::jsonb
from (values
  ('00000000-0000-4000-d200-00000000000a'::uuid, '대본 프로젝트',
   '{"1":"approved","2":"approved","3":"idle","4":"idle","5":"idle","6":"idle"}'),
  ('00000000-0000-4000-d200-00000000000b'::uuid, '소재 프로젝트',
   '{"1":"idle","2":"idle","3":"idle","4":"idle","5":"idle","6":"idle"}')
) as v(id, name, status)
cross join public.categories c
where c.name = '뷰티';

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-d000-00000000000a","role":"authenticated"}', true);

do $$
declare v_status jsonb;
begin
  begin
    perform public.mark_step_ready('00000000-0000-4000-d200-00000000000a', 3, 'ready');
    raise exception 'FAIL: 대본 없이 3단계 ready';
  exception when object_not_in_prerequisite_state then
    raise notice 'PASS 1 대본 없이 3단계 ready 거부';
  end;
  begin
    perform public.mark_step_ready('00000000-0000-4000-d200-00000000000b', 1, 'ready');
    raise exception 'FAIL: 선택 소재 없이 1단계 ready';
  exception when object_not_in_prerequisite_state then
    raise notice 'PASS 2 선택 소재 없이 1단계 ready 거부';
  end;
  v_status := public.mark_step_ready('00000000-0000-4000-d200-00000000000a', 3, 'suggested');
  if v_status ->> '3' <> 'suggested' then raise exception 'FAIL: suggested 전이 실패'; end if;
  raise notice 'PASS 3 산출물 없이 suggested 허용';
end $$;

-- 선택 소재(서버 생성 → 소유자 권한으로 준비)
reset role;
insert into public.topics (project_id, name, picked)
values ('00000000-0000-4000-d200-00000000000b', '메이크업 브러시 클리너', true);
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-d000-00000000000a","role":"authenticated"}', true);

do $$
declare v_status jsonb; v_approved timestamptz;
begin
  v_status := public.mark_step_ready('00000000-0000-4000-d200-00000000000b', 1, 'ready');
  if v_status ->> '1' <> 'ready' then raise exception 'FAIL: 선택 소재 있는데 ready 실패'; end if;
  raise notice 'PASS 4 선택 소재 있으면 1단계 ready 허용';

  -- REST(사용자 세션)로 금지 표현 대본을 직접 저장
  insert into public.scripts (project_id, version, lines)
  values ('00000000-0000-4000-d200-00000000000a', 1, '["이걸로 피부 재생 효과를 보세요"]');
  v_status := public.mark_step_ready('00000000-0000-4000-d200-00000000000a', 3, 'ready');
  if v_status ->> '3' <> 'ready' then raise exception 'FAIL: 대본 있는데 ready 실패'; end if;
  raise notice 'PASS 5 대본 있으면 3단계 ready 허용';

  begin
    perform public.approve_step('00000000-0000-4000-d200-00000000000a', 3);
    raise exception 'FAIL: 금지 표현 대본 승인됨';
  exception when sqlstate 'BT001' then
    raise notice 'PASS 6 금지 표현(피부 재생) 대본 승인 거부 BT001';
  end;

  insert into public.scripts (project_id, version, lines)
  values ('00000000-0000-4000-d200-00000000000a', 2,
          jsonb_build_array('효과 좋은 ' || '피' || chr(8203) || '부' || chr(65279) || ' ' || chr(8288) || '재생 크림'));
  begin
    perform public.approve_step('00000000-0000-4000-d200-00000000000a', 3);
    raise exception 'FAIL: 제로폭 변형 금지 표현 대본 승인됨';
  exception when sqlstate 'BT001' then
    raise notice 'PASS 7 제로폭·공백 변형(피​부﻿ ⁠재생) 승인 거부';
  end;

  insert into public.scripts (project_id, version, lines)
  values ('00000000-0000-4000-d200-00000000000a', 3, '["오늘은 피부", "재생 루틴"]');
  begin
    perform public.approve_step('00000000-0000-4000-d200-00000000000a', 3);
    raise exception 'FAIL: 줄을 나눈 금지 표현 대본 승인됨';
  exception when sqlstate 'BT001' then
    raise notice 'PASS 8 줄을 나눈 금지 표현 승인 거부';
  end;

  select approved_at into v_approved from public.scripts
  where project_id = '00000000-0000-4000-d200-00000000000a' and approved_at is not null;
  select step_status into v_status from public.projects where id = '00000000-0000-4000-d200-00000000000a';
  if v_approved is not null or v_status ->> '3' <> 'ready' then
    raise exception 'FAIL: 거부됐는데 승인 흔적 남음';
  end if;
  raise notice 'PASS 9 거부 시 approved_at·step_status 변화 없음';

  insert into public.scripts (project_id, version, lines)
  values ('00000000-0000-4000-d200-00000000000a', 4, '["브러시를 30초 만에 세척하는 방법", "물기만 털면 끝"]');
  v_status := public.approve_step('00000000-0000-4000-d200-00000000000a', 3);
  select approved_at into v_approved from public.scripts
  where project_id = '00000000-0000-4000-d200-00000000000a' and version = 4;
  if v_status ->> '3' <> 'approved' or v_approved is null then
    raise exception 'FAIL: 정상 대본 승인 실패 %', v_status;
  end if;
  raise notice 'PASS 10 금지 표현 없는 최신 대본 정상 승인';
end $$;

rollback;
