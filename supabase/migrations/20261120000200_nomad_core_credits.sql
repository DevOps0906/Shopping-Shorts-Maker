-- 코어 웨이브 1단계 C1: 크레딧 원장 보강 — 버킷(plan·pack)·참조(ref_type·ref_id)·환불·월 지급분 만료. 서버(service_role) 전용 함수.
-- 원본: platform-docs _supabase-modular 0003_core_credits.sql(consume/refund_credits, plan 먼저→pack 순 차감, 환불 상한).
-- 규칙
--   · 백필 없음. bucket null = pack(기존 행). 차감은 plan 먼저→pack 순이며, 두 버킷에 걸치면 같은 멱등 키로 버킷별 행 2개를 쓴다.
--   · 사용자 키(spend·grant·consume)는 (조직, 키, 버킷) 단위로 유일하고, 같은 키의 행 묶음 전체를 한 요청으로 비교한다.
--   · 서버 생성 행(plan 지급·plan 만료·환불)은 예약 접두사 'nomad:' 키를 쓰고, 사용자 경로는 이 접두사를 거부한다(선점 방지).
--     plan 지급·만료의 멱등은 (조직, ref_type, ref_id=기간) 부분 유니크 인덱스, 환불은 (대표 consume 행, 환불 키)다.
--   · 기간: 열린 plan 기간은 조직당 최대 1개(지급됐고 만료 행이 없는 기간). 새 기간 지급은 열린 기간의 남은 plan을 먼저 만료한다.
--     만료 행은 0이어도 완료 표시로 남는다(delta 0은 plan_expire에만 허용).
--   · 기존 spend_credits·grant_credits·write_credit_entry·public.nomad_spend_credits 서명은 그대로다.
-- 되돌림: drop function nomad_core.expire_plan_credits(uuid, text), nomad_core.refund_credits(uuid, text, text, integer),
--   nomad_core.consume_credits(uuid, integer, text, text, text, text, text), nomad_core.grant_plan_credits(uuid, integer, text, text, text),
--   nomad_core.close_plan_period(uuid, text), nomad_core.open_plan_period(uuid),
--   nomad_core.post_credit_entry(uuid, integer, text, text, text, text, text), nomad_core.credit_bucket_balances(uuid);
--   write_credit_entry를 20261114000100 정의로 되돌린 뒤 drop index credit_ledger_key_bucket, credit_ledger_plan_period_key;
--   delta 검사를 (delta <> 0)으로, unique (organization_id, idempotency_key) 제약을 되살리고
--   drop column requested_amount, period_key, refund_of, ref_id, ref_type, bucket.
begin;

-- ── 컬럼 (nullable 추가, 백필 없음) ───────────────────────
alter table nomad_core.credit_ledger
  add column bucket text check (bucket in ('plan', 'pack')),
  add column ref_type text check (ref_type is null or length(ref_type) between 1 and 60),
  add column ref_id text check (ref_id is null or length(ref_id) between 1 and 200),
  add column refund_of uuid references nomad_core.credit_ledger(id),
  add column period_key text check (period_key is null or length(period_key) between 1 and 60),
  add column requested_amount integer check (requested_amount is null or requested_amount > 0);

comment on column nomad_core.credit_ledger.bucket is 'plan = 월 지급분(만료 대상), pack = 단품 충전분. null(기존 행) = pack.';
comment on column nomad_core.credit_ledger.refund_of is '환불 행이 가리키는 원 consume 묶음의 대표 행(plan 행 우선).';
comment on column nomad_core.credit_ledger.period_key is 'plan 행이 속한 지급 기간(지급·만료·plan 차감·plan 환불).';
comment on column nomad_core.credit_ledger.requested_amount is '환불 요청액(null = 남은 전액). 환불 재호출 멱등 비교용.';

-- 만료 완료 표시(0원 만료)를 위해 delta 0은 plan_expire 행에만 허용한다.
alter table nomad_core.credit_ledger drop constraint credit_ledger_delta_check;
alter table nomad_core.credit_ledger add constraint credit_ledger_delta_check check (delta <> 0 or ref_type is not distinct from 'plan_expire');

-- 버킷 2행 차감을 위해 멱등 유일성을 (조직, 키, 버킷)으로 넓힌다. 기존 행은 모두 null(=pack)이라 충돌 없음.
alter table nomad_core.credit_ledger drop constraint credit_ledger_organization_id_idempotency_key_key;
create unique index credit_ledger_key_bucket
  on nomad_core.credit_ledger (organization_id, idempotency_key, coalesce(bucket, 'pack'));
-- plan 지급·만료는 조직·기간당 1행.
create unique index credit_ledger_plan_period_key
  on nomad_core.credit_ledger (organization_id, ref_type, ref_id) where ref_type in ('plan_period', 'plan_expire');
create index credit_ledger_ref_idx on nomad_core.credit_ledger (organization_id, ref_type, ref_id);
create index credit_ledger_refund_of_idx on nomad_core.credit_ledger (refund_of) where refund_of is not null;

comment on table nomad_core.credit_ledger is
  '조직 크레딧 원장(추가 전용). 잔액 = sum(delta), 버킷 잔액 = bucket별 sum(null=pack). spend/grant/consume/refund/expire 함수로만 기록.';

-- ── 내부 도우미 (API 역할에 주지 않음) ─────────────────────
create function nomad_core.credit_bucket_balances(target_organization uuid, out plan_balance integer, out pack_balance integer)
language sql stable security definer set search_path = ''
as $$
  select coalesce(sum(l.delta) filter (where l.bucket = 'plan'), 0)::integer,
         coalesce(sum(l.delta) filter (where l.bucket is distinct from 'plan'), 0)::integer
  from nomad_core.credit_ledger l where l.organization_id = target_organization
$$;

-- 열린 plan 기간: 지급됐고 만료 행이 없는 기간(조직당 최대 1개).
create function nomad_core.open_plan_period(target_organization uuid)
returns text
language sql stable security definer set search_path = ''
as $$
  select g.ref_id from nomad_core.credit_ledger g
  where g.organization_id = target_organization and g.ref_type = 'plan_period'
    and not exists (select 1 from nomad_core.credit_ledger e
                    where e.organization_id = target_organization and e.ref_type = 'plan_expire' and e.ref_id = g.ref_id)
  limit 1
$$;

-- 기간을 닫는다: 남은 plan 잔액 전부를 만료(0이어도 완료 행). 호출자가 조직 잠금을 잡은 뒤 부른다.
create function nomad_core.close_plan_period(target_organization uuid, target_period text)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_plan integer;
begin
  select greatest(b.plan_balance, 0) into v_plan from nomad_core.credit_bucket_balances(target_organization) b;
  insert into nomad_core.credit_ledger
    (organization_id, delta, reason, idempotency_key, created_by, bucket, ref_type, ref_id, period_key)
  values (target_organization, -v_plan, 'plan_expire', 'nomad:plan_expire:' || target_period, (select auth.uid()),
          'plan', 'plan_expire', target_period, target_period);
  return v_plan;
end;
$$;

-- ── 공용 기록 (사용자 키 경로: spend·grant·consume) ─────────
-- 음수 = plan 먼저→pack 순 차감(버킷별 음수 금지), 양수 = pack 지급. 반환 ledger_id는 묶음의 대표 행(plan 행 우선).
create function nomad_core.post_credit_entry(
  target_organization uuid, entry_delta integer, entry_reason text, entry_key text, entry_product text,
  entry_ref_type text, entry_ref_id text
)
returns table (ledger_id uuid, balance integer, plan_used integer, pack_used integer)
language plpgsql security definer set search_path = ''
as $$
declare
  v_plan integer; v_pack integer; v_take_plan integer; v_take_pack integer;
  v_first uuid; v_second uuid;
  g_count integer; g_sum integer; g_plan integer; g_pack integer; g_mismatch boolean; g_bucket text;
begin
  if entry_reason is null or entry_key is null then raise exception 'reason and idempotency key required'; end if;
  if entry_delta is null or entry_delta = 0 then raise exception 'amount must be positive'; end if;
  if entry_key like 'nomad:%' then raise exception 'reserved idempotency key' using errcode = '22023'; end if;
  if entry_ref_type in ('plan_period', 'plan_expire') then raise exception 'reserved ref_type' using errcode = '22023'; end if;
  -- 조직별 기록 직렬화(잔액 확인 + 기록). 기존 write_credit_entry와 같은 잠금 키.
  perform pg_advisory_xact_lock(hashtextextended(target_organization::text, 0));

  select b.plan_balance, b.pack_balance into v_plan, v_pack
  from nomad_core.credit_bucket_balances(target_organization) b;

  select count(*)::integer, coalesce(sum(l.delta), 0)::integer,
         coalesce(-sum(l.delta) filter (where l.bucket = 'plan'), 0)::integer,
         coalesce(-sum(l.delta) filter (where l.bucket is distinct from 'plan'), 0)::integer,
         coalesce(bool_or(l.reason <> entry_reason or l.product_code is distinct from entry_product
                          or l.ref_type is distinct from entry_ref_type or l.ref_id is distinct from entry_ref_id
                          or l.refund_of is not null), false),
         min(coalesce(l.bucket, 'pack'))
  into g_count, g_sum, g_plan, g_pack, g_mismatch, g_bucket
  from nomad_core.credit_ledger l
  where l.organization_id = target_organization and l.idempotency_key = entry_key;

  if g_count > 0 then
    if g_sum = entry_delta and not g_mismatch and (entry_delta < 0 or (g_count = 1 and g_bucket = 'pack')) then
      return query
        select (select l.id from nomad_core.credit_ledger l
                where l.organization_id = target_organization and l.idempotency_key = entry_key
                order by coalesce(l.bucket = 'plan', false) desc limit 1),
               v_plan + v_pack,
               case when entry_delta < 0 then g_plan else 0 end,
               case when entry_delta < 0 then g_pack else 0 end;
      return;
    end if;
    raise exception 'idempotency key reused with different request';
  end if;

  if entry_delta < 0 then
    if v_plan + v_pack + entry_delta < 0 then raise exception 'insufficient credits'; end if;
    v_take_plan := least(greatest(v_plan, 0), -entry_delta);
    v_take_pack := -entry_delta - v_take_plan;
    if v_take_plan > 0 then
      insert into nomad_core.credit_ledger
        (organization_id, product_code, delta, reason, idempotency_key, created_by, bucket, ref_type, ref_id, period_key)
      values (target_organization, entry_product, -v_take_plan, entry_reason, entry_key, (select auth.uid()),
              'plan', entry_ref_type, entry_ref_id, nomad_core.open_plan_period(target_organization))
      returning id into v_first;
    end if;
    if v_take_pack > 0 then
      insert into nomad_core.credit_ledger
        (organization_id, product_code, delta, reason, idempotency_key, created_by, bucket, ref_type, ref_id)
      values (target_organization, entry_product, -v_take_pack, entry_reason, entry_key, (select auth.uid()),
              'pack', entry_ref_type, entry_ref_id)
      returning id into v_second;
    end if;
    return query select coalesce(v_first, v_second), v_plan + v_pack + entry_delta, v_take_plan, v_take_pack;
    return;
  end if;

  insert into nomad_core.credit_ledger
    (organization_id, product_code, delta, reason, idempotency_key, created_by, bucket, ref_type, ref_id)
  values (target_organization, entry_product, entry_delta, entry_reason, entry_key, (select auth.uid()),
          'pack', entry_ref_type, entry_ref_id)
  returning id into v_first;
  return query select v_first, v_plan + v_pack + entry_delta, 0, 0;
end;
$$;

-- 기존 서명 유지: spend_credits·grant_credits가 부른다(차감은 이제 plan 먼저→pack, 예약 키 거부).
create or replace function nomad_core.write_credit_entry(
  target_organization uuid, entry_delta int, entry_reason text, entry_key text, entry_product text
)
returns int
language sql security definer set search_path = ''
as $$
  select p.balance from nomad_core.post_credit_entry(
    target_organization, entry_delta, entry_reason, entry_key, entry_product, null, null) p
$$;

-- ── 서버 전용 함수 ────────────────────────────────────────
-- 월 지급분(plan) 지급. 멱등 = (조직, 기간). 열린 이전 기간이 있으면 같은 잠금 안에서 남은 plan을 먼저 만료한다.
create function nomad_core.grant_plan_credits(
  p_organization uuid, p_amount integer, p_period_key text, p_reason text, p_product text default null
)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_existing nomad_core.credit_ledger; v_open text; v_plan integer; v_pack integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'grant_plan_credits: server only' using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount must be positive'; end if;
  if p_reason is null then raise exception 'reason and idempotency key required'; end if;
  if p_period_key is null or length(p_period_key) not between 1 and 60 then
    raise exception 'invalid period key' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_organization::text, 0));

  select * into v_existing from nomad_core.credit_ledger l
  where l.organization_id = p_organization and l.ref_type = 'plan_period' and l.ref_id = p_period_key;
  if v_existing.id is not null then
    if v_existing.delta <> p_amount or v_existing.reason <> p_reason or v_existing.product_code is distinct from p_product then
      raise exception 'idempotency key reused with different request';
    end if;
  else
    -- 기간 키는 정렬 가능한 형식(예: 'YYYY-MM')이어야 한다. 이미 지급한 기간보다 앞선 키(지연·재시도된 과거 지급)는
    -- 현재 열린 기간을 닫아 버리므로 거부한다.
    if exists (select 1 from nomad_core.credit_ledger l
               where l.organization_id = p_organization and l.ref_type = 'plan_period' and l.ref_id > p_period_key) then
      raise exception 'grant_plan_credits: stale period key %', p_period_key using errcode = '22023';
    end if;
    v_open := nomad_core.open_plan_period(p_organization);
    if v_open is not null then perform nomad_core.close_plan_period(p_organization, v_open); end if;
    insert into nomad_core.credit_ledger
      (organization_id, product_code, delta, reason, idempotency_key, created_by, bucket, ref_type, ref_id, period_key)
    values (p_organization, p_product, p_amount, p_reason, 'nomad:plan_period:' || p_period_key, (select auth.uid()),
            'plan', 'plan_period', p_period_key, p_period_key);
  end if;
  select b.plan_balance, b.pack_balance into v_plan, v_pack from nomad_core.credit_bucket_balances(p_organization) b;
  return v_plan + v_pack;
end;
$$;

-- 참조(ref_type·ref_id)를 남기는 차감. 반환 ledger_id는 환불·작업 연결용 대표 행.
create function nomad_core.consume_credits(
  p_organization uuid, p_amount integer, p_reason text, p_idempotency_key text,
  p_product text default null, p_ref_type text default null, p_ref_id text default null
)
returns table (ledger_id uuid, balance integer, plan_used integer, pack_used integer)
language plpgsql security definer set search_path = ''
as $$
begin
  if not nomad_core.is_service_caller() then
    raise exception 'consume_credits: server only' using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount must be positive'; end if;
  return query select * from nomad_core.post_credit_entry(
    p_organization, -p_amount, p_reason, p_idempotency_key, p_product, p_ref_type, p_ref_id);
end;
$$;

-- consume 묶음 환불. 상한 = 원 consume 금액 − 기존 환불 합계(요청이 크면 상한까지), 남은 0이면 no-op(ledger_id null).
-- 원래 차감된 버킷으로 plan 먼저 되돌리되, plan 부분이 속한 기간이 이미 만료됐으면 plan 환불은 0(pack 부분만).
-- 멱등 = (대표 consume 행, 환불 키). 재호출은 사유·요청액이 같을 때만 기존 결과를 돌려준다.
create function nomad_core.refund_credits(
  p_consume_ledger_id uuid, p_reason text, p_idempotency_key text, p_amount integer default null
)
returns table (ledger_id uuid, balance integer, refunded integer)
language plpgsql security definer set search_path = ''
as $$
declare
  v_row nomad_core.credit_ledger; v_primary uuid; v_key text; v_period text;
  v_used_plan integer; v_used_pack integer; v_ref_plan integer; v_ref_pack integer;
  v_rem_plan integer; v_rem_pack integer; v_amount integer; v_back_plan integer; v_back_pack integer;
  v_first uuid; v_second uuid; v_plan integer; v_pack integer;
  g_count integer; g_sum integer; g_mismatch boolean;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'refund_credits: server only' using errcode = '42501';
  end if;
  if p_reason is null or p_idempotency_key is null then raise exception 'reason and idempotency key required'; end if;
  if p_amount is not null and p_amount <= 0 then raise exception 'amount must be positive'; end if;

  select * into v_row from nomad_core.credit_ledger l where l.id = p_consume_ledger_id;
  if v_row.id is null or v_row.delta >= 0 or v_row.refund_of is not null
     or v_row.ref_type is not distinct from 'plan_expire' then
    raise exception 'not a consume entry' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_row.organization_id::text, 0));

  -- 원 consume 묶음(같은 조직·같은 키의 음수 행)과 대표 행, plan 부분의 기간
  select coalesce(-sum(l.delta) filter (where l.bucket = 'plan'), 0)::integer,
         coalesce(-sum(l.delta) filter (where l.bucket is distinct from 'plan'), 0)::integer,
         max(l.period_key) filter (where l.bucket = 'plan')
  into v_used_plan, v_used_pack, v_period
  from nomad_core.credit_ledger l
  where l.organization_id = v_row.organization_id and l.idempotency_key = v_row.idempotency_key and l.delta < 0;
  select l.id into v_primary from nomad_core.credit_ledger l
  where l.organization_id = v_row.organization_id and l.idempotency_key = v_row.idempotency_key and l.delta < 0
  order by coalesce(l.bucket = 'plan', false) desc limit 1;
  v_key := 'nomad:refund:' || v_primary::text || ':' || p_idempotency_key;

  select b.plan_balance, b.pack_balance into v_plan, v_pack
  from nomad_core.credit_bucket_balances(v_row.organization_id) b;

  -- 멱등: 같은 consume·같은 환불 키
  select count(*)::integer, coalesce(sum(l.delta), 0)::integer,
         coalesce(bool_or(l.reason <> p_reason or l.requested_amount is distinct from p_amount), false)
  into g_count, g_sum, g_mismatch
  from nomad_core.credit_ledger l
  where l.organization_id = v_row.organization_id and l.idempotency_key = v_key;
  if g_count > 0 then
    if not g_mismatch then
      return query
        select (select l.id from nomad_core.credit_ledger l
                where l.organization_id = v_row.organization_id and l.idempotency_key = v_key
                order by coalesce(l.bucket = 'plan', false) desc limit 1),
               v_plan + v_pack, g_sum;
      return;
    end if;
    raise exception 'idempotency key reused with different request';
  end if;

  select coalesce(sum(l.delta) filter (where l.bucket = 'plan'), 0)::integer,
         coalesce(sum(l.delta) filter (where l.bucket is distinct from 'plan'), 0)::integer
  into v_ref_plan, v_ref_pack
  from nomad_core.credit_ledger l where l.refund_of = v_primary;

  v_rem_plan := greatest(v_used_plan - v_ref_plan, 0);
  v_rem_pack := greatest(v_used_pack - v_ref_pack, 0);
  -- plan 부분의 기간이 닫혔으면(만료 행 존재 또는 기간 불명) plan은 되돌리지 않는다.
  if v_rem_plan > 0 and (v_period is null or exists (
       select 1 from nomad_core.credit_ledger e
       where e.organization_id = v_row.organization_id and e.ref_type = 'plan_expire' and e.ref_id = v_period)) then
    v_rem_plan := 0;
  end if;
  v_amount := least(coalesce(p_amount, v_rem_plan + v_rem_pack), v_rem_plan + v_rem_pack);
  if v_amount = 0 then
    return query select null::uuid, v_plan + v_pack, 0;
    return;
  end if;
  v_back_plan := least(v_rem_plan, v_amount);
  v_back_pack := v_amount - v_back_plan;

  if v_back_plan > 0 then
    insert into nomad_core.credit_ledger
      (organization_id, product_code, delta, reason, idempotency_key, created_by, bucket, ref_type, ref_id,
       refund_of, period_key, requested_amount)
    values (v_row.organization_id, v_row.product_code, v_back_plan, p_reason, v_key, (select auth.uid()),
            'plan', v_row.ref_type, v_row.ref_id, v_primary, v_period, p_amount)
    returning id into v_first;
  end if;
  if v_back_pack > 0 then
    insert into nomad_core.credit_ledger
      (organization_id, product_code, delta, reason, idempotency_key, created_by, bucket, ref_type, ref_id,
       refund_of, requested_amount)
    values (v_row.organization_id, v_row.product_code, v_back_pack, p_reason, v_key, (select auth.uid()),
            'pack', v_row.ref_type, v_row.ref_id, v_primary, p_amount)
    returning id into v_second;
  end if;
  return query select coalesce(v_first, v_second), v_plan + v_pack + v_amount, v_amount;
end;
$$;

-- 월 지급분 만료(멱등, 스케줄링·수치 없음). 그 기간이 열린 기간이면 남은 plan 전부를 만료하고 0이어도 완료 행을 남긴다.
-- 이미 닫힌 기간은 기록된 만료액을 돌려주고, 지급된 적 없는 기간은 0(기록 없음).
create function nomad_core.expire_plan_credits(p_organization uuid, p_period_key text)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_done integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'expire_plan_credits: server only' using errcode = '42501';
  end if;
  if p_period_key is null or length(p_period_key) not between 1 and 60 then
    raise exception 'invalid period key' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_organization::text, 0));

  select -l.delta into v_done from nomad_core.credit_ledger l
  where l.organization_id = p_organization and l.ref_type = 'plan_expire' and l.ref_id = p_period_key;
  if v_done is not null then return v_done; end if;
  if nomad_core.open_plan_period(p_organization) is distinct from p_period_key then return 0; end if;
  return nomad_core.close_plan_period(p_organization, p_period_key);
end;
$$;

-- ── 함수 권한 ─────────────────────────────────────────────
revoke all on function
  nomad_core.credit_bucket_balances(uuid),
  nomad_core.open_plan_period(uuid),
  nomad_core.close_plan_period(uuid, text),
  nomad_core.post_credit_entry(uuid, integer, text, text, text, text, text),
  nomad_core.grant_plan_credits(uuid, integer, text, text, text),
  nomad_core.consume_credits(uuid, integer, text, text, text, text, text),
  nomad_core.refund_credits(uuid, text, text, integer),
  nomad_core.expire_plan_credits(uuid, text)
from public, anon, authenticated;
grant execute on function
  nomad_core.credit_bucket_balances(uuid),
  nomad_core.grant_plan_credits(uuid, integer, text, text, text),
  nomad_core.consume_credits(uuid, integer, text, text, text, text, text),
  nomad_core.refund_credits(uuid, text, text, integer),
  nomad_core.expire_plan_credits(uuid, text)
to service_role;

commit;
