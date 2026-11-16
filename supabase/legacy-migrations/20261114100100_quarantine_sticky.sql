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
      quarantined = s.quarantined or coalesce((e->>'quarantined')::boolean,
                             (e->>'score') is null and (e->>'exclude_reason') is not null),
      checked = case when v_selecting then false else s.checked end
  from jsonb_array_elements(p_results) e
  where s.project_id = v_project and s.id::text = e->>'id';
  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;
