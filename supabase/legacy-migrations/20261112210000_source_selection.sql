-- task-017: 02 소스 — 다운로드 체크·사용 선택·권리 근거·출처 표기 고지 확인·승인 규칙
-- 근거: docs/planning.md 3장 02(승인 조건 정본), 17-2 D1·D7·D8, docs/05_DATA_MODEL.md 1절(함수 전용 열)·sources
-- - 승인 조건: 사용 원본(used + 권리 근거 확인 + 내려받은 파일) 5편 이상. 3~4편은 부족 사유가 있어야 예외 승인, 0~2편 불가.
--   사용 원본에 출처 표기(attribution_notice) 원본이 있으면 고지 확인이 있어야 승인.
-- - 고지 확인·부족 사유 열은 projects 에 추가하고 authenticated 의 INSERT·UPDATE GRANT 를 주지 않는다(함수 전용).
-- - 사용자 조작 함수는 private(SECURITY DEFINER) 본체 + public(SECURITY INVOKER) 래퍼. authenticated 에만 EXECUTE.
--   제작 파트너 AI 도구 처리기는 이 래퍼를 부르지 않는다(17-7). 체크·사용·권리·고지는 사용자 클릭만.
-- - 편집 입력은 public.edit_input_sources: 권리 근거가 없는 원본(미확인)은 빠진다.

-- ── 함수 전용 열 ─────────────────────────────────────────────
alter table public.projects
  add column sources_notice_ack_by uuid references auth.users (id) on delete set null,
  add column sources_notice_ack_at timestamptz,
  add column sources_shortage_reason text
    check (sources_shortage_reason is null or char_length(sources_shortage_reason) between 1 and 500);

comment on column public.projects.sources_notice_ack_at is '02 소스 출처 표기 고지 확인 시각(D7). 함수 전용, 사용자 클릭만';
comment on column public.projects.sources_notice_ack_by is '02 소스 출처 표기 고지 확인자(D7). 함수 전용';
comment on column public.projects.sources_shortage_reason is '02 소스 사용 3~4편 예외 승인 부족 사유. 함수 전용';

-- 함수 전용 열 초기값 강제(열 GRANT 없음에 더한 2중 방어). 기존 규칙은 그대로
create or replace function private.projects_force_initial_state()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- 서버(SR)·마이그레이션 주체가 아니면 강제. 트리거 안에서 private 함수를 부르지 않는다(authenticated에 USAGE 없음).
  if current_user not in ('postgres', 'service_role', 'supabase_admin') then
    new.current_step := 1;
    new.step_status := '{"1":"idle","2":"idle","3":"idle","4":"idle","5":"idle","6":"idle"}'::jsonb;
    new.status := 'in_progress';
  end if;
  if current_user <> 'postgres' then
    new.sources_notice_ack_by := null;
    new.sources_notice_ack_at := null;
    new.sources_shortage_reason := null;
  end if;
  return new;
end;
$$;

-- ── 규칙 ────────────────────────────────────────────────────
-- 승인을 막는 이유. 통과면 null: too_few(0~2편) · reason_required(3~4편 사유 없음) · notice_required(출처 표기 원본 + 고지 미확인)
create function private.source_approval_problem(p_project_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  with u as (
    select count(*) as n,
           count(*) filter (where s.rights_basis = 'attribution_notice') as attribution
    from public.sources s
    where s.project_id = p_project_id
      and s.used
      and s.rights_basis is not null
      and s.rights_confirmed_at is not null
      and s.file_path is not null
      and s.file_deleted_at is null
  )
  select case
    when u.n < 3 then 'too_few'
    when u.n < 5 and coalesce(btrim(p.sources_shortage_reason), '') = '' then 'reason_required'
    when u.attribution > 0 and p.sources_notice_ack_at is null then 'notice_required'
  end
  from u
  cross join public.projects p
  where p.id = p_project_id;
$$;
revoke execute on function private.source_approval_problem(uuid) from public, anon, authenticated;

-- 02 소스를 사용자가 바꿀 수 있는지 확인하고 프로젝트 행을 잠근다. 지금 상태(step_status)를 돌려준다
create function private.lock_source_step(p_project_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_status jsonb;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  select step_status into v_status
  from public.projects
  where id = p_project_id and user_id = v_uid
  for update;
  if not found then
    raise exception '프로젝트를 찾을 수 없거나 권한이 없습니다' using errcode = '42501';
  end if;
  if v_status ->> '1' <> 'approved' then
    raise exception '01 소재가 승인되지 않았습니다' using errcode = '55000';
  end if;
  if v_status ->> '2' not in ('idle', 'change', 'suggested', 'ready') then
    raise exception '지금 상태(%)에서는 원본을 바꿀 수 없습니다', v_status ->> '2' using errcode = '55000';
  end if;
  return v_status;
end;
$$;
revoke execute on function private.lock_source_step(uuid) from public, anon, authenticated;

-- ── 다운로드 체크(D8: 최대 10편) ─────────────────────────────
create function private.set_source_checks(p_project_id uuid, p_source_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ids uuid[] := coalesce(p_source_ids, '{}');
  v_found integer;
  v_checked integer;
begin
  perform private.lock_source_step(p_project_id);
  if cardinality(v_ids) > 10 then
    raise exception '다운로드는 10편까지 체크할 수 있습니다' using errcode = '22023';
  end if;
  select count(*) into v_found
  from public.sources s
  where s.project_id = p_project_id and s.id = any (v_ids);
  if v_found <> (select count(distinct x) from unnest(v_ids) as x) then
    raise exception '이 프로젝트의 원본이 아닙니다' using errcode = '22023';
  end if;

  update public.sources s
  set checked = (s.id = any (v_ids))
  where s.project_id = p_project_id and s.checked is distinct from (s.id = any (v_ids));

  select count(*) into v_checked from public.sources where project_id = p_project_id and checked;
  return v_checked;
end;
$$;

-- ── 사용 선택·권리 근거·고지 확인·부족 사유 저장 + 02 상태 재계산 ──
-- p_uses: [{"id": uuid, "rights_basis": "attribution_notice"|"own"|"seller"|"licensed"}] — 목록에 없는 원본은 사용 해제
create function private.save_source_use(
  p_project_id uuid, p_uses jsonb, p_notice_ack boolean, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_status jsonb := private.lock_source_step(p_project_id);
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_old_reason text;
  v_total integer;
  v_valid integer;
  v_problem text;
  v_next text;
begin
  if jsonb_typeof(p_uses) is distinct from 'array' then
    raise exception '사용 목록은 배열이어야 합니다' using errcode = '22023';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception '부족 사유는 500자까지 쓸 수 있습니다' using errcode = '22023';
  end if;

  -- 모든 항목이 이 프로젝트의 내려받은 원본 + 허용 권리 근거, id 중복 없음
  select count(*),
         count(*) filter (where s.id is not null
                            and s.file_path is not null
                            and s.file_deleted_at is null
                            and e->>'rights_basis' in ('attribution_notice', 'own', 'seller', 'licensed'))
    into v_total, v_valid
  from jsonb_array_elements(p_uses) e
  left join public.sources s
    on s.project_id = p_project_id
   and s.id::text = e->>'id';
  if v_total <> v_valid
     or v_total <> (select count(distinct e->>'id') from jsonb_array_elements(p_uses) e) then
    raise exception '사용할 수 없는 원본이 있습니다(내려받지 않았거나 권리 근거가 없음)' using errcode = '22023';
  end if;

  -- 사용 원본: 권리 근거가 바뀌었거나 처음이면 확인자·시각을 이번 사용자·지금으로
  update public.sources s
  set used = true,
      rights_basis = e->>'rights_basis',
      rights_confirmed_by = case when s.rights_basis is distinct from e->>'rights_basis' or s.rights_confirmed_at is null
                                 then v_uid else s.rights_confirmed_by end,
      rights_confirmed_at = case when s.rights_basis is distinct from e->>'rights_basis' or s.rights_confirmed_at is null
                                 then now() else s.rights_confirmed_at end
  from jsonb_array_elements(p_uses) e
  where s.project_id = p_project_id and s.id::text = e->>'id';

  -- 나머지: 사용 해제 + 권리 확인 해제(미확인 = 편집 입력 제외)
  update public.sources s
  set used = false, rights_basis = null, rights_confirmed_by = null, rights_confirmed_at = null
  where s.project_id = p_project_id
    and not exists (select 1 from jsonb_array_elements(p_uses) e where e->>'id' = s.id::text)
    and (s.used or s.rights_basis is not null);

  select sources_shortage_reason into v_old_reason from public.projects where id = p_project_id;
  update public.projects
  set sources_notice_ack_at = case when coalesce(p_notice_ack, false)
                                   then coalesce(sources_notice_ack_at, now()) end,
      sources_notice_ack_by = case when coalesce(p_notice_ack, false)
                                   then coalesce(sources_notice_ack_by, v_uid) end,
      sources_shortage_reason = v_reason
  where id = p_project_id;

  -- 부족 사유는 제작 파트너 채팅에도 남긴다(3장 02). 바뀌었을 때만
  if v_reason is not null and v_reason is distinct from v_old_reason then
    insert into public.chat_messages (project_id, role, kind, text)
    values (p_project_id, 'user', 'text', '02 소스 부족 사유: ' || v_reason);
  end if;

  -- 조건을 채우면 ready(승인 버튼 활성), 못 채우면 ready 를 suggested 로 내린다. 다른 상태는 그대로
  v_problem := private.source_approval_problem(p_project_id);
  v_next := case
    when v_problem is null then 'ready'
    when v_status ->> '2' = 'ready' then 'suggested'
    else v_status ->> '2'
  end;
  if v_next <> v_status ->> '2' then
    update public.projects
    set step_status = jsonb_set(step_status, '{2}', to_jsonb(v_next))
    where id = p_project_id
    returning step_status into v_status;
  end if;

  return jsonb_build_object('status', v_status, 'problem', v_problem);
end;
$$;

-- ── 직접 추가(URL·작성자 필수) ──────────────────────────────
create function private.add_direct_source(
  p_project_id uuid, p_url text, p_author text, p_title text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text := btrim(coalesce(p_url, ''));
  v_author text := btrim(coalesce(p_author, ''));
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
  v_host text;
  v_platform text;
  v_id uuid;
begin
  perform private.lock_source_step(p_project_id);
  if char_length(v_url) > 2000 or v_url !~* '^https?://[^\s/?#]+[^\s]*$' then
    raise exception 'http(s) URL을 입력해 주세요' using errcode = '22023';
  end if;
  if char_length(v_author) not between 1 and 100 then
    raise exception '작성자를 입력해 주세요' using errcode = '22023';
  end if;
  if v_title is not null and char_length(v_title) > 200 then
    raise exception '제목은 200자까지 쓸 수 있습니다' using errcode = '22023';
  end if;
  if (select count(*) from public.sources where project_id = p_project_id) >= 100 then
    raise exception '원본은 프로젝트당 100편까지 추가할 수 있습니다' using errcode = '22023';
  end if;
  if exists (select 1 from public.sources where project_id = p_project_id and url = v_url) then
    raise exception '이미 추가한 URL입니다' using errcode = '23505';
  end if;

  v_host := lower(substring(v_url from '^[A-Za-z]+://([^/?#:@]+)'));
  v_platform := case
    when v_host ~ '(^|\.)tiktok\.com$' then 'tiktok'
    when v_host ~ '(^|\.)(xiaohongshu\.com|xhslink\.com)$' then 'xiaohongshu'
    else 'direct'
  end;

  insert into public.sources (project_id, platform, url, author, title, collected_at)
  values (p_project_id, v_platform, v_url, v_author, v_title, now())
  returning id into v_id;
  return v_id;
end;
$$;

-- ── 02 승인 규칙을 approve_step 에 추가(나머지는 20261112200300 그대로) ──
create or replace function private.approve_step(p_project_id uuid, p_step integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_status jsonb;
  v_script_id uuid;
  v_lines jsonb;
  v_banned text;
  v_problem text;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  if p_step is null or p_step not between 1 and 5 then
    raise exception '승인할 수 없는 단계입니다: %', p_step using errcode = '22023';
  end if;

  select step_status into v_status
  from public.projects
  where id = p_project_id and user_id = v_uid
  for update;
  if not found then
    raise exception '프로젝트를 찾을 수 없거나 권한이 없습니다' using errcode = '42501';
  end if;

  if exists (select 1 from generate_series(1, p_step - 1) as g(n)
             where v_status ->> g.n::text <> 'approved') then
    raise exception '앞 단계가 승인되지 않았습니다' using errcode = '55000';
  end if;
  if v_status ->> p_step::text <> 'ready' then
    raise exception '준비 완료(ready) 상태에서만 승인할 수 있습니다: %', v_status ->> p_step::text
      using errcode = '55000';
  end if;

  -- 02 소스 승인 = 사용 편수·부족 사유·고지 확인(3장 02, D7·D8)
  if p_step = 2 then
    v_problem := private.source_approval_problem(p_project_id);
    if v_problem = 'too_few' then
      raise exception '권리를 확인한 사용 원본이 3편 미만이라 승인할 수 없습니다' using errcode = '55000';
    elsif v_problem = 'reason_required' then
      raise exception '사용 원본이 5편 미만이면 부족 사유가 있어야 승인할 수 있습니다' using errcode = '55000';
    elsif v_problem = 'notice_required' then
      raise exception '출처 표기 고지를 확인해야 승인할 수 있습니다' using errcode = '55000';
    end if;
  end if;

  -- 03 대본 승인 = 최신 대본 버전 금지 표현 재검사 후 approved_at 기록
  if p_step = 3 then
    select id, lines into v_script_id, v_lines
    from public.scripts
    where project_id = p_project_id
    order by version desc
    limit 1;
    if v_script_id is null then
      raise exception '승인할 대본이 없습니다' using errcode = '55000';
    end if;
    v_banned := private.find_banned_term(p_project_id, v_lines);
    if v_banned is not null then
      raise exception '대본에 금지 표현이 있어 승인할 수 없습니다: %', v_banned using errcode = 'BT001';
    end if;
    update public.scripts set approved_at = now() where id = v_script_id;
  end if;

  update public.projects
  set step_status = jsonb_set(step_status, array[p_step::text], '"approved"'::jsonb),
      current_step = p_step + 1
  where id = p_project_id
  returning step_status into v_status;

  insert into public.project_events (project_id, step, event)
  values (p_project_id, p_step, 'step_approved');

  return v_status;
end;
$$;

-- ── 편집 입력: 권리 근거를 확인한 사용 원본만(미확인 제외, D1) ──
-- SECURITY INVOKER: 호출자 RLS 그대로(본인 프로젝트만). 출처 표기 원본은 고지 확인이 있어야 들어간다.
create function public.edit_input_sources(p_project_id uuid)
returns setof public.sources
language sql
stable
security invoker
set search_path = ''
as $$
  select s.*
  from public.sources s
  join public.projects p on p.id = s.project_id
  where s.project_id = p_project_id
    and s.used
    and s.rights_basis is not null
    and s.rights_confirmed_at is not null
    and s.file_path is not null
    and s.file_deleted_at is null
    and (s.rights_basis <> 'attribution_notice' or p.sources_notice_ack_at is not null)
  order by s.score desc nulls last, s.id;
$$;
comment on function public.edit_input_sources(uuid) is '05 편집 입력 원본. 권리 근거 확인·사용·내려받은 원본만(미확인 제외)';
revoke execute on function public.edit_input_sources(uuid) from public, anon;
grant execute on function public.edit_input_sources(uuid) to authenticated, service_role;

-- ── 권한·래퍼 ───────────────────────────────────────────────
revoke execute on function private.set_source_checks(uuid, uuid[]) from public, anon, authenticated;
revoke execute on function private.save_source_use(uuid, jsonb, boolean, text) from public, anon, authenticated;
revoke execute on function private.add_direct_source(uuid, text, text, text) from public, anon, authenticated;
grant execute on function private.set_source_checks(uuid, uuid[]) to authenticated;
grant execute on function private.save_source_use(uuid, jsonb, boolean, text) to authenticated;
grant execute on function private.add_direct_source(uuid, text, text, text) to authenticated;

create function public.set_source_checks(p_project_id uuid, p_source_ids uuid[])
returns integer
language sql
security invoker
set search_path = ''
as $$
  select private.set_source_checks(p_project_id, p_source_ids);
$$;

create function public.save_source_use(p_project_id uuid, p_uses jsonb, p_notice_ack boolean, p_reason text)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.save_source_use(p_project_id, p_uses, p_notice_ack, p_reason);
$$;

create function public.add_direct_source(p_project_id uuid, p_url text, p_author text, p_title text)
returns uuid
language sql
security invoker
set search_path = ''
as $$
  select private.add_direct_source(p_project_id, p_url, p_author, p_title);
$$;

comment on function public.set_source_checks(uuid, uuid[]) is '사용자가 누른 다운로드 체크(10편까지). Route Handler·서버 액션이 사용자 세션으로 호출';
comment on function public.save_source_use(uuid, jsonb, boolean, text) is '사용자가 누른 사용 선택·권리 근거·고지 확인·부족 사유 저장. 02 상태를 ready/suggested 로 다시 계산';
comment on function public.add_direct_source(uuid, text, text, text) is '사용자가 직접 추가한 원본(URL·작성자 필수). 권리 근거는 비워 둔다';

revoke execute on function public.set_source_checks(uuid, uuid[]) from public, anon;
revoke execute on function public.save_source_use(uuid, jsonb, boolean, text) from public, anon;
revoke execute on function public.add_direct_source(uuid, text, text, text) from public, anon;
grant execute on function public.set_source_checks(uuid, uuid[]) to authenticated;
grant execute on function public.save_source_use(uuid, jsonb, boolean, text) to authenticated;
grant execute on function public.add_direct_source(uuid, text, text, text) to authenticated;
