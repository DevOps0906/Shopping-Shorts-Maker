-- 코어 웨이브 3단계 C7: 음성(STT·TTS) 공용 테이블 voice_sessions·voice_jobs. 서버(service_role) 쓰기 전용.
-- 원본: platform-docs _supabase-modular 0009_core_voice.sql(core.voice_sessions·voice_jobs·expire_voice_audio).
-- 원본과 다른 점
--   · core.apps → nomad_core.products(code), org_id → organization_id, credit_ledger_id는 uuid(이 저장소 원장 키).
--   · 제공자(stt/tts/provider)는 nomad_core.ai_providers(id) FK(on delete restrict), conversation_id는 같은 조직 ai_conversations 복합 FK.
--   · 테이블 직접 접근은 service_role만. 사용자 읽기는 public.nomad_my_voice_sessions·nomad_my_voice_jobs(본인 행 + 조직 멤버).
--   · 사용자 삭제 시 그 사용자의 세션·작업은 cascade 삭제(개인정보). 기능 키 기본값은 'voice'.
--   · 녹음 만료는 2단계(expire_voice_audio 요청 → Storage 삭제 → confirm_voice_audio_purged 확정).
--   · voice-audio Storage 버킷·정책은 만들지 않는다(노출 면 — 별도 결정). 녹음 경로 열람은 서버가 서명 URL로.
-- 되돌림: drop function public.nomad_my_voice_jobs(uuid, integer), public.nomad_my_voice_sessions(uuid, integer),
--   nomad_core.confirm_voice_audio_purged(uuid[]), nomad_core.expire_voice_audio(integer); drop table nomad_core.voice_jobs, nomad_core.voice_sessions;
begin;

create table nomad_core.voice_sessions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id),
  product_code text not null references nomad_core.products(code),
  user_id uuid references auth.users(id) on delete cascade,  -- 비로그인 방문자 상담이면 null. 탈퇴 시 본인 세션 삭제(개인정보)
  conversation_id uuid,
  visitor_key text check (visitor_key is null or length(visitor_key) between 1 and 200),
  stt_provider text references nomad_core.ai_providers(id) on delete restrict,
  tts_provider text references nomad_core.ai_providers(id) on delete restrict,
  total_seconds numeric(10, 2) not null default 0 check (total_seconds >= 0),
  status text not null default 'active' check (status in ('active', 'ended')),
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (id, organization_id),
  constraint voice_sessions_owner_check check (user_id is not null or visitor_key is not null),
  -- 같은 조직 대화만 연결(ai_conversations의 unique (id, organization_id)를 쓴다). 대화가 지워지면 연결만 끊는다
  foreign key (conversation_id, organization_id) references nomad_core.ai_conversations(id, organization_id) on delete set null (conversation_id)
);
create index voice_sessions_user_idx on nomad_core.voice_sessions (organization_id, user_id, started_at desc);
create index voice_sessions_conversation_idx on nomad_core.voice_sessions (conversation_id) where conversation_id is not null;
comment on table nomad_core.voice_sessions is
  '음성 대화 세션(제품 slug = product_code). 서버 전용 쓰기, 사용자 읽기는 public.nomad_my_voice_sessions(본인 세션만).';

create table nomad_core.voice_jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id),
  product_code text not null references nomad_core.products(code),
  user_id uuid references auth.users(id) on delete cascade,  -- 탈퇴 시 본인 작업 삭제(개인정보)
  session_id uuid,
  feature text not null default 'voice' check (length(feature) between 1 and 60),  -- 기능 키(기본 voice). 세부 용도 예: dictation, lecture_note, narration
  kind text not null check (kind in ('stt', 'tts')),
  provider text not null references nomad_core.ai_providers(id) on delete restrict,
  model text,
  voice_id text,  -- TTS 보이스(상용 보이스 id 또는 오픈소스 화자 키)
  status text not null default 'queued' check (status in ('queued', 'running', 'succeeded', 'failed', 'expired')),
  duration_seconds numeric(10, 2) check (duration_seconds is null or duration_seconds >= 0),
  characters integer check (characters is null or characters >= 0),
  store_audio boolean not null default false,
  consent_at timestamptz,  -- 녹음 저장 동의 시각(저장하는 기능은 필수)
  consent_kind text check (consent_kind is null or consent_kind in ('self', 'third_party_notice')),
  notice_version text,     -- 동의한 고지문 버전
  storage_path text,
  expires_at timestamptz,
  audio_purge_requested_at timestamptz,  -- 만료 정리 요청 시각(Storage 삭제 대기). confirm_voice_audio_purged 후 status = expired
  fallback_from text,      -- 대체 실행이면 원래 제공자
  credits integer not null default 0 check (credits >= 0),
  credit_ledger_id uuid references nomad_core.credit_ledger(id),
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint voice_jobs_store_check check (not store_audio or (storage_path is not null and expires_at is not null)),
  constraint voice_jobs_no_store_check check (store_audio or storage_path is null),
  constraint voice_jobs_consent_check check (not store_audio or (consent_at is not null and consent_kind is not null)),
  foreign key (session_id, organization_id) references nomad_core.voice_sessions(id, organization_id) on delete set null (session_id)
);
create index voice_jobs_org_idx on nomad_core.voice_jobs (organization_id, product_code, created_at desc);
create index voice_jobs_user_idx on nomad_core.voice_jobs (organization_id, user_id, created_at desc);
create index voice_jobs_session_idx on nomad_core.voice_jobs (session_id) where session_id is not null;
create index voice_jobs_expiry_idx on nomad_core.voice_jobs (expires_at) where store_audio and status <> 'expired';
comment on table nomad_core.voice_jobs is
  'STT·TTS 작업 기록(크레딧 연결, 녹음 보관 동의·만료). 서버 전용 쓰기, 사용자 읽기는 public.nomad_my_voice_jobs(본인 작업만).';

create trigger voice_sessions_touch_updated_at
  before update on nomad_core.voice_sessions
  for each row execute function nomad_core.touch_updated_at();
create trigger voice_jobs_touch_updated_at
  before update on nomad_core.voice_jobs
  for each row execute function nomad_core.touch_updated_at();

-- 사용자 정책 없음 = authenticated·anon 직접 접근 0. service_role만 직접 쓴다(원본도 쓰기는 service_role).
alter table nomad_core.voice_sessions enable row level security;
alter table nomad_core.voice_jobs enable row level security;
revoke all on nomad_core.voice_sessions, nomad_core.voice_jobs from public, anon, authenticated;
grant select, insert, update, delete on nomad_core.voice_sessions, nomad_core.voice_jobs to service_role;

-- 만료 녹음 정리 2단계(서버·스케줄러). Storage 삭제 전에 expired로 확정하지 않는다(중단·삭제 실패 시 녹음 잔존 방지).
--   1) expire_voice_audio: 만료됐고 아직 expired가 아닌 작업에 audio_purge_requested_at을 찍고 지울 경로를 돌려준다.
--      확정 전이면 재호출 때 다시 돌려준다(요청 시각이 오래된 것부터 — 실패 행이 새 행을 막지 않게 매번 시각 갱신).
--   2) 서버가 Storage API로 객체를 지운 뒤 confirm_voice_audio_purged(ids)로 expired 확정(storage.objects 직접 삭제 금지).
create function nomad_core.expire_voice_audio(p_limit integer default 500)
returns table (job_id uuid, storage_path text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not nomad_core.is_service_caller() then
    raise exception 'expire_voice_audio: server only' using errcode = '42501';
  end if;
  return query
    with due as (
      select j.id
      from nomad_core.voice_jobs j
      where j.store_audio and j.status <> 'expired' and j.expires_at <= now()
      order by j.audio_purge_requested_at nulls first, j.expires_at
      limit greatest(1, least(coalesce(p_limit, 500), 5000))
      for update skip locked
    )
    update nomad_core.voice_jobs v
       set audio_purge_requested_at = clock_timestamp()
      from due
     where v.id = due.id
    returning v.id, v.storage_path;
end;
$$;

-- Storage 삭제가 끝난 작업만 expired로 확정한다. 정리 요청이 없던 작업·이미 확정된 작업은 건너뛴다(반복 안전). 반환: 확정한 행 수.
create function nomad_core.confirm_voice_audio_purged(p_job_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare v_count integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'confirm_voice_audio_purged: server only' using errcode = '42501';
  end if;
  update nomad_core.voice_jobs v
     set status = 'expired', error = coalesce(v.error, 'audio expired')
   where v.id = any(coalesce(p_job_ids, '{}'))
     and v.store_audio and v.status <> 'expired' and v.audio_purge_requested_at is not null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ── 사용자 읽기 (본인 행 + 활성 조직 멤버) ─────────────────
create function public.nomad_my_voice_sessions(target_organization uuid, page_size integer default 50)
returns table (id uuid, product_code text, conversation_id uuid, stt_provider text, tts_provider text,
               total_seconds numeric, status text, started_at timestamptz, ended_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if nomad_core.organization_role(target_organization) is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
    select s.id, s.product_code, s.conversation_id, s.stt_provider, s.tts_provider,
           s.total_seconds, s.status, s.started_at, s.ended_at
    from nomad_core.voice_sessions s
    where s.organization_id = target_organization and s.user_id = (select auth.uid())
    order by s.started_at desc, s.id
    limit least(greatest(coalesce(page_size, 50), 1), 200);
end;
$$;

-- 녹음 경로·오류 원문·크레딧 원장 id는 주지 않는다(서버가 서명 URL로 따로 준다).
create function public.nomad_my_voice_jobs(target_organization uuid, page_size integer default 50)
returns table (id uuid, product_code text, session_id uuid, feature text, kind text, provider text, status text,
               duration_seconds numeric, characters integer, store_audio boolean, expires_at timestamptz,
               credits integer, created_at timestamptz, updated_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if nomad_core.organization_role(target_organization) is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
    select j.id, j.product_code, j.session_id, j.feature, j.kind, j.provider, j.status,
           j.duration_seconds, j.characters, j.store_audio, j.expires_at, j.credits, j.created_at, j.updated_at
    from nomad_core.voice_jobs j
    where j.organization_id = target_organization and j.user_id = (select auth.uid())
    order by j.created_at desc, j.id
    limit least(greatest(coalesce(page_size, 50), 1), 200);
end;
$$;

-- ── 함수 권한 ─────────────────────────────────────────────
revoke all on function
  nomad_core.expire_voice_audio(integer),
  nomad_core.confirm_voice_audio_purged(uuid[]),
  public.nomad_my_voice_sessions(uuid, integer),
  public.nomad_my_voice_jobs(uuid, integer)
from public, anon, authenticated;
grant execute on function nomad_core.expire_voice_audio(integer), nomad_core.confirm_voice_audio_purged(uuid[]) to service_role;
grant execute on function public.nomad_my_voice_sessions(uuid, integer), public.nomad_my_voice_jobs(uuid, integer)
  to authenticated;

commit;
