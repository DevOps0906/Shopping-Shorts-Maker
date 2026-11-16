-- task-022a: 행 삭제 시 Vault 정리 트리거 수정(20261112270000).
-- plpgsql 은 CASE 안의 old.<열> 도 테이블마다 해석하므로 accounts 에서 old.secret_ref 가 오류였다 → 분기마다 따로 읽는다.
create or replace function private.vault_secret_cleanup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ref uuid;
begin
  if tg_table_name = 'accounts' then
    v_ref := old.oauth_token_ref;
  elsif tg_table_name = 'api_keys' then
    v_ref := old.secret_ref;
  end if;
  if v_ref is not null then
    delete from vault.secrets s where s.id = v_ref;
  end if;
  return old;
end;
$$;
revoke execute on function private.vault_secret_cleanup() from public, anon, authenticated, service_role;
