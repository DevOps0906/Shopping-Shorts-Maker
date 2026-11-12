-- AI 결과 도착 시 단계 상태를 suggested(제안 도착) 또는 ready(승인 필요)로 바꾸는 함수.
-- 서버(service_role)가 projects.step_status 를 직접 쓰던 경로(apps/web/src/server/llm/step-mark.ts)를 대체한다.
-- 근거: docs/05_DATA_MODEL.md 1절(SECURITY DEFINER 조건), docs/planning.md 6장 상태 머신
-- - 본체 private, SECURITY DEFINER, search_path = '', auth.uid() = 소유자 검사, projects 행 FOR UPDATE.
-- - 허용 전이: 해당 단계가 idle·change·suggested·ready 일 때 → suggested 또는 ready. approved 로는 절대 바꾸지 않고,
--   approved·running 단계는 거부한다. 앞 단계가 모두 approved 일 때만.
-- - 이미 목표 상태면 바꾸지 않고 현재 상태를 돌려준다(멱등).
-- - project_events 는 기록하지 않는다(이벤트 종류에 해당 값 없음, 17-9).
-- - 래퍼 public.mark_step_ready(SECURITY INVOKER), EXECUTE는 authenticated만.

create function private.mark_step_ready(p_project_id uuid, p_step integer, p_status text)
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

  update public.projects
  set step_status = jsonb_set(step_status, array[p_step::text], to_jsonb(p_status))
  where id = p_project_id
  returning step_status into v_status;

  return v_status;
end;
$$;

revoke execute on function private.mark_step_ready(uuid, integer, text) from public, anon, authenticated;
grant execute on function private.mark_step_ready(uuid, integer, text) to authenticated;

create function public.mark_step_ready(p_project_id uuid, p_step integer, p_status text)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.mark_step_ready(p_project_id, p_step, p_status);
$$;

comment on function public.mark_step_ready(uuid, integer, text) is 'AI 결과 도착 시 단계를 suggested·ready로(approved 불가). 서버가 사용자 세션으로 호출';

revoke execute on function public.mark_step_ready(uuid, integer, text) from public, anon;
grant execute on function public.mark_step_ready(uuid, integer, text) to authenticated;
