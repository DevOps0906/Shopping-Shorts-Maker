-- task-022a 보안 리뷰 반영(🟡1·❓):
-- 1) 늦게 도착한 invalid_grant 가 그사이 재연결로 받은 새 토큰을 지우지 않게, 갱신에 쓴 토큰 버전(oauth_token_ref)과
--    현재 값이 같을 때만 reconnect_required·Vault 삭제(조건부). 버전이 되도록 새 토큰은 항상 새 secret 으로 저장한다.
-- 2) access token 조회는 사용자 소유 확인을 필수로(youtube_token_for).
-- 270000 의 youtube_refresh_token(해제 경로)·youtube_clear_token 은 그대로 둔다.

-- ── 연결 저장 교체: 새 갱신 토큰 = 새 secret(이전 secret 삭제) → oauth_token_ref 가 토큰 버전 ──
create or replace function private.youtube_save_connection(p_user_id uuid, p_account_id uuid, p_channel_id text,
                                                           p_refresh_token text, p_scopes text[])
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acc public.accounts;
  v_ref uuid;
  v_old uuid;
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
    v_old := v_ref;
    v_ref := vault.create_secret(v_token, null, 'youtube refresh token');
  end if;

  update public.accounts a
  set external_channel_id = p_channel_id,
      oauth_token_ref = v_ref,
      status = case when v_ref is null then 'reconnect_required' else 'connected' end
  where a.id = p_account_id;
  if v_old is not null then
    delete from vault.secrets s where s.id = v_old;
  end if;
  return case when v_ref is null then 'reconnect_required' else 'connected' end;
end;
$$;
revoke execute on function private.youtube_save_connection(uuid, uuid, text, text, text[])
  from public, anon, authenticated, service_role;

-- ── access token 발급용: 소유자 확인 필수 + 토큰 버전 함께 ──
create function private.youtube_token_for(p_user_id uuid, p_account_id uuid)
returns table (token_ref uuid, refresh_token text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acc public.accounts;
begin
  select a.* into v_acc from public.accounts a
  where a.id = p_account_id and a.platform = 'youtube';
  if v_acc.id is null or p_user_id is null or v_acc.user_id <> p_user_id then
    raise exception '연결할 수 없는 계정입니다' using errcode = '42501';
  end if;
  if v_acc.oauth_token_ref is null then
    return;
  end if;
  return query
  select d.id, d.decrypted_secret from vault.decrypted_secrets d where d.id = v_acc.oauth_token_ref;
end;
$$;
revoke execute on function private.youtube_token_for(uuid, uuid) from public, anon, authenticated, service_role;

-- invalid_grant: 갱신에 쓴 버전이 아직 현재일 때만 재연결 필요·Vault 삭제. 반환 = 바꿨는지
create function private.youtube_expire_token(p_account_id uuid, p_token_ref uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_token_ref is null then
    return false;
  end if;
  update public.accounts a
  set oauth_token_ref = null, status = 'reconnect_required'
  where a.id = p_account_id and a.platform = 'youtube' and a.oauth_token_ref = p_token_ref;
  if not found then
    return false;
  end if;
  delete from vault.secrets s where s.id = p_token_ref;
  return true;
end;
$$;
revoke execute on function private.youtube_expire_token(uuid, uuid) from public, anon, authenticated, service_role;

create function public.youtube_token_for(p_user_id uuid, p_account_id uuid)
returns table (token_ref uuid, refresh_token text)
language sql
security definer
set search_path = ''
as $$
  select * from private.youtube_token_for(p_user_id, p_account_id);
$$;

create function public.youtube_expire_token(p_account_id uuid, p_token_ref uuid)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select private.youtube_expire_token(p_account_id, p_token_ref);
$$;

revoke execute on function public.youtube_token_for(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.youtube_expire_token(uuid, uuid) from public, anon, authenticated;
grant execute on function public.youtube_token_for(uuid, uuid) to service_role;
grant execute on function public.youtube_expire_token(uuid, uuid) to service_role;
comment on function public.youtube_token_for(uuid, uuid) is
  'YouTube 갱신 토큰 원문 + 버전(서버 전용, 소유자 확인). 브라우저·로그로 내보내지 않는다';
