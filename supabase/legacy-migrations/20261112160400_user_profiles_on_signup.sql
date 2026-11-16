-- task-010: 가입(auth.users INSERT) 시 본인 user_profiles 행 자동 생성
-- 근거: docs/05_DATA_MODEL.md 1절(SECURITY DEFINER 조건), 3절 user_profiles
-- 트리거 전용 함수라 노출 스키마 래퍼(api.*)는 두지 않고 EXECUTE를 모두 회수한다.

create function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.user_profiles (user_id, email)
  values (new.id, new.email)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

revoke execute on function private.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created_user_profile
  after insert on auth.users
  for each row execute function private.handle_new_user();
