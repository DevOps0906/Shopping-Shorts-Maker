begin;

-- ── 내 초대 목록 · 초대 거절 · 멤버 역할 변경 · 멤버 내보내기 ──
-- 초대 목록·거절은 확인된 auth 이메일이 초대 이메일과 일치하는 사람만 쓸 수 있다.

create function nomad_core.my_invitations()
returns table (
  id uuid, organization_id uuid, organization_name text, email text, role text,
  token text, expires_at timestamptz, created_at timestamptz
)
language sql stable security definer set search_path = ''
as $$
  select i.id, i.organization_id, o.name, i.email, i.role, i.token, i.expires_at, i.created_at
  from nomad_core.invitations i
  join nomad_core.organizations o on o.id = i.organization_id
  join auth.users au on au.id = (select auth.uid())
  where au.email_confirmed_at is not null
    and lower(trim(au.email)) = i.email
    and i.accepted_at is null and i.expires_at > now() and o.active
  order by i.created_at desc
$$;

create function nomad_core.decline_invitation(invitation_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  me uuid := (select auth.uid());
  inv nomad_core.invitations;
  my_email text;
  my_confirmed timestamptz;
begin
  if me is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  select * into inv from nomad_core.invitations i where i.id = invitation_id for update;
  if not found or inv.accepted_at is not null then raise exception 'invalid invitation'; end if;

  select au.email, au.email_confirmed_at into my_email, my_confirmed from auth.users au where au.id = me;
  if my_confirmed is null or my_email is null or lower(trim(my_email)) <> inv.email then
    raise exception 'email mismatch' using errcode = '42501';
  end if;
  delete from nomad_core.invitations where id = inv.id;
end;
$$;

create function nomad_core.change_member_role(target_organization uuid, target_user uuid, new_role text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  caller_role text;
  old_role text;
  org nomad_core.organizations;
  used_seats int;
begin
  -- Lock first, then read the caller's role, so a concurrent demotion is seen.
  select * into org from nomad_core.organizations where id = target_organization for update;
  caller_role := nomad_core.organization_role(target_organization);
  if caller_role is null or caller_role not in ('owner', 'admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if new_role is null or new_role not in ('owner', 'admin', 'editor', 'viewer') then
    raise exception 'invalid role';
  end if;

  select m.role into old_role from nomad_core.memberships m
  where m.organization_id = target_organization and m.user_id = target_user;
  if old_role is null then raise exception 'member not found'; end if;
  if old_role = new_role then return; end if;

  if caller_role = 'admin' and (old_role = 'owner' or new_role = 'owner') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if old_role = 'owner' and not exists (
    select 1 from nomad_core.memberships m
    where m.organization_id = target_organization and m.role = 'owner' and m.user_id <> target_user
  ) then raise exception 'last owner'; end if;

  if old_role = 'viewer' and org.seat_limit is not null then
    select (select count(*) from nomad_core.memberships m
            where m.organization_id = target_organization and m.role <> 'viewer')
         + (select count(*) from nomad_core.invitations i
            where i.organization_id = target_organization and i.role <> 'viewer'
              and i.accepted_at is null and i.expires_at > now())
      into used_seats;
    if used_seats >= org.seat_limit then raise exception 'seat limit reached'; end if;
  end if;

  update nomad_core.memberships set role = new_role
  where organization_id = target_organization and user_id = target_user;
end;
$$;

create function nomad_core.remove_member(target_organization uuid, target_user uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  me uuid := (select auth.uid());
  caller_role text;
  old_role text;
begin
  -- Lock first, then read the caller's role, so a concurrent demotion is seen.
  perform 1 from nomad_core.organizations where id = target_organization for update;
  caller_role := nomad_core.organization_role(target_organization);
  if caller_role is null or (target_user <> me and caller_role not in ('owner', 'admin')) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select m.role into old_role from nomad_core.memberships m
  where m.organization_id = target_organization and m.user_id = target_user;
  if old_role is null then raise exception 'member not found'; end if;

  if caller_role = 'admin' and old_role = 'owner' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if old_role = 'owner' and not exists (
    select 1 from nomad_core.memberships m
    where m.organization_id = target_organization and m.role = 'owner' and m.user_id <> target_user
  ) then raise exception 'last owner'; end if;

  delete from nomad_core.memberships
  where organization_id = target_organization and user_id = target_user;
end;
$$;

revoke all on function
  nomad_core.my_invitations(),
  nomad_core.decline_invitation(uuid),
  nomad_core.change_member_role(uuid, uuid, text),
  nomad_core.remove_member(uuid, uuid)
from public, anon, authenticated;
grant execute on function
  nomad_core.my_invitations(),
  nomad_core.decline_invitation(uuid),
  nomad_core.change_member_role(uuid, uuid, text),
  nomad_core.remove_member(uuid, uuid)
to authenticated;

-- ── public invoker wrappers (Data API) ────────────────────
create function public.nomad_my_invitations()
returns table (
  id uuid, organization_id uuid, organization_name text, email text, role text,
  token text, expires_at timestamptz, created_at timestamptz
)
language sql stable security invoker set search_path = ''
as $$ select * from nomad_core.my_invitations() $$;

create function public.nomad_decline_invitation(invitation_id uuid)
returns void
language sql security invoker set search_path = ''
as $$ select nomad_core.decline_invitation(invitation_id) $$;

create function public.nomad_change_member_role(target_organization uuid, target_user uuid, new_role text)
returns void
language sql security invoker set search_path = ''
as $$ select nomad_core.change_member_role(target_organization, target_user, new_role) $$;

create function public.nomad_remove_member(target_organization uuid, target_user uuid)
returns void
language sql security invoker set search_path = ''
as $$ select nomad_core.remove_member(target_organization, target_user) $$;

revoke all on function
  public.nomad_my_invitations(),
  public.nomad_decline_invitation(uuid),
  public.nomad_change_member_role(uuid, uuid, text),
  public.nomad_remove_member(uuid, uuid)
from public, anon, authenticated;
grant execute on function
  public.nomad_my_invitations(),
  public.nomad_decline_invitation(uuid),
  public.nomad_change_member_role(uuid, uuid, text),
  public.nomad_remove_member(uuid, uuid)
to authenticated;

commit;
