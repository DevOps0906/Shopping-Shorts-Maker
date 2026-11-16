-- task-023: 06 발행 — 제휴 링크·링크인바이오 번호·정책 점검 6항목·발행 준비 저장
-- 근거: docs/planning.md 3장 06 · 15-1 · 15-4 · 16-3 · 16-4, docs/05_DATA_MODEL.md 1절(SECURITY DEFINER 조건) · affiliate_links · publications · policy_checks · bio_items
-- - 정책 점검 6항목(15-4 정본, 항목 추가·삭제 없음)은 private.publish_policy 가 판정한다. 자동 항목은 DB 값으로,
--   사용자 체크 항목(출처 표기·고지 확인 / 구매 경로의 링크인바이오 등록 완료)은 confirm_policy_check 로만 checked_by·checked_at 기록.
-- - 발행 준비 저장(prepare_publication)은 6/6 통과를 DB가 다시 확인한 뒤에만 publications 행(mode·scheduled_at 포함, 함수 전용)을 만든다.
--   실제 업로드는 task-024. 이 함수는 projects.status 를 awaiting_publish(발행 대기)로 바꾸는 데까지.
-- - 설명란은 DB가 고정 순서로 만든다: 고지 → 구매 안내 → 본문(+ 출처 문구 = private.render_credits_text) → 해시태그.
-- - 링크인바이오 번호(16-4): 채널(account)마다 1번부터, 재사용 없음. 계정 행을 잠가 번호가 겹치지 않게 한다.
-- - affiliate_links.url·short_url 은 기존대로 서버(SR)만 쓴다. 이 마이그레이션은 그 규칙을 바꾸지 않는다.
-- - 호출 경로: public SECURITY INVOKER 래퍼 → private SECURITY DEFINER 본체, authenticated 에만 EXECUTE(anon 없음).

-- ── 스키마 보강 ─────────────────────────────────────────────
-- 링크인바이오 서비스에 링크트리 추가(docs/design.md 5-7 · planning 16-3)
alter table public.affiliate_links drop constraint affiliate_links_bio_service_check;
alter table public.affiliate_links add constraint affiliate_links_bio_service_check
  check (bio_service in ('inpock', 'litly', 'linktree'));
alter table public.bio_pages drop constraint bio_pages_service_check;
alter table public.bio_pages add constraint bio_pages_service_check
  check (service in ('inpock', 'litly', 'linktree'));

-- 프로젝트당 제휴 링크 1개(06 발행 카드 1개)
alter table public.affiliate_links add constraint affiliate_links_project_id_key unique (project_id);
-- 같은 링크인바이오 페이지 안 번호 중복 금지, 프로젝트당 번호 1개
alter table public.bio_items add constraint bio_items_bio_page_id_no_key unique (bio_page_id, no);
create unique index bio_items_project_id_key on public.bio_items (project_id) where project_id is not null;
-- 링크인바이오 1개 = 채널 1개(16-4)
alter table public.bio_pages add constraint bio_pages_account_id_key unique (account_id);

-- 발행 문구(함수 전용: authenticated 에는 SELECT 만 있다)
alter table public.publications
  add column title text check (char_length(title) between 1 and 100),
  add column description text check (char_length(description) <= 5000),
  add column hashtags text[] not null default '{}',
  add column pin_comment boolean not null default false,
  add column prepared_at timestamptz;
comment on column public.publications.description is '설명란(고지 → 구매 안내 → 본문 → 출처 → 해시태그). prepare_publication 이 DB 값으로 만든다';

-- ── 문구 규칙(TS 미러: apps/web/src/lib/publish/rules.ts) ──────
create function private.publish_is_link_program(p_program text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(p_program, 'none') not in ('none', 'youtube_shopping');
$$;
revoke execute on function private.publish_is_link_program(text) from public, anon, authenticated;

-- 제휴 고지 문구(15-1). 제휴를 쓰지 않거나 고지가 꺼져 있으면 빈 문자열
create function private.publish_disclosure_text(p_program text, p_disclosed boolean)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when not coalesce(p_disclosed, false) or coalesce(p_program, 'none') = 'none' then ''
    when p_program = 'coupang_partners' then '이 영상은 쿠팡 파트너스 활동의 일환으로, 이에 따른 일정액의 수수료를 제공받습니다.'
    when p_program = 'youtube_shopping' then '이 영상에는 유튜브 쇼핑 제휴 상품 태그가 있으며, 구매 시 일정액의 수수료를 제공받습니다.'
    else '이 영상은 ' || case p_program
                          when 'naver_shopping_connect' then '네이버 쇼핑 커넥트'
                          when 'ohouse_curator' then '오늘의집 큐레이터'
                          when 'musinsa_curator' then '무신사 큐레이터'
                          when 'oliveyoung_curator' then '올리브영 쇼핑 큐레이터'
                          when 'aliexpress' then '알리익스프레스 어필리에이트'
                          else p_program end
         || ' 활동으로 일정액의 수수료를 제공받습니다.'
  end;
$$;
revoke execute on function private.publish_disclosure_text(text, boolean) from public, anon, authenticated;

-- 구매 안내(16-3 6번): 링크형 제휴 = "구매 정보: 프로필 링크 N번", 유튜브 쇼핑 = 상품 태그 안내
create function private.publish_purchase_text(p_program text, p_bio_no integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_program = 'youtube_shopping' then '구매 정보: 영상 왼쪽 아래 상품 태그'
    when private.publish_is_link_program(p_program) and p_bio_no is not null then '구매 정보: 프로필 링크 ' || p_bio_no || '번'
    else ''
  end;
$$;
revoke execute on function private.publish_purchase_text(text, integer) from public, anon, authenticated;

-- 설명란: 고지 → 구매 안내 → 본문 → 출처 문구 → 해시태그(빈 블록은 건너뛰고 빈 줄 하나로 잇는다)
create function private.publish_description(p_disclosure text, p_purchase text, p_body text, p_credits text, p_hashtags text[])
returns text
language sql
immutable
set search_path = ''
as $$
  select array_to_string(array_remove(array[
    nullif(btrim(coalesce(p_disclosure, '')), ''),
    nullif(btrim(coalesce(p_purchase, '')), ''),
    nullif(btrim(coalesce(p_body, '')), ''),
    nullif(btrim(coalesce(p_credits, '')), ''),
    nullif((select string_agg('#' || t, ' ' order by o) from unnest(coalesce(p_hashtags, '{}')) with ordinality u(t, o)), '')
  ], null), E'\n\n');
$$;
revoke execute on function private.publish_description(text, text, text, text, text[]) from public, anon, authenticated;

-- 해시태그 정리: 앞의 # 와 공백 제거, 빈 값·중복 제거, 순서 유지
create function private.publish_clean_hashtags(p_hashtags text[])
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(array_agg(t order by first_o), '{}')
  from (
    select t, min(o) as first_o
    from (select btrim(ltrim(btrim(x), '#')) as t, o
          from unnest(coalesce(p_hashtags, '{}')) with ordinality u(x, o)) c
    where t <> ''
    group by t
  ) d;
$$;
revoke execute on function private.publish_clean_hashtags(text[]) from public, anon, authenticated;

-- 15-4 공통 금지어 + 카테고리 금지어(11장). 제목·설명 본문·해시태그·승인 대본을 이어 붙여 검사, 첫 금지어(원문)를 돌려준다
create function private.publish_banned_term(p_project_id uuid, p_texts text[])
returns text
language sql
stable
set search_path = ''
as $$
  with body as (
    select private.normalize_for_ban(
             coalesce(array_to_string(p_texts, ''), '')
             || coalesce((select string_agg(l.line, '' order by l.ord)
                          from public.scripts s
                          cross join lateral jsonb_array_elements_text(s.lines) with ordinality as l(line, ord)
                          where s.id = (select s2.id from public.scripts s2
                                        where s2.project_id = p_project_id and s2.approved_at is not null
                                        order by s2.version desc limit 1)), '')) as text
  ),
  terms as (
    select unnest(array['최고', '완벽', '100%', '무조건', '기적', '치료']) as term
    union all
    select t.term
    from public.projects p
    join public.categories c on c.id = p.category_id
    cross join lateral unnest(c.banned_terms) as t(term)
    where p.id = p_project_id
  )
  select terms.term
  from terms cross join body
  where private.normalize_for_ban(terms.term) <> ''
    and strpos(body.text, private.normalize_for_ban(terms.term)) > 0
  limit 1;
$$;
revoke execute on function private.publish_banned_term(uuid, text[]) from public, anon, authenticated;

-- ── 정책 점검 판정(15-4) ───────────────────────────────────
-- 호출자 소유 검사는 부르는 쪽(공개 래퍼의 본체)이 한다. 결과를 policy_checks 에 기록하고 화면용 묶음을 돌려준다.
create function private.publish_evaluate(p_project_id uuid, p_title text, p_body text, p_hashtags text[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status jsonb;
  v_ack timestamptz;
  v_platform text;
  v_cuts jsonb;
  v_render_ok boolean := false;
  v_link public.affiliate_links;
  v_has_link boolean;
  v_link_program boolean;
  v_banned text;
  v_credits text := '';
  v_attr_checked timestamptz;
  v_path_checked timestamptz;
  v_results jsonb := '[]'::jsonb;
  v_item text;
  v_result text;
  v_detail text;
  v_passed integer := 0;
  v_tags text[] := private.publish_clean_hashtags(p_hashtags);
begin
  select p.step_status, p.sources_notice_ack_at, a.platform
    into v_status, v_ack, v_platform
  from public.projects p
  join public.accounts a on a.id = p.account_id
  where p.id = p_project_id;

  select r.cut_map -> 'cuts', r.mp4_path is not null
    into v_cuts, v_render_ok
  from public.renders r
  where r.project_id = p_project_id
  order by r.version desc
  limit 1;
  v_render_ok := coalesce(v_render_ok, false);
  if jsonb_typeof(v_cuts) = 'array' then
    v_credits := private.render_credits_text(v_cuts);
  else
    v_cuts := '[]'::jsonb;
  end if;

  select * into v_link from public.affiliate_links where project_id = p_project_id;
  v_has_link := v_link.id is not null and v_link.program <> 'none';
  v_link_program := v_has_link and private.publish_is_link_program(v_link.program);

  select checked_at into v_attr_checked from public.policy_checks
  where project_id = p_project_id and item = 'attribution_notice' and checked_by is not null;
  select checked_at into v_path_checked from public.policy_checks
  where project_id = p_project_id and item = 'purchase_path' and checked_by is not null;

  v_banned := private.publish_banned_term(p_project_id,
                array[coalesce(p_title, ''), coalesce(p_body, ''), array_to_string(v_tags, '')]);

  foreach v_item in array array['source_record', 'attribution_notice', 'original_elements',
                                'banned_terms', 'affiliate_disclosure', 'purchase_path'] loop
    case v_item
      when 'source_record' then
        if jsonb_array_length(v_cuts) > 0 and not exists (
             select 1 from jsonb_array_elements(v_cuts) c
             where coalesce(btrim(c ->> 'source_url'), '') = ''
                or coalesce(btrim(c ->> 'author'), '') = ''
                or coalesce(c ->> 'collected_at', '') = '') then
          v_result := 'pass'; v_detail := '쓴 원본 ' || (select count(distinct c ->> 'source_id') from jsonb_array_elements(v_cuts) c) || '편의 URL·작성자·수집 시각이 기록되어 있습니다';
        else
          v_result := 'fail'; v_detail := '최신 검토본의 컷 원본 기록(URL·작성자·수집 시각)이 없습니다. 05 편집에서 MP4를 다시 만들어 주세요';
        end if;
      when 'attribution_notice' then
        if v_ack is null then
          v_result := 'fail'; v_detail := '02 소스의 출처 표기 고지를 먼저 확인해 주세요';
        elsif v_attr_checked is null then
          v_result := 'pending'; v_detail := '영상과 설명란에 출처가 들어갔는지 확인하고 체크해 주세요';
        else
          v_result := 'pass'; v_detail := '사용자가 확인했습니다';
        end if;
      when 'original_elements' then
        if v_status ->> '5' = 'approved' and v_render_ok then
          v_result := 'pass'; v_detail := '대본·AI 음성·자막·컷 구성을 새로 만들었습니다(05 편집 승인)';
        else
          v_result := 'fail'; v_detail := '05 편집을 승인해야 통과합니다';
        end if;
      when 'banned_terms' then
        if v_banned is null then
          v_result := 'pass'; v_detail := '제목·설명·해시태그·대본에 금지·과장 표현이 없습니다';
        else
          v_result := 'fail'; v_detail := '금지·과장 표현 "' || v_banned || '"을(를) 고쳐 주세요';
        end if;
      when 'affiliate_disclosure' then
        if not v_has_link then
          v_result := 'pass'; v_detail := '제휴 링크를 쓰지 않습니다';
        elsif v_link.disclosed then
          v_result := 'pass'; v_detail := '고지 문구가 설명란 첫머리에 들어갑니다';
        else
          v_result := 'fail'; v_detail := '제휴 링크가 있으면 고지 문구를 켜야 합니다';
        end if;
      when 'purchase_path' then
        if not v_has_link then
          v_result := 'pass'; v_detail := '제휴를 쓰지 않습니다';
        elsif v_link.program = 'youtube_shopping' then
          if v_platform = 'youtube' then
            v_result := 'pass'; v_detail := 'YouTube 채널의 상품 태그로 연결합니다';
          else
            v_result := 'fail'; v_detail := '유튜브 쇼핑 상품 태그는 YouTube 채널에서만 쓸 수 있습니다';
          end if;
        elsif v_link.url is null then
          v_result := 'fail'; v_detail := '상품 제휴 링크를 입력해 주세요';
        elsif v_link.bio_no is null then
          v_result := 'fail'; v_detail := '링크인바이오 서비스를 골라 번호를 받아 주세요';
        elsif v_link.bio_registered_at is null or v_path_checked is null then
          v_result := 'pending'; v_detail := '링크인바이오에 ' || v_link.bio_no || '번 항목을 등록한 뒤 등록 완료를 켜 주세요';
        else
          v_result := 'pass'; v_detail := '링크인바이오 ' || v_link.bio_no || '번 등록을 확인했습니다';
        end if;
    end case;

    if v_result = 'pass' then
      v_passed := v_passed + 1;
    end if;
    insert into public.policy_checks (project_id, item, result, detail)
    values (p_project_id, v_item, v_result, v_detail)
    on conflict (project_id, item) do update set result = excluded.result, detail = excluded.detail;

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'item', v_item, 'result', v_result, 'detail', v_detail,
      'checked_at', case v_item when 'attribution_notice' then v_attr_checked
                                when 'purchase_path' then v_path_checked end));
  end loop;

  return jsonb_build_object(
    'items', v_results,
    'passed', v_passed,
    'total', 6,
    'credits', v_credits,
    'disclosure', private.publish_disclosure_text(v_link.program, v_link.disclosed),
    'purchase', private.publish_purchase_text(v_link.program, v_link.bio_no));
end;
$$;
revoke execute on function private.publish_evaluate(uuid, text, text, text[]) from public, anon, authenticated;

-- 소유자 확인 공통(없으면 42501)
create function private.publish_owned(p_project_id uuid, p_lock boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  if p_lock then
    perform 1 from public.projects where id = p_project_id and user_id = auth.uid() for update;
  else
    perform 1 from public.projects where id = p_project_id and user_id = auth.uid();
  end if;
  if not found then
    raise exception '프로젝트를 찾을 수 없거나 권한이 없습니다' using errcode = '42501';
  end if;
end;
$$;
revoke execute on function private.publish_owned(uuid, boolean) from public, anon, authenticated;

-- 화면 진입·변경 뒤 점검 다시 하기
create function private.publish_policy(p_project_id uuid, p_title text, p_body text, p_hashtags text[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.publish_owned(p_project_id, false);
  return private.publish_evaluate(p_project_id, p_title, p_body, p_hashtags);
end;
$$;

-- 사용자 체크(출처 표기·고지 확인 / 구매 경로 = 링크인바이오 등록 완료). 사용자가 누른 요청만 이 함수를 부른다
create function private.confirm_policy_check(p_project_id uuid, p_item text, p_checked boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link public.affiliate_links;
  v_ack timestamptz;
  v_on boolean := coalesce(p_checked, false);
begin
  perform private.publish_owned(p_project_id, true);
  if p_item is null or p_item not in ('attribution_notice', 'purchase_path') then
    raise exception '사용자가 확인하는 항목이 아닙니다: %', p_item using errcode = '22023';
  end if;

  if v_on and p_item = 'attribution_notice' then
    select sources_notice_ack_at into v_ack from public.projects where id = p_project_id;
    if v_ack is null then
      raise exception '02 소스의 출처 표기 고지를 먼저 확인해 주세요' using errcode = '55000';
    end if;
  end if;

  if p_item = 'purchase_path' then
    select * into v_link from public.affiliate_links where project_id = p_project_id;
    if v_on and (v_link.id is null or not private.publish_is_link_program(v_link.program)
                 or v_link.url is null or v_link.bio_no is null) then
      raise exception '링크인바이오 번호를 받은 제휴 링크가 있어야 등록 완료를 켤 수 있습니다' using errcode = '55000';
    end if;
    if v_link.id is not null then
      update public.affiliate_links
      set bio_registered_at = case when v_on then coalesce(bio_registered_at, now()) end
      where id = v_link.id;
      update public.bio_items
      set registered_at = case when v_on then coalesce(registered_at, now()) end
      where project_id = p_project_id;
    end if;
  end if;

  insert into public.policy_checks (project_id, item, checked_by, checked_at)
  values (p_project_id, p_item, case when v_on then auth.uid() end, case when v_on then now() end)
  on conflict (project_id, item) do update
    set checked_by = excluded.checked_by, checked_at = excluded.checked_at;
end;
$$;

-- 링크인바이오 번호 받기(16-4): 채널마다 1번부터 올라가고 다시 쓰지 않는다. 이미 받은 프로젝트는 같은 번호를 돌려준다
create function private.assign_bio_number(p_project_id uuid, p_service text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid;
  v_name text;
  v_link public.affiliate_links;
  v_page uuid;
  v_no integer;
begin
  perform private.publish_owned(p_project_id, true);
  if p_service is null or p_service not in ('inpock', 'litly', 'linktree') then
    raise exception '링크인바이오 서비스가 올바르지 않습니다' using errcode = '22023';
  end if;
  select * into v_link from public.affiliate_links where project_id = p_project_id;
  if v_link.id is null or not private.publish_is_link_program(v_link.program) then
    raise exception '링크형 제휴 프로그램을 먼저 골라 주세요' using errcode = '55000';
  end if;

  select account_id, name into v_account, v_name from public.projects where id = p_project_id;
  -- 같은 채널의 번호 발급을 한 줄로 세운다
  perform 1 from public.accounts where id = v_account for update;

  insert into public.bio_pages (account_id, service) values (v_account, p_service)
  on conflict (account_id) do update set service = excluded.service
  returning id into v_page;

  select no into v_no from public.bio_items where project_id = p_project_id;
  if v_no is null then
    select coalesce(max(bi.no), 0) + 1 into v_no
    from public.bio_items bi
    join public.bio_pages bp on bp.id = bi.bio_page_id
    where bp.account_id = v_account;
    insert into public.bio_items (bio_page_id, project_id, no, affiliate_link_id, short_url, title)
    values (v_page, p_project_id, v_no, v_link.id, v_link.short_url, v_name);
  end if;

  update public.affiliate_links set bio_service = p_service, bio_no = v_no where id = v_link.id;
  return v_no;
end;
$$;

-- 발행 준비 저장: 6/6 통과를 DB가 다시 확인한 뒤 publications(함수 전용 열) 생성·갱신, projects.status = awaiting_publish
create function private.prepare_publication(
  p_project_id uuid, p_mode text, p_scheduled_at timestamptz, p_title text, p_body text,
  p_hashtags text[], p_purchase_guide boolean, p_pin_comment boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status jsonb;
  v_account uuid;
  v_policy jsonb;
  v_tags text[] := private.publish_clean_hashtags(p_hashtags);
  v_title text := btrim(coalesce(p_title, ''));
  v_existing text;
  v_description text;
  v_row public.publications;
begin
  perform private.publish_owned(p_project_id, true);
  select step_status, account_id into v_status, v_account from public.projects where id = p_project_id;
  if v_status ->> '5' <> 'approved' then
    raise exception '05 편집을 먼저 승인해 주세요' using errcode = '55000';
  end if;
  if p_mode is null or p_mode not in ('scheduled', 'now') then
    raise exception '발행 방식이 올바르지 않습니다' using errcode = '22023';
  end if;
  if p_mode = 'scheduled' and (p_scheduled_at is null or p_scheduled_at <= now()) then
    raise exception '예약 시각은 지금보다 뒤여야 합니다' using errcode = '22023';
  end if;
  if char_length(v_title) not between 1 and 100 then
    raise exception '제목은 1~100자여야 합니다' using errcode = '22023';
  end if;
  if char_length(coalesce(p_body, '')) > 4000 or cardinality(v_tags) > 15
     or exists (select 1 from unnest(v_tags) t where t !~ '^[^[:space:]#]{1,30}$') then
    raise exception '설명·해시태그 형식이 올바르지 않습니다' using errcode = '22023';
  end if;

  select status into v_existing from public.publications where project_id = p_project_id;
  if v_existing is not null and v_existing <> 'pending' then
    raise exception '이미 예약·업로드가 시작된 발행입니다' using errcode = '55000';
  end if;

  v_policy := private.publish_evaluate(p_project_id, v_title, p_body, v_tags);
  if (v_policy ->> 'passed')::int <> 6 then
    raise exception '정책 점검 6개 항목을 모두 통과해야 발행할 수 있습니다' using errcode = 'PC001';
  end if;

  v_description := private.publish_description(
    v_policy ->> 'disclosure',
    case when coalesce(p_purchase_guide, true) then v_policy ->> 'purchase' else '' end,
    p_body, v_policy ->> 'credits', v_tags);

  insert into public.publications (project_id, account_id, mode, scheduled_at, title, description, hashtags,
                                   pin_comment, prepared_at, status)
  values (p_project_id, v_account, p_mode, case when p_mode = 'scheduled' then p_scheduled_at end, v_title,
          v_description, v_tags, coalesce(p_pin_comment, false), now(), 'pending')
  on conflict (project_id) do update
    set mode = excluded.mode, scheduled_at = excluded.scheduled_at, title = excluded.title,
        description = excluded.description, hashtags = excluded.hashtags, pin_comment = excluded.pin_comment,
        prepared_at = excluded.prepared_at
  returning * into v_row;

  update public.projects set status = 'awaiting_publish' where id = p_project_id;

  return jsonb_build_object('id', v_row.id, 'mode', v_row.mode, 'scheduled_at', v_row.scheduled_at,
                            'title', v_row.title, 'description', v_row.description,
                            'prepared_at', v_row.prepared_at, 'status', v_row.status);
end;
$$;

revoke execute on function private.publish_policy(uuid, text, text, text[]) from public, anon, authenticated;
revoke execute on function private.confirm_policy_check(uuid, text, boolean) from public, anon, authenticated;
revoke execute on function private.assign_bio_number(uuid, text) from public, anon, authenticated;
revoke execute on function private.prepare_publication(uuid, text, timestamptz, text, text, text[], boolean, boolean)
  from public, anon, authenticated;
grant execute on function private.publish_policy(uuid, text, text, text[]) to authenticated;
grant execute on function private.confirm_policy_check(uuid, text, boolean) to authenticated;
grant execute on function private.assign_bio_number(uuid, text) to authenticated;
grant execute on function private.prepare_publication(uuid, text, timestamptz, text, text, text[], boolean, boolean)
  to authenticated;

-- ── public 래퍼(SECURITY INVOKER, authenticated 만) ───────────
create function public.publish_policy(p_project_id uuid, p_title text, p_body text, p_hashtags text[])
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.publish_policy(p_project_id, p_title, p_body, p_hashtags);
$$;

create function public.confirm_policy_check(p_project_id uuid, p_item text, p_checked boolean)
returns void
language sql
security invoker
set search_path = ''
as $$
  select private.confirm_policy_check(p_project_id, p_item, p_checked);
$$;

create function public.assign_bio_number(p_project_id uuid, p_service text)
returns integer
language sql
security invoker
set search_path = ''
as $$
  select private.assign_bio_number(p_project_id, p_service);
$$;

create function public.prepare_publication(
  p_project_id uuid, p_mode text, p_scheduled_at timestamptz, p_title text, p_body text,
  p_hashtags text[], p_purchase_guide boolean, p_pin_comment boolean)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.prepare_publication(p_project_id, p_mode, p_scheduled_at, p_title, p_body,
                                     p_hashtags, p_purchase_guide, p_pin_comment);
$$;

comment on function public.publish_policy(uuid, text, text, text[]) is '06 정책 점검 6항목 판정(15-4) + 설명란 조각. 사용자 세션으로 호출';
comment on function public.confirm_policy_check(uuid, text, boolean) is '사용자 체크(출처 표기·고지 / 링크인바이오 등록 완료). 사용자가 누른 요청만';
comment on function public.assign_bio_number(uuid, text) is '링크인바이오 번호 받기(16-4, 채널별 1부터·재사용 없음)';
comment on function public.prepare_publication(uuid, text, timestamptz, text, text, text[], boolean, boolean) is '발행 준비 저장(6/6 통과 시만). 업로드는 task-024';

revoke execute on function public.publish_policy(uuid, text, text, text[]) from public, anon;
revoke execute on function public.confirm_policy_check(uuid, text, boolean) from public, anon;
revoke execute on function public.assign_bio_number(uuid, text) from public, anon;
revoke execute on function public.prepare_publication(uuid, text, timestamptz, text, text, text[], boolean, boolean)
  from public, anon;
grant execute on function public.publish_policy(uuid, text, text, text[]) to authenticated;
grant execute on function public.confirm_policy_check(uuid, text, boolean) to authenticated;
grant execute on function public.assign_bio_number(uuid, text) to authenticated;
grant execute on function public.prepare_publication(uuid, text, timestamptz, text, text, text[], boolean, boolean)
  to authenticated;
