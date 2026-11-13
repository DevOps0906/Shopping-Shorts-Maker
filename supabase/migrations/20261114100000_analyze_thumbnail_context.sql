-- task-015c-1: select_sources 가 file_path 없는 후보를 썸네일로 점수화하도록 컨텍스트에 thumbnail_path 추가
-- - 썸네일 객체가 이미 삭제됐으면(thumbnail_deleted_at) null 로 내려 워커가 "썸네일 없음"으로 처리한다.
-- - 시그니처·권한 그대로(create or replace). 다른 열·조건은 20261112200000 과 같다.
create or replace function private.analyze_sources_context(p_job_id uuid)
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
  select coalesce(jsonb_agg(jsonb_build_object(
                              'id', s.id,
                              'file_path', s.file_path,
                              'thumbnail_path', case when s.thumbnail_deleted_at is null then s.thumbnail_path end)
                            order by s.collected_at, s.id), '[]'::jsonb)
    into v_sources
  from public.sources s
  where s.project_id = v_project and s.file_deleted_at is null;
  return jsonb_build_object('project_id', v_project, 'user_id', v_user, 'sources', v_sources);
end;
$$;
