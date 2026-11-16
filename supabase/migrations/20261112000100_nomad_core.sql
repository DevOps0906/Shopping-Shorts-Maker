begin;

create schema nomad_core;
revoke all on schema nomad_core from public, anon, authenticated;
grant usage on schema nomad_core to authenticated, service_role;

create table nomad_core.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  locale text,
  created_at timestamptz not null default now()
);

create table nomad_core.products (
  code text primary key,
  name text not null
);

create table nomad_core.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table nomad_core.memberships (
  organization_id uuid not null references nomad_core.organizations(id),
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'admin', 'editor', 'viewer')),
  primary key (organization_id, user_id)
);
create index memberships_by_user on nomad_core.memberships(user_id, organization_id);

create table nomad_core.platform_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  scope text not null check (scope in ('operations', 'billing')),
  active boolean not null default true
);

create table nomad_core.plans (
  product_code text not null references nomad_core.products(code),
  code text not null check (code in ('A', 'B', 'C')),
  name text not null,
  primary key (product_code, code)
);

create table nomad_core.features (
  product_code text not null references nomad_core.products(code),
  code text not null,
  name text not null,
  primary key (product_code, code)
);

create table nomad_core.plan_features (
  product_code text not null,
  plan_code text not null,
  feature_code text not null,
  primary key (product_code, plan_code, feature_code),
  foreign key (product_code, plan_code) references nomad_core.plans(product_code, code),
  foreign key (product_code, feature_code) references nomad_core.features(product_code, code)
);

create table nomad_core.subscriptions (
  organization_id uuid not null references nomad_core.organizations(id),
  product_code text not null,
  plan_code text not null,
  status text not null check (status in ('active', 'inactive')),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  primary key (organization_id, product_code),
  foreign key (product_code, plan_code) references nomad_core.plans(product_code, code),
  check (ends_at is null or ends_at > starts_at)
);

create table nomad_core.addon_products (
  product_code text not null,
  sku text not null,
  feature_code text not null,
  for_sale boolean not null default true,
  primary key (product_code, sku),
  unique (product_code, sku, feature_code),
  foreign key (product_code, feature_code) references nomad_core.features(product_code, code)
);

create table nomad_core.addon_purchases (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id),
  product_code text not null,
  sku text not null,
  feature_code text not null,
  provider text not null,
  provider_purchase_id text not null,
  status text not null check (status in ('pending', 'paid', 'refunded', 'cancelled')),
  created_at timestamptz not null default now(),
  unique (provider, provider_purchase_id),
  unique (id, organization_id, product_code, feature_code),
  foreign key (product_code, sku, feature_code)
    references nomad_core.addon_products(product_code, sku, feature_code)
);

create table nomad_core.feature_grants (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id),
  product_code text not null,
  feature_code text not null,
  purchase_id uuid unique,
  source text not null check (source in ('purchase', 'manual')),
  starts_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  check ((source = 'purchase') = (purchase_id is not null)),
  check (expires_at is null or expires_at > starts_at),
  foreign key (product_code, feature_code) references nomad_core.features(product_code, code),
  foreign key (purchase_id, organization_id, product_code, feature_code)
    references nomad_core.addon_purchases(id, organization_id, product_code, feature_code)
);
create index active_grants_lookup
  on nomad_core.feature_grants(organization_id, product_code, feature_code)
  where revoked_at is null;

-- Core tables are server-only. End users call scoped functions.
revoke all on all tables in schema nomad_core from public, anon, authenticated;
grant select, insert, update, delete on all tables in schema nomad_core to service_role;

do $$
declare table_name text;
begin
  for table_name in
    select tablename from pg_catalog.pg_tables where schemaname = 'nomad_core'
  loop
    execute format('alter table nomad_core.%I enable row level security', table_name);
  end loop;
end;
$$;

create function nomad_core.organization_role(target_organization uuid)
returns text
language sql stable security definer set search_path = ''
as $$
  select m.role
  from nomad_core.memberships m
  join nomad_core.organizations o on o.id = m.organization_id
  where m.organization_id = target_organization and m.user_id = (select auth.uid())
    and o.active
$$;

create function nomad_core.has_feature(
  target_organization uuid, target_product text, target_feature text
)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select nomad_core.organization_role(target_organization) is not null and (
    exists (
      select 1
      from nomad_core.subscriptions s
      join nomad_core.plan_features pf
        on pf.product_code = s.product_code and pf.plan_code = s.plan_code
      where s.organization_id = target_organization and s.product_code = target_product
        and pf.feature_code = target_feature and s.status = 'active'
        and s.starts_at <= now() and (s.ends_at is null or s.ends_at > now())
    ) or exists (
      select 1
      from nomad_core.feature_grants g
      left join nomad_core.addon_purchases p on p.id = g.purchase_id
      where g.organization_id = target_organization and g.product_code = target_product
        and g.feature_code = target_feature and g.revoked_at is null
        and g.starts_at <= now() and (g.expires_at is null or g.expires_at > now())
        and (g.source = 'manual' or p.status = 'paid')
    )
  )
$$;

create function nomad_core.dashboard_features(target_organization uuid, target_product text)
returns table (feature_code text, title text, unlocked boolean, upgrade_to text, addon_sku text, can_purchase boolean)
language sql stable security definer set search_path = ''
as $$
  select f.code, f.name,
         nomad_core.has_feature(target_organization, target_product, f.code),
         upg.plan_code, addon.sku,
         coalesce(nomad_core.organization_role(target_organization) in ('owner', 'admin'), false)
  from nomad_core.features f
  left join nomad_core.subscriptions s
    on s.organization_id = target_organization and s.product_code = f.product_code
   and s.status = 'active' and s.starts_at <= now() and (s.ends_at is null or s.ends_at > now())
  left join lateral (
    select pf.plan_code
    from nomad_core.plan_features pf
    where pf.product_code = f.product_code and pf.feature_code = f.code
      and (s.plan_code is null or pf.plan_code < s.plan_code)
    order by pf.plan_code desc
    limit 1
  ) upg on true
  left join lateral (
    select a.sku
    from nomad_core.addon_products a
    where a.product_code = f.product_code and a.feature_code = f.code and a.for_sale
    order by a.sku
    limit 1
  ) addon on true
  where f.product_code = target_product
    and nomad_core.organization_role(target_organization) is not null
  order by f.code
$$;

revoke execute on all functions in schema nomad_core from public, anon, authenticated;
grant execute on function nomad_core.organization_role(uuid) to authenticated;
grant execute on function nomad_core.has_feature(uuid, text, text) to authenticated;
grant execute on function nomad_core.dashboard_features(uuid, text) to authenticated;

-- Expose only this invoker wrapper through the Data API.
create function public.nomad_dashboard_features(target_organization uuid, target_product text)
returns table (feature_code text, title text, unlocked boolean, upgrade_to text, addon_sku text, can_purchase boolean)
language sql stable security invoker set search_path = ''
as $$
  select * from nomad_core.dashboard_features(target_organization, target_product)
$$;
revoke execute on function public.nomad_dashboard_features(uuid, text) from public, anon, authenticated;
grant execute on function public.nomad_dashboard_features(uuid, text) to authenticated;

commit;
