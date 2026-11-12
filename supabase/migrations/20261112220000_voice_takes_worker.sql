-- task-019 04 목소리: 워커 TTS 결과 기록 (docs/planning.md 3장 04 · 17-5 · 17-6, ADR-0001)
-- - voice_takes 에 열 2개: job_id(어느 tts 작업 결과인지, 재시도 멱등 키) · sentences(문장 단위 타이밍).
--   words(단어 타이밍) · pauses(쉼 후보) · duration_sec 은 기존 열을 쓴다.
-- - worker_role 에는 scripts·voice_takes 테이블 권한을 주지 않는다. 아래 두 함수(SECURITY DEFINER)만 EXECUTE.
--   두 함수 모두 "그 작업이 running 인 tts 작업"일 때만, 그 작업 프로젝트만 다룬다.
-- - 대본은 job payload(사용자가 RPC로 넣을 수 있음)가 아니라 DB의 승인 대본(최신 approved_at)을 읽는다.
-- - audio_path 는 <user_id>/<project_id>/ 아래만 허용(다른 사용자·프로젝트 객체 경로 저장 거부).
-- - 녹음 업로드(source = 'recording')는 서버(SR)가 직접 insert 한다(05_DATA_MODEL 2절).

alter table public.voice_takes
  add column job_id uuid references public.jobs (id) on delete set null,
  add column sentences jsonb check (sentences is null or jsonb_typeof(sentences) = 'array');
alter table public.voice_takes
  add constraint voice_takes_words_array check (words is null or jsonb_typeof(words) = 'array');
create unique index voice_takes_job_id_key on public.voice_takes (job_id) where job_id is not null;
comment on column public.voice_takes.job_id is 'TTS 결과를 만든 tts 작업. 같은 작업 재시도는 이 행을 덮어쓴다(녹음은 null)';
comment on column public.voice_takes.sentences is '문장 단위 타이밍 [{i, text, start, end}] (초). 대본 줄 수와 같다';

create function private.tts_job_project(p_job_id uuid)
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
  where id = p_job_id and type = 'tts' and status = 'running';
  if v_project is null then
    raise exception '실행 중인 음성 생성 작업이 아닙니다' using errcode = '55000';
  end if;
  return v_project;
end;
$$;
revoke execute on function private.tts_job_project(uuid) from public, anon, authenticated;

-- 워커 입력: 프로젝트·소유자·승인 대본 줄
create function private.tts_job_context(p_job_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid := private.tts_job_project(p_job_id);
  v_user uuid;
  v_lines jsonb;
begin
  select user_id into v_user from public.projects where id = v_project;
  select s.lines into v_lines
  from public.scripts s
  where s.project_id = v_project and s.approved_at is not null
  order by s.version desc
  limit 1;
  return jsonb_build_object('project_id', v_project, 'user_id', v_user, 'lines', coalesce(v_lines, '[]'::jsonb));
end;
$$;
revoke execute on function private.tts_job_context(uuid) from public, anon, authenticated;

-- 워커 결과: 음성 테이크 1행(같은 작업이면 덮어씀). 반환: voice_takes.id
create function private.save_voice_take(
  p_job_id uuid, p_voice_id text, p_audio_path text, p_duration_sec numeric,
  p_sentences jsonb, p_words jsonb, p_pauses jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid := private.tts_job_project(p_job_id);
  v_user uuid;
  v_id uuid;
begin
  select user_id into v_user from public.projects where id = v_project;
  if p_audio_path is null
     or p_audio_path !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[A-Za-z0-9._-]{1,120}$'
     or not starts_with(p_audio_path, v_user::text || '/' || v_project::text || '/') then
    raise exception '음성 파일 경로가 올바르지 않습니다' using errcode = '22023';
  end if;
  if p_voice_id is null or length(p_voice_id) not between 1 and 100 then
    raise exception '목소리 ID가 올바르지 않습니다' using errcode = '22023';
  end if;
  if p_duration_sec is null or p_duration_sec <= 0 or p_duration_sec > 600 then
    raise exception '음성 길이가 올바르지 않습니다' using errcode = '22023';
  end if;
  if jsonb_typeof(p_sentences) is distinct from 'array' or jsonb_typeof(p_words) is distinct from 'array'
     or jsonb_typeof(p_pauses) is distinct from 'array' then
    raise exception '타이밍은 배열이어야 합니다' using errcode = '22023';
  end if;

  insert into public.voice_takes (project_id, job_id, voice_id, source, audio_path, duration_sec, sentences, words, pauses)
  values (v_project, p_job_id, p_voice_id, 'tts', p_audio_path, p_duration_sec, p_sentences, p_words, p_pauses)
  on conflict (job_id) where job_id is not null do update
    set voice_id = excluded.voice_id, audio_path = excluded.audio_path, duration_sec = excluded.duration_sec,
        sentences = excluded.sentences, words = excluded.words, pauses = excluded.pauses
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function private.save_voice_take(uuid, text, text, numeric, jsonb, jsonb, jsonb)
  from public, anon, authenticated;

grant execute on function private.tts_job_context(uuid) to worker_role;
grant execute on function private.save_voice_take(uuid, text, text, numeric, jsonb, jsonb, jsonb) to worker_role;
