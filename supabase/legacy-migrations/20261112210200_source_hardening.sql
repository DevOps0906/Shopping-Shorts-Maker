-- task-017 보안 리뷰 반영
-- 1) 격리 원본: sources.quarantined(함수 전용). select_sources 워커가 형식 위장·경로 오류로 거부한 원본(점수 없음 + 사유)을 true 로 저장.
--    순위 밖 제외(점수 있음 + "일치도 순위 20위 밖")와 구분한다. 격리 원본은 사용 선택·승인 편수·편집 입력에서 빠진다.
-- 2) 직접 추가 URL: userinfo(@) 거부, 호스트로 플랫폼 판별. 3) 작성자·제목·URL 제어 문자·양방향 제어 문자 거부.
-- 4) sources.url http(s) 스킴 CHECK(기존 행 위반 시 NOT VALID 로 남김), edit_input_sources 의 service_role EXECUTE 회수.
-- 기존 함수는 create or replace(시그니처·권한 유지).

-- ── 1) 격리 열 ───────────────────────────────────────────────
alter table public.sources add column quarantined boolean not null default false;
comment on column public.sources.quarantined is '워커가 형식 위장·경로 오류로 거부한 원본. 함수 전용, 사용·편집 입력 제외';

-- 권리 열·격리 열은 함수(postgres)만 바꾼다. 다른 주체의 INSERT 는 초기값으로 강제
create or replace function private.sources_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if current_user <> 'postgres' then
      new.rights_basis := null;
      new.rights_confirmed_by := null;
      new.rights_confirmed_at := null;
      new.quarantined := false;
    end if;
    if new.purge_after is null then
      new.purge_after := (new.collected_at + interval '30 days')::date;
    end if;
  elsif current_user <> 'postgres'
    and (new.rights_basis, new.rights_confirmed_by, new.rights_confirmed_at, new.quarantined)
        is distinct from (old.rights_basis, old.rights_confirmed_by, old.rights_confirmed_at, old.quarantined) then
    raise exception '권리·격리 열은 확인 함수로만 바꿀 수 있습니다' using errcode = '42501';
  end if;
  return new;
end;
$$;

-- 워커 저장: quarantined 를 명시하면 그 값(boolean), 없으면 "점수 없음 + 사유 있음"(워커의 거부 후보)으로 판정
create or replace function private.save_source_scores(p_job_id uuid, p_results jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid := private.analyze_job_project(p_job_id);
  v_selecting boolean;
  v_total integer;
  v_valid integer;
  v_updated integer;
begin
  if jsonb_typeof(p_results) is distinct from 'array' then
    raise exception '결과는 배열이어야 합니다' using errcode = '22023';
  end if;

  -- 승인 함수와 직렬화(02 승인 여부를 읽는 사이 바뀌지 않게)
  select coalesce(step_status->>'2', '') <> 'approved' into v_selecting
  from public.projects where id = v_project
  for update;

  select count(*),
         count(*) filter (where s.id is not null
                            and (e->'score' = 'null'::jsonb
                                 or (jsonb_typeof(e->'score') = 'number' and (e->>'score')::numeric between 0 and 100))
                            and (e->'exclude_reason' is null or e->'exclude_reason' = 'null'::jsonb
                                 or (jsonb_typeof(e->'exclude_reason') = 'string'
                                     and length(e->>'exclude_reason') <= 200))
                            and (e->'quarantined' is null or jsonb_typeof(e->'quarantined') = 'boolean'))
    into v_total, v_valid
  from jsonb_array_elements(p_results) e
  left join public.sources s
    on s.project_id = v_project
   and s.id::text = e->>'id';
  if v_total <> v_valid then
    raise exception '저장할 수 없는 결과가 있습니다(다른 프로젝트 원본이거나 값 범위 밖)' using errcode = '22023';
  end if;

  update public.sources s
  set score = (e->>'score')::numeric,
      exclude_reason = e->>'exclude_reason',
      quarantined = coalesce((e->>'quarantined')::boolean,
                             (e->>'score') is null and (e->>'exclude_reason') is not null),
      checked = case when v_selecting then false else s.checked end
  from jsonb_array_elements(p_results) e
  where s.project_id = v_project and s.id::text = e->>'id';
  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;

-- 승인 편수에서 격리 원본 제외(고지 확인은 항상, 210100 그대로)
create or replace function private.source_approval_problem(p_project_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  with u as (
    select count(*) as n
    from public.sources s
    where s.project_id = p_project_id
      and s.used
      and not s.quarantined
      and s.rights_basis is not null
      and s.rights_confirmed_at is not null
      and s.file_path is not null
      and s.file_deleted_at is null
  )
  select case
    when u.n < 3 then 'too_few'
    when u.n < 5 and coalesce(btrim(p.sources_shortage_reason), '') = '' then 'reason_required'
    when p.sources_notice_ack_at is null then 'notice_required'
  end
  from u
  cross join public.projects p
  where p.id = p_project_id;
$$;

-- 사용 선택: 격리 원본은 사용할 수 없다(나머지는 210000 그대로)
create or replace function private.save_source_use(
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

  select count(*),
         count(*) filter (where s.id is not null
                            and s.file_path is not null
                            and s.file_deleted_at is null
                            and not s.quarantined
                            and e->>'rights_basis' in ('attribution_notice', 'own', 'seller', 'licensed'))
    into v_total, v_valid
  from jsonb_array_elements(p_uses) e
  left join public.sources s
    on s.project_id = p_project_id
   and s.id::text = e->>'id';
  if v_total <> v_valid
     or v_total <> (select count(distinct e->>'id') from jsonb_array_elements(p_uses) e) then
    raise exception '사용할 수 없는 원본이 있습니다(내려받지 않았거나 격리됐거나 권리 근거가 없음)' using errcode = '22023';
  end if;

  update public.sources s
  set used = true,
      rights_basis = e->>'rights_basis',
      rights_confirmed_by = case when s.rights_basis is distinct from e->>'rights_basis' or s.rights_confirmed_at is null
                                 then v_uid else s.rights_confirmed_by end,
      rights_confirmed_at = case when s.rights_basis is distinct from e->>'rights_basis' or s.rights_confirmed_at is null
                                 then now() else s.rights_confirmed_at end
  from jsonb_array_elements(p_uses) e
  where s.project_id = p_project_id and s.id::text = e->>'id';

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

  if v_reason is not null and v_reason is distinct from v_old_reason then
    insert into public.chat_messages (project_id, role, kind, text)
    values (p_project_id, 'user', 'text', '02 소스 부족 사유: ' || v_reason);
  end if;

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

-- 편집 입력: 격리 원본 제외(나머지는 210000 그대로)
create or replace function public.edit_input_sources(p_project_id uuid)
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
    and not s.quarantined
    and s.rights_basis is not null
    and s.rights_confirmed_at is not null
    and s.file_path is not null
    and s.file_deleted_at is null
    and (s.rights_basis <> 'attribution_notice' or p.sources_notice_ack_at is not null)
  order by s.score desc nulls last, s.id;
$$;
-- 렌더 워커용은 이후 worker_role 전용 함수로 둔다
revoke execute on function public.edit_input_sources(uuid) from service_role;

-- ── 2)·3) 직접 추가 입력 검사 ──────────────────────────────
-- 제어 문자([[:cntrl:]])·양방향 제어(U+202A–U+202E, U+2066–U+2069)
create function private.has_unsafe_chars(p_text text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(p_text, '') ~ '[[:cntrl:]‪-‮⁦-⁩]';
$$;
revoke execute on function private.has_unsafe_chars(text) from public, anon, authenticated;

create or replace function private.add_direct_source(
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
  v_authority text;
  v_host text;
  v_platform text;
  v_id uuid;
begin
  perform private.lock_source_step(p_project_id);
  if char_length(v_url) > 2000 or v_url !~* '^https?://[^\s/?#]+[^\s]*$' or private.has_unsafe_chars(v_url) then
    raise exception 'http(s) URL을 입력해 주세요' using errcode = '22023';
  end if;
  -- authority 에 userinfo(@)가 있으면 거부(https://www.tiktok.com@evil.example/ 같은 위장)
  v_authority := substring(v_url from '^[A-Za-z]+://([^/?#]*)');
  v_host := lower(regexp_replace(v_authority, ':[0-9]*$', ''));
  if v_authority like '%@%' or v_host !~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$' then
    raise exception 'URL 주소 형식이 올바르지 않습니다' using errcode = '22023';
  end if;
  if char_length(v_author) not between 1 and 100 or private.has_unsafe_chars(v_author) then
    raise exception '작성자를 확인해 주세요' using errcode = '22023';
  end if;
  if v_title is not null and (char_length(v_title) > 200 or private.has_unsafe_chars(v_title)) then
    raise exception '제목을 확인해 주세요' using errcode = '22023';
  end if;
  if (select count(*) from public.sources where project_id = p_project_id) >= 100 then
    raise exception '원본은 프로젝트당 100편까지 추가할 수 있습니다' using errcode = '22023';
  end if;
  if exists (select 1 from public.sources where project_id = p_project_id and url = v_url) then
    raise exception '이미 추가한 URL입니다' using errcode = '23505';
  end if;

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

-- ── 4) url 스킴 CHECK: 기존 행이 위반하면 NOT VALID 로 두고 새 행만 검사 ──
alter table public.sources
  add constraint sources_url_http_check check (url ~* '^https?://') not valid;
do $$
begin
  alter table public.sources validate constraint sources_url_http_check;
exception when check_violation then
  raise notice 'sources_url_http_check: 기존 행 위반이 있어 NOT VALID 로 둡니다(새 행만 검사)';
end;
$$;
