-- task-016: analyze 워커가 02 소스 후보를 읽고 일치도 점수를 저장하는 함수 (docs/planning.md 4장, 17-2 D1·D8)
-- - sources 에 점수 열(score)은 이미 있어 열은 추가하지 않는다. 순위는 score 내림차순(같으면 id)으로 정해진다.
-- - worker_role 에는 sources 테이블 권한을 주지 않는다. 아래 두 함수(SECURITY DEFINER)만 EXECUTE.
--   두 함수 모두 "그 작업이 running 인 analyze 작업"일 때만, 그 작업 프로젝트의 sources 만 다룬다.
-- - 권리 열(rights_*)·used·file_path 는 건드리지 않는다. 체크(checked)는 02 승인 전(선정 단계)에만 false 로 맞추고,
--   02 승인 뒤에는 사용자가 고른 값을 그대로 둔다(D1: 체크는 사용자만).

create function private.analyze_job_project(p_job_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid;
begin
  select project_id into v_project
  from public.jobs
  where id = p_job_id and type = 'analyze' and status = 'running';
  if v_project is null then
    raise exception '실행 중인 analyze 작업이 아닙니다' using errcode = '55000';
  end if;
  return v_project;
end;
$$;
revoke execute on function private.analyze_job_project(uuid) from public, anon, authenticated;

create function private.analyze_sources_context(p_job_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid := private.analyze_job_project(p_job_id);
  v_user uuid;
  v_sources jsonb;
begin
  select user_id into v_user from public.projects where id = v_project;
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'file_path', s.file_path)
                            order by s.collected_at, s.id), '[]'::jsonb)
    into v_sources
  from public.sources s
  where s.project_id = v_project and s.file_deleted_at is null;
  return jsonb_build_object('project_id', v_project, 'user_id', v_user, 'sources', v_sources);
end;
$$;
revoke execute on function private.analyze_sources_context(uuid) from public, anon, authenticated;

create function private.save_source_scores(p_job_id uuid, p_results jsonb)
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
                                     and length(e->>'exclude_reason') <= 200)))
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
      checked = case when v_selecting then false else s.checked end
  from jsonb_array_elements(p_results) e
  where s.project_id = v_project and s.id::text = e->>'id';
  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;
revoke execute on function private.save_source_scores(uuid, jsonb) from public, anon, authenticated;

grant execute on function private.analyze_sources_context(uuid) to worker_role;
grant execute on function private.save_source_scores(uuid, jsonb) to worker_role;
