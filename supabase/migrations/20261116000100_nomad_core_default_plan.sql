-- 구독이 없는 조직은 C 플랜으로 취급(has_feature·dashboard_features) + 개인형 잠금 함수 user_has_feature.
-- 되돌림: has_feature·dashboard_features 본문은 20261112000100_nomad_core.sql 참조(create or replace로 복원) 후 drop function nomad_core.user_has_feature(text, text), nomad_core.org_has_feature(uuid, text, text);
begin;

-- 조직의 이용권만 본다(멤버십 확인 없음). 사용자 JWT가 없는 서버·워커(service_role) 전용.
create function nomad_core.org_has_feature(
  target_organization uuid, target_product text, target_feature text
)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
      select 1 from nomad_core.organizations o
      where o.id = target_organization and o.active
    ) and (
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
    ) or (
      not exists (
        select 1
        from nomad_core.subscriptions s
        where s.organization_id = target_organization and s.product_code = target_product
          and s.status = 'active' and s.starts_at <= now() and (s.ends_at is null or s.ends_at > now())
      ) and exists (
        select 1
        from nomad_core.plan_features pf
        where pf.product_code = target_product and pf.plan_code = 'C'
          and pf.feature_code = target_feature
      )
    )
  )
$$;
revoke execute on function nomad_core.org_has_feature(uuid, text, text) from public, anon, authenticated;
grant execute on function nomad_core.org_has_feature(uuid, text, text) to service_role;

-- 사용자 문맥: 호출자가 활성 조직의 멤버일 때만 org_has_feature 결과를 돌려준다.
create or replace function nomad_core.has_feature(
  target_organization uuid, target_product text, target_feature text
)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select nomad_core.organization_role(target_organization) is not null
    and nomad_core.org_has_feature(target_organization, target_product, target_feature)
$$;

create or replace function nomad_core.dashboard_features(target_organization uuid, target_product text)
returns table (feature_code text, title text, unlocked boolean, upgrade_to text, addon_sku text, can_purchase boolean)
language sql stable security definer set search_path = ''
as $$
  select f.code, f.name,
         nomad_core.has_feature(target_organization, target_product, f.code),
         case when nomad_core.has_feature(target_organization, target_product, f.code)
              then null else upg.plan_code end,
         addon.sku,
         coalesce(nomad_core.organization_role(target_organization) in ('owner', 'admin'), false)
  from nomad_core.features f
  left join nomad_core.subscriptions s
    on s.organization_id = target_organization and s.product_code = f.product_code
   and s.status = 'active' and s.starts_at <= now() and (s.ends_at is null or s.ends_at > now())
  left join lateral (
    select pf.plan_code
    from nomad_core.plan_features pf
    where pf.product_code = f.product_code and pf.feature_code = f.code
      and pf.plan_code < coalesce(s.plan_code, 'C')
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

-- 개인형: 호출자가 owner인 활성 조직 중 하나라도 기능이 열려 있으면 true.
-- 구독한 조직의 owner 본인만 혜택을 받고, admin·editor·viewer로 초대된 멤버에게는 공유되지 않는다.
create function nomad_core.user_has_feature(target_product text, target_feature text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from nomad_core.memberships m
    join nomad_core.organizations o on o.id = m.organization_id
    where m.user_id = (select auth.uid()) and m.role = 'owner' and o.active
      and nomad_core.has_feature(m.organization_id, target_product, target_feature)
  )
$$;
revoke execute on function nomad_core.user_has_feature(text, text) from public, anon, authenticated;
grant execute on function nomad_core.user_has_feature(text, text) to authenticated;

commit;
