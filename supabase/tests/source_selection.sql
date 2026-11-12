-- task-017 02 소스 승인 규칙·사용 선택·편집 입력(20261112210000) 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/source_selection.sql
-- 한 트랜잭션으로 돌리고 ROLLBACK 한다(테스트 사용자 src-test-* 는 남지 않는다).
-- 프로젝트: P2(2편) · P3(3편 사유 없음→있음) · P5(5편) · PN(출처 표기 + 고지 미확인) · PB(다른 사용자)
begin;

insert into auth.users (id, aud, role, email) values
  ('00000000-0000-4000-e017-00000000000a', 'authenticated', 'authenticated', 'src-test-a@example.com'),
  ('00000000-0000-4000-e017-00000000000b', 'authenticated', 'authenticated', 'src-test-b@example.com');
insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-e017-00000000010a', '00000000-0000-4000-e017-00000000000a', 'youtube', 'src-a'),
  ('00000000-0000-4000-e017-00000000010b', '00000000-0000-4000-e017-00000000000b', 'youtube', 'src-b');
insert into public.projects (id, user_id, account_id, name, step_status)
select v.id, v.uid, v.acc, v.name,
       '{"1":"approved","2":"idle","3":"idle","4":"idle","5":"idle","6":"idle"}'::jsonb
from (values
  ('00000000-0000-4000-e017-000000000202'::uuid, '00000000-0000-4000-e017-00000000000a'::uuid,
   '00000000-0000-4000-e017-00000000010a'::uuid, 'P2'),
  ('00000000-0000-4000-e017-000000000203', '00000000-0000-4000-e017-00000000000a',
   '00000000-0000-4000-e017-00000000010a', 'P3'),
  ('00000000-0000-4000-e017-000000000205', '00000000-0000-4000-e017-00000000000a',
   '00000000-0000-4000-e017-00000000010a', 'P5'),
  ('00000000-0000-4000-e017-00000000020e', '00000000-0000-4000-e017-00000000000a',
   '00000000-0000-4000-e017-00000000010a', 'PN'),
  ('00000000-0000-4000-e017-00000000020b', '00000000-0000-4000-e017-00000000000b',
   '00000000-0000-4000-e017-00000000010b', 'PB')
) as v(id, uid, acc, name);

-- 프로젝트마다 내려받은 원본 6편(…3<p><n>) + 목록만 1편(…3<p>9)
insert into public.sources (id, project_id, platform, url, author, file_path, score)
select ('00000000-0000-4000-e017-000000003' || p.tag || n)::uuid, p.id,
       case when n = 6 then 'direct' else 'tiktok' end,
       'https://www.tiktok.com/@a/video/' || p.tag || n, 'author' || n,
       case when n = 9 then null else 'u/' || p.tag || n || '.mp4' end, 100 - n
from (values ('02', '00000000-0000-4000-e017-000000000202'::uuid),
             ('03', '00000000-0000-4000-e017-000000000203'),
             ('05', '00000000-0000-4000-e017-000000000205'),
             ('0e', '00000000-0000-4000-e017-00000000020e'),
             ('0b', '00000000-0000-4000-e017-00000000020b')) as p(tag, id)
cross join (values (1), (2), (3), (4), (5), (6), (9)) as s(n);

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-e017-00000000000a","role":"authenticated"}', true);

-- 사용 목록 jsonb 만들기: tag 프로젝트의 1..k 번 원본, 권리 근거 basis
create function pg_temp.uses(tag text, k int, basis text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', '00000000-0000-4000-e017-000000003' || tag || n, 'rights_basis', basis)), '[]'::jsonb)
  from generate_series(1, k) n;
$$;

do $$
declare v jsonb; n int; r record;
begin
  -- 직접 테이블 쓰기 불가(권리 열·used 는 함수 전용)
  begin
    update public.sources set used = true where project_id = '00000000-0000-4000-e017-000000000202';
    raise exception 'FAIL: sources 직접 수정';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.projects set sources_notice_ack_at = now() where id = '00000000-0000-4000-e017-000000000202';
    raise exception 'FAIL: 고지 확인 열 직접 수정';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS 1 권리·사용·고지 열 직접 쓰기 거부';

  -- 다른 사용자 프로젝트 거부
  begin
    perform public.save_source_use('00000000-0000-4000-e017-00000000020b', pg_temp.uses('0b', 5, 'own'), true, null);
    raise exception 'FAIL: 다른 사용자 프로젝트 저장';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS 2 다른 사용자 프로젝트 거부';

  -- 다운로드 체크 11편 거부, 다른 프로젝트 원본 거부, 10편까지 허용
  begin
    perform public.set_source_checks('00000000-0000-4000-e017-000000000202',
      array_fill('00000000-0000-4000-e017-000000003021'::uuid, array[11]));
    raise exception 'FAIL: 11편 체크';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.set_source_checks('00000000-0000-4000-e017-000000000202',
      array['00000000-0000-4000-e017-000000003031']::uuid[]);
    raise exception 'FAIL: 다른 프로젝트 원본 체크';
  exception when invalid_parameter_value then null;
  end;
  n := public.set_source_checks('00000000-0000-4000-e017-000000000202',
    array['00000000-0000-4000-e017-000000003021', '00000000-0000-4000-e017-000000003029']::uuid[]);
  if n <> 2 then raise exception 'FAIL: 체크 수 %', n; end if;
  raise notice 'PASS 3 다운로드 체크 10편 상한·소유 검사';

  -- 목록만(파일 없음) 원본·권리 근거 없음은 사용 불가
  begin
    perform public.save_source_use('00000000-0000-4000-e017-000000000202',
      '[{"id":"00000000-0000-4000-e017-000000003029","rights_basis":"own"}]', true, null);
    raise exception 'FAIL: 내려받지 않은 원본 사용';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.save_source_use('00000000-0000-4000-e017-000000000202',
      '[{"id":"00000000-0000-4000-e017-000000003021","rights_basis":null}]', true, null);
    raise exception 'FAIL: 권리 근거 없는 사용';
  exception when invalid_parameter_value then null;
  end;
  raise notice 'PASS 4 목록만·권리 근거 없음 사용 거부';

  -- 2편: 저장해도 ready 가 되지 않고, ready 로 강제해도 승인 거부
  v := public.save_source_use('00000000-0000-4000-e017-000000000202', pg_temp.uses('02', 2, 'own'), true, '부족');
  if v->>'problem' <> 'too_few' or v->'status'->>'2' = 'ready' then raise exception 'FAIL: 2편 저장 %', v; end if;

  -- 3편 사유 없음: ready 아님
  v := public.save_source_use('00000000-0000-4000-e017-000000000203', pg_temp.uses('03', 3, 'own'), true, '  ');
  if v->>'problem' <> 'reason_required' or v->'status'->>'2' = 'ready' then raise exception 'FAIL: 3편 사유 없음 %', v; end if;

  -- 판매자 제공 5편이어도 고지 미확인이면 ready 아님(고지는 원본 종류와 관계없이 항상, 210100)
  v := public.save_source_use('00000000-0000-4000-e017-000000000205', pg_temp.uses('05', 5, 'seller'), false, null);
  if v->>'problem' <> 'notice_required' or v->'status'->>'2' = 'ready' then raise exception 'FAIL: 판매자 5편 고지 미확인 %', v; end if;
  -- 5편 + 고지 확인: 사유 없이 ready
  v := public.save_source_use('00000000-0000-4000-e017-000000000205', pg_temp.uses('05', 5, 'seller'), true, null);
  if v->>'problem' is not null or v->'status'->>'2' <> 'ready' then raise exception 'FAIL: 5편 %', v; end if;

  -- 출처 표기 5편 + 고지 미확인: ready 아님
  v := public.save_source_use('00000000-0000-4000-e017-00000000020e', pg_temp.uses('0e', 5, 'attribution_notice'), false, null);
  if v->>'problem' <> 'notice_required' or v->'status'->>'2' = 'ready' then raise exception 'FAIL: 고지 미확인 %', v; end if;
  raise notice 'PASS 5 저장 시 승인 조건으로 02 상태 재계산';

  -- 확인자·시각 기록
  select count(*) into n from public.sources
  where project_id = '00000000-0000-4000-e017-000000000205' and used
    and rights_confirmed_by = '00000000-0000-4000-e017-00000000000a' and rights_confirmed_at is not null;
  if n <> 5 then raise exception 'FAIL: 확인자 기록 %', n; end if;
  raise notice 'PASS 6 권리 근거 확인자·시각 기록';
end $$;

-- 규칙만 검사하도록 P2·P3·PN 을 ready 로 강제(서버 주체)
reset role;
update public.projects set step_status = jsonb_set(step_status, '{2}', '"ready"')
where id in ('00000000-0000-4000-e017-000000000202', '00000000-0000-4000-e017-000000000203',
             '00000000-0000-4000-e017-00000000020e');
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-e017-00000000000a","role":"authenticated"}', true);

do $$
declare v jsonb; msg text;
begin
  begin
    perform public.approve_step('00000000-0000-4000-e017-000000000202', 2);
    raise exception 'FAIL: 2편 승인';
  exception when object_not_in_prerequisite_state then
    get stacked diagnostics msg = message_text;
    if msg not like '%3편 미만%' then raise exception 'FAIL: 2편 거부 사유 %', msg; end if;
  end;
  raise notice 'PASS 7 2편 승인 거부';

  begin
    perform public.approve_step('00000000-0000-4000-e017-000000000203', 2);
    raise exception 'FAIL: 3편 사유 없음 승인';
  exception when object_not_in_prerequisite_state then
    get stacked diagnostics msg = message_text;
    if msg not like '%부족 사유%' then raise exception 'FAIL: 3편 거부 사유 %', msg; end if;
  end;
  raise notice 'PASS 8 3편 + 사유 없음 승인 거부';

  begin
    perform public.approve_step('00000000-0000-4000-e017-00000000020e', 2);
    raise exception 'FAIL: 고지 미확인 승인';
  exception when object_not_in_prerequisite_state then
    get stacked diagnostics msg = message_text;
    if msg not like '%고지%' then raise exception 'FAIL: 고지 거부 사유 %', msg; end if;
  end;
  raise notice 'PASS 9 출처 표기 원본 + 고지 미확인 승인 거부';

  -- 3편 + 사유: 저장하면 ready, 승인 허용, 사유는 채팅에도 남음
  v := public.save_source_use('00000000-0000-4000-e017-000000000203', pg_temp.uses('03', 3, 'own'), true, '같은 구조 영상이 3편뿐');
  if v->>'problem' is not null or v->'status'->>'2' <> 'ready' then raise exception 'FAIL: 3편 사유 저장 %', v; end if;
  v := public.approve_step('00000000-0000-4000-e017-000000000203', 2);
  if v->>'2' <> 'approved' then raise exception 'FAIL: 3편 + 사유 승인 %', v; end if;
  if not exists (select 1 from public.chat_messages
                 where project_id = '00000000-0000-4000-e017-000000000203' and text like '%같은 구조 영상이 3편뿐') then
    raise exception 'FAIL: 부족 사유 채팅 기록';
  end if;
  raise notice 'PASS 10 3편 + 사유 승인 허용';

  v := public.approve_step('00000000-0000-4000-e017-000000000205', 2);
  if v->>'2' <> 'approved' then raise exception 'FAIL: 5편 승인 %', v; end if;
  raise notice 'PASS 11 5편 승인 허용';

  -- 승인 뒤에는 사용 선택을 바꿀 수 없음
  begin
    perform public.save_source_use('00000000-0000-4000-e017-000000000205', '[]', false, null);
    raise exception 'FAIL: 승인 뒤 변경';
  exception when object_not_in_prerequisite_state then null;
  end;
  raise notice 'PASS 12 승인 뒤 사용 선택 변경 거부';

  -- 고지 확인하면 출처 표기 5편 승인
  v := public.save_source_use('00000000-0000-4000-e017-00000000020e', pg_temp.uses('0e', 5, 'attribution_notice'), true, null);
  if v->'status'->>'2' <> 'ready' then raise exception 'FAIL: 고지 확인 저장 %', v; end if;
  v := public.approve_step('00000000-0000-4000-e017-00000000020e', 2);
  if v->>'2' <> 'approved' then raise exception 'FAIL: 고지 확인 승인 %', v; end if;
  raise notice 'PASS 13 고지 확인 후 출처 표기 원본 승인';
end $$;

-- 편집 입력: 미확인 원본(권리 근거 없음)·목록만·고지 미확인 출처 표기 원본 제외
reset role;
-- PN 의 6번(direct)을 권리 근거 없이 used 로(서버 주체가 잘못 쓴 경우), P2 고지 해제 + 출처 표기 원본 1편
update public.sources set used = true where id = '00000000-0000-4000-e017-0000000030e6';
update public.sources set used = true, rights_basis = 'attribution_notice', rights_confirmed_at = now()
where id = '00000000-0000-4000-e017-000000003023';
update public.projects set sources_notice_ack_at = null, sources_notice_ack_by = null
where id = '00000000-0000-4000-e017-000000000202';
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-e017-00000000000a","role":"authenticated"}', true);

do $$
declare n int;
begin
  select count(*) into n from public.edit_input_sources('00000000-0000-4000-e017-00000000020e');
  if n <> 5 then raise exception 'FAIL: PN 편집 입력 % (미확인 원본 포함?)', n; end if;
  if exists (select 1 from public.edit_input_sources('00000000-0000-4000-e017-00000000020e')
             where id = '00000000-0000-4000-e017-0000000030e6') then
    raise exception 'FAIL: 미확인 원본이 편집 입력에 들어감';
  end if;
  -- P2: own 2편만, 고지 미확인 출처 표기 1편 제외
  select count(*) into n from public.edit_input_sources('00000000-0000-4000-e017-000000000202');
  if n <> 2 then raise exception 'FAIL: P2 편집 입력 %', n; end if;
  -- 다른 사용자 프로젝트는 RLS 로 0편
  select count(*) into n from public.edit_input_sources('00000000-0000-4000-e017-00000000020b');
  if n <> 0 then raise exception 'FAIL: 다른 사용자 편집 입력 %', n; end if;
  raise notice 'PASS 14 미확인 원본·고지 미확인 출처 표기 원본은 편집 입력에서 제외';
end $$;

-- 직접 추가
do $$
declare v_id uuid; v_platform text;
begin
  begin
    perform public.add_direct_source('00000000-0000-4000-e017-000000000202', 'https://example.com/v/1', '  ', null);
    raise exception 'FAIL: 작성자 없이 추가';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.add_direct_source('00000000-0000-4000-e017-000000000202', 'javascript:alert(1)', 'me', null);
    raise exception 'FAIL: http 아닌 URL 추가';
  exception when invalid_parameter_value then null;
  end;
  v_id := public.add_direct_source('00000000-0000-4000-e017-000000000202',
    'https://www.xiaohongshu.com/explore/abc', '판매자', '제품 시연');
  select platform into v_platform from public.sources where id = v_id;
  if v_platform <> 'xiaohongshu' then raise exception 'FAIL: 플랫폼 판별 %', v_platform; end if;
  if exists (select 1 from public.sources where id = v_id and (rights_basis is not null or used or checked)) then
    raise exception 'FAIL: 직접 추가 원본에 권리·체크 기본값';
  end if;
  begin
    perform public.add_direct_source('00000000-0000-4000-e017-000000000202',
      'https://www.xiaohongshu.com/explore/abc', '판매자', null);
    raise exception 'FAIL: 같은 URL 중복 추가';
  exception when unique_violation then null;
  end;
  raise notice 'PASS 15 직접 추가 URL·작성자 필수·플랫폼 판별·중복 거부';

  -- userinfo(@) 위장 URL 거부, 작성자·제목 제어 문자·양방향 제어 문자 거부(210200)
  foreach v_platform in array array['https://www.tiktok.com@evil.example/v', 'https://user:pw@example.com/v',
                                     'https://exa mple.com/v'] loop
    begin
      perform public.add_direct_source('00000000-0000-4000-e017-000000000202', v_platform, 'me', null);
      raise exception 'FAIL: 위장 URL 추가 %', v_platform;
    exception when invalid_parameter_value then null;
    end;
  end loop;
  foreach v_platform in array array['evil' || chr(8238) || 'gpj', 'line' || chr(10) || 'break', 'iso' || chr(8294) || 'x'] loop
    begin
      perform public.add_direct_source('00000000-0000-4000-e017-000000000202', 'https://example.com/a1', v_platform, null);
      raise exception 'FAIL: 제어 문자 작성자 %', v_platform;
    exception when invalid_parameter_value then null;
    end;
    begin
      perform public.add_direct_source('00000000-0000-4000-e017-000000000202', 'https://example.com/a2', 'me', v_platform);
      raise exception 'FAIL: 제어 문자 제목 %', v_platform;
    exception when invalid_parameter_value then null;
    end;
  end loop;
  v_id := public.add_direct_source('00000000-0000-4000-e017-000000000202', 'https://m.tiktok.com:443/v/9', '@seller', null);
  select platform into v_platform from public.sources where id = v_id;
  if v_platform <> 'tiktok' then raise exception 'FAIL: 호스트 판별 %', v_platform; end if;
  raise notice 'PASS 17 userinfo 위장 URL·제어 문자 거부, 호스트로 플랫폼 판별';
end $$;

-- 격리 원본(워커가 형식 위장으로 거부): 사용·편집 입력 제외, 직접 수정 불가
reset role;
update public.projects set step_status = jsonb_set(step_status, '{2}', '"suggested"')
where id = '00000000-0000-4000-e017-000000000202';
insert into public.jobs (id, project_id, step, type, status, idempotency_key) values
  ('00000000-0000-4000-e017-000000000401', '00000000-0000-4000-e017-000000000202', 2, 'select_sources', 'running', 'src-test-q1');
select private.save_source_scores('00000000-0000-4000-e017-000000000401',
  '[{"id":"00000000-0000-4000-e017-000000003024","score":null,"rank":null,"exclude_reason":"확장자와 실제 형식이 다름"},
    {"id":"00000000-0000-4000-e017-000000003025","score":40,"rank":21,"exclude_reason":"일치도 순위 20위 밖"}]');
do $$
begin
  if not (select quarantined from public.sources where id = '00000000-0000-4000-e017-000000003024') then
    raise exception 'FAIL: 형식 위장 원본 격리 안 됨';
  end if;
  if (select quarantined from public.sources where id = '00000000-0000-4000-e017-000000003025') then
    raise exception 'FAIL: 순위 밖 원본이 격리됨';
  end if;
end $$;
-- 이미 사용 중인 원본이 격리되면 편집 입력에서 빠진다
update public.sources set used = true, rights_basis = 'own', rights_confirmed_at = now()
where id = '00000000-0000-4000-e017-000000003024';
set local role service_role;
do $$
begin
  begin
    update public.sources set quarantined = false where id = '00000000-0000-4000-e017-000000003024';
    raise exception 'FAIL: service_role 격리 해제';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.edit_input_sources('00000000-0000-4000-e017-000000000202');
    raise exception 'FAIL: service_role edit_input_sources 실행';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-e017-00000000000a","role":"authenticated"}', true);
do $$
begin
  if exists (select 1 from public.edit_input_sources('00000000-0000-4000-e017-000000000202')
             where id = '00000000-0000-4000-e017-000000003024') then
    raise exception 'FAIL: 격리 원본이 편집 입력에 들어감';
  end if;
  begin
    perform public.save_source_use('00000000-0000-4000-e017-000000000202',
      '[{"id":"00000000-0000-4000-e017-000000003024","rights_basis":"own"}]', true, null);
    raise exception 'FAIL: 격리 원본 사용 저장';
  exception when invalid_parameter_value then null;
  end;
  raise notice 'PASS 18 격리 원본(순위 밖과 구분) 사용·편집 입력 제외, 직접 해제·service_role 실행 거부';
end $$;

-- anon 은 래퍼 실행 불가
reset role;
set local role anon;
do $$
begin
  begin
    perform public.save_source_use('00000000-0000-4000-e017-000000000202', '[]', true, null);
    raise exception 'FAIL: anon 실행';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS 16 anon 실행 거부';
end $$;

rollback;
