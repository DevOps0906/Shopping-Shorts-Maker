-- task-023 보안 리뷰 반영: 링크인바이오 번호·등록 완료·발행 준비 무효화
-- 1) affiliate_links 의 bio_service·bio_no·bio_registered_at 는 사용자 직접 INSERT·UPDATE 불가(함수 전용).
--    등록 완료(confirm_policy_check)와 정책 판정(purchase_path)은 같은 프로젝트·같은 번호·같은 채널 bio_pages 의 bio_items 행이 있어야 통과.
-- 2) bio_items 는 사용자 직접 INSERT·UPDATE·DELETE 불가(assign_bio_number 로만). bio_pages 는 service·url 만 수정, 삭제 불가.
--    번호는 accounts.last_bio_no(채널별 지금까지 발급한 최대값)로만 올린다 → 항목이 지워지거나 채널이 바뀌어도 재사용 없음.
--    발급 시 bio_pages 채널 = 프로젝트 채널. 프로젝트 채널이 바뀌었으면 옛 번호는 은퇴(project_id 해제)하고 새 채널 번호를 받는다.
-- 3) 체크 해제·정책 변화(제휴 링크 변경·5단계 승인 해제·자동 판정 미통과)면 pending 발행 행을 invalidated 로,
--    projects.status 를 awaiting_publish → in_progress 로 되돌린다. 다시 발행 준비하면 pending 으로 돌아온다.
-- 4) 업로드 직전 6/6 재판정: public.publish_recheck(p_project_id) — 서버(service_role, task-024) 전용. 저장된 제목·본문·해시태그로
--    private.publish_evaluate 를 다시 돌리고, 미통과면 무효화 후 ok=false 를 돌려준다.
-- 20261112260000·260100 의 나머지 규칙은 그대로(함수는 create or replace, 시그니처·권한 유지).

-- ── 1) 권한 회수 ─────────────────────────────────────────────
revoke insert (bio_service, bio_no, bio_registered_at) on public.affiliate_links from authenticated;
revoke update (bio_service, bio_no, bio_registered_at) on public.affiliate_links from authenticated;

revoke insert, update, delete on public.bio_items from authenticated;
drop policy bio_items_insert_own on public.bio_items;
drop policy bio_items_update_own on public.bio_items;
drop policy bio_items_delete_own on public.bio_items;
comment on table public.bio_items is '링크인바이오 번호 항목. 본인 읽기만, 쓰기는 assign_bio_number·confirm_policy_check 함수 전용';

revoke update, delete on public.bio_pages from authenticated;
grant update (service, url) on public.bio_pages to authenticated;
drop policy bio_pages_delete_own on public.bio_pages;

-- 채널별 발급한 최대 번호(재사용 금지 기준). authenticated 열 GRANT 에 없으므로 함수만 쓴다
alter table public.accounts add column last_bio_no integer not null default 0 check (last_bio_no >= 0);
comment on column public.accounts.last_bio_no is '링크인바이오 번호 발급 최대값(16-4 재사용 금지). assign_bio_number 전용';
update public.accounts a
set last_bio_no = coalesce((select max(bi.no) from public.bio_items bi
                            join public.bio_pages bp on bp.id = bi.bio_page_id
                            where bp.account_id = a.id), 0);

-- 발행 행 무효화 상태
alter table public.publications drop constraint publications_status_check;
alter table public.publications add constraint publications_status_check
  check (status in ('pending', 'invalidated', 'scheduled', 'uploading', 'uploaded', 'failed'));

-- ── 3) 무효화 ───────────────────────────────────────────────
create function private.publish_invalidate(p_project_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.publications set status = 'invalidated'
  where project_id = p_project_id and status = 'pending';
  update public.projects set status = 'in_progress'
  where id = p_project_id and status = 'awaiting_publish';
end;
$$;
revoke execute on function private.publish_invalidate(uuid) from public, anon, authenticated;

-- 제휴 링크가 바뀌면(사용자 직접 program·disclosed 변경·삭제 포함) 발행 준비를 푼다
create function private.affiliate_links_invalidate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.publish_invalidate(coalesce(new.project_id, old.project_id));
  if tg_op = 'UPDATE' and new.project_id is distinct from old.project_id then
    perform private.publish_invalidate(old.project_id);
  end if;
  return null;
end;
$$;
revoke execute on function private.affiliate_links_invalidate() from public, anon, authenticated;

create trigger affiliate_links_invalidate_ins_del
  after insert or delete on public.affiliate_links
  for each row execute function private.affiliate_links_invalidate();
create trigger affiliate_links_invalidate_upd
  after update on public.affiliate_links
  for each row
  when ((new.project_id, new.program, new.url, new.disclosed, new.bio_service, new.bio_no)
          is distinct from (old.project_id, old.program, old.url, old.disclosed, old.bio_service, old.bio_no)
        or (new.bio_registered_at is null and old.bio_registered_at is not null))
  execute function private.affiliate_links_invalidate();

-- 5단계 승인이 풀리면(변경 요청 등) 발행 준비를 푼다
create function private.projects_publish_invalidate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.step_status ->> '5' is distinct from 'approved' then
    update public.publications set status = 'invalidated'
    where project_id = new.id and status = 'pending';
    if new.status = 'awaiting_publish' then
      new.status := 'in_progress';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function private.projects_publish_invalidate() from public, anon, authenticated;

create trigger projects_publish_invalidate
  before update of step_status on public.projects
  for each row execute function private.projects_publish_invalidate();

-- ── 정책 판정: 구매 경로는 같은 채널 bio_items 행 확인, 자동 항목 미통과면 무효화 ─────
create or replace function private.publish_evaluate(p_project_id uuid, p_title text, p_body text, p_hashtags text[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status jsonb;
  v_ack timestamptz;
  v_platform text;
  v_account uuid;
  v_cuts jsonb;
  v_render_ok boolean := false;
  v_link public.affiliate_links;
  v_has_link boolean;
  v_bio_ok boolean := false;
  v_banned text;
  v_credits text := '';
  v_attr_checked timestamptz;
  v_path_checked timestamptz;
  v_results jsonb := '[]'::jsonb;
  v_item text;
  v_result text;
  v_detail text;
  v_passed integer := 0;
  v_other_fail boolean := false;
  v_tags text[] := private.publish_clean_hashtags(p_hashtags);
begin
  select p.step_status, p.sources_notice_ack_at, a.platform, p.account_id
    into v_status, v_ack, v_platform, v_account
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
  if v_link.bio_no is not null then
    v_bio_ok := exists (select 1 from public.bio_items bi
                        join public.bio_pages bp on bp.id = bi.bio_page_id
                        where bi.project_id = p_project_id and bi.no = v_link.bio_no and bp.account_id = v_account);
  end if;

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
        elsif v_link.bio_service is null or v_link.bio_no is null or not v_bio_ok then
          v_result := 'fail'; v_detail := '링크인바이오 서비스를 골라 이 채널의 번호를 받아 주세요';
        elsif v_link.bio_registered_at is null or v_path_checked is null then
          v_result := 'pending'; v_detail := '링크인바이오에 ' || v_link.bio_no || '번 항목을 등록한 뒤 등록 완료를 켜 주세요';
        else
          v_result := 'pass'; v_detail := '링크인바이오 ' || v_link.bio_no || '번 등록을 확인했습니다';
        end if;
    end case;

    if v_result = 'pass' then
      v_passed := v_passed + 1;
    elsif v_item <> 'banned_terms' then
      -- 금지어는 입력 중 문구로 판정하므로 저장된 발행 행 무효화 근거로 쓰지 않는다(publish_recheck 가 저장 문구로 다시 본다)
      v_other_fail := true;
    end if;
    insert into public.policy_checks (project_id, item, result, detail)
    values (p_project_id, v_item, v_result, v_detail)
    on conflict (project_id, item) do update set result = excluded.result, detail = excluded.detail;

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'item', v_item, 'result', v_result, 'detail', v_detail,
      'checked_at', case v_item when 'attribution_notice' then v_attr_checked
                                when 'purchase_path' then v_path_checked end));
  end loop;

  if v_other_fail then
    perform private.publish_invalidate(p_project_id);
  end if;

  return jsonb_build_object(
    'items', v_results,
    'passed', v_passed,
    'total', 6,
    'credits', v_credits,
    'disclosure', private.publish_disclosure_text(v_link.program, v_link.disclosed),
    'purchase', private.publish_purchase_text(v_link.program, v_link.bio_no));
end;
$$;

-- ── 사용자 체크: 등록 완료는 같은 채널 bio_items 행이 있을 때만, 해제하면 발행 준비 무효화 ─────
create or replace function private.confirm_policy_check(p_project_id uuid, p_item text, p_checked boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link public.affiliate_links;
  v_ack timestamptz;
  v_account uuid;
  v_on boolean := coalesce(p_checked, false);
begin
  perform private.publish_owned(p_project_id, true);
  if p_item is null or p_item not in ('attribution_notice', 'purchase_path') then
    raise exception '사용자가 확인하는 항목이 아닙니다: %', p_item using errcode = '22023';
  end if;
  select sources_notice_ack_at, account_id into v_ack, v_account from public.projects where id = p_project_id;

  if v_on and p_item = 'attribution_notice' and v_ack is null then
    raise exception '02 소스의 출처 표기 고지를 먼저 확인해 주세요' using errcode = '55000';
  end if;

  if p_item = 'purchase_path' then
    select * into v_link from public.affiliate_links where project_id = p_project_id;
    if v_on and (v_link.id is null or not private.publish_is_link_program(v_link.program)
                 or v_link.url is null or v_link.bio_service is null or v_link.bio_no is null
                 or not exists (select 1 from public.bio_items bi
                                join public.bio_pages bp on bp.id = bi.bio_page_id
                                where bi.project_id = p_project_id and bi.no = v_link.bio_no
                                  and bp.account_id = v_account)) then
      raise exception '이 채널의 링크인바이오 번호를 받은 제휴 링크가 있어야 등록 완료를 켤 수 있습니다' using errcode = '55000';
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

  if not v_on then
    perform private.publish_invalidate(p_project_id);
  end if;
end;
$$;

-- ── 번호 받기: 채널 카운터(last_bio_no)로만 발급, 페이지 채널 = 프로젝트 채널. 'none' = 서비스 해제 ─────
create or replace function private.assign_bio_number(p_project_id uuid, p_service text)
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
  v_item uuid;
  v_item_account uuid;
  v_no integer;
begin
  perform private.publish_owned(p_project_id, true);
  if p_service is null or p_service not in ('inpock', 'litly', 'linktree', 'none') then
    raise exception '링크인바이오 서비스가 올바르지 않습니다' using errcode = '22023';
  end if;
  select * into v_link from public.affiliate_links where project_id = p_project_id;

  if p_service = 'none' then
    -- 서비스만 해제. 번호는 은퇴하지 않고 프로젝트에 남는다(다시 고르면 같은 번호)
    if v_link.id is not null then
      update public.affiliate_links set bio_service = null, bio_registered_at = null where id = v_link.id;
    end if;
    update public.bio_items set registered_at = null where project_id = p_project_id;
    insert into public.policy_checks (project_id, item, checked_by, checked_at)
    values (p_project_id, 'purchase_path', null, null)
    on conflict (project_id, item) do update set checked_by = null, checked_at = null;
    perform private.publish_invalidate(p_project_id);
    return v_link.bio_no;
  end if;

  if v_link.id is null or not private.publish_is_link_program(v_link.program) then
    raise exception '링크형 제휴 프로그램을 먼저 골라 주세요' using errcode = '55000';
  end if;

  select account_id, name into v_account, v_name from public.projects where id = p_project_id;
  -- 같은 채널의 번호 발급을 한 줄로 세운다
  perform 1 from public.accounts where id = v_account for update;

  insert into public.bio_pages (account_id, service) values (v_account, p_service)
  on conflict (account_id) do update set service = excluded.service
  returning id into v_page;

  select bi.id, bi.no, bp.account_id into v_item, v_no, v_item_account
  from public.bio_items bi
  join public.bio_pages bp on bp.id = bi.bio_page_id
  where bi.project_id = p_project_id;
  if v_item is not null and v_item_account is distinct from v_account then
    -- 프로젝트 채널이 바뀌었다: 옛 채널 번호는 은퇴(행은 남기고 프로젝트 연결만 해제)
    update public.bio_items set project_id = null where id = v_item;
    v_no := null;
  end if;

  if v_no is null then
    update public.accounts set last_bio_no = last_bio_no + 1 where id = v_account
    returning last_bio_no into v_no;
    insert into public.bio_items (bio_page_id, project_id, no, affiliate_link_id, short_url, title)
    values (v_page, p_project_id, v_no, v_link.id, v_link.short_url, v_name);
  end if;

  if v_link.bio_no is distinct from v_no then
    -- 번호가 바뀌면 이전 등록 완료는 무효
    update public.affiliate_links set bio_service = p_service, bio_no = v_no, bio_registered_at = null where id = v_link.id;
    update public.bio_items set registered_at = null where project_id = p_project_id;
    insert into public.policy_checks (project_id, item, checked_by, checked_at)
    values (p_project_id, 'purchase_path', null, null)
    on conflict (project_id, item) do update set checked_by = null, checked_at = null;
  else
    update public.affiliate_links set bio_service = p_service where id = v_link.id;
  end if;
  return v_no;
end;
$$;

-- ── 발행 준비 저장: invalidated 행도 다시 pending 으로 ─────
create or replace function private.prepare_publication(
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
  if v_existing is not null and v_existing not in ('pending', 'invalidated') then
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

  insert into public.publications (project_id, account_id, mode, scheduled_at, title, body, description, hashtags,
                                   pin_comment, prepared_at, status)
  values (p_project_id, v_account, p_mode, case when p_mode = 'scheduled' then p_scheduled_at end, v_title,
          nullif(btrim(coalesce(p_body, '')), ''), v_description, v_tags, coalesce(p_pin_comment, false), now(), 'pending')
  on conflict (project_id) do update
    set mode = excluded.mode, scheduled_at = excluded.scheduled_at, title = excluded.title, body = excluded.body,
        description = excluded.description, hashtags = excluded.hashtags, pin_comment = excluded.pin_comment,
        prepared_at = excluded.prepared_at, status = 'pending'
  returning * into v_row;

  update public.projects set status = 'awaiting_publish' where id = p_project_id;

  return jsonb_build_object('id', v_row.id, 'mode', v_row.mode, 'scheduled_at', v_row.scheduled_at,
                            'title', v_row.title, 'description', v_row.description,
                            'prepared_at', v_row.prepared_at, 'status', v_row.status);
end;
$$;

-- ── 4) 업로드 직전 6/6 재판정(task-024 서버 전용) ───────────────
create function private.publish_recheck(p_project_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pub public.publications;
  v_policy jsonb;
begin
  select * into v_pub from public.publications where project_id = p_project_id for update;
  if v_pub.id is null or v_pub.status <> 'pending' then
    return jsonb_build_object('ok', false, 'reason', 'not_pending', 'status', v_pub.status);
  end if;
  v_policy := private.publish_evaluate(p_project_id, v_pub.title, v_pub.body, v_pub.hashtags);
  if (v_policy ->> 'passed')::int <> 6 then
    perform private.publish_invalidate(p_project_id);
    return jsonb_build_object('ok', false, 'reason', 'policy_failed', 'policy', v_policy);
  end if;
  return jsonb_build_object('ok', true, 'policy', v_policy);
end;
$$;
revoke execute on function private.publish_recheck(uuid) from public, anon, authenticated;
grant execute on function private.publish_recheck(uuid) to service_role;

create function public.publish_recheck(p_project_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.publish_recheck(p_project_id);
$$;
comment on function public.publish_recheck(uuid) is '업로드 직전 정책 6/6 재판정(저장된 문구). 서버(service_role, task-024) 전용, 미통과면 발행 준비 무효화';
revoke execute on function public.publish_recheck(uuid) from public, anon, authenticated;
grant execute on function public.publish_recheck(uuid) to service_role;
