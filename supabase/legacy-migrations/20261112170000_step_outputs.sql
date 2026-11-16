-- task-011: 단계 산출물 — topics · sources · scripts · voice_takes · renders · chat_messages
-- 근거: docs/05_DATA_MODEL.md 1·2절, 3절 해당 표, docs/planning.md 6장·15-4·17-2(D1·D5·D7·D8)
-- 소유자 경로는 모두 project_id → projects.user_id.
-- "postgres" = 마이그레이션·SECURITY DEFINER 함수(private.*) 주체. 함수 전용 열은 이 주체만 바꾼다.

-- ── topics (01 소재 후보) ─────────────────────────────────────
create table public.topics (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  round integer not null default 1 check (round >= 1),
  name text not null,
  reason text,
  evidence_urls text[] not null default '{}',
  picked boolean not null default false,
  created_at timestamptz not null default now()
);
comment on table public.topics is '01 소재 후보. 생성은 서버(SR, search_topics), 사용자는 picked만 바꾼다';
create index topics_project_id_idx on public.topics (project_id);

alter table public.topics enable row level security;
revoke all on public.topics from anon, authenticated;
grant select on public.topics to authenticated;
grant update (picked) on public.topics to authenticated;

create policy topics_select_own on public.topics
  for select to authenticated
  using (exists (select 1 from public.projects p
                 where p.id = topics.project_id and p.user_id = (select auth.uid())));
create policy topics_update_own on public.topics
  for update to authenticated
  using (exists (select 1 from public.projects p
                 where p.id = topics.project_id and p.user_id = (select auth.uid())))
  with check (exists (select 1 from public.projects p
                      where p.id = topics.project_id and p.user_id = (select auth.uid())));

-- ── sources (02 원본) ────────────────────────────────────────
create table public.sources (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  -- direct = 파일·URL 직접 추가(05_DATA_MODEL 4절 6번 확인 필요)
  platform text not null check (platform in ('tiktok', 'xiaohongshu', 'direct')),
  url text not null,
  author text not null,
  title text,
  collected_at timestamptz not null default now(),
  width integer,
  height integer,
  duration_sec numeric,
  score numeric,
  -- 비공개 버킷 sources 의 객체 경로. 목록만 수집했으면 null(D8)
  file_path text,
  checked boolean not null default false,
  used boolean not null default false,
  exclude_reason text,
  -- 함수 전용: attribution_notice(D7 출처 표기·고지 확인) · own · seller · licensed(D1)
  rights_basis text check (rights_basis in ('attribution_notice', 'own', 'seller', 'licensed')),
  rights_confirmed_by uuid references auth.users (id) on delete set null,
  rights_confirmed_at timestamptz,
  -- 삭제 예정일: 미발행 collected_at + 30일(트리거 기본값), 발행 시 서버가 발행일 + 30일로 바꾼다
  purge_after date not null,
  file_deleted_at timestamptz,
  created_at timestamptz not null default now()
);
comment on table public.sources is '02 원본. URL·작성자·수집 시각 필수, 권리 열은 함수 전용, 파일은 purge_after 뒤 삭제하고 행은 남긴다';
create index sources_project_id_idx on public.sources (project_id);
create index sources_purge_after_idx on public.sources (purge_after) where file_deleted_at is null;

alter table public.sources enable row level security;
revoke all on public.sources from anon, authenticated;
grant select on public.sources to authenticated;

create policy sources_select_own on public.sources
  for select to authenticated
  using (exists (select 1 from public.projects p
                 where p.id = sources.project_id and p.user_id = (select auth.uid())));

create function private.sources_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if current_user <> 'postgres' then
      new.rights_basis := null;
      new.rights_confirmed_by := null;
      new.rights_confirmed_at := null;
    end if;
    if new.purge_after is null then
      new.purge_after := (new.collected_at + interval '30 days')::date;
    end if;
  elsif current_user <> 'postgres'
    and (new.rights_basis, new.rights_confirmed_by, new.rights_confirmed_at)
        is distinct from (old.rights_basis, old.rights_confirmed_by, old.rights_confirmed_at) then
    raise exception '권리 열은 사용자 확인 함수로만 바꿀 수 있습니다' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke execute on function private.sources_guard() from public, anon, authenticated;

create trigger sources_guard
  before insert or update on public.sources
  for each row execute function private.sources_guard();

-- ── scripts (03 대본) ────────────────────────────────────────
create table public.scripts (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  version integer not null check (version >= 1),
  lines jsonb not null default '[]'::jsonb check (jsonb_typeof(lines) = 'array'),
  est_sec numeric,
  -- 함수 전용(03 단계 승인 시 private.approve_step 이 기록)
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  unique (project_id, version)
);
comment on table public.scripts is '03 대본 버전. 본인·서버(SR) 작성, approved_at은 함수 전용';
create index scripts_project_id_idx on public.scripts (project_id);

alter table public.scripts enable row level security;
revoke all on public.scripts from anon, authenticated;
grant select on public.scripts to authenticated;
grant insert (project_id, version, lines, est_sec) on public.scripts to authenticated;
grant update (lines, est_sec) on public.scripts to authenticated;

create policy scripts_select_own on public.scripts
  for select to authenticated
  using (exists (select 1 from public.projects p
                 where p.id = scripts.project_id and p.user_id = (select auth.uid())));
create policy scripts_insert_own on public.scripts
  for insert to authenticated
  with check (exists (select 1 from public.projects p
                      where p.id = scripts.project_id and p.user_id = (select auth.uid())));
create policy scripts_update_own on public.scripts
  for update to authenticated
  using (exists (select 1 from public.projects p
                 where p.id = scripts.project_id and p.user_id = (select auth.uid())))
  with check (exists (select 1 from public.projects p
                      where p.id = scripts.project_id and p.user_id = (select auth.uid())));

create function private.scripts_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user <> 'postgres' then
    if tg_op = 'INSERT' then
      new.approved_at := null;
    elsif new.approved_at is distinct from old.approved_at then
      raise exception 'approved_at은 단계 승인 함수로만 바꿀 수 있습니다' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function private.scripts_guard() from public, anon, authenticated;

create trigger scripts_guard
  before insert or update on public.scripts
  for each row execute function private.scripts_guard();

-- ── voice_takes (04 목소리) ──────────────────────────────────
create table public.voice_takes (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  voice_id text,
  source text not null check (source in ('tts', 'recording')),
  -- 비공개 버킷 voices 의 객체 경로
  audio_path text,
  words jsonb,
  pauses jsonb,
  duration_sec numeric,
  created_at timestamptz not null default now()
);
comment on table public.voice_takes is '04 음성 테이크. 쓰기는 서버(SR), 워커 쓰기 여부는 확인 필요(05 4절 3번)';
create index voice_takes_project_id_idx on public.voice_takes (project_id);

alter table public.voice_takes enable row level security;
revoke all on public.voice_takes from anon, authenticated;
grant select on public.voice_takes to authenticated;

create policy voice_takes_select_own on public.voice_takes
  for select to authenticated
  using (exists (select 1 from public.projects p
                 where p.id = voice_takes.project_id and p.user_id = (select auth.uid())));

-- ── renders (05 편집) ────────────────────────────────────────
create table public.renders (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  version integer not null check (version >= 1),
  cut_map jsonb,
  upscale_status text not null default 'none'
    check (upscale_status in ('none', 'queued', 'running', 'succeeded', 'failed')),
  -- clean = 워터마크 제거. 사용 원본 전부가 own·seller·licensed 일 때만 요청 가능(트리거)
  clean_status text not null default 'none'
    check (clean_status in ('none', 'queued', 'running', 'succeeded', 'failed')),
  -- 비공개 버킷 renders 의 객체 경로. 서명 URL은 웹 서버만 발급
  mp4_path text,
  created_at timestamptz not null default now(),
  unique (project_id, version)
);
comment on table public.renders is '05 렌더 버전. 쓰기는 서버(SR), 워터마크 제거는 권리 확인 원본에만';
create index renders_project_id_idx on public.renders (project_id);

alter table public.renders enable row level security;
revoke all on public.renders from anon, authenticated;
grant select on public.renders to authenticated;

create policy renders_select_own on public.renders
  for select to authenticated
  using (exists (select 1 from public.projects p
                 where p.id = renders.project_id and p.user_id = (select auth.uid())));

create function private.renders_guard_clean()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.clean_status <> 'none'
     and (tg_op = 'INSERT' or old.clean_status = 'none')
     and exists (
       select 1 from public.sources s
       where s.project_id = new.project_id
         and s.used
         and (s.rights_basis is null or s.rights_basis not in ('own', 'seller', 'licensed'))
     ) then
    raise exception '권리를 확인하지 않은 원본(출처 표기 포함)이 있어 워터마크 제거를 할 수 없습니다'
      using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke execute on function private.renders_guard_clean() from public, anon, authenticated;

create trigger renders_guard_clean
  before insert or update on public.renders
  for each row execute function private.renders_guard_clean();

-- ── chat_messages (제작 파트너) ──────────────────────────────
create table public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  role text not null check (role in ('user', 'ai')),
  kind text not null default 'text' check (kind in ('screen', 'text', 'ai')),
  text text,
  -- 외부 글은 데이터로만(17-7)
  payload jsonb,
  created_at timestamptz not null default now()
);
comment on table public.chat_messages is '제작 파트너 대화. 사용자는 role=user만 쓰고 AI 응답은 서버(SR)가 쓴다';
create index chat_messages_project_id_created_at_idx on public.chat_messages (project_id, created_at);

alter table public.chat_messages enable row level security;
revoke all on public.chat_messages from anon, authenticated;
grant select on public.chat_messages to authenticated;
grant insert (project_id, role, kind, text, payload) on public.chat_messages to authenticated;

create policy chat_messages_select_own on public.chat_messages
  for select to authenticated
  using (exists (select 1 from public.projects p
                 where p.id = chat_messages.project_id and p.user_id = (select auth.uid())));
create policy chat_messages_insert_own_user on public.chat_messages
  for insert to authenticated
  with check (
    role = 'user'
    and exists (select 1 from public.projects p
                where p.id = chat_messages.project_id and p.user_id = (select auth.uid()))
  );
