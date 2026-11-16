-- 코어 웨이브 2단계 C2: 범용 작업 큐 jobs — 클레임(SKIP LOCKED)·하트비트·재시도(지수 백오프)·최종 실패/취소 시 크레딧 환불.
-- 원본: platform-docs _supabase-modular 0005_core_jobs_storage.sql(core.jobs·enqueue/claim/heartbeat/complete/fail/cancel/reap).
-- 규칙
--   · 워커는 서버(service_role)만: enqueue_job → claim_jobs → (heartbeat_job)* → complete_job | fail_job. reap_stale_jobs는 스케줄러가 부른다.
--   · 테이블 직접 쓰기 없음(service_role도 select만). 상태 변경은 아래 함수로만.
--   · credit_ledger_id는 같은 조직의 consume 묶음 대표 행(consume_credits 반환 ledger_id)만, 작업당 1개(unique).
--   · 환불은 refund_credits_internal(키 'job:<작업 id>')로 하며, 이미 다 환불된 묶음이면 no-op이다. refund_credits는 서버 판별 래퍼로 바뀐다(동작 동일).
--   · 사용자: public.nomad_my_jobs(멤버 읽기, payload·result·last_error·워커 정보 제외) · public.nomad_cancel_job(생성자 또는 owner·admin, queued만, 항상 환불).
--   · Realtime 발행 없음(진행률은 nomad_my_jobs 조회).
-- 되돌림: drop function public.nomad_cancel_job(uuid), public.nomad_my_jobs(uuid, integer, timestamptz, uuid),
--   nomad_core.cancel_job(uuid), nomad_core.reap_stale_jobs(integer, integer), nomad_core.fail_job(uuid, text, integer, text, boolean, integer),
--   nomad_core.complete_job(uuid, text, integer, jsonb), nomad_core.heartbeat_job(uuid, text, integer, integer, text),
--   nomad_core.claim_jobs(text, text, integer, text[], text),
--   nomad_core.enqueue_job(uuid, text, text, jsonb, text, integer, timestamptz, integer, uuid, text, uuid, uuid, boolean),
--   nomad_core.refund_job_credits(nomad_core.jobs, text); drop table nomad_core.jobs;
--   refund_credits를 20261120000200 정의로 되돌린 뒤 drop function nomad_core.refund_credits_internal(uuid, text, text, integer).
begin;

create table nomad_core.jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id),
  product_code text not null references nomad_core.products(code),
  queue text not null default 'default' check (length(queue) between 1 and 60),
  job_type text not null check (length(job_type) between 1 and 120),
  payload jsonb not null default '{}'::jsonb,
  result jsonb,
  status text not null default 'queued' check (status in ('queued', 'running', 'succeeded', 'failed', 'canceled')),
  priority integer not null default 100,
  attempts integer not null default 0 check (attempts >= 0),
  max_attempts integer not null default 3 check (max_attempts between 1 and 20),
  run_after timestamptz not null default now(),
  locked_at timestamptz,
  locked_by text check (locked_by is null or length(locked_by) between 1 and 200),
  heartbeat_at timestamptz,
  progress integer not null default 0 check (progress between 0 and 100),
  progress_message text check (progress_message is null or length(progress_message) <= 500),
  last_error text,
  credit_ledger_id uuid unique references nomad_core.credit_ledger(id),
  refund_on_failure boolean not null default true,
  idempotency_key text check (idempotency_key is null or length(idempotency_key) between 1 and 200),
  parent_job_id uuid references nomad_core.jobs(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (organization_id, idempotency_key)
);
create index jobs_claim_idx on nomad_core.jobs (queue, priority, run_after, created_at) where status = 'queued';
create index jobs_org_created_idx on nomad_core.jobs (organization_id, created_at desc);
create index jobs_running_heartbeat_idx on nomad_core.jobs (heartbeat_at) where status = 'running';
create index jobs_parent_idx on nomad_core.jobs (parent_job_id) where parent_job_id is not null;
comment on table nomad_core.jobs is
  '범용 작업 큐(제품 slug = product_code). 서버 전용 — 쓰기는 enqueue/claim/heartbeat/complete/fail/cancel/reap 함수로만, 사용자 읽기는 public.nomad_my_jobs.';

comment on column nomad_core.jobs.progress_message is
  '진행 문구(500자). nomad_my_jobs로 조직 멤버 전원에게 보이므로 개인정보·비밀·입력 원문 등 민감 정보를 넣지 않는다(워커 계약).';
comment on column nomad_core.jobs.attempts is
  '클레임 횟수. 워커는 claim_jobs가 돌려준 값을 heartbeat·complete·fail에 p_attempt로 넘겨 자기 시도임을 증명한다.';

create trigger jobs_touch_updated_at
  before update on nomad_core.jobs
  for each row execute function nomad_core.touch_updated_at();

-- 사용자 정책 없음 = authenticated·anon 직접 접근 0. service_role은 읽기만(쓰기는 함수가 SECURITY DEFINER로).
alter table nomad_core.jobs enable row level security;
revoke all on nomad_core.jobs from public, anon, authenticated, service_role;
grant select on nomad_core.jobs to service_role;

-- ── 내부 도우미 (API 역할에 주지 않음) ─────────────────────
-- 환불 본문 분리(rate_limit_take 패턴): refund_credits_internal = 20261120000200의 refund_credits 본문 그대로(서버 판별만 없음),
-- 어떤 API 역할에도 실행 권한 없음 — 소유자의 security definer 함수(cancel_job·fail_job)만 호출한다.
-- refund_credits는 같은 서명·동작으로 서버 판별 후 internal을 부른다.
create function nomad_core.refund_credits_internal(
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
revoke all on function nomad_core.refund_credits_internal(uuid, text, text, integer) from public, anon, authenticated, service_role;
comment on function nomad_core.refund_credits_internal(uuid, text, text, integer) is
  'refund_credits 본문(서버 판별 없음). execute grant 없음 — 소유자 함수(cancel_job·fail_job)만 호출.';

create or replace function nomad_core.refund_credits(
  p_consume_ledger_id uuid, p_reason text, p_idempotency_key text, p_amount integer default null
)
returns table (ledger_id uuid, balance integer, refunded integer)
language plpgsql security definer set search_path = ''
as $$
begin
  if not nomad_core.is_service_caller() then
    raise exception 'refund_credits: server only' using errcode = '42501';
  end if;
  return query select * from nomad_core.refund_credits_internal(p_consume_ledger_id, p_reason, p_idempotency_key, p_amount);
end;
$$;
revoke all on function nomad_core.refund_credits(uuid, text, text, integer) from public, anon, authenticated;
grant execute on function nomad_core.refund_credits(uuid, text, text, integer) to service_role;

-- 작업에 연결된 consume 묶음을 환불한다. 키 'job:<id>' 고정이라 같은 작업은 한 번만 환불되고, 남은 금액이 0이면 no-op.
-- 환불 여부(refund_on_failure 등)는 호출자가 정한다. 권한 검사를 마친 cancel_job·fail_job 안에서만 불리며
-- refund_credits_internal을 직접 부른다(사용자 취소도 환불 가능).
create function nomad_core.refund_job_credits(target_job nomad_core.jobs, refund_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if target_job.credit_ledger_id is not null then
    perform nomad_core.refund_credits_internal(target_job.credit_ledger_id, refund_reason, 'job:' || target_job.id::text);
  end if;
end;
$$;

-- ── 서버 전용 함수 ────────────────────────────────────────
-- 작업 등록. 멱등 = (조직, 키): 같은 요청이면 기존 작업을 돌려주고, 다른 요청이면 거부한다.
create function nomad_core.enqueue_job(
  p_organization uuid,
  p_product text,
  p_job_type text,
  p_payload jsonb default '{}'::jsonb,
  p_queue text default 'default',
  p_priority integer default 100,
  p_run_after timestamptz default null,
  p_max_attempts integer default 3,
  p_credit_ledger_id uuid default null,
  p_idempotency_key text default null,
  p_parent_job_id uuid default null,
  p_created_by uuid default null,
  p_refund_on_failure boolean default true
)
returns nomad_core.jobs
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_core.jobs; v_ledger nomad_core.credit_ledger; v_primary uuid;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'enqueue_job: server only' using errcode = '42501';
  end if;
  if p_organization is null or p_product is null or p_job_type is null then
    raise exception 'enqueue_job: organization, product and job type required' using errcode = '22023';
  end if;

  if p_idempotency_key is not null then
    perform pg_advisory_xact_lock(hashtextextended('job:' || p_organization::text || ':' || p_idempotency_key, 0));
    select * into v_row from nomad_core.jobs j
    where j.organization_id = p_organization and j.idempotency_key = p_idempotency_key;
    if v_row.id is not null then
      if v_row.product_code <> p_product or v_row.job_type <> p_job_type
         or v_row.queue <> coalesce(p_queue, 'default') or v_row.payload <> coalesce(p_payload, '{}'::jsonb)
         or v_row.credit_ledger_id is distinct from p_credit_ledger_id
         or v_row.refund_on_failure <> coalesce(p_refund_on_failure, true)
         or v_row.created_by is distinct from p_created_by
         or v_row.max_attempts <> coalesce(p_max_attempts, 3)
         or v_row.parent_job_id is distinct from p_parent_job_id then
        raise exception 'idempotency key reused with different request';
      end if;
      return v_row;
    end if;
  end if;

  -- 크레딧 연결: 같은 조직의 consume 묶음 대표 행만(지급·환불·만료 행, 묶음의 두 번째 행 거부)
  if p_credit_ledger_id is not null then
    select * into v_ledger from nomad_core.credit_ledger l where l.id = p_credit_ledger_id;
    if v_ledger.id is null or v_ledger.organization_id <> p_organization or v_ledger.delta >= 0
       or v_ledger.refund_of is not null or v_ledger.ref_type is not distinct from 'plan_expire'
       or (v_ledger.product_code is not null and v_ledger.product_code <> p_product) then
      raise exception 'enqueue_job: credit entry is not a consume of this organization' using errcode = '22023';
    end if;
    select l.id into v_primary from nomad_core.credit_ledger l
    where l.organization_id = v_ledger.organization_id and l.idempotency_key = v_ledger.idempotency_key and l.delta < 0
    order by coalesce(l.bucket = 'plan', false) desc limit 1;
    if v_primary <> p_credit_ledger_id then
      raise exception 'enqueue_job: use the primary consume entry' using errcode = '22023';
    end if;
    if exists (select 1 from nomad_core.jobs j where j.credit_ledger_id = p_credit_ledger_id) then
      raise exception 'enqueue_job: credit entry already linked to a job' using errcode = '23505';
    end if;
  end if;

  if p_parent_job_id is not null and not exists (
       select 1 from nomad_core.jobs j where j.id = p_parent_job_id and j.organization_id = p_organization) then
    raise exception 'enqueue_job: parent job not in organization' using errcode = '22023';
  end if;
  if p_created_by is not null and not exists (
       select 1 from nomad_core.memberships m where m.organization_id = p_organization and m.user_id = p_created_by) then
    raise exception 'enqueue_job: creator is not a member' using errcode = '22023';
  end if;

  insert into nomad_core.jobs (organization_id, product_code, queue, job_type, payload, priority, run_after, max_attempts,
                               credit_ledger_id, idempotency_key, parent_job_id, created_by, refund_on_failure)
  values (p_organization, p_product, coalesce(p_queue, 'default'), p_job_type, coalesce(p_payload, '{}'::jsonb),
          coalesce(p_priority, 100), coalesce(p_run_after, now()), coalesce(p_max_attempts, 3), p_credit_ledger_id,
          p_idempotency_key, p_parent_job_id, p_created_by, coalesce(p_refund_on_failure, true))
  returning * into v_row;
  return v_row;
end;
$$;

-- 클레임: FOR UPDATE SKIP LOCKED로 여러 워커가 같은 큐를 나눠 가진다. attempts는 클레임 때 1 증가.
create function nomad_core.claim_jobs(
  p_queue text, p_worker_id text, p_limit integer default 1, p_job_types text[] default null, p_product text default null
)
returns setof nomad_core.jobs
language plpgsql security definer set search_path = ''
as $$
begin
  if not nomad_core.is_service_caller() then
    raise exception 'claim_jobs: server only' using errcode = '42501';
  end if;
  if p_queue is null or p_worker_id is null or length(p_worker_id) not between 1 and 200 then
    raise exception 'claim_jobs: queue and worker id required' using errcode = '22023';
  end if;
  return query
  with picked as (
    select j.id from nomad_core.jobs j
    where j.queue = p_queue and j.status = 'queued' and j.run_after <= now()
      and (p_job_types is null or j.job_type = any (p_job_types))
      and (p_product is null or j.product_code = p_product)
    order by j.priority asc, j.run_after asc, j.created_at asc
    limit least(greatest(coalesce(p_limit, 1), 1), 100)
    for update skip locked
  )
  update nomad_core.jobs j
  set status = 'running', locked_at = now(), locked_by = p_worker_id, heartbeat_at = now(),
      started_at = coalesce(j.started_at, now()), attempts = j.attempts + 1
  from picked
  where j.id = picked.id
  returning j.*;
end;
$$;

-- 워커 소유 판별: running이고 locked_by·attempts가 모두 맞아야 한다. 멈췄던 이전 시도(같은 워커 id라도 attempts가 다름)는
-- 새 시도의 하트비트·결과를 덮지 못한다.
-- 하트비트·진행률. 자기 시도가 아니면 false(워커는 작업을 놓아야 한다).
create function nomad_core.heartbeat_job(
  p_job_id uuid, p_worker_id text, p_attempt integer, p_progress integer default null, p_message text default null
)
returns boolean
language plpgsql security definer set search_path = ''
as $$
begin
  if not nomad_core.is_service_caller() then
    raise exception 'heartbeat_job: server only' using errcode = '42501';
  end if;
  update nomad_core.jobs
  set heartbeat_at = now(), progress = coalesce(p_progress, progress),
      progress_message = coalesce(left(p_message, 500), progress_message)
  where id = p_job_id and status = 'running' and locked_by = p_worker_id and attempts = p_attempt;
  return found;
end;
$$;

create function nomad_core.complete_job(p_job_id uuid, p_worker_id text, p_attempt integer, p_result jsonb default '{}'::jsonb)
returns nomad_core.jobs
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_core.jobs;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'complete_job: server only' using errcode = '42501';
  end if;
  update nomad_core.jobs
  set status = 'succeeded', result = coalesce(p_result, '{}'::jsonb), progress = 100,
      finished_at = now(), locked_at = null, locked_by = null
  where id = p_job_id and status = 'running' and locked_by = p_worker_id and attempts = p_attempt
  returning * into v_row;
  if v_row.id is null then
    raise exception 'complete_job: job % is not running under worker % attempt %', p_job_id, p_worker_id, p_attempt
      using errcode = '55000';
  end if;
  return v_row;
end;
$$;

-- 실패. 재시도 가능하고 attempts < max_attempts면 지수 백오프(지연 × 2^(attempts−1), 최대 1일)로 재대기,
-- 아니면 최종 실패 + 환불(refund_on_failure일 때, no-op 허용).
create function nomad_core.fail_job(
  p_job_id uuid, p_worker_id text, p_attempt integer, p_error text,
  p_retryable boolean default true, p_retry_delay_seconds integer default 60
)
returns nomad_core.jobs
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_core.jobs; v_delay double precision;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'fail_job: server only' using errcode = '42501';
  end if;
  if p_retry_delay_seconds is null or p_retry_delay_seconds not between 0 and 86400 then
    raise exception 'fail_job: retry delay must be 0..86400 seconds' using errcode = '22023';
  end if;
  select * into v_row from nomad_core.jobs j where j.id = p_job_id for update;
  if v_row.id is null or v_row.status <> 'running' or v_row.locked_by is distinct from p_worker_id
     or v_row.attempts is distinct from p_attempt then
    raise exception 'fail_job: job % is not running under worker % attempt %', p_job_id, p_worker_id, p_attempt
      using errcode = '55000';
  end if;

  if coalesce(p_retryable, true) and v_row.attempts < v_row.max_attempts then
    v_delay := least(p_retry_delay_seconds * power(2, greatest(v_row.attempts - 1, 0)), 86400);
    update nomad_core.jobs
    set status = 'queued', run_after = now() + make_interval(secs => v_delay), last_error = left(p_error, 4000),
        locked_at = null, locked_by = null, heartbeat_at = null
    where id = p_job_id
    returning * into v_row;
    return v_row;
  end if;

  update nomad_core.jobs
  set status = 'failed', last_error = left(p_error, 4000), finished_at = now(),
      locked_at = null, locked_by = null
  where id = p_job_id
  returning * into v_row;
  if v_row.refund_on_failure then perform nomad_core.refund_job_credits(v_row, 'job_failed'); end if;
  return v_row;
end;
$$;

-- 하트비트가 끊긴 running 작업을 실패 처리(재시도 남으면 재대기, 아니면 최종 실패 + 환불). 한 번에 최대 p_limit건(1..1000),
-- 오래 끊긴 순. 반복 호출 안전: 처리된 작업은 더 이상 running이 아니고, 다른 호출이 잡은 행은 SKIP LOCKED로 건너뛴다.
-- 반환: 처리한 작업 수.
create function nomad_core.reap_stale_jobs(p_stale_seconds integer default 600, p_limit integer default 100)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare r record; v_count integer := 0;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'reap_stale_jobs: server only' using errcode = '42501';
  end if;
  if p_stale_seconds is null or p_stale_seconds < 1 then
    raise exception 'reap_stale_jobs: stale seconds must be >= 1' using errcode = '22023';
  end if;
  if p_limit is null or p_limit not between 1 and 1000 then
    raise exception 'reap_stale_jobs: limit must be 1..1000' using errcode = '22023';
  end if;
  for r in
    select j.id, j.locked_by, j.attempts from nomad_core.jobs j
    where j.status = 'running' and coalesce(j.heartbeat_at, j.locked_at) < now() - make_interval(secs => p_stale_seconds)
    order by coalesce(j.heartbeat_at, j.locked_at)
    limit p_limit
    for update skip locked
  loop
    perform nomad_core.fail_job(r.id, r.locked_by, r.attempts, 'stale heartbeat', true, 60);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- 취소: queued 작업만(running은 워커가 끝낸다). 서버, 또는 조직 멤버 중 생성자·owner·admin.
-- 권한 확인 전에는 잠그지 않는다(남의 작업 행 잠금 방지): 잠금 없이 조직·생성자를 보고 권한을 확인한 뒤 for update로 다시 읽는다.
-- 실행 전 취소이므로 refund_on_failure와 무관하게 항상 환불(no-op 허용) + 감사 기록.
create function nomad_core.cancel_job(p_job_id uuid)
returns nomad_core.jobs
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_core.jobs; v_role text;
begin
  select * into v_row from nomad_core.jobs j where j.id = p_job_id;
  if not nomad_core.is_service_caller() then
    v_role := case when v_row.id is null then null else nomad_core.organization_role(v_row.organization_id) end;
    -- 남의 조직 작업은 존재 여부도 알리지 않는다
    if v_role is null then raise exception 'cancel_job: not found' using errcode = 'P0002'; end if;
    if v_role not in ('owner', 'admin') and v_row.created_by is distinct from (select auth.uid()) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
  elsif v_row.id is null then
    raise exception 'cancel_job: not found' using errcode = 'P0002';
  end if;
  -- 조직·생성자를 바꾸는 함수는 없으므로 재조회 뒤에는 상태만 다시 본다
  select * into v_row from nomad_core.jobs j where j.id = p_job_id for update;
  if v_row.status <> 'queued' then
    raise exception 'cancel_job: only queued jobs can be canceled (status=%)', v_row.status using errcode = '55000';
  end if;
  update nomad_core.jobs set status = 'canceled', finished_at = now() where id = p_job_id returning * into v_row;
  perform nomad_core.refund_job_credits(v_row, 'job_canceled');
  perform nomad_core.write_audit(v_row.organization_id, 'job.cancel', 'job', v_row.id::text);
  return v_row;
end;
$$;

-- ── 사용자 RPC ────────────────────────────────────────────
-- 조직 멤버가 자기 조직 작업 상태를 최신순(created_at desc, id desc)으로 본다(최대 200건).
-- 다음 쪽은 마지막 행의 created_at·id를 before_created_at·before_id로 넘긴다(nomad_audit_log 방식).
-- 입력·출력 본문·오류 원문·워커·크레딧 연결은 주지 않는다.
create function public.nomad_my_jobs(
  target_organization uuid, page_size integer default 50,
  before_created_at timestamptz default null, before_id uuid default null
)
returns table (id uuid, product_code text, queue text, job_type text, status text, progress integer, progress_message text,
               attempts integer, max_attempts integer, run_after timestamptz, parent_job_id uuid, created_by uuid,
               created_at timestamptz, started_at timestamptz, finished_at timestamptz, updated_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if nomad_core.organization_role(target_organization) is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
    select j.id, j.product_code, j.queue, j.job_type, j.status, j.progress, j.progress_message, j.attempts, j.max_attempts,
           j.run_after, j.parent_job_id, j.created_by, j.created_at, j.started_at, j.finished_at, j.updated_at
    from nomad_core.jobs j
    where j.organization_id = target_organization
      and (before_created_at is null or j.created_at < before_created_at
           or (j.created_at = before_created_at and before_id is not null and j.id < before_id))
    order by j.created_at desc, j.id desc
    limit least(greatest(coalesce(page_size, 50), 1), 200);
end;
$$;

-- 취소 후 상태만 돌려준다(작업 행 전체는 주지 않음).
create function public.nomad_cancel_job(job_id uuid)
returns text
language sql security definer set search_path = ''
as $$
  select (nomad_core.cancel_job(job_id)).status
$$;

-- ── 함수 권한 ─────────────────────────────────────────────
revoke all on function
  nomad_core.refund_job_credits(nomad_core.jobs, text),
  nomad_core.enqueue_job(uuid, text, text, jsonb, text, integer, timestamptz, integer, uuid, text, uuid, uuid, boolean),
  nomad_core.claim_jobs(text, text, integer, text[], text),
  nomad_core.heartbeat_job(uuid, text, integer, integer, text),
  nomad_core.complete_job(uuid, text, integer, jsonb),
  nomad_core.fail_job(uuid, text, integer, text, boolean, integer),
  nomad_core.reap_stale_jobs(integer, integer),
  nomad_core.cancel_job(uuid),
  public.nomad_my_jobs(uuid, integer, timestamptz, uuid),
  public.nomad_cancel_job(uuid)
from public, anon, authenticated;
grant execute on function
  nomad_core.enqueue_job(uuid, text, text, jsonb, text, integer, timestamptz, integer, uuid, text, uuid, uuid, boolean),
  nomad_core.claim_jobs(text, text, integer, text[], text),
  nomad_core.heartbeat_job(uuid, text, integer, integer, text),
  nomad_core.complete_job(uuid, text, integer, jsonb),
  nomad_core.fail_job(uuid, text, integer, text, boolean, integer),
  nomad_core.reap_stale_jobs(integer, integer),
  nomad_core.cancel_job(uuid)
to service_role;
grant execute on function public.nomad_my_jobs(uuid, integer, timestamptz, uuid), public.nomad_cancel_job(uuid) to authenticated;

commit;
