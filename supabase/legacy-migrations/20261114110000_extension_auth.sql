-- task-015b-1 확장 토큰 발급·제자리 회전·폐기, DB 속도 제한
-- 근거: tasks/task-015b.md "결정 보강", docs/adr/0003-extension-server-auth.md
-- - 신원 단위 = extension_connections 행. 회전은 같은 행 제자리 갱신(prev 해시·rotated_at·activated_at 열 추가).
-- - 토큰 원문은 앱이 SHA-256(소문자 hex 64자)으로 바꿔 해시만 DB 로 보낸다. DB 에는 원문이 닿지 않는다.
-- - 갱신은 `refresh_token_hash = old and revoked_at is null` 원자적 CAS 로 1건만 성공. 유예 없음:
--   직전 해시(prev) 재사용 = 그 행 즉시 폐기.
-- - 발급 후 첫 하트비트 전(activated_at null) 10분 지난 행은 스위퍼가 폐기(20261114110200).
-- - 속도 제한: private.rate_hit(고정 창 카운터). 키·한도는 서버가 정한다(값은 task-015b 결정).
-- - 함수는 서버(service_role)가 public 래퍼로 부른다. anon·authenticated EXECUTE 없음.

alter table public.extension_connections
  add column prev_refresh_token_hash text,
  add column rotated_at timestamptz,
  add column activated_at timestamptz;
comment on column public.extension_connections.prev_refresh_token_hash is '직전 갱신 토큰 해시. 재사용 감지용(재사용 시 행 폐기). 원문 저장 금지';
comment on column public.extension_connections.rotated_at is '마지막 회전 시각';
comment on column public.extension_connections.activated_at is '발급 후 첫 하트비트 시각. null 로 10분 지나면 스위퍼가 폐기';
create index extension_connections_prev_refresh_idx on public.extension_connections (prev_refresh_token_hash)
  where prev_refresh_token_hash is not null;
-- 이미 쓰던 연결은 활성으로 본다(새 열이 스위퍼에 걸리지 않게)
update public.extension_connections set activated_at = coalesce(last_heartbeat_at, created_at) where activated_at is null;
-- authenticated 읽기 권한은 열 단위 목록이라 새 열(해시·prev 포함)은 노출되지 않는다

-- ── 속도 제한 카운터 ─────────────────────────────────────────
create table private.rate_counters (
  key text not null check (char_length(key) <= 200),
  window_start timestamptz not null,
  hits integer not null default 0,
  primary key (key, window_start)
);
alter table private.rate_counters enable row level security;
revoke all on private.rate_counters from public, anon, authenticated, service_role, worker_role;
create index rate_counters_window_idx on private.rate_counters (window_start);

-- 한도 안이면 true, 초과면 false(초과 시도도 센다). 창은 p_window_seconds 단위 고정 창
create function private.rate_hit(p_key text, p_limit integer, p_window_seconds integer)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_start timestamptz;
  v_hits integer;
begin
  if p_key is null or char_length(p_key) not between 1 and 200
     or p_limit is null or p_limit not between 1 and 100000
     or p_window_seconds is null or p_window_seconds not between 1 and 86400 then
    raise exception '속도 제한 인자가 올바르지 않습니다' using errcode = '22023';
  end if;
  v_start := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  insert into private.rate_counters as c (key, window_start, hits)
  values (p_key, v_start, 1)
  on conflict (key, window_start) do update set hits = c.hits + 1
  returning c.hits into v_hits;
  return v_hits <= p_limit;
end;
$$;
revoke execute on function private.rate_hit(text, integer, integer) from public, anon, authenticated;
grant execute on function private.rate_hit(text, integer, integer) to service_role;

-- ── 발급 ────────────────────────────────────────────────────
-- 액세스 15분 · 갱신 30일. 해시는 SHA-256 소문자 hex 64자만 받는다
create function private.ext_issue(p_user_id uuid, p_access_hash text, p_refresh_hash text)
returns table (extension_id uuid, access_expires_at timestamptz, refresh_expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if p_access_hash is null or p_access_hash !~ '^[0-9a-f]{64}$'
     or p_refresh_hash is null or p_refresh_hash !~ '^[0-9a-f]{64}$'
     or p_access_hash = p_refresh_hash then
    raise exception '토큰 해시 형식이 올바르지 않습니다' using errcode = '22023';
  end if;
  return query
  insert into public.extension_connections as e
    (user_id, access_token_hash, access_expires_at, refresh_token_hash, refresh_expires_at, family_id)
  values (p_user_id, p_access_hash, now() + interval '15 minutes', p_refresh_hash, now() + interval '30 days',
          gen_random_uuid())
  returning e.id, e.access_expires_at, e.refresh_expires_at;
end;
$$;
revoke execute on function private.ext_issue(uuid, text, text) from public, anon, authenticated;
grant execute on function private.ext_issue(uuid, text, text) to service_role;

-- ── 액세스 토큰 검사: 유효하면 1행, 폐기·만료면 0행 ──────────
create function private.ext_authenticate(p_access_hash text)
returns table (extension_id uuid, user_id uuid)
language sql
security definer
set search_path = ''
as $$
  select e.id, e.user_id
  from public.extension_connections e
  where e.access_token_hash = p_access_hash
    and e.revoked_at is null
    and e.access_expires_at > now()
    and e.refresh_expires_at > now();
$$;
revoke execute on function private.ext_authenticate(text) from public, anon, authenticated;
grant execute on function private.ext_authenticate(text) to service_role;

-- ── 회전(제자리) ────────────────────────────────────────────
-- result: ok(새 토큰 저장됨) · reused(직전 해시 재사용 → 그 행 폐기) · invalid(없음·폐기·만료)
create function private.ext_rotate(p_old_refresh_hash text, p_new_access_hash text, p_new_refresh_hash text)
returns table (result text, extension_id uuid, access_expires_at timestamptz, refresh_expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_id uuid;
  v_access timestamptz;
  v_refresh timestamptz;
begin
  if p_new_access_hash is null or p_new_access_hash !~ '^[0-9a-f]{64}$'
     or p_new_refresh_hash is null or p_new_refresh_hash !~ '^[0-9a-f]{64}$'
     or p_new_access_hash = p_new_refresh_hash then
    raise exception '토큰 해시 형식이 올바르지 않습니다' using errcode = '22023';
  end if;

  -- CAS: 같은 갱신 토큰으로 동시에 와도 1건만 갱신된다(나머지는 행 잠금을 기다린 뒤 조건 불일치)
  update public.extension_connections e
  set prev_refresh_token_hash = e.refresh_token_hash,
      refresh_token_hash = p_new_refresh_hash,
      access_token_hash = p_new_access_hash,
      access_expires_at = now() + interval '15 minutes',
      refresh_expires_at = now() + interval '30 days',
      rotated_at = now()
  where e.refresh_token_hash = p_old_refresh_hash
    and e.revoked_at is null
    and e.refresh_expires_at > now()
  returning e.id, e.access_expires_at, e.refresh_expires_at into v_id, v_access, v_refresh;
  if found then
    return query select 'ok'::text, v_id, v_access, v_refresh;
    return;
  end if;

  -- 이미 회전된 토큰의 재사용(유예 없음): 그 행 폐기
  update public.extension_connections e
  set revoked_at = now()
  where e.prev_refresh_token_hash = p_old_refresh_hash and e.revoked_at is null
  returning e.id into v_id;
  if found then
    return query select 'reused'::text, v_id, null::timestamptz, null::timestamptz;
    return;
  end if;

  return query select 'invalid'::text, null::uuid, null::timestamptz, null::timestamptz;
end;
$$;
revoke execute on function private.ext_rotate(text, text, text) from public, anon, authenticated;
grant execute on function private.ext_rotate(text, text, text) to service_role;

-- ── 폐기: 그 사용자의 행만. 새로 폐기하면 true ──────────────
-- 확장 자체 해제·S-19 폐기 버튼·전달 실패 즉시 폐기가 같이 쓴다(호출자가 사용자 id 를 확정해 넘긴다)
create function private.ext_revoke(p_extension_id uuid, p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.extension_connections e
  set revoked_at = now()
  where e.id = p_extension_id and e.user_id = p_user_id and e.revoked_at is null;
  return found;
end;
$$;
revoke execute on function private.ext_revoke(uuid, uuid) from public, anon, authenticated;
grant execute on function private.ext_revoke(uuid, uuid) to service_role;

-- ── 하트비트: 첫 하트비트에 activated_at 기록(20261112240000 그대로 + activated_at) ──
create or replace function private.ext_heartbeat(p_extension_id uuid)
returns table (id uuid, type text, payload jsonb)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_user uuid;
begin
  update public.extension_connections e
  set last_heartbeat_at = now(),
      activated_at = coalesce(e.activated_at, now())
  where e.id = p_extension_id and e.revoked_at is null
  returning e.user_id into v_user;
  if v_user is null then
    raise exception '확장 연결을 찾을 수 없거나 폐기됐습니다' using errcode = '42501';
  end if;

  return query
  select j.id, j.type, j.payload
  from public.jobs j
  join public.projects p on p.id = j.project_id
  where p.user_id = v_user
    and j.status = 'waiting_extension'
    and j.type in ('collect', 'collect_download')
  order by coalesce(j.waiting_since, j.created_at), j.id
  limit 1;
end;
$$;

-- ── 서버(service_role) 전용 래퍼 ─────────────────────────────
create function public.extension_issue(p_user_id uuid, p_access_hash text, p_refresh_hash text)
returns table (extension_id uuid, access_expires_at timestamptz, refresh_expires_at timestamptz)
language sql
security invoker
set search_path = ''
as $$
  select * from private.ext_issue(p_user_id, p_access_hash, p_refresh_hash);
$$;
comment on function public.extension_issue(uuid, text, text) is '확장 토큰 발급(서버 전용). 해시만 저장, 액세스 15분·갱신 30일';

create function public.extension_authenticate(p_access_hash text)
returns table (extension_id uuid, user_id uuid)
language sql
security invoker
set search_path = ''
as $$
  select * from private.ext_authenticate(p_access_hash);
$$;
comment on function public.extension_authenticate(text) is '확장 액세스 토큰 검사(서버 전용). 폐기·만료면 0행';

create function public.extension_rotate(p_old_refresh_hash text, p_new_access_hash text, p_new_refresh_hash text)
returns table (result text, extension_id uuid, access_expires_at timestamptz, refresh_expires_at timestamptz)
language sql
security invoker
set search_path = ''
as $$
  select * from private.ext_rotate(p_old_refresh_hash, p_new_access_hash, p_new_refresh_hash);
$$;
comment on function public.extension_rotate(text, text, text) is '확장 토큰 제자리 회전(서버 전용). result ok·reused(행 폐기)·invalid';

create function public.extension_revoke(p_extension_id uuid, p_user_id uuid)
returns boolean
language sql
security invoker
set search_path = ''
as $$
  select private.ext_revoke(p_extension_id, p_user_id);
$$;
comment on function public.extension_revoke(uuid, uuid) is '확장 연결 폐기(서버 전용). 그 사용자의 행만';

create function public.extension_rate_hit(p_key text, p_limit integer, p_window_seconds integer)
returns boolean
language sql
security invoker
set search_path = ''
as $$
  select private.rate_hit(p_key, p_limit, p_window_seconds);
$$;
comment on function public.extension_rate_hit(text, integer, integer) is '속도 제한 카운터(서버 전용). 한도 안 true · 초과 false';

revoke execute on function public.extension_issue(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.extension_authenticate(text) from public, anon, authenticated;
revoke execute on function public.extension_rotate(text, text, text) from public, anon, authenticated;
revoke execute on function public.extension_revoke(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.extension_rate_hit(text, integer, integer) from public, anon, authenticated;
grant execute on function public.extension_issue(uuid, text, text) to service_role;
grant execute on function public.extension_authenticate(text) to service_role;
grant execute on function public.extension_rotate(text, text, text) to service_role;
grant execute on function public.extension_revoke(uuid, uuid) to service_role;
grant execute on function public.extension_rate_hit(text, integer, integer) to service_role;
