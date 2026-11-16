-- 프로필 확장(아바타·테마·수정 시각) + touch_updated_at 트리거 함수 + 소셜 로그인 중계용 oauth_states.
-- 되돌림: drop function nomad_core.consume_oauth_state(text), nomad_core.set_my_theme(text), nomad_core.my_profile(), public.nomad_set_my_theme(text), public.nomad_my_profile();
--        drop table nomad_core.oauth_states; alter table nomad_core.profiles drop column avatar_url, drop column theme, drop column updated_at;
begin;

alter default privileges in schema nomad_core revoke execute on functions from public;

-- 행 수정 시 updated_at을 now()로 맞추는 공용 트리거 함수. 직접 호출 대상이 아니므로 grant 없음.
create function nomad_core.touch_updated_at()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
revoke all on function nomad_core.touch_updated_at() from public, anon, authenticated;

-- ── profiles ───────────────────────────────────────────────
alter table nomad_core.profiles
  add column avatar_url text,
  add column theme text not null default 'system',
  add column updated_at timestamptz not null default now();

alter table nomad_core.profiles
  add constraint profiles_avatar_url_check
    check (avatar_url is null or (avatar_url ~ '^https://' and char_length(avatar_url) <= 2048)),
  add constraint profiles_theme_check check (theme in ('system', 'light', 'dark')),
  add constraint profiles_display_name_length
    check (display_name is null or char_length(display_name) <= 100) not valid;
alter table nomad_core.profiles validate constraint profiles_display_name_length;

create trigger profiles_touch_updated_at
  before update on nomad_core.profiles
  for each row execute function nomad_core.touch_updated_at();

comment on column nomad_core.profiles.avatar_url is '소셜 로그인 사진 주소(https만, 2048자 이하).';
comment on column nomad_core.profiles.theme is '화면 테마: system · light · dark.';

-- 테이블은 서버 전용이므로 본인 프로필 읽기·테마 변경은 함수로만 연다.
create function nomad_core.my_profile()
returns table (display_name text, avatar_url text, theme text, locale text)
language sql stable security definer set search_path = ''
as $$
  select p.display_name, p.avatar_url, p.theme, p.locale
  from nomad_core.profiles p
  where p.user_id = (select auth.uid())
$$;

create function nomad_core.set_my_theme(new_theme text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare me uuid := (select auth.uid());
begin
  if me is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  if new_theme is null or new_theme not in ('system', 'light', 'dark') then
    raise exception 'invalid theme';
  end if;
  update nomad_core.profiles set theme = new_theme where user_id = me;
  if not found then raise exception 'profile not found'; end if;
end;
$$;

revoke all on function nomad_core.my_profile(), nomad_core.set_my_theme(text) from public, anon, authenticated;
grant execute on function nomad_core.my_profile(), nomad_core.set_my_theme(text) to authenticated;

create function public.nomad_my_profile()
returns table (display_name text, avatar_url text, theme text, locale text)
language sql stable security invoker set search_path = ''
as $$ select * from nomad_core.my_profile() $$;

create function public.nomad_set_my_theme(new_theme text)
returns void
language sql security invoker set search_path = ''
as $$ select nomad_core.set_my_theme(new_theme) $$;

revoke all on function public.nomad_my_profile(), public.nomad_set_my_theme(text) from public, anon, authenticated;
grant execute on function public.nomad_my_profile(), public.nomad_set_my_theme(text) to authenticated;

-- ── oauth_states: 외부 로그인 중계(Edge Function)용 1회용 state ─
create table nomad_core.oauth_states (
  state text primary key check (char_length(state) between 32 and 256),
  provider text not null,
  redirect_to text not null
    check (redirect_to ~ '^/(?![/\\])[^\x00-\x20\\]*$' and char_length(redirect_to) <= 2048),
  nonce text,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index oauth_states_by_expiry on nomad_core.oauth_states(expires_at);
comment on table nomad_core.oauth_states is '소셜 로그인 중계용 1회용 state(서버 전용). redirect_to는 상대 경로만 허용(열린 리다이렉트 방지).';

alter table nomad_core.oauth_states enable row level security;
revoke all on nomad_core.oauth_states from public, anon, authenticated;
grant select, insert, update, delete on nomad_core.oauth_states to service_role;

-- state를 1회 소비한다. 없거나 만료면 null. 호출 때 만료 행도 정리한다.
create function nomad_core.consume_oauth_state(target_state text)
returns table (provider text, redirect_to text, nonce text)
language plpgsql security definer set search_path = ''
as $$
begin
  delete from nomad_core.oauth_states s where s.expires_at <= now() and s.state <> target_state;
  return query
    delete from nomad_core.oauth_states s
    where s.state = target_state and s.expires_at > now()
    returning s.provider, s.redirect_to, s.nonce;
  delete from nomad_core.oauth_states s where s.state = target_state;
end;
$$;
revoke all on function nomad_core.consume_oauth_state(text) from public, anon, authenticated;
grant execute on function nomad_core.consume_oauth_state(text) to service_role;

commit;
