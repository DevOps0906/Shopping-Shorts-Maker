-- task-011: extension_connections · jobs · credit_ledger · 워커 전용 역할(worker_role)
-- 근거: docs/05_DATA_MODEL.md 1·2절, 3절 해당 표, docs/planning.md 17-5, ADR-0001, ADR-0003
-- worker_role 은 로그인 불가로만 만든다. 로그인 역할·비밀번호는 task-012에서 만든다(이 역할을 GRANT).

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'worker_role') then
    create role worker_role nologin nobypassrls;
  end if;
end
$$;

-- ── extension_connections (ADR-0003) ─────────────────────────
create table public.extension_connections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  -- 원문 저장 금지, 해시만. authenticated 읽기 제외
  access_token_hash text not null,
  access_expires_at timestamptz not null,
  refresh_token_hash text not null,
  refresh_expires_at timestamptz not null,
  family_id uuid not null,
  last_heartbeat_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);
comment on table public.extension_connections is '브라우저 확장 연결(ADR-0003). 토큰은 해시만, 쓰기는 서버(SR)만, 본인은 해시 제외 읽기';
create index extension_connections_user_id_idx on public.extension_connections (user_id);
create index extension_connections_family_id_idx on public.extension_connections (family_id);
create unique index extension_connections_access_hash_idx on public.extension_connections (access_token_hash);
create unique index extension_connections_refresh_hash_idx on public.extension_connections (refresh_token_hash);

alter table public.extension_connections enable row level security;
revoke all on public.extension_connections from anon, authenticated;
grant select (id, user_id, access_expires_at, refresh_expires_at, family_id, last_heartbeat_at,
              revoked_at, created_at)
  on public.extension_connections to authenticated;

create policy extension_connections_select_own on public.extension_connections
  for select to authenticated using (user_id = (select auth.uid()));

-- ── jobs (17-5, ADR-0001) ───────────────────────────────────
create table public.jobs (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  step smallint not null check (step between 1 and 6),
  -- 큐 종류 render·tts·analyze, 수집(collect)은 확장이 처리
  type text not null check (type in ('render', 'tts', 'analyze', 'collect')),
  status text not null default 'queued'
    check (status in ('queued', 'waiting_extension', 'running', 'succeeded', 'failed', 'canceled')),
  idempotency_key text not null unique,
  attempts integer not null default 0 check (attempts >= 0),
  max_attempts integer not null default 3 check (max_attempts >= 1),
  payload jsonb not null default '{}'::jsonb,
  error text,
  started_at timestamptz,
  finished_at timestamptz,
  extension_id uuid references public.extension_connections (id) on delete set null,
  created_at timestamptz not null default now()
);
comment on table public.jobs is '오래 걸리는 작업 1건 = 1행(17-5). 생성·취소는 서버(SR), 상태 갱신은 워커(worker_role)';
create index jobs_project_id_idx on public.jobs (project_id);
create index jobs_status_idx on public.jobs (status) where status in ('queued', 'waiting_extension', 'running');
create index jobs_extension_id_idx on public.jobs (extension_id);

alter table public.jobs enable row level security;
revoke all on public.jobs from anon, authenticated;
grant select on public.jobs to authenticated;

create policy jobs_select_own on public.jobs
  for select to authenticated
  using (exists (select 1 from public.projects p
                 where p.id = jobs.project_id and p.user_id = (select auth.uid())));

-- 워커: 읽기 + 상태 열만 갱신(BYPASSRLS 없이 정책으로 허용)
grant usage on schema public to worker_role;
grant select on public.jobs to worker_role;
grant update (status, attempts, error, started_at, finished_at) on public.jobs to worker_role;

create policy jobs_select_worker on public.jobs
  for select to worker_role using (true);
create policy jobs_update_worker on public.jobs
  for update to worker_role
  using (status in ('queued', 'running'))
  with check (status in ('running', 'succeeded', 'failed', 'queued'));

-- ── credit_ledger (추가 전용, 정수 크레딧) ───────────────────
create table public.credit_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  project_id uuid references public.projects (id) on delete set null,
  job_id uuid references public.jobs (id) on delete set null,
  kind text not null check (kind in ('reserve', 'settle', 'release', 'charge')),
  delta integer not null,
  reason text,
  idempotency_key text not null unique,
  created_at timestamptz not null default now(),
  unique (job_id, kind)
);
comment on table public.credit_ledger is '크레딧 원장(추가 전용). 서버(SR)·워커만 INSERT, 작업당 settle·release 중 하나만';
create index credit_ledger_user_id_created_at_idx on public.credit_ledger (user_id, created_at);
create index credit_ledger_project_id_idx on public.credit_ledger (project_id);
-- 작업당 정산(settle)과 반환(release)은 합쳐서 1건만
create unique index credit_ledger_one_final_per_job_idx on public.credit_ledger (job_id)
  where kind in ('settle', 'release');

alter table public.credit_ledger enable row level security;
-- 추가 전용: 소유자(마이그레이션 주체) 외에는 UPDATE·DELETE·TRUNCATE 불가
revoke all on public.credit_ledger from anon, authenticated;
revoke update, delete, truncate on public.credit_ledger from service_role;
grant select on public.credit_ledger to authenticated;

create policy credit_ledger_select_own on public.credit_ledger
  for select to authenticated using (user_id = (select auth.uid()));

grant select, insert on public.credit_ledger to worker_role;
create policy credit_ledger_select_worker on public.credit_ledger
  for select to worker_role using (true);
create policy credit_ledger_insert_worker on public.credit_ledger
  for insert to worker_role with check (kind in ('settle', 'release'));

-- ── pgmq (ADR-0001): 워커가 큐 함수 실행. 큐별 테이블 권한은 큐를 만드는 작업에서 준다 ──
grant usage on schema pgmq to worker_role;
grant execute on function pgmq.read(text, integer, integer, jsonb) to worker_role;
grant execute on function pgmq.set_vt(text, bigint, integer) to worker_role;
grant execute on function pgmq.archive(text, bigint) to worker_role;
grant execute on function pgmq.delete(text, bigint) to worker_role;
