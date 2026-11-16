-- 소셜 로그인 가입 보강: 이름 우선순위 확장(full_name·nickname) + 사진(avatar_url·picture, https만)
-- + 익명 → 정식 전환 때 같은 프로비저닝. 20261114000100_nomad_core_accounts.sql 뒤에 적용된다.
-- 되돌림: 이전 정의의 nomad_core.handle_new_user()로 create or replace, drop trigger nomad_on_auth_user_upgraded; drop function nomad_core.provision_user(uuid, text, jsonb);
begin;

-- 프로필·1인 조직 생성(멱등). 가입·전환 트리거가 공유한다. 어떤 API 역할에도 grant 없음.
create function nomad_core.provision_user(target_user uuid, user_email text, user_meta jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
declare display_name text; photo text;
begin
  display_name := left(coalesce(
    nullif(trim(user_meta ->> 'name'), ''),
    nullif(split_part(coalesce(user_email, ''), '@', 1), ''),
    nullif(trim(user_meta ->> 'full_name'), ''),
    nullif(trim(user_meta ->> 'nickname'), ''),
    '내 워크스페이스'
  ), 100);
  photo := coalesce(
    case when user_meta ->> 'avatar_url' ~ '^https://' then user_meta ->> 'avatar_url' end,
    case when user_meta ->> 'picture' ~ '^https://' then user_meta ->> 'picture' end
  );
  if char_length(photo) > 2048 or photo ~ '[\s\x00-\x1f]' then photo := null; end if;

  insert into nomad_core.profiles (user_id, display_name, avatar_url)
  values (target_user, display_name, photo)
  on conflict (user_id) do nothing;

  if not exists (select 1 from nomad_core.memberships m where m.user_id = target_user) then
    perform nomad_core.create_personal_organization(target_user, display_name);
  end if;
end;
$$;
revoke all on function nomad_core.provision_user(uuid, text, jsonb) from public, anon, authenticated;

create or replace function nomad_core.handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if coalesce(new.is_anonymous, false) then
    return new;
  end if;
  perform nomad_core.provision_user(new.id, new.email, new.raw_user_meta_data);
  return new;
end;
$$;

create function nomad_core.handle_user_upgraded()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform nomad_core.provision_user(new.id, new.email, new.raw_user_meta_data);
  return new;
end;
$$;
revoke all on function nomad_core.handle_user_upgraded() from public, anon, authenticated;

create trigger nomad_on_auth_user_upgraded
  after update of is_anonymous on auth.users
  for each row
  when (old.is_anonymous is true and new.is_anonymous is not true)
  execute function nomad_core.handle_user_upgraded();

commit;
