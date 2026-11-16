-- task-024b: 보관 기간이 지나 파일이 지워진 프로젝트를 다시 렌더할 때 명확히 거부
-- - render_job_context 의 음성 테이크는 파일이 남은 것(file_deleted_at is null)만 고른다.
-- - 쓸 음성이 없고 지워진 테이크가 있거나, 편집 입력 원본이 0개이고 사용 원본 중 지워진 파일이 있으면
--   빈 값을 워커에 넘기지 않고 SQLSTATE RD001 로 거부한다.
-- - 삭제와 무관하게 비어 있는 경우(음성 미생성·원본 미선정)는 기존대로 워커가 사용자 문구로 실패 처리한다.
-- - 나머지(20261112230200)는 그대로.

create or replace function private.render_job_context(p_job_id uuid)
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
  where t.project_id = v_project and t.audio_path is not null and t.file_deleted_at is null
  order by t.created_at desc, t.id desc
  limit 1;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'platform', s.platform, 'author', s.author, 'url', s.url, 'collected_at', s.collected_at,
           'file_path', s.file_path, 'duration_sec', s.duration_sec, 'score', s.score,
           'rights_basis', s.rights_basis)), '[]'::jsonb)
    into v_sources
  from private.render_input_sources(v_project) s;

  if (v_take is null
      and exists (select 1 from public.voice_takes t
                  where t.project_id = v_project and t.audio_path is not null and t.file_deleted_at is not null))
     or (jsonb_array_length(v_sources) = 0
         and exists (select 1 from public.sources s
                     where s.project_id = v_project and s.used and s.file_path is not null
                       and s.file_deleted_at is not null)) then
    raise exception '보관 기간이 지나 원본/음성 파일이 삭제되어 다시 렌더할 수 없습니다' using errcode = 'RD001';
  end if;

  return jsonb_build_object('project_id', v_project, 'user_id', v_user, 'target_sec', v_target,
                            'lines', coalesce(v_lines, '[]'::jsonb), 'take', v_take, 'sources', v_sources);
end;
$$;
