-- 단계 산출물 검사 강화 (기존 함수 create or replace, 시그니처·권한 유지)
-- 1) mark_step_ready: ready 는 산출물이 있을 때만. 1단계 = 선택된 소재(topics.picked), 3단계 = 최신 대본 행(lines 비어 있지 않음).
--    다른 단계는 기존 규칙 그대로(산출물 검사는 해당 단계 작업에서 추가). suggested 는 산출물 없이 허용.
-- 2) approve_step(3): 최신 대본을 프로젝트 카테고리의 banned_terms 로 다시 검사. 걸리면 SQLSTATE BT001 로 거부.
--    REST로 직접 저장한 대본도 승인 단계에서 막는다. 정규화: NFC → 제로폭 문자(U+200B~U+200D·U+FEFF·U+2060)·공백 제거 → 소문자.
--    대본 줄은 이어 붙여 검사한다(줄을 나눠 피하는 경우까지 막기 위해).

create function private.normalize_for_ban(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select lower(regexp_replace(normalize(coalesce(p_text, ''), nfc), '[​-‍﻿⁠[:space:]]', '', 'g'));
$$;
revoke execute on function private.normalize_for_ban(text) from public, anon, authenticated;

-- 대본(lines)에 걸린 첫 금지어(원문)를 돌려준다. 없으면 null.
create function private.find_banned_term(p_project_id uuid, p_lines jsonb)
returns text
language sql
stable
set search_path = ''
as $$
  with body as (
    select private.normalize_for_ban(string_agg(l.line, '' order by l.ord)) as text
    from jsonb_array_elements_text(coalesce(p_lines, '[]'::jsonb)) with ordinality as l(line, ord)
  )
  select t.term
  from public.projects p
  join public.categories c on c.id = p.category_id
  cross join lateral unnest(c.banned_terms) as t(term)
  cross join body
  where p.id = p_project_id
    and private.normalize_for_ban(t.term) <> ''
    and strpos(body.text, private.normalize_for_ban(t.term)) > 0
  limit 1;
$$;
revoke execute on function private.find_banned_term(uuid, jsonb) from public, anon, authenticated;

create or replace function private.mark_step_ready(p_project_id uuid, p_step integer, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_status jsonb;
  v_current text;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  if p_step is null or p_step not between 1 and 6 then
    raise exception '잘못된 단계입니다: %', p_step using errcode = '22023';
  end if;
  if p_status is null or p_status not in ('suggested', 'ready') then
    raise exception '바꿀 수 없는 상태입니다: %', p_status using errcode = '22023';
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

  v_current := v_status ->> p_step::text;
  if v_current = p_status then
    return v_status;
  end if;
  if v_current not in ('idle', 'change', 'suggested', 'ready') then
    raise exception '지금 상태(%)에서는 바꿀 수 없습니다', v_current using errcode = '55000';
  end if;

  -- ready 는 산출물이 있을 때만
  if p_status = 'ready' then
    if p_step = 1 and not exists (
         select 1 from public.topics t where t.project_id = p_project_id and t.picked) then
      raise exception '선택된 소재가 없어 준비 완료로 바꿀 수 없습니다' using errcode = '55000';
    end if;
    if p_step = 3 and not exists (
         select 1 from (
           select s.lines from public.scripts s
           where s.project_id = p_project_id
           order by s.version desc
           limit 1
         ) latest
         where jsonb_array_length(latest.lines) > 0) then
      raise exception '대본이 없어 준비 완료로 바꿀 수 없습니다' using errcode = '55000';
    end if;
  end if;

  update public.projects
  set step_status = jsonb_set(step_status, array[p_step::text], to_jsonb(p_status))
  where id = p_project_id
  returning step_status into v_status;

  return v_status;
end;
$$;

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
