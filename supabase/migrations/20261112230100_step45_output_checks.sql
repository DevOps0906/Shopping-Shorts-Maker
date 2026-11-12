-- 04·05 단계 산출물 검사 (create or replace, 시그니처·권한 유지)
-- 기준 정의: mark_step_ready = 20261112200300, approve_step = 20261112210000(02 소스 검사) + 20261112200300(03 금지 표현).
-- 기존 검사는 그대로 두고 아래만 더한다.
-- - 04 목소리 ready·승인: 그 프로젝트의 쓸 수 있는 음성 테이크 1개 이상
--   (audio_path 있음 · duration_sec > 0. 경로·길이 형식은 save_voice_take(20261112220000)가 저장 때 검사한다)
-- - 05 편집 ready·승인: 그 프로젝트 최신 버전 렌더가 성공 결과
--   (mp4_path 있음 · duration_sec > 0. renders 에 상태 열이 없어 save_render(20261112230000)가 쓴 결과 열로 판정)

create function private.has_voice_output(p_project_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.voice_takes t
    where t.project_id = p_project_id
      and t.audio_path is not null
      and t.duration_sec > 0
  );
$$;
revoke execute on function private.has_voice_output(uuid) from public, anon, authenticated;

create function private.has_render_output(p_project_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select r.mp4_path is not null and r.duration_sec > 0
    from public.renders r
    where r.project_id = p_project_id
    order by r.version desc
    limit 1
  ), false);
$$;
revoke execute on function private.has_render_output(uuid) from public, anon, authenticated;

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
    if p_step = 4 and not private.has_voice_output(p_project_id) then
      raise exception '음성 테이크가 없어 준비 완료로 바꿀 수 없습니다' using errcode = '55000';
    end if;
    if p_step = 5 and not private.has_render_output(p_project_id) then
      raise exception '완성된 최신 렌더가 없어 준비 완료로 바꿀 수 없습니다' using errcode = '55000';
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

  -- 04 목소리 승인 = 쓸 수 있는 음성 테이크 1개 이상
  if p_step = 4 and not private.has_voice_output(p_project_id) then
    raise exception '음성 테이크가 없어 승인할 수 없습니다' using errcode = '55000';
  end if;

  -- 05 편집 승인 = 최신 버전 렌더가 성공 결과
  if p_step = 5 and not private.has_render_output(p_project_id) then
    raise exception '완성된 최신 렌더가 없어 승인할 수 없습니다' using errcode = '55000';
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
