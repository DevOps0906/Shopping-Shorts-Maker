-- 코어 웨이브 1단계 C3: 고정 윈도우 레이트 리밋(Redis가 없는 제품의 기본값). 서버(service_role) 전용.
-- 원본: platform-docs _supabase-modular 0004_core_security.sql 7장(core.rate_limit_buckets·rate_limit_hit·purge_rate_limit_buckets).
-- 되돌림: drop function nomad_core.purge_rate_limit_buckets(interval), nomad_core.rate_limit_hit(text, integer, integer);
--   drop table nomad_core.rate_limit_buckets;
begin;

create table nomad_core.rate_limit_buckets (
  key text primary key check (length(key) between 1 and 200),
  window_start timestamptz not null,
  window_end timestamptz not null,  -- 이 윈도우가 끝나는 시각. 정리는 이 값 기준(긴 윈도우가 정리로 초기화되지 않게)
  count integer not null default 0 check (count >= 0),
  updated_at timestamptz not null default now()
);
create index rate_limit_buckets_window_end_idx on nomad_core.rate_limit_buckets (window_end);
comment on table nomad_core.rate_limit_buckets is
  '고정 윈도우 레이트 리밋 카운터(키당 1행). 서버 전용 — 읽기·쓰기는 rate_limit_hit·purge_rate_limit_buckets 함수로만.';

-- 사용자 정책 없음 = authenticated·anon 접근 0. 테이블 권한도 주지 않는다(함수가 SECURITY DEFINER로 쓴다).
alter table nomad_core.rate_limit_buckets enable row level security;
revoke all on nomad_core.rate_limit_buckets from public, anon, authenticated, service_role;

-- 키는 서버가 정규화·해시한 값만 쓴다(사용자 입력 원문 금지 — 행 무한 증가 방지). 같은 키에는 항상 같은 한도·윈도우를 쓴다.
-- 시각은 clock_timestamp()(트랜잭션 시작 시각 now()가 아니라 호출 시각). 오류 시 호출 측은 거부(fail-closed)로 처리한다.
-- 호출 1회 = 1 히트. 반환: allowed(이번 히트가 한도 안인지), remaining, reset_at(윈도우 끝).
-- insert … on conflict do update 한 문장이라 같은 키 동시 호출도 행 잠금으로 직렬화되어 누락·중복 행이 없다.
create function nomad_core.rate_limit_hit(p_key text, p_limit integer, p_window_seconds integer)
returns table (allowed boolean, remaining integer, reset_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
  v_start timestamptz;
  v_win interval;
  v_now timestamptz := clock_timestamp();
begin
  if not nomad_core.is_service_caller() then
    raise exception 'rate_limit_hit: server only' using errcode = '42501';
  end if;
  if p_key is null or length(p_key) not between 1 and 200 then
    raise exception 'rate_limit_hit: invalid key' using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_window_seconds is null or p_window_seconds < 1 then
    raise exception 'rate_limit_hit: limit and window must be >= 1' using errcode = '22023';
  end if;

  v_win := make_interval(secs => p_window_seconds);
  insert into nomad_core.rate_limit_buckets as b (key, window_start, window_end, count, updated_at)
  values (p_key, v_now, v_now + v_win, 1, v_now)
  on conflict (key) do update
    set count        = case when b.window_start + v_win <= v_now then 1 else b.count + 1 end,
        window_start = case when b.window_start + v_win <= v_now then v_now else b.window_start end,
        window_end   = case when b.window_start + v_win <= v_now then v_now + v_win else b.window_start + v_win end,
        updated_at   = v_now
  returning b.count, b.window_start into v_count, v_start;

  return query select v_count <= p_limit, greatest(p_limit - v_count, 0), v_start + v_win;
end;
$$;

-- 윈도우가 끝난 지 p_older_than 넘게 지난 키만 정리(진행 중 윈도우는 지우지 않음). 스케줄링(pg_cron 등)은 제품 몫이며 반드시 건다. 반환: 지운 행 수.
create function nomad_core.purge_rate_limit_buckets(p_older_than interval default interval '1 day')
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'purge_rate_limit_buckets: server only' using errcode = '42501';
  end if;
  if p_older_than is null or p_older_than < interval '0' then
    raise exception 'purge_rate_limit_buckets: p_older_than must be >= 0' using errcode = '22023';
  end if;
  delete from nomad_core.rate_limit_buckets where window_end < clock_timestamp() - p_older_than;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function nomad_core.rate_limit_hit(text, integer, integer), nomad_core.purge_rate_limit_buckets(interval)
  from public, anon, authenticated;
grant execute on function nomad_core.rate_limit_hit(text, integer, integer), nomad_core.purge_rate_limit_buckets(interval)
  to service_role;

commit;
