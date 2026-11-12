-- task-020 05 편집: 렌더 워커 입력·결과 기록 (docs/planning.md 3장 05 · 17-5 · 17-6 · D7, ADR-0001·0002)
-- - renders 에 열 2개: job_id(어느 render 작업 결과인지, 재시도 멱등 키) · duration_sec(결과 영상 길이).
-- - worker_role 에는 sources·scripts·voice_takes·renders·project_events 테이블 권한을 주지 않는다. 아래 두 함수(SECURITY DEFINER)만 EXECUTE.
--   두 함수 모두 "그 작업이 running 인 render 작업"일 때만, 그 작업 프로젝트만 다룬다.
-- - 편집 입력 원본은 public.edit_input_sources(20261112210200)와 같은 조건이다(그 함수는 security invoker·authenticated 용이라
--   auth.uid() 가 없는 워커는 쓸 수 없다): 사용 · 격리 아님 · 권리 근거와 확인 시각 있음 · 파일 있음(삭제 전) · 출처 표기 원본은 고지 확인.
-- - 결과 기록 때 컷 원본을 다시 같은 조건으로 검사한다(작업 중 권리 철회·격리된 원본으로 만든 영상은 저장 거부).
-- - render_succeeded 이벤트(17-9)는 결과 행을 처음 만들 때 한 번만 남긴다(재시도 덮어쓰기는 이벤트 없음).

alter table public.renders
  add column job_id uuid references public.jobs (id) on delete set null,
  add column duration_sec numeric check (duration_sec is null or duration_sec > 0);
create unique index renders_job_id_key on public.renders (job_id) where job_id is not null;
comment on column public.renders.job_id is '이 버전을 만든 render 작업. 같은 작업 재시도는 이 행을 덮어쓴다';
comment on column public.renders.duration_sec is '결과 MP4 길이(초, ffprobe 실측)';

create function private.render_job_project(p_job_id uuid)
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
  where id = p_job_id and type = 'render' and status = 'running';
  if v_project is null then
    raise exception '실행 중인 렌더 작업이 아닙니다' using errcode = '55000';
  end if;
  return v_project;
end;
$$;
revoke execute on function private.render_job_project(uuid) from public, anon, authenticated;

-- 편집 입력 원본 id(edit_input_sources 와 같은 조건, 점수 순)
create function private.render_input_sources(p_project_id uuid)
returns setof public.sources
language sql
stable
security definer
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
revoke execute on function private.render_input_sources(uuid) from public, anon, authenticated;

-- 워커 입력: 프로젝트·소유자·목표 길이·승인 대본 줄·최신 음성 테이크·편집 입력 원본
create function private.render_job_context(p_job_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid := private.render_job_project(p_job_id);
  v_user uuid;
  v_target smallint;
  v_lines jsonb;
  v_take jsonb;
  v_sources jsonb;
begin
  select user_id, target_sec into v_user, v_target from public.projects where id = v_project;
  select s.lines into v_lines
  from public.scripts s
  where s.project_id = v_project and s.approved_at is not null
  order by s.version desc
  limit 1;
  select jsonb_build_object('id', t.id, 'source', t.source, 'audio_path', t.audio_path,
                            'duration_sec', t.duration_sec, 'sentences', coalesce(t.sentences, '[]'::jsonb),
                            'words', coalesce(t.words, '[]'::jsonb))
    into v_take
  from public.voice_takes t
  where t.project_id = v_project and t.audio_path is not null
  order by t.created_at desc, t.id desc
  limit 1;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'platform', s.platform, 'author', s.author, 'file_path', s.file_path,
           'duration_sec', s.duration_sec, 'score', s.score, 'rights_basis', s.rights_basis)), '[]'::jsonb)
    into v_sources
  from private.render_input_sources(v_project) s;
  return jsonb_build_object('project_id', v_project, 'user_id', v_user, 'target_sec', v_target,
                            'lines', coalesce(v_lines, '[]'::jsonb), 'take', v_take, 'sources', v_sources);
end;
$$;
revoke execute on function private.render_job_context(uuid) from public, anon, authenticated;

-- 워커 결과: 렌더 버전 1행(같은 작업이면 덮어씀) + 처음 만들 때 render_succeeded 이벤트. 반환: {id, version}
create function private.save_render(p_job_id uuid, p_mp4_path text, p_duration_sec numeric, p_cut_map jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid := private.render_job_project(p_job_id);
  v_user uuid;
  v_target smallint;
  v_id uuid;
  v_version integer;
  v_inserted boolean;
begin
  -- 버전 번호를 겹치지 않게 프로젝트 행을 잠근다
  select user_id, target_sec into v_user, v_target from public.projects where id = v_project for update;
  if p_mp4_path is null
     or p_mp4_path !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[A-Za-z0-9._-]{1,120}\.mp4$'
     or not starts_with(p_mp4_path, v_user::text || '/' || v_project::text || '/') then
    raise exception '영상 파일 경로가 올바르지 않습니다' using errcode = '22023';
  end if;
  if p_duration_sec is null or abs(p_duration_sec - v_target) > 0.1 then
    raise exception '영상 길이가 목표 길이와 다릅니다' using errcode = '22023';
  end if;
  if jsonb_typeof(p_cut_map) is distinct from 'object'
     or jsonb_typeof(p_cut_map -> 'cuts') is distinct from 'array'
     or jsonb_array_length(p_cut_map -> 'cuts') = 0
     or jsonb_array_length(p_cut_map -> 'cuts') > 20 then
    raise exception '컷 정보가 올바르지 않습니다' using errcode = '22023';
  end if;
  if exists (
       select 1 from jsonb_array_elements(p_cut_map -> 'cuts') c
       where jsonb_typeof(c) is distinct from 'object'
          or (c ->> 'source_id') is null
          or (c ->> 'source_id') !~ '^[0-9a-f-]{36}$'
          or not exists (select 1 from private.render_input_sources(v_project) s
                         where s.id::text = c ->> 'source_id')) then
    raise exception '편집에 쓸 수 없는 원본(권리 미확인·격리·삭제)이 컷에 있습니다' using errcode = '42501';
  end if;

  select coalesce(max(version), 0) + 1 into v_version from public.renders where project_id = v_project;
  insert into public.renders (project_id, version, job_id, mp4_path, duration_sec, cut_map)
  values (v_project, v_version, p_job_id, p_mp4_path, p_duration_sec, p_cut_map)
  on conflict (job_id) where job_id is not null do update
    set mp4_path = excluded.mp4_path, duration_sec = excluded.duration_sec, cut_map = excluded.cut_map
  returning id, version, (xmax = 0) into v_id, v_version, v_inserted;

  if v_inserted then
    insert into public.project_events (project_id, step, event) values (v_project, 5, 'render_succeeded');
  end if;
  return jsonb_build_object('id', v_id, 'version', v_version);
end;
$$;
revoke execute on function private.save_render(uuid, text, numeric, jsonb) from public, anon, authenticated;

grant execute on function private.render_job_context(uuid) to worker_role;
grant execute on function private.save_render(uuid, text, numeric, jsonb) to worker_role;
