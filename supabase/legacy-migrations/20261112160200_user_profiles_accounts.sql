-- task-010: user_profiles · accounts
-- 근거: docs/05_DATA_MODEL.md 1·2절, 3절 accounts·user_profiles, docs/planning.md 12장·17-4

create table public.user_profiles (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  name text,
  email text,
  default_tone text,
  default_lang text,
  subtitle_style text,
  default_len smallint not null default 15 check (default_len in (15, 20)),
  notify_done boolean not null default true,
  notify_weekly boolean not null default false
);

comment on table public.user_profiles is '환경설정 기본값(planning 13장). 본인 읽기·쓰기';

alter table public.user_profiles enable row level security;

revoke all on public.user_profiles from anon, authenticated;
grant select, insert, update on public.user_profiles to authenticated;

create policy user_profiles_select_own on public.user_profiles
  for select to authenticated using (user_id = (select auth.uid()));
create policy user_profiles_insert_own on public.user_profiles
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy user_profiles_update_own on public.user_profiles
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create table public.accounts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  -- youtube·instagram·tiktok = 업로드, xiaohongshu = 수집
  platform text not null check (platform in ('youtube', 'instagram', 'tiktok', 'xiaohongshu')),
  channel_name text not null,
  category_id uuid references public.categories (id),
  tone text,
  target text,
  weekly_goal integer not null default 0 check (weekly_goal >= 0),
  is_default boolean not null default false,
  -- Vault secret id. 원문은 Vault에만. 서버(SR)만 쓰고, authenticated는 읽지도 못한다.
  oauth_token_ref uuid,
  -- 연결됨 · 재연결 필요. 서버(SR)만 쓴다.
  status text not null default 'reconnect_required'
    check (status in ('connected', 'reconnect_required')),
  created_at timestamptz not null default now(),
  -- projects 복합 FK (account_id, user_id) 대상
  unique (id, user_id)
);

comment on table public.accounts is '운영 채널(다중 계정, planning 12장). oauth_token_ref는 Vault id이며 authenticated 읽기 불가';

create index accounts_user_id_idx on public.accounts (user_id);
create index accounts_category_id_idx on public.accounts (category_id);
-- 사용자당 기본 채널 1개(12장)
create unique index accounts_one_default_per_user_idx on public.accounts (user_id) where is_default;

alter table public.accounts enable row level security;

-- 열 단위 권한: oauth_token_ref 는 읽기 제외, oauth_token_ref·status 는 INSERT·UPDATE 제외
revoke all on public.accounts from anon, authenticated;
grant select (id, user_id, platform, channel_name, category_id, tone, target, weekly_goal,
              is_default, status, created_at)
  on public.accounts to authenticated;
grant insert (user_id, platform, channel_name, category_id, tone, target, weekly_goal, is_default)
  on public.accounts to authenticated;
grant update (channel_name, category_id, tone, target, weekly_goal, is_default)
  on public.accounts to authenticated;

create policy accounts_select_own on public.accounts
  for select to authenticated using (user_id = (select auth.uid()));
create policy accounts_insert_own on public.accounts
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy accounts_update_own on public.accounts
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- 서버 전용 열 초기값 강제(열 GRANT 회수에 더한 2중 방어)
create function private.accounts_force_server_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- 서버(SR)·마이그레이션 주체가 아니면 강제. 트리거 안에서 private 함수를 부르지 않는다(authenticated에 USAGE 없음).
  if current_user not in ('postgres', 'service_role', 'supabase_admin') then
    new.oauth_token_ref := null;
    new.status := 'reconnect_required';
  end if;
  return new;
end;
$$;
revoke execute on function private.accounts_force_server_columns() from public, anon, authenticated;

create trigger accounts_force_server_columns
  before insert on public.accounts
  for each row execute function private.accounts_force_server_columns();
