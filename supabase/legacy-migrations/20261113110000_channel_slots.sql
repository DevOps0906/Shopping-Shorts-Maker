-- task-034a: 채널 연결 한도 · 30일 새 채널 회전 제한 · 초과 채널 새 프로젝트 거부 · 감사 이벤트
-- 근거: docs/planning.md 12장·17-2 D14, docs/05_DATA_MODEL.md 3절, tasks/task-034.md(034a), 팀장 확정 사양(2026-11-13)
--
-- - 슬롯 보유 행 = 업로드용 accounts 중 external_channel_id 가 있고 disconnected_at 이 없는 행.
--   토큰 만료(invalid_grant)는 슬롯을 반환하지 않는다. 사용자 해제(youtube_clear_token)만 반환한다.
-- - 한도 = private.channel_quotas.channel_limit, 행이 없으면 1. 기존 계정은 지금 슬롯 수(2 이상)를 한도로 기록한다.
-- - 회전 제한: 지난 30일 first_connected_at 이 3개 이상이면 새 채널(처음 연결하는 행) 연결 거부.
-- - 초과 채널(순위 is_default desc → first_connected_at asc → id 가 한도를 넘는 행): 연결 유지, 새 프로젝트·프로젝트 채널 변경만 거부.
-- - 거부도 감사 이벤트로 남겨야 하므로 youtube_save_connection 은 CS001~CS003 을 예외가 아니라 반환값으로 알린다
--   (예외면 이벤트까지 롤백된다). 반환: connected | reconnect_required | CS001 | CS002 | CS003.
-- - 발행 예약 거부(prepare_publication)·is_default 변경 우회 차단은 034b.

-- ── 1) 한도 ───────────────────────────────────────────────
create table private.channel_quotas (
  user_id uuid primary key references auth.users (id) on delete cascade,
  channel_limit integer not null check (channel_limit between 1 and 50),
  updated_at timestamptz not null default now()
);
comment on table private.channel_quotas is
  '사용자별 채널 연결 한도(행 없음 = 1). 함수로만 읽는다. 요금제·구독은 P1 결제 작업';
alter table private.channel_quotas enable row level security;
revoke all on private.channel_quotas from public, anon, authenticated, service_role;

-- ── 2) accounts: 처음 연결 시각 · 해제 시각(서버 전용) ─────────
alter table public.accounts
  add column first_connected_at timestamptz,
  add column disconnected_at timestamptz;
comment on column public.accounts.first_connected_at is
  '처음 external_channel_id 를 저장한 시각(이후 불변). 30일 새 채널 연결 수·초과 채널 순위. 서버 전용';
comment on column public.accounts.disconnected_at is
  '사용자 해제 시각(슬롯 반환). 재연결하면 null. 토큰 만료는 여기에 쓰지 않는다. 서버 전용';
-- 열 GRANT 는 열 이름을 나열하는 방식이라 새 열은 authenticated 에 열리지 않는다(2중으로 회수).
revoke select (first_connected_at, disconnected_at), insert (first_connected_at, disconnected_at),
       update (first_connected_at, disconnected_at)
  on public.accounts from anon, authenticated;
-- 읽기만 연다: 만료돼도 슬롯을 차지한 채널에 설정 화면이 해제 버튼을 보여 주기 위함(쓰기는 서버 전용 유지)
grant select (first_connected_at, disconnected_at) on public.accounts to authenticated;

update public.accounts set first_connected_at = created_at where external_channel_id is not null;

-- 사용자 INSERT 에서 서버 전용 열 초기값 강제(270000 함수에 새 열 추가)
create or replace function private.accounts_force_server_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('postgres', 'service_role', 'supabase_admin') then
    new.oauth_token_ref := null;
    new.status := 'reconnect_required';
    new.external_channel_id := null;
    new.first_connected_at := null;
    new.disconnected_at := null;
  end if;
  return new;
end;
$$;
revoke execute on function private.accounts_force_server_columns() from public, anon, authenticated;

-- 기존 계정: 지금 슬롯 수가 2 이상이면 그 수를 한도로(이미 한도 행이 있으면 두고). 테스트가 같은 규칙을 다시 부를 수 있게 함수로 둔다.
create function private.channel_quotas_seed()
returns integer
language sql
security definer
set search_path = ''
as $$
  with ins as (
    insert into private.channel_quotas (user_id, channel_limit)
    select a.user_id, least(count(*), 50)::int
    from public.accounts a
    where a.platform in ('youtube', 'instagram', 'tiktok')
      and a.external_channel_id is not null and a.disconnected_at is null
    group by a.user_id
    having count(*) >= 2
    on conflict (user_id) do nothing
    returning 1
  )
  select count(*)::int from ins;
$$;
revoke execute on function private.channel_quotas_seed() from public, anon, authenticated, service_role;
select private.channel_quotas_seed();

-- ── 3) 감사 이벤트 ─────────────────────────────────────────
create table public.channel_slot_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  account_id uuid references public.accounts (id) on delete set null,
  kind text not null check (kind in ('connect', 'reconnect', 'disconnect', 'expire',
                                     'reject_limit', 'reject_rotation', 'reject_duplicate')),
  -- 기록 시점의 슬롯 수·한도(연결·해제는 반영 뒤 값)
  slots integer not null check (slots >= 0),
  channel_limit integer not null check (channel_limit >= 1),
  created_at timestamptz not null default now()
);
comment on table public.channel_slot_events is
  '채널 연결·해제·만료·한도 거부 감사 기록. 함수만 쓰고 본인만 읽는다. 토큰·이메일·code·state 원문 없음';
create index channel_slot_events_user_id_created_at_idx on public.channel_slot_events (user_id, created_at desc);
create index channel_slot_events_account_id_idx on public.channel_slot_events (account_id);

alter table public.channel_slot_events enable row level security;
revoke all on public.channel_slot_events from public, anon, authenticated, service_role;
grant select on public.channel_slot_events to authenticated;
create policy channel_slot_events_select_own on public.channel_slot_events
  for select to authenticated using (user_id = (select auth.uid()));

-- ── 4) 슬롯 계산 ───────────────────────────────────────────
create function private.channel_limit_of(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select q.channel_limit from private.channel_quotas q where q.user_id = p_user_id), 1);
$$;
revoke execute on function private.channel_limit_of(uuid) from public, anon, authenticated, service_role;

create function private.channel_slot_count(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.accounts a
  where a.user_id = p_user_id and a.platform in ('youtube', 'instagram', 'tiktok')
    and a.external_channel_id is not null and a.disconnected_at is null;
$$;
revoke execute on function private.channel_slot_count(uuid) from public, anon, authenticated, service_role;

-- 초과 채널: 슬롯 보유 행을 is_default desc → first_connected_at asc → id 로 매긴 순위가 한도보다 큰 행
create function private.channel_is_excess(p_user_id uuid, p_account_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select r.rn > private.channel_limit_of(p_user_id)
    from (select a.id,
                 row_number() over (order by a.is_default desc, a.first_connected_at asc nulls last, a.id) as rn
          from public.accounts a
          where a.user_id = p_user_id and a.platform in ('youtube', 'instagram', 'tiktok')
            and a.external_channel_id is not null and a.disconnected_at is null) r
    where r.id = p_account_id), false);
$$;
revoke execute on function private.channel_is_excess(uuid, uuid) from public, anon, authenticated, service_role;

create function private.channel_slot_log(p_user_id uuid, p_account_id uuid, p_kind text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.channel_slot_events (user_id, account_id, kind, slots, channel_limit)
  values (p_user_id, p_account_id, p_kind, private.channel_slot_count(p_user_id), private.channel_limit_of(p_user_id));
$$;
revoke execute on function private.channel_slot_log(uuid, uuid, text) from public, anon, authenticated, service_role;

-- 연결 가능 여부(웹 사전 검사 + youtube_save_connection 최종 검사). 채널 id 를 모르므로 CS003 은 여기서 보지 않는다.
-- p_account_id 가 없으면 새 채널 기준. code: null(통과) | CS001(한도) | CS002(30일 새 채널 3회, next_at = 다시 가능한 시각)
create function private.channel_slot_status(p_user_id uuid, p_account_id uuid default null)
returns table (slots integer, channel_limit integer, recent_new integer, allowed boolean, code text,
               next_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acc public.accounts;
  v_holding boolean := false;
  v_first boolean := true;
  v_slots integer;
  v_limit integer;
  v_recent integer;
  v_code text;
  v_next timestamptz;
begin
  if p_user_id is null then
    raise exception '연결할 수 없는 계정입니다' using errcode = '42501';
  end if;
  if p_account_id is not null then
    select a.* into v_acc from public.accounts a
    where a.id = p_account_id and a.user_id = p_user_id and a.platform = 'youtube';
    if v_acc.id is null then
      raise exception '연결할 수 없는 계정입니다' using errcode = '42501';
    end if;
    v_holding := v_acc.external_channel_id is not null and v_acc.disconnected_at is null;
    v_first := v_acc.first_connected_at is null;
  end if;
  v_slots := private.channel_slot_count(p_user_id);
  v_limit := private.channel_limit_of(p_user_id);
  select count(*)::int into v_recent from public.accounts a
  where a.user_id = p_user_id and a.platform in ('youtube', 'instagram', 'tiktok')
    and a.first_connected_at > now() - interval '30 days';

  if not v_holding then
    if v_slots >= v_limit then
      v_code := 'CS001';
    elsif v_first and v_recent >= 3 then
      v_code := 'CS002';
      -- 30일 창에서 3개 미만이 되는 시각 = (v_recent - 2)번째로 오래된 연결 + 30일
      select f.first_connected_at + interval '30 days' into v_next
      from public.accounts f
      where f.user_id = p_user_id and f.platform in ('youtube', 'instagram', 'tiktok')
        and f.first_connected_at > now() - interval '30 days'
      order by f.first_connected_at asc
      offset v_recent - 3 limit 1;
    end if;
  end if;
  return query select v_slots, v_limit, v_recent, v_code is null, v_code, v_next;
end;
$$;
revoke execute on function private.channel_slot_status(uuid, uuid) from public, anon, authenticated, service_role;

-- ── 5) 연결 저장 교체(기준: 20261112270200) — 사용자 잠금 · 한도 · 회전 · 본인 중복 ──
create or replace function private.youtube_save_connection(p_user_id uuid, p_account_id uuid, p_channel_id text,
                                                           p_refresh_token text, p_scopes text[])
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acc public.accounts;
  v_ref uuid;
  v_old uuid;
  v_token text := nullif(btrim(coalesce(p_refresh_token, '')), '');
  v_holding boolean;
  v_code text;
begin
  -- 같은 사용자의 동시 콜백은 줄 세운다(슬롯 수 판정 경쟁 방지)
  perform pg_advisory_xact_lock(hashtextextended('channel_slots:' || p_user_id::text, 0));
  select a.* into v_acc from public.accounts a
  where a.id = p_account_id and a.user_id = p_user_id and a.platform = 'youtube'
  for update;
  if v_acc.id is null then
    raise exception '연결할 수 없는 계정입니다' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_channel_id, '')), '') is null then
    raise exception '채널 정보가 없습니다' using errcode = '22023';
  end if;
  if v_acc.external_channel_id is not null and v_acc.external_channel_id <> p_channel_id then
    raise exception '이 계정에 연결된 채널과 다른 채널입니다' using errcode = 'OA001';
  end if;
  if not (coalesce(p_scopes, '{}') @> array[
            'https://www.googleapis.com/auth/youtube.upload',
            'https://www.googleapis.com/auth/youtube.readonly',
            'https://www.googleapis.com/auth/yt-analytics.readonly']) then
    raise exception '필수 권한이 빠졌습니다' using errcode = 'OA002';
  end if;

  -- 이미 슬롯을 가진 행(같은 채널 재인증·만료 재연결)은 한도와 무관하게 통과
  v_holding := v_acc.external_channel_id is not null and v_acc.disconnected_at is null;
  if not v_holding then
    if exists (select 1 from public.accounts a
               where a.platform = 'youtube' and a.external_channel_id = p_channel_id
                 and a.id <> p_account_id and a.user_id = p_user_id) then
      perform private.channel_slot_log(p_user_id, p_account_id, 'reject_duplicate');
      return 'CS003';
    end if;
    if exists (select 1 from public.accounts a
               where a.platform = 'youtube' and a.external_channel_id = p_channel_id
                 and a.user_id <> p_user_id) then
      raise exception '이미 다른 계정에 연결된 채널입니다' using errcode = '23505';
    end if;
    select s.code into v_code from private.channel_slot_status(p_user_id, p_account_id) s;
    if v_code = 'CS001' then
      perform private.channel_slot_log(p_user_id, p_account_id, 'reject_limit');
      return 'CS001';
    elsif v_code = 'CS002' then
      perform private.channel_slot_log(p_user_id, p_account_id, 'reject_rotation');
      return 'CS002';
    end if;
  end if;

  v_ref := v_acc.oauth_token_ref;
  if v_ref is not null and not exists (select 1 from vault.secrets s where s.id = v_ref) then
    v_ref := null;
  end if;
  if v_token is not null then
    v_old := v_ref;
    v_ref := vault.create_secret(v_token, null, 'youtube refresh token');
  end if;

  update public.accounts a
  set external_channel_id = p_channel_id,
      oauth_token_ref = v_ref,
      status = case when v_ref is null then 'reconnect_required' else 'connected' end,
      first_connected_at = coalesce(a.first_connected_at, now()),
      disconnected_at = null
  where a.id = p_account_id;
  if v_old is not null then
    delete from vault.secrets s where s.id = v_old;
  end if;
  perform private.channel_slot_log(p_user_id, p_account_id,
                                   case when v_holding then 'reconnect' else 'connect' end);
  return case when v_ref is null then 'reconnect_required' else 'connected' end;
end;
$$;
revoke execute on function private.youtube_save_connection(uuid, uuid, text, text, text[])
  from public, anon, authenticated, service_role;

-- ── 6) 해제(기준: 20261112270000) — 사용자 해제면 슬롯 반환 ───
create or replace function private.youtube_clear_token(p_account_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acc public.accounts;
begin
  select a.* into v_acc from public.accounts a
  where a.id = p_account_id and a.platform = 'youtube'
  for update;
  if v_acc.id is null or (p_user_id is not null and v_acc.user_id <> p_user_id) then
    raise exception '연결할 수 없는 계정입니다' using errcode = '42501';
  end if;
  -- p_user_id 가 있으면 사용자 해제(슬롯 반환), 없으면 서버 내부 경로(만료와 같이 슬롯 유지)
  update public.accounts a
  set oauth_token_ref = null, status = 'reconnect_required',
      disconnected_at = case when p_user_id is not null then now() else a.disconnected_at end
  where a.id = p_account_id;
  if v_acc.oauth_token_ref is not null then
    delete from vault.secrets s where s.id = v_acc.oauth_token_ref;
  end if;
  perform private.channel_slot_log(v_acc.user_id, p_account_id,
                                   case when p_user_id is not null then 'disconnect' else 'expire' end);
end;
$$;
revoke execute on function private.youtube_clear_token(uuid, uuid) from public, anon, authenticated, service_role;

-- ── 7) invalid_grant(기준: 20261112270200) — 슬롯 유지, 이벤트만 ──
create or replace function private.youtube_expire_token(p_account_id uuid, p_token_ref uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
begin
  if p_token_ref is null then
    return false;
  end if;
  update public.accounts a
  set oauth_token_ref = null, status = 'reconnect_required'
  where a.id = p_account_id and a.platform = 'youtube' and a.oauth_token_ref = p_token_ref
  returning a.user_id into v_user;
  if not found then
    return false;
  end if;
  delete from vault.secrets s where s.id = p_token_ref;
  perform private.channel_slot_log(v_user, p_account_id, 'expire');
  return true;
end;
$$;
revoke execute on function private.youtube_expire_token(uuid, uuid) from public, anon, authenticated, service_role;

-- ── 8) 초과 채널로 새 프로젝트·채널 변경 거부 ──────────────────
-- 1 프로젝트 = 1 채널·첫 발행 뒤 변경 불가(publications 복합 FK)는 그대로 둔다.
create function private.projects_channel_slot_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.account_id is not distinct from old.account_id then
    return new;
  end if;
  if private.channel_is_excess(new.user_id, new.account_id) then
    raise exception '이 채널은 요금제 채널 수를 넘어 새 프로젝트를 만들 수 없습니다' using errcode = 'CS004';
  end if;
  return new;
end;
$$;
revoke execute on function private.projects_channel_slot_guard() from public, anon, authenticated, service_role;

create trigger projects_channel_slot_guard
  before insert or update of account_id on public.projects
  for each row execute function private.projects_channel_slot_guard();

-- ── 9) public 래퍼(service_role 만) ──────────────────────────
create function public.channel_slot_status(p_user_id uuid, p_account_id uuid default null)
returns table (slots integer, channel_limit integer, recent_new integer, allowed boolean, code text,
               next_at timestamptz)
language sql
security definer
set search_path = ''
as $$
  select * from private.channel_slot_status(p_user_id, p_account_id);
$$;
revoke execute on function public.channel_slot_status(uuid, uuid) from public, anon, authenticated;
grant execute on function public.channel_slot_status(uuid, uuid) to service_role;
comment on function public.channel_slot_status(uuid, uuid) is
  '채널 연결 사전 검사(서버 전용): 슬롯 수·한도·30일 새 연결 수·통과 여부·예상 코드(CS001·CS002)';

-- 기존 래퍼 권한 다시 명시(본체 교체로 바뀌지 않지만 계약을 이 파일에서도 확인할 수 있게)
revoke execute on function public.youtube_save_connection(uuid, uuid, text, text, text[]) from public, anon, authenticated;
revoke execute on function public.youtube_clear_token(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.youtube_expire_token(uuid, uuid) from public, anon, authenticated;
grant execute on function public.youtube_save_connection(uuid, uuid, text, text, text[]) to service_role;
grant execute on function public.youtube_clear_token(uuid, uuid) to service_role;
grant execute on function public.youtube_expire_token(uuid, uuid) to service_role;
