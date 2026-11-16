-- task-011: 단계 승인·변경 요청 함수 (함수 전용 열 projects.step_status·current_step, scripts.approved_at)
-- 근거: docs/05_DATA_MODEL.md 1절(SECURITY DEFINER 조건), docs/planning.md 6장 상태 머신·17-5 취소·17-7
-- - 본체는 private(PostgREST 비노출), SECURITY DEFINER, search_path = '', 함수 안에서 auth.uid() = 소유자 검사.
-- - 호출 경로: 노출 스키마(public)의 얇은 SECURITY INVOKER 래퍼 → private 본체. authenticated에만 EXECUTE.
--   (05 문서의 api.* 래퍼는 PGRST_DB_SCHEMAS를 바꾸지 않으려고 public에 둔다.)
-- - Route Handler는 사용자 세션으로 부른다. service_role 호출은 auth.uid()가 없어 거부된다.
-- - AI 제작 파트너 도구 처리기는 이 래퍼를 부르지 않는다(17-7 도구 목록에 없음).
-- - 06 발행은 발행 버튼이 승인을 대신하므로 approve_step은 1~5단계만 받는다.

create function private.approve_step(p_project_id uuid, p_step integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_status jsonb;
  v_script_id uuid;
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

  -- 03 대본 승인 = 최신 대본 버전에 approved_at 기록
  if p_step = 3 then
    select id into v_script_id
    from public.scripts
    where project_id = p_project_id
    order by version desc
    limit 1;
    if v_script_id is null then
      raise exception '승인할 대본이 없습니다' using errcode = '55000';
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

create function private.request_step_change(p_project_id uuid, p_step integer)
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
  if p_step is null or p_step not between 1 and 6 then
    raise exception '변경할 수 없는 단계입니다: %', p_step using errcode = '22023';
  end if;

  select step_status into v_status
  from public.projects
  where id = p_project_id and user_id = v_uid
  for update;
  if not found then
    raise exception '프로젝트를 찾을 수 없거나 권한이 없습니다' using errcode = '42501';
  end if;

  if v_status ->> p_step::text not in ('ready', 'approved') then
    raise exception '준비 완료·승인 상태에서만 변경을 요청할 수 있습니다: %', v_status ->> p_step::text
      using errcode = '55000';
  end if;

  -- 이 단계는 change, 뒤 단계는 모두 idle 로 초기화(6장)
  select jsonb_object_agg(
           e.k,
           case
             when e.k::int = p_step then to_jsonb('change'::text)
             when e.k::int > p_step then to_jsonb('idle'::text)
             else e.v
           end)
  into v_status
  from jsonb_each(v_status) as e(k, v);

  update public.projects
  set step_status = v_status,
      current_step = p_step
  where id = p_project_id;

  -- 대본(03) 이하를 바꾸면 대본 승인도 풀린다
  if p_step <= 3 then
    update public.scripts set approved_at = null
    where project_id = p_project_id and approved_at is not null;
  end if;

  -- 초기화된 뒤 단계의 진행 중 작업 취소(17-5). 크레딧 반환(release)은 서버·워커가 jobs 상태를 보고 처리
  update public.jobs
  set status = 'canceled', finished_at = now()
  where project_id = p_project_id
    and step > p_step
    and status in ('queued', 'waiting_extension', 'running');

  insert into public.project_events (project_id, step, event)
  values (p_project_id, p_step, 'step_change_requested');

  return v_status;
end;
$$;

revoke execute on function private.approve_step(uuid, integer) from public, anon, authenticated;
revoke execute on function private.request_step_change(uuid, integer) from public, anon, authenticated;

-- 래퍼가 본체를 부를 수 있도록 authenticated에만 private USAGE와 두 함수 EXECUTE
grant usage on schema private to authenticated;
grant execute on function private.approve_step(uuid, integer) to authenticated;
grant execute on function private.request_step_change(uuid, integer) to authenticated;

create function public.approve_step(p_project_id uuid, p_step integer)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.approve_step(p_project_id, p_step);
$$;

create function public.request_step_change(p_project_id uuid, p_step integer)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.request_step_change(p_project_id, p_step);
$$;

comment on function public.approve_step(uuid, integer) is '사용자가 누른 단계 승인(1~5). Route Handler가 사용자 세션으로 호출';
comment on function public.request_step_change(uuid, integer) is '사용자가 누른 변경 요청. 뒤 단계 초기화·진행 작업 취소';

revoke execute on function public.approve_step(uuid, integer) from public, anon;
revoke execute on function public.request_step_change(uuid, integer) from public, anon;
grant execute on function public.approve_step(uuid, integer) to authenticated;
grant execute on function public.request_step_change(uuid, integer) to authenticated;
