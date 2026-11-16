-- 레이트 리밋 내부판: 제품의 security definer RPC(anon·authenticated가 부르는 함수) 안에서 쓰는 rate_limit_take.
-- rate_limit_hit은 서버(service_role) 전용이라 사용자 RPC 안에서 못 부른다 → 같은 테이블·같은 고정 윈도우 로직을 서버 판별 없이 둔다.
-- execute는 아무 역할에도 주지 않는다 = 함수 소유자(postgres)가 만든 security definer 함수만 호출할 수 있다.
-- 되돌림: drop function nomad_core.rate_limit_take(text, integer, integer);
begin;

-- 키는 호출 함수가 만든 값만 쓴다('<제품>:' 접두사 필수, 예: 'erp:join:<user_id>'. 사용자 입력 원문 금지). 같은 키에는 항상 같은 한도·윈도우.
-- 호출 1회 = 1 히트. 반환·동작은 rate_limit_hit과 같다. 호출 함수가 raise하면 이번 히트도 롤백되므로,
-- 실패도 세려면 호출 함수는 거부를 raise 대신 결과 값으로 돌려준다.
create function nomad_core.rate_limit_take(p_key text, p_limit integer, p_window_seconds integer)
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
  -- 제품 키 공간 분리: '<제품>:' 접두사 필수(예 'erp:join:…', 'floria:inq:…')
  if p_key is null or length(p_key) not between 1 and 200 or p_key !~ '^[a-z0-9_]+:' then
    raise exception 'rate_limit_take: invalid key' using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_window_seconds is null or p_window_seconds < 1 then
    raise exception 'rate_limit_take: limit and window must be >= 1' using errcode = '22023';
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

revoke execute on function nomad_core.rate_limit_take(text, integer, integer)
  from public, anon, authenticated, service_role;
comment on function nomad_core.rate_limit_take(text, integer, integer) is
  '제품 security definer RPC 내부용 고정 윈도우 레이트 리밋(서버 판별 없음). execute grant 없음 — 소유자 함수만 호출.';

commit;
