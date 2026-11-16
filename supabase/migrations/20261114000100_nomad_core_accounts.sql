begin;

-- New functions in nomad_core are not executable unless granted explicitly.
alter default privileges in schema nomad_core revoke execute on functions from public;

-- ── organizations: kind · creator · seat limit ─────────────
alter table nomad_core.organizations
  add column kind text not null default 'team' check (kind in ('personal', 'team')),
  add column created_by uuid references auth.users(id) on delete set null,
  add column seat_limit int check (seat_limit is null or seat_limit > 0);

-- ── invitations ────────────────────────────────────────────
create table nomad_core.invitations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id),
  email text not null check (email = lower(trim(email)) and email <> ''),
  role text not null check (role in ('admin', 'editor', 'viewer')),
  token text not null unique default encode(extensions.gen_random_bytes(32), 'hex'),
  invited_by uuid references auth.users(id) on delete set null,
  expires_at timestamptz not null default now() + interval '7 days',
  accepted_at timestamptz,
  accepted_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index invitations_by_organization on nomad_core.invitations(organization_id);
create unique index invitations_pending_email
  on nomad_core.invitations(organization_id, email) where accepted_at is null;

-- ── credit ledger ──────────────────────────────────────────
create table nomad_core.credit_ledger (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id),
  product_code text references nomad_core.products(code),
  delta int not null check (delta <> 0),
  reason text not null,
  idempotency_key text not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id, idempotency_key)
);

comment on table nomad_core.invitations is '팀 조직 초대. 서버 전용, create/accept/revoke_invitation 함수로만 다룬다.';
comment on table nomad_core.credit_ledger is '조직 크레딧 원장(추가 전용). 잔액 = sum(delta), spend/grant_credits로만 기록.';

alter table nomad_core.invitations enable row level security;
alter table nomad_core.credit_ledger enable row level security;
revoke all on nomad_core.invitations, nomad_core.credit_ledger from public, anon, authenticated;
grant select, insert, update, delete on nomad_core.invitations, nomad_core.credit_ledger to service_role;

-- ── signup: profile + personal organization + owner ───────
create function nomad_core.create_personal_organization(target_user uuid, display_name text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare new_org uuid;
begin
  insert into nomad_core.organizations (name, kind, created_by, seat_limit)
  values (display_name, 'personal', target_user, 1)
  returning id into new_org;
  insert into nomad_core.memberships (organization_id, user_id, role)
  values (new_org, target_user, 'owner');
  return new_org;
end;
$$;

create function nomad_core.handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare display_name text;
begin
  if coalesce(new.is_anonymous, false) then
    return new;
  end if;
  display_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'name'), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    '내 워크스페이스'
  );
  insert into nomad_core.profiles (user_id, display_name)
  values (new.id, display_name)
  on conflict (user_id) do nothing;
  perform nomad_core.create_personal_organization(new.id, display_name);
  return new;
end;
$$;

create trigger nomad_on_auth_user_created
  after insert on auth.users
  for each row execute function nomad_core.handle_new_user();

-- Backfill: existing non-anonymous users without any membership.
do $$
declare u record; display_name text;
begin
  for u in
    select au.id, au.email, au.raw_user_meta_data
    from auth.users au
    where not coalesce(au.is_anonymous, false)
      and not exists (select 1 from nomad_core.memberships m where m.user_id = au.id)
  loop
    display_name := coalesce(
      nullif(trim(u.raw_user_meta_data ->> 'name'), ''),
      nullif(split_part(coalesce(u.email, ''), '@', 1), ''),
      '내 워크스페이스'
    );
    insert into nomad_core.profiles (user_id, display_name)
    values (u.id, display_name)
    on conflict (user_id) do nothing;
    perform nomad_core.create_personal_organization(u.id, display_name);
  end loop;
end;
$$;

-- ── team organization ─────────────────────────────────────
create function nomad_core.create_team_organization(name text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare new_org uuid; me uuid := (select auth.uid());
begin
  if me is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  if nullif(trim(name), '') is null then raise exception 'organization name required'; end if;
  insert into nomad_core.organizations (name, kind, created_by, seat_limit)
  values (trim(name), 'team', me, null)
  returning id into new_org;
  insert into nomad_core.memberships (organization_id, user_id, role)
  values (new_org, me, 'owner');
  return new_org;
end;
$$;

create function nomad_core.my_organizations()
returns table (id uuid, name text, kind text, role text)
language sql stable security definer set search_path = ''
as $$
  select o.id, o.name, o.kind, m.role
  from nomad_core.memberships m
  join nomad_core.organizations o on o.id = m.organization_id
  where m.user_id = (select auth.uid()) and o.active
  order by o.kind, o.created_at
$$;

-- ── invitations ───────────────────────────────────────────
create function nomad_core.create_invitation(target_organization uuid, invitee_email text, invitee_role text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  org nomad_core.organizations;
  normalized text := lower(trim(invitee_email));
  used_seats int;
  new_token text;
begin
  if coalesce(nomad_core.organization_role(target_organization), '') not in ('owner', 'admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if invitee_role is null or invitee_role not in ('admin', 'editor', 'viewer') then
    raise exception 'invalid role';
  end if;
  if normalized is null or normalized = '' then raise exception 'email required'; end if;

  -- Lock the organization so concurrent invitations see the same seat count.
  select * into org from nomad_core.organizations where id = target_organization for update;
  if org.kind = 'personal' then raise exception 'upgrade required'; end if;

  if exists (
    select 1 from nomad_core.memberships m
    join auth.users au on au.id = m.user_id
    where m.organization_id = target_organization and lower(trim(au.email)) = normalized
  ) then raise exception 'already a member'; end if;

  if invitee_role <> 'viewer' and org.seat_limit is not null then
    select (select count(*) from nomad_core.memberships m
            where m.organization_id = target_organization and m.role <> 'viewer')
         + (select count(*) from nomad_core.invitations i
            where i.organization_id = target_organization and i.role <> 'viewer'
              and i.accepted_at is null and i.expires_at > now())
      into used_seats;
    if used_seats >= org.seat_limit then raise exception 'seat limit reached'; end if;
  end if;

  insert into nomad_core.invitations (organization_id, email, role, invited_by)
  values (target_organization, normalized, invitee_role, (select auth.uid()))
  returning token into new_token;
  return new_token;
end;
$$;

create function nomad_core.accept_invitation(invite_token text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  me uuid := (select auth.uid());
  inv nomad_core.invitations;
  org nomad_core.organizations;
  my_email text;
  my_confirmed timestamptz;
  used_seats int;
begin
  if me is null then raise exception 'not authenticated' using errcode = '42501'; end if;

  select * into inv from nomad_core.invitations where token = invite_token for update;
  if not found or inv.accepted_at is not null then raise exception 'invalid invitation'; end if;
  if inv.expires_at <= now() then raise exception 'invitation expired'; end if;

  select * into org from nomad_core.organizations where id = inv.organization_id for update;
  if not org.active then raise exception 'organization inactive'; end if;

  select au.email, au.email_confirmed_at into my_email, my_confirmed
  from auth.users au where au.id = me;
  if my_confirmed is null then raise exception 'email not confirmed'; end if;
  if my_email is null or lower(trim(my_email)) <> inv.email then raise exception 'email mismatch'; end if;

  if exists (
    select 1 from nomad_core.memberships m
    where m.organization_id = inv.organization_id and m.user_id = me
  ) then raise exception 'already a member'; end if;

  if inv.role <> 'viewer' and org.seat_limit is not null then
    select count(*) into used_seats from nomad_core.memberships m
    where m.organization_id = inv.organization_id and m.role <> 'viewer';
    if used_seats >= org.seat_limit then raise exception 'seat limit reached'; end if;
  end if;

  insert into nomad_core.memberships (organization_id, user_id, role)
  values (inv.organization_id, me, inv.role);
  update nomad_core.invitations set accepted_at = now(), accepted_by = me where id = inv.id;
  return inv.organization_id;
end;
$$;

create function nomad_core.revoke_invitation(invitation_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare target_organization uuid;
begin
  select i.organization_id into target_organization
  from nomad_core.invitations i where i.id = invitation_id;
  if target_organization is null
     or coalesce(nomad_core.organization_role(target_organization), '') not in ('owner', 'admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  delete from nomad_core.invitations where id = invitation_id;
end;
$$;

-- ── credits ───────────────────────────────────────────────
create function nomad_core.credit_balance(target_organization uuid)
returns int
language sql stable security definer set search_path = ''
as $$
  select case when nomad_core.organization_role(target_organization) is null then null
    else (select coalesce(sum(l.delta), 0)::int from nomad_core.credit_ledger l
          where l.organization_id = target_organization)
  end
$$;

-- Shared ledger write. Not granted to any API role; callers check permissions first.
create function nomad_core.write_credit_entry(
  target_organization uuid, entry_delta int, entry_reason text, entry_key text, entry_product text
)
returns int
language plpgsql security definer set search_path = ''
as $$
declare existing nomad_core.credit_ledger; balance int;
begin
  if entry_reason is null or entry_key is null then raise exception 'reason and idempotency key required'; end if;
  -- Serialize ledger writes per organization (balance check + insert).
  perform pg_advisory_xact_lock(hashtextextended(target_organization::text, 0));

  select * into existing from nomad_core.credit_ledger
  where organization_id = target_organization and idempotency_key = entry_key;
  select coalesce(sum(delta), 0)::int into balance
  from nomad_core.credit_ledger where organization_id = target_organization;

  if existing.id is not null then
    if existing.delta = entry_delta and existing.reason = entry_reason
       and existing.product_code is not distinct from entry_product then
      return balance;
    end if;
    raise exception 'idempotency key reused with different request';
  end if;

  if balance + entry_delta < 0 then raise exception 'insufficient credits'; end if;
  insert into nomad_core.credit_ledger
    (organization_id, product_code, delta, reason, idempotency_key, created_by)
  values (target_organization, entry_product, entry_delta, entry_reason, entry_key, (select auth.uid()));
  return balance + entry_delta;
end;
$$;

create function nomad_core.spend_credits(
  target_organization uuid, amount int, reason text, idempotency_key text, product text default null
)
returns int
language plpgsql security definer set search_path = ''
as $$
begin
  if amount is null or amount <= 0 then raise exception 'amount must be positive'; end if;
  if coalesce(nomad_core.organization_role(target_organization), '') not in ('owner', 'admin', 'editor') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return nomad_core.write_credit_entry(target_organization, -amount, reason, idempotency_key, product);
end;
$$;

create function nomad_core.grant_credits(
  target_organization uuid, amount int, reason text, idempotency_key text, product text default null
)
returns int
language plpgsql security definer set search_path = ''
as $$
begin
  if amount is null or amount <= 0 then raise exception 'amount must be positive'; end if;
  return nomad_core.write_credit_entry(target_organization, amount, reason, idempotency_key, product);
end;
$$;

-- ── function privileges ───────────────────────────────────
revoke all on function
  nomad_core.create_personal_organization(uuid, text),
  nomad_core.handle_new_user(),
  nomad_core.create_team_organization(text),
  nomad_core.my_organizations(),
  nomad_core.create_invitation(uuid, text, text),
  nomad_core.accept_invitation(text),
  nomad_core.revoke_invitation(uuid),
  nomad_core.credit_balance(uuid),
  nomad_core.write_credit_entry(uuid, int, text, text, text),
  nomad_core.spend_credits(uuid, int, text, text, text),
  nomad_core.grant_credits(uuid, int, text, text, text)
from public, anon, authenticated;

grant execute on function
  nomad_core.create_team_organization(text),
  nomad_core.my_organizations(),
  nomad_core.create_invitation(uuid, text, text),
  nomad_core.accept_invitation(text),
  nomad_core.revoke_invitation(uuid),
  nomad_core.credit_balance(uuid),
  nomad_core.spend_credits(uuid, int, text, text, text)
to authenticated;
grant execute on function nomad_core.grant_credits(uuid, int, text, text, text) to service_role;

-- ── public invoker wrappers (Data API) ────────────────────
create function public.nomad_create_team_organization(name text)
returns uuid
language sql security invoker set search_path = ''
as $$ select nomad_core.create_team_organization(name) $$;

create function public.nomad_my_organizations()
returns table (id uuid, name text, kind text, role text)
language sql stable security invoker set search_path = ''
as $$ select * from nomad_core.my_organizations() $$;

create function public.nomad_create_invitation(target_organization uuid, invitee_email text, invitee_role text)
returns text
language sql security invoker set search_path = ''
as $$ select nomad_core.create_invitation(target_organization, invitee_email, invitee_role) $$;

create function public.nomad_accept_invitation(invite_token text)
returns uuid
language sql security invoker set search_path = ''
as $$ select nomad_core.accept_invitation(invite_token) $$;

create function public.nomad_revoke_invitation(invitation_id uuid)
returns void
language sql security invoker set search_path = ''
as $$ select nomad_core.revoke_invitation(invitation_id) $$;

create function public.nomad_credit_balance(target_organization uuid)
returns int
language sql stable security invoker set search_path = ''
as $$ select nomad_core.credit_balance(target_organization) $$;

create function public.nomad_spend_credits(
  target_organization uuid, amount int, reason text, idempotency_key text, product text default null
)
returns int
language sql security invoker set search_path = ''
as $$ select nomad_core.spend_credits(target_organization, amount, reason, idempotency_key, product) $$;

revoke all on function
  public.nomad_create_team_organization(text),
  public.nomad_my_organizations(),
  public.nomad_create_invitation(uuid, text, text),
  public.nomad_accept_invitation(text),
  public.nomad_revoke_invitation(uuid),
  public.nomad_credit_balance(uuid),
  public.nomad_spend_credits(uuid, int, text, text, text)
from public, anon, authenticated;
grant execute on function
  public.nomad_create_team_organization(text),
  public.nomad_my_organizations(),
  public.nomad_create_invitation(uuid, text, text),
  public.nomad_accept_invitation(text),
  public.nomad_revoke_invitation(uuid),
  public.nomad_credit_balance(uuid),
  public.nomad_spend_credits(uuid, int, text, text, text)
to authenticated;

commit;
