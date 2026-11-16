-- task-020 보안 리뷰 🟡 반영: renders.cut_map 에 컷 원본 스냅샷(URL·작성자·플랫폼·수집 시각)과 설명란 출처 문구를 DB 값으로 기록
-- - 워커가 보낸 컷의 원본 정보는 믿지 않는다. save_render 가 private.render_input_sources(편집 입력 조건)에서 읽은 값으로
--   각 컷의 source_url · author · platform · collected_at 을 덮어쓰고, credits(설명란 문구)도 그 값으로 다시 만든다.
-- - render_job_context 의 원본 목록에 url · collected_at 을 더한다(워커 cut_map·credits 생성용).
-- - 20261112230000 의 나머지 규칙(경로·길이·실행 중 작업·버전·이벤트)은 그대로.

-- 설명란 출처 문구: '영상 출처: @a(TikTok), @b(小红书)' (중복 제거, 컷 순서). 워커 render.plan.credits_text 와 같은 규칙
create function private.render_credits_text(p_cuts jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce('영상 출처: ' || string_agg(item, ', ' order by first_no), '')
  from (
    select item, min(no) as first_no
    from (
      select (c ->> 'no')::numeric as no,
             '@' || ltrim(btrim(c ->> 'author'), '@')
               || case when coalesce(c ->> 'platform', '') = '' then ''
                       else '(' || case c ->> 'platform'
                                     when 'tiktok' then 'TikTok'
                                     when 'xiaohongshu' then '小红书'
                                     when 'direct' then '직접 추가'
                                     else c ->> 'platform' end || ')' end as item
      from jsonb_array_elements(p_cuts) c
      where ltrim(btrim(coalesce(c ->> 'author', '')), '@') <> ''
    ) labeled
    group by item
  ) items;
$$;
revoke execute on function private.render_credits_text(jsonb) from public, anon, authenticated;

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
  where t.project_id = v_project and t.audio_path is not null
  order by t.created_at desc, t.id desc
  limit 1;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'platform', s.platform, 'author', s.author, 'url', s.url, 'collected_at', s.collected_at,
           'file_path', s.file_path, 'duration_sec', s.duration_sec, 'score', s.score,
           'rights_basis', s.rights_basis)), '[]'::jsonb)
    into v_sources
  from private.render_input_sources(v_project) s;
  return jsonb_build_object('project_id', v_project, 'user_id', v_user, 'target_sec', v_target,
                            'lines', coalesce(v_lines, '[]'::jsonb), 'take', v_take, 'sources', v_sources);
end;
$$;

create or replace function private.save_render(p_job_id uuid, p_mp4_path text, p_duration_sec numeric, p_cut_map jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid := private.render_job_project(p_job_id);
  v_user uuid;
  v_target smallint;
  v_cuts jsonb;
  v_map jsonb;
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

  -- 컷 원본 스냅샷은 DB 값으로 덮어쓴다(워커 입력 무시)
  select jsonb_agg(c.value || jsonb_build_object('source_url', s.url, 'author', s.author,
                                                 'platform', s.platform, 'collected_at', s.collected_at)
                   order by c.ordinality)
    into v_cuts
  from jsonb_array_elements(p_cut_map -> 'cuts') with ordinality c
  join private.render_input_sources(v_project) s on s.id::text = c.value ->> 'source_id';
  v_map := p_cut_map || jsonb_build_object('cuts', v_cuts, 'credits', private.render_credits_text(v_cuts));

  select coalesce(max(version), 0) + 1 into v_version from public.renders where project_id = v_project;
  insert into public.renders (project_id, version, job_id, mp4_path, duration_sec, cut_map)
  values (v_project, v_version, p_job_id, p_mp4_path, p_duration_sec, v_map)
  on conflict (job_id) where job_id is not null do update
    set mp4_path = excluded.mp4_path, duration_sec = excluded.duration_sec, cut_map = excluded.cut_map
  returning id, version, (xmax = 0) into v_id, v_version, v_inserted;

  if v_inserted then
    insert into public.project_events (project_id, step, event) values (v_project, 5, 'render_succeeded');
  end if;
  return jsonb_build_object('id', v_id, 'version', v_version);
end;
$$;
