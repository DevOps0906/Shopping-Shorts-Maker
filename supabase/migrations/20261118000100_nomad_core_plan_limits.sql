-- 플랜별 수량 한도(plan_limits) + 한도 조회 함수 org_plan_limit(서버) · plan_limit(사용자 문맥).
-- 되돌림: drop function nomad_core.plan_limit(uuid, text, text), nomad_core.org_plan_limit(uuid, text, text); drop table nomad_core.plan_limits;
begin;

create table nomad_core.plan_limits (
  product_code text not null,
  plan_code text not null,
  limit_key text not null check (limit_key ~ '^[a-z][a-z0-9_]*$'),
  limit_value integer not null check (limit_value >= 0),
  primary key (product_code, plan_code, limit_key),
  foreign key (product_code, plan_code) references nomad_core.plans(product_code, code)
);
comment on table nomad_core.plan_limits is
  '플랜별 수량 한도 카탈로그(서버 전용, 정책 없음). 무제한 = 2147483647(integer 최대) — 앱은 이 값과 같으면 "무제한"으로 표시. -1·null 금지.';

alter table nomad_core.plan_limits enable row level security;
revoke all on nomad_core.plan_limits from public, anon, authenticated;
grant select, insert, update, delete on nomad_core.plan_limits to service_role;

-- 조직의 한도만 본다(멤버십 확인 없음). 서버·워커(service_role) 전용.
-- null = 조직 없음·비활성·정의 없음 → 호출자는 생성을 거부한다(fail-closed).
create function nomad_core.org_plan_limit(
  target_organization uuid, target_product text, target_key text
)
returns integer
language sql stable security definer set search_path = ''
as $$
  select pl.limit_value
  from nomad_core.organizations o
  join nomad_core.plan_limits pl
    on pl.product_code = target_product and pl.limit_key = target_key
   and pl.plan_code = coalesce((
     select s.plan_code
     from nomad_core.subscriptions s
     where s.organization_id = target_organization and s.product_code = target_product
       and s.status = 'active' and s.starts_at <= now()
       and (s.ends_at is null or s.ends_at > now())
     order by s.starts_at desc
     limit 1
   ), 'C')
  where o.id = target_organization and o.active
$$;
revoke execute on function nomad_core.org_plan_limit(uuid, text, text) from public, anon, authenticated;
grant execute on function nomad_core.org_plan_limit(uuid, text, text) to service_role;

-- 사용자 문맥: 호출자가 조직 멤버일 때만 org_plan_limit 결과를 돌려준다.
create function nomad_core.plan_limit(
  target_organization uuid, target_product text, target_key text
)
returns integer
language sql stable security definer set search_path = ''
as $$
  select case when nomad_core.organization_role(target_organization) is null then null
         else nomad_core.org_plan_limit(target_organization, target_product, target_key) end
$$;
revoke execute on function nomad_core.plan_limit(uuid, text, text) from public, anon, authenticated;
grant execute on function nomad_core.plan_limit(uuid, text, text) to authenticated;

commit;
