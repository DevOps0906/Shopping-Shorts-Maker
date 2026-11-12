-- task-015a 보안 리뷰 반영(20261112240000 의 확장 함수 create or replace, 시그니처·권한 유지)
-- 잠금 순서(전역): projects → jobs → extension_connections → sources.
--   approve_step·request_step_change 가 projects → jobs 순으로 잠그므로 같은 순서를 지켜 교착을 피한다.
--   확장 폐기(서버의 extension_connections UPDATE)는 같은 확장 행 잠금을 기다리므로 claim·입력과 직렬화된다.
-- 1) claim: 작업 행 FOR UPDATE(대기 상태 재확인) → 확장 행 FOR UPDATE(폐기 전·소유자) 후 갱신. 동시 claim 은 1건만.
-- 2) ext_job_project: 프로젝트 → 작업(running·이 확장) → 확장(폐기 전·소유자) 순으로 잠근다.
-- 3) 다운로드 입력 TOCTOU: 대상 sources 행까지 잠근 뒤, 최종 UPDATE 에 작업·확장·원본 조건을 다시 걸고
--    갱신 행 수가 검증 건수와 다르면 예외(전부 되돌림).

create or replace function private.ext_job_project(p_extension_id uuid, p_job_id uuid, p_type text,
                                                   out project_id uuid, out user_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pid uuid;
  v_uid uuid;
begin
  select j.project_id into v_pid from public.jobs j where j.id = p_job_id;

  select p.user_id into v_uid
  from public.projects p
  where p.id = v_pid
  for update;

  perform 1
  from public.jobs j
  where j.id = p_job_id and j.project_id = v_pid and j.type = p_type
    and j.status = 'running' and j.extension_id = p_extension_id
  for update;
  if not found then
    raise exception '실행 중인 수집 작업이 아니거나 권한이 없습니다' using errcode = '42501';
  end if;

  perform 1
  from public.extension_connections e
  where e.id = p_extension_id and e.revoked_at is null and e.user_id = v_uid
  for update;
  if not found then
    raise exception '실행 중인 수집 작업이 아니거나 권한이 없습니다' using errcode = '42501';
  end if;

  project_id := v_pid;
  user_id := v_uid;
end;
$$;

create or replace function private.ext_claim_job(p_extension_id uuid, p_job_id uuid)
returns table (id uuid, type text, payload jsonb)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_job public.jobs;
begin
  -- 작업 행: 다른 claim·스위퍼·취소와 직렬화. 기다린 뒤 상태가 바뀌었으면 0행
  select j.* into v_job
  from public.jobs j
  where j.id = p_job_id
    and j.status = 'waiting_extension'
    and j.type in ('collect', 'collect_download')
  for update;
  if not found then
    return;
  end if;

  -- 확장 행: 폐기와 직렬화. 폐기됐거나 프로젝트 소유자의 확장이 아니면 0행
  perform 1
  from public.extension_connections e
  where e.id = p_extension_id
    and e.revoked_at is null
    and e.user_id = (select p.user_id from public.projects p where p.id = v_job.project_id)
  for update;
  if not found then
    return;
  end if;

  update public.jobs j
  set status = 'running', extension_id = p_extension_id, started_at = now(), error = null
  where j.id = p_job_id;
  -- claim 직후 스위퍼가 끊김으로 보지 않게 연결 시각도 갱신
  update public.extension_connections e
  set last_heartbeat_at = now()
  where e.id = p_extension_id;

  return query select v_job.id, v_job.type, v_job.payload;
end;
$$;

create or replace function private.ext_collect_download(p_extension_id uuid, p_job_id uuid, p_files jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job record := private.ext_job_project(p_extension_id, p_job_id, 'collect_download');
  v_prefix text;
  v_total integer;
  v_valid integer;
  v_updated integer;
begin
  v_prefix := v_job.user_id::text || '/' || v_job.project_id::text || '/';
  if jsonb_typeof(p_files) is distinct from 'array' then
    raise exception '파일 목록은 배열이어야 합니다' using errcode = '22023';
  end if;
  if jsonb_array_length(p_files) not between 1 and 60 then
    raise exception '한 번에 1~60개까지 보낼 수 있습니다' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_files) e
             where jsonb_typeof(e) is distinct from 'object'
                or exists (select 1 from jsonb_object_keys(e) k where k not in ('id', 'file_path'))
                or jsonb_typeof(e -> 'id') is distinct from 'string'
                or jsonb_typeof(e -> 'file_path') is distinct from 'string') then
    raise exception '허용되지 않은 필드나 형식이 있습니다' using errcode = '22023';
  end if;

  -- 대상 원본 행 잠금(체크 해제·격리와 직렬화)
  perform 1
  from public.sources s
  where s.project_id = v_job.project_id
    and s.id::text in (select e->>'id' from jsonb_array_elements(p_files) e)
  order by s.id
  for update;

  select count(*),
         count(*) filter (where s.id is not null
                            and s.checked
                            and not s.quarantined
                            and s.file_deleted_at is null
                            and left(e->>'file_path', char_length(v_prefix)) = v_prefix
                            and substr(e->>'file_path', char_length(v_prefix) + 1)
                                ~ '^[A-Za-z0-9_-][A-Za-z0-9._-]{0,199}$')
    into v_total, v_valid
  from jsonb_array_elements(p_files) e
  left join public.sources s
    on s.project_id = v_job.project_id
   and s.id::text = e->>'id';
  if v_total <> v_valid
     or v_total <> (select count(distinct e->>'id') from jsonb_array_elements(p_files) e) then
    raise exception '기록할 수 없는 파일이 있습니다(체크하지 않은 원본이거나 경로가 다름)' using errcode = '22023';
  end if;

  -- 최종 갱신에도 작업·확장·원본 조건을 다시 건다
  update public.sources s
  set file_path = e->>'file_path'
  from jsonb_array_elements(p_files) e, public.jobs j, public.extension_connections x
  where s.project_id = v_job.project_id and s.id::text = e->>'id'
    and s.checked and not s.quarantined and s.file_deleted_at is null
    and j.id = p_job_id and j.type = 'collect_download' and j.status = 'running'
    and j.extension_id = p_extension_id
    and x.id = p_extension_id and x.revoked_at is null and x.user_id = v_job.user_id;
  get diagnostics v_updated = row_count;
  if v_updated <> v_total then
    raise exception '작업 상태가 바뀌어 기록하지 않았습니다' using errcode = '40001';
  end if;
  return v_updated;
end;
$$;
