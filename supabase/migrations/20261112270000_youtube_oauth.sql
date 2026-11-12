-- task-022a: YouTube 공식 OAuth 연결·재연결·해제 + 갱신 토큰 Vault 저장
-- 근거: docs/04_API.md YouTube 2절(최소 범위 3개, state + PKCE, 해제 시 폐기 후 Vault 삭제),
--       docs/05_DATA_MODEL.md accounts·api_keys, docs/planning.md 17-8, docs/w4/threat-022a.md
-- 원칙: 토큰 원문은 Vault 에만. 모든 함수는 private SECURITY DEFINER 본체 + public 래퍼(service_role 만 EXECUTE).
--       anon·authenticated 는 래퍼·본체·oauth_states·vault 어디에도 닿지 못한다.

-- ── 1) accounts.external_channel_id (서버 전용) ────────────────
alter table public.accounts add column external_channel_id text;
comment on column public.accounts.external_channel_id is
  '플랫폼 채널 id(YouTube channels.list mine=true). 서버(SR)만 쓰고 authenticated 는 읽지 못한다. 재연결 시 다른 채널이면 거부';
-- 같은 채널은 한 계정에만(전역, 팀장 잠정 결정)
create unique index accounts_platform_external_channel_idx
  on public.accounts (platform, external_channel_id) where external_channel_id is not null;
-- 열 GRANT 는 열 이름을 나열하는 방식이라 새 열은 authenticated 에 자동으로 열리지 않는다(2중으로 회수).
revoke select (external_channel_id), insert (external_channel_id), update (external_channel_id)
  on public.accounts from anon, authenticated;

-- 사용자 INSERT 에서 서버 전용 열 초기값 강제(160200 함수에 external_channel_id 추가)
create or replace function private.accounts_force_server_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('postgres', 'service_role', 'supabase_admin') then
    new.oauth_token_ref := null;
    new.status := 'reconnect_required';
    new.external_channel_id := null;
  end if;
  return new;
end;
$$;
revoke execute on function private.accounts_force_server_columns() from public, anon, authenticated;

-- ── 2) oauth_states: state·PKCE verifier 서버 보관(10분, 1회) ──
create table public.oauth_states (
  -- state 원문은 브라우저 왕복값이라 해시(sha256 hex)만 저장
  state_hash text primary key check (state_hash ~ '^[0-9a-f]{64}$'),
  user_id uuid not null references auth.users (id) on delete cascade,
  account_id uuid not null,
  provider text not null default 'youtube' check (provider = 'youtube'),
  -- PKCE verifier 원문. 서버만 읽는다(RLS 정책 없음 + 모든 역할 GRANT 회수, 함수로만 접근)
  code_verifier text not null check (code_verifier ~ '^[A-Za-z0-9._~-]{43,128}$'),
  expires_at timestamptz not null default now() + interval '10 minutes',
  used_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (account_id, user_id) references public.accounts (id, user_id) on delete cascade
);
comment on table public.oauth_states is
  'OAuth 시작 요청의 state·PKCE verifier(10분·1회 사용). 사용자 접근 불가, private 함수로만 읽고 쓴다';
create index oauth_states_user_id_idx on public.oauth_states (user_id);
create index oauth_states_account_id_idx on public.oauth_states (account_id, user_id);

alter table public.oauth_states enable row level security;
-- 정책 없음 = authenticated 는 RLS 로도 0행. 테이블 GRANT 는 service_role 까지 회수(함수 경유만)
revoke all on public.oauth_states from public, anon, authenticated, service_role;

-- ── 3) 시작: 계정 소유 확인 + state 저장 ─────────────────────
create function private.oauth_state_create(p_user_id uuid, p_account_id uuid,
                                           p_state_hash text, p_verifier text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.accounts a
                 where a.id = p_account_id and a.user_id = p_user_id and a.platform = 'youtube') then
    raise exception '연결할 수 없는 계정입니다' using errcode = '42501';
  end if;
  -- 쓴 것·만료된 것은 정리, 진행 중인 시작 요청은 사용자당 10개까지
  delete from public.oauth_states s
  where s.user_id = p_user_id and (s.used_at is not null or s.expires_at <= now());
  if (select count(*) from public.oauth_states s where s.user_id = p_user_id) >= 10 then
    raise exception '연결 요청이 너무 많습니다. 잠시 후 다시 시도하세요' using errcode = '54000';
  end if;
  insert into public.oauth_states (state_hash, user_id, account_id, code_verifier)
  values (p_state_hash, p_user_id, p_account_id, p_verifier);
end;
$$;
revoke execute on function private.oauth_state_create(uuid, uuid, text, text) from public, anon, authenticated, service_role;

-- 콜백: state 1회 소모. 없음·재사용·만료·다른 사용자는 0행(소모 표시는 남는다)
create function private.oauth_state_consume(p_user_id uuid, p_state_hash text)
returns table (account_id uuid, code_verifier text)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v public.oauth_states;
begin
  update public.oauth_states s
  set used_at = now()
  where s.state_hash = p_state_hash and s.used_at is null
  returning s.* into v;
  if v.state_hash is null or v.expires_at <= now() or v.user_id is distinct from p_user_id then
    return;
  end if;
  return query select v.account_id, v.code_verifier;
end;
$$;
revoke execute on function private.oauth_state_consume(uuid, text) from public, anon, authenticated, service_role;

-- ── 4) 연결 저장: 채널 고정 · 필수 범위 · 빈 갱신 토큰 미덮어쓰기 ──
-- 반환: 'connected' | 'reconnect_required'(저장된 토큰도 새 토큰도 없음)
-- 오류: 42501 소유 아님 · OA001 다른 채널 · OA002 필수 범위 누락 · 23505 다른 계정에 연결된 채널
create function private.youtube_save_connection(p_user_id uuid, p_account_id uuid, p_channel_id text,
                                                p_refresh_token text, p_scopes text[])
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acc public.accounts;
  v_ref uuid;
  v_token text := nullif(btrim(coalesce(p_refresh_token, '')), '');
begin
  select a.* into v_acc from public.accounts a
  where a.id = p_account_id and a.user_id = p_user_id and a.platform = 'youtube'
  for update;
  if v_acc.id is null then
    raise exception '연결할 수 없는 계정입니다' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_channel_id, '')), '') is null then
    raise exception '채널 정보가 없습니다' using errcode = '22023';
  end if;
  if v_acc.external_channel_id is not null and v_acc.external_channel_id <> p_channel_id then
    raise exception '이 계정에 연결된 채널과 다른 채널입니다' using errcode = 'OA001';
  end if;
  if not (coalesce(p_scopes, '{}') @> array[
            'https://www.googleapis.com/auth/youtube.upload',
            'https://www.googleapis.com/auth/youtube.readonly',
            'https://www.googleapis.com/auth/yt-analytics.readonly']) then
    raise exception '필수 권한이 빠졌습니다' using errcode = 'OA002';
  end if;

  v_ref := v_acc.oauth_token_ref;
  if v_ref is not null and not exists (select 1 from vault.secrets s where s.id = v_ref) then
    v_ref := null;
  end if;
  if v_token is not null then
    if v_ref is null then
      v_ref := vault.create_secret(v_token, null, 'youtube refresh token');
    else
      perform vault.update_secret(v_ref, v_token);
    end if;
  end if;

  update public.accounts a
  set external_channel_id = p_channel_id,
      oauth_token_ref = v_ref,
      status = case when v_ref is null then 'reconnect_required' else 'connected' end
  where a.id = p_account_id;
  return case when v_ref is null then 'reconnect_required' else 'connected' end;
end;
$$;
revoke execute on function private.youtube_save_connection(uuid, uuid, text, text, text[])
  from public, anon, authenticated, service_role;

-- 갱신 토큰 원문(서버 전용). p_user_id 를 주면 소유자까지 확인(해제 경로)
create function private.youtube_refresh_token(p_account_id uuid, p_user_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acc public.accounts;
begin
  select a.* into v_acc from public.accounts a
  where a.id = p_account_id and a.platform = 'youtube';
  if v_acc.id is null or (p_user_id is not null and v_acc.user_id <> p_user_id) then
    raise exception '연결할 수 없는 계정입니다' using errcode = '42501';
  end if;
  if v_acc.oauth_token_ref is null then
    return null;
  end if;
  return (select d.decrypted_secret from vault.decrypted_secrets d where d.id = v_acc.oauth_token_ref);
end;
$$;
revoke execute on function private.youtube_refresh_token(uuid, uuid) from public, anon, authenticated, service_role;

-- 토큰 폐기·해제: Vault 삭제 + 재연결 필요. p_user_id 가 null 이면 서버 내부(invalid_grant) 경로
create function private.youtube_clear_token(p_account_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acc public.accounts;
begin
  select a.* into v_acc from public.accounts a
  where a.id = p_account_id and a.platform = 'youtube'
  for update;
  if v_acc.id is null or (p_user_id is not null and v_acc.user_id <> p_user_id) then
    raise exception '연결할 수 없는 계정입니다' using errcode = '42501';
  end if;
  update public.accounts a
  set oauth_token_ref = null, status = 'reconnect_required'
  where a.id = p_account_id;
  if v_acc.oauth_token_ref is not null then
    delete from vault.secrets s where s.id = v_acc.oauth_token_ref;
  end if;
end;
$$;
revoke execute on function private.youtube_clear_token(uuid, uuid) from public, anon, authenticated, service_role;

-- ── 5) 행 삭제 시 Vault secret 정리(accounts·api_keys) ───────
create function private.vault_secret_cleanup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ref uuid;
begin
  v_ref := case tg_table_name
             when 'accounts' then old.oauth_token_ref
             when 'api_keys' then old.secret_ref
           end;
  if v_ref is not null then
    delete from vault.secrets s where s.id = v_ref;
  end if;
  return old;
end;
$$;
revoke execute on function private.vault_secret_cleanup() from public, anon, authenticated, service_role;

create trigger accounts_vault_cleanup
  after delete on public.accounts
  for each row execute function private.vault_secret_cleanup();
create trigger api_keys_vault_cleanup
  after delete on public.api_keys
  for each row execute function private.vault_secret_cleanup();

-- ── 6) public 래퍼: service_role(서버 코드)만 ────────────────
-- 래퍼도 SECURITY DEFINER 라 service_role 에 private EXECUTE 를 주지 않는다.
create function public.oauth_state_create(p_user_id uuid, p_account_id uuid, p_state_hash text, p_verifier text)
returns void
language sql
security definer
set search_path = ''
as $$
  select private.oauth_state_create(p_user_id, p_account_id, p_state_hash, p_verifier);
$$;

create function public.oauth_state_consume(p_user_id uuid, p_state_hash text)
returns table (account_id uuid, code_verifier text)
language sql
security definer
set search_path = ''
as $$
  select * from private.oauth_state_consume(p_user_id, p_state_hash);
$$;

create function public.youtube_save_connection(p_user_id uuid, p_account_id uuid, p_channel_id text,
                                               p_refresh_token text, p_scopes text[])
returns text
language sql
security definer
set search_path = ''
as $$
  select private.youtube_save_connection(p_user_id, p_account_id, p_channel_id, p_refresh_token, p_scopes);
$$;

create function public.youtube_refresh_token(p_account_id uuid, p_user_id uuid default null)
returns text
language sql
security definer
set search_path = ''
as $$
  select private.youtube_refresh_token(p_account_id, p_user_id);
$$;

create function public.youtube_clear_token(p_account_id uuid, p_user_id uuid default null)
returns void
language sql
security definer
set search_path = ''
as $$
  select private.youtube_clear_token(p_account_id, p_user_id);
$$;

revoke execute on function public.oauth_state_create(uuid, uuid, text, text) from public, anon, authenticated;
revoke execute on function public.oauth_state_consume(uuid, text) from public, anon, authenticated;
revoke execute on function public.youtube_save_connection(uuid, uuid, text, text, text[]) from public, anon, authenticated;
revoke execute on function public.youtube_refresh_token(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.youtube_clear_token(uuid, uuid) from public, anon, authenticated;
grant execute on function public.oauth_state_create(uuid, uuid, text, text) to service_role;
grant execute on function public.oauth_state_consume(uuid, text) to service_role;
grant execute on function public.youtube_save_connection(uuid, uuid, text, text, text[]) to service_role;
grant execute on function public.youtube_refresh_token(uuid, uuid) to service_role;
grant execute on function public.youtube_clear_token(uuid, uuid) to service_role;

comment on function public.youtube_refresh_token(uuid, uuid) is
  'YouTube 갱신 토큰 원문(서버 전용, service_role). 브라우저·로그로 내보내지 않는다';
