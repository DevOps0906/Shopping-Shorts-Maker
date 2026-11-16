-- 앱(Data API)이 쓰는 읽기 RPC 2개: 조직의 대기 초대 목록(owner·admin) · 내 조직의 플랜 한도(멤버).
-- nomad_core는 API에 노출하지 않으므로 public에 둔다(nomad_audit_log와 같은 형식).
-- 되돌림: drop function public.nomad_organization_invitations(uuid), public.nomad_plan_limits(uuid, text);
begin;

-- 아직 수락되지 않은 초대(만료 포함 — 같은 이메일 재초대를 막는 행이라 owner·admin이 보고 취소할 수 있어야 한다).
-- 최소 노출: token(수락 열쇠)·초대자 이메일은 돌려주지 않는다. 초대자는 user id만(멤버 목록과 맞춰 보면 된다).
create function public.nomad_organization_invitations(target_organization uuid)
returns table (id uuid, email text, role text, invited_by uuid, expires_at timestamptz, created_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if coalesce(nomad_core.organization_role(target_organization), '') not in ('owner', 'admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
    select i.id, i.email, i.role, i.invited_by, i.expires_at, i.created_at
    from nomad_core.invitations i
    where i.organization_id = target_organization and i.accepted_at is null
    order by i.created_at desc;
end;
$$;

-- 호출자가 멤버인 조직의 현재 플랜(활성 구독, 없으면 기본 C) 한도 전체. 멤버가 아니거나 조직이 비활성이면 빈 결과.
-- 무제한 = 2147483647(plan_limits 주석). 정의가 없는 키는 행이 없다 → 앱은 생성을 거부한다(fail-closed).
create function public.nomad_plan_limits(target_organization uuid, target_product text)
returns table (plan_code text, limit_key text, limit_value integer)
language sql stable security definer set search_path = ''
as $$
  select pl.plan_code, pl.limit_key, pl.limit_value
  from nomad_core.plan_limits pl
  where nomad_core.organization_role(target_organization) is not null
    and pl.product_code = target_product
    and pl.plan_code = coalesce((
      select s.plan_code
      from nomad_core.subscriptions s
      where s.organization_id = target_organization and s.product_code = target_product
        and s.status = 'active' and s.starts_at <= now()
        and (s.ends_at is null or s.ends_at > now())
      order by s.starts_at desc
      limit 1
    ), 'C')
  order by pl.limit_key
$$;

revoke execute on function public.nomad_organization_invitations(uuid), public.nomad_plan_limits(uuid, text)
  from public, anon, authenticated;
grant execute on function public.nomad_organization_invitations(uuid), public.nomad_plan_limits(uuid, text)
  to authenticated;

commit;
