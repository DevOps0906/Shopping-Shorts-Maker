-- task-025 단축 링크 클릭 기록·성과 수집(20261113100000) 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/analytics_links_metrics.sql
-- 한 트랜잭션으로 돌리고 ROLLBACK 한다. 트랜잭션 안에서는 now() 가 고정이라 "최근 10분" 조건이 모두 참이다.
-- A = 소유자, B = 남. 발행 T(대상) · R(재연결 필요) · I(인스타) · N(업로드 전) · O(40일 전) · C(방금 수집)
begin;

insert into auth.users (id, aud, role, email) values
  ('00000000-0000-4000-f025-00000000000a', 'authenticated', 'authenticated', 'rls-test-an-a@example.com'),
  ('00000000-0000-4000-f025-00000000000b', 'authenticated', 'authenticated', 'rls-test-an-b@example.com');
insert into public.accounts (id, user_id, platform, channel_name, status) values
  ('00000000-0000-4000-f025-0000000001a1', '00000000-0000-4000-f025-00000000000a', 'youtube', 'A 유튜브', 'connected'),
  ('00000000-0000-4000-f025-0000000001a2', '00000000-0000-4000-f025-00000000000a', 'youtube', 'A 재연결', 'reconnect_required'),
  ('00000000-0000-4000-f025-0000000001a3', '00000000-0000-4000-f025-00000000000a', 'instagram', 'A 인스타', 'connected');
insert into public.projects (id, user_id, account_id, name) values
  ('00000000-0000-4000-f025-0000000002a1', '00000000-0000-4000-f025-00000000000a', '00000000-0000-4000-f025-0000000001a1', 'T'),
  ('00000000-0000-4000-f025-0000000002a2', '00000000-0000-4000-f025-00000000000a', '00000000-0000-4000-f025-0000000001a2', 'R'),
  ('00000000-0000-4000-f025-0000000002a3', '00000000-0000-4000-f025-00000000000a', '00000000-0000-4000-f025-0000000001a3', 'I'),
  ('00000000-0000-4000-f025-0000000002a4', '00000000-0000-4000-f025-00000000000a', '00000000-0000-4000-f025-0000000001a1', 'N'),
  ('00000000-0000-4000-f025-0000000002a5', '00000000-0000-4000-f025-00000000000a', '00000000-0000-4000-f025-0000000001a1', 'O'),
  ('00000000-0000-4000-f025-0000000002a6', '00000000-0000-4000-f025-00000000000a', '00000000-0000-4000-f025-0000000001a1', 'C');
insert into public.publications (id, project_id, account_id, mode, status, platform_video_id, published_at) values
  ('00000000-0000-4000-f025-0000000003a1', '00000000-0000-4000-f025-0000000002a1', '00000000-0000-4000-f025-0000000001a1', 'now', 'uploaded', 'vidT', now() - interval '2 days'),
  ('00000000-0000-4000-f025-0000000003a2', '00000000-0000-4000-f025-0000000002a2', '00000000-0000-4000-f025-0000000001a2', 'now', 'uploaded', 'vidR', now() - interval '2 days'),
  ('00000000-0000-4000-f025-0000000003a3', '00000000-0000-4000-f025-0000000002a3', '00000000-0000-4000-f025-0000000001a3', 'now', 'uploaded', 'vidI', now() - interval '2 days'),
  ('00000000-0000-4000-f025-0000000003a4', '00000000-0000-4000-f025-0000000002a4', '00000000-0000-4000-f025-0000000001a1', 'now', 'pending', null, null),
  ('00000000-0000-4000-f025-0000000003a5', '00000000-0000-4000-f025-0000000002a5', '00000000-0000-4000-f025-0000000001a1', 'now', 'uploaded', 'vidO', now() - interval '40 days'),
  ('00000000-0000-4000-f025-0000000003a6', '00000000-0000-4000-f025-0000000002a6', '00000000-0000-4000-f025-0000000001a1', 'now', 'uploaded', 'vidC', now() - interval '2 days');
insert into public.video_metrics (publication_id, date, views, collected_at) values
  ('00000000-0000-4000-f025-0000000003a6', current_date - 1, 10, now() - interval '1 hour');
insert into public.affiliate_links (id, project_id, program, url, short_url) values
  ('00000000-0000-4000-f025-0000000004a1', '00000000-0000-4000-f025-0000000002a1', 'coupang_partners',
   'https://link.coupang.com/a/an-test', 'Ab3dEf7h'),
  ('00000000-0000-4000-f025-0000000004a2', '00000000-0000-4000-f025-0000000002a2', 'naver_shopping_connect',
   'https://naver.me/an-test', 'Nv3dEf7h');

-- ── 1) 스키마·권한 ─────────────────────────────────────────
do $$
declare f text; r text;
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'link_clicks' and column_name ~* '(^|_)(ip|ip_?addr(ess)?|user_agent)(_|$)') then
    raise exception 'FAIL: link_clicks 에 IP·UA 열이 있음';
  end if;
  foreach f in array array[
    'public.record_link_click(text,text,text,text)', 'public.metrics_targets()',
    'public.save_video_metrics(uuid,date,date,jsonb)', 'public.metrics_run_start()',
    'public.metrics_run_finish(bigint,integer,integer,text)',
    'private.metrics_targets()', 'private.save_video_metrics(uuid,date,date,jsonb)',
    'private.set_internal_metrics(text,text)', 'private.call_collect_metrics()', 'private.cleanup_analytics()'] loop
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then raise exception 'FAIL: % 가 % 실행 가능', r, f; end if;
    end loop;
    if f like 'public.%' and not has_function_privilege('service_role', f, 'execute') then
      raise exception 'FAIL: service_role % 불가', f;
    end if;
    if f like 'private.%' and has_function_privilege('service_role', f, 'execute') then
      raise exception 'FAIL: service_role 이 % 실행 가능', f;
    end if;
  end loop;
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_table_privilege(r, 'private.click_salts', 'select') or has_table_privilege(r, 'private.metrics_runs', 'select') then
      raise exception 'FAIL: % 가 비공개 테이블 조회 가능', r;
    end if;
    if has_table_privilege(r, 'public.link_clicks', 'insert') and r <> 'service_role' then
      raise exception 'FAIL: % 가 link_clicks 쓰기 가능', r;
    end if;
  end loop;
  if (select count(*) from cron.job where jobname in ('collect-metrics', 'cleanup-analytics')) <> 2 then
    raise exception 'FAIL: 예약 작업 2개가 없음';
  end if;
  raise notice 'PASS 1 IP 열 없음, 함수는 service_role 만(본체 private 불가), 비공개 테이블 차단, cron 등록';
end $$;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f025-00000000000a","role":"authenticated"}', true);
do $$
begin
  begin
    perform public.record_link_click('Ab3dEf7h', '1.1.1.1', null, 'youtube');
    raise exception 'FAIL: authenticated 가 record_link_click 실행';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS 2 authenticated 는 record_link_click 실행 불가';
end $$;
reset role;

-- ── 3) 클릭 기록: counted · 속도 제한 · 입력 정리 ───────────
set local role service_role;
do $$
declare v_url text; v_prog text; v_n int; v_c int; i int;
begin
  select url, program into v_url, v_prog from public.record_link_click('Ab3dEf7h', '10.0.0.1', 'M.YouTube.com', 'youtube');
  if v_url is distinct from 'https://link.coupang.com/a/an-test' or v_prog <> 'coupang_partners' then
    raise exception 'FAIL: 반환값 %, %', v_url, v_prog;
  end if;
  perform public.record_link_click('Ab3dEf7h', '10.0.0.1', null, 'evil');
  perform public.record_link_click('Ab3dEf7h', '10.0.0.2', repeat('x', 400), 'tiktok');
  if (select count(*) from public.record_link_click('Zz9yXw8v', '10.0.0.1', null, 'youtube')) <> 0 then
    raise exception 'FAIL: 없는 코드가 행을 반환';
  end if;
  if (select count(*) from public.record_link_click('Nv3dEf7h', '10.0.0.9', null, 'youtube')) <> 0
     or exists (select 1 from public.link_clicks where affiliate_link_id = '00000000-0000-4000-f025-0000000004a2') then
    raise exception 'FAIL: naver.me 링크가 행을 반환하거나 클릭을 기록';
  end if;
  if (select count(*) from public.record_link_click('bad', '10.0.0.1', null, 'youtube')) <> 0
     or (select count(*) from public.record_link_click(null, '10.0.0.1', null, 'youtube')) <> 0 then
    raise exception 'FAIL: 형식이 틀린 코드가 행을 반환';
  end if;
  select count(*), count(*) filter (where counted) into v_n, v_c from public.link_clicks
  where affiliate_link_id = '00000000-0000-4000-f025-0000000004a1';
  if v_n <> 3 or v_c <> 2 then raise exception 'FAIL: 기록 %건 / 집계 %건 (기대 3 / 2)', v_n, v_c; end if;
  if exists (select 1 from public.link_clicks where referrer like '%10.0.0%' or visitor_hash like '%10.0.0%'
             or visitor_hash !~ '^[0-9a-f]{64}$') then
    raise exception 'FAIL: IP 원문이 남거나 해시 형식이 아님';
  end if;
  if not exists (select 1 from public.link_clicks where referrer = 'm.youtube.com' and platform = 'youtube' and counted)
     or not exists (select 1 from public.link_clicks where platform = 'other' and not counted)
     or not exists (select 1 from public.link_clicks where length(referrer) = 255 and platform = 'tiktok') then
    raise exception 'FAIL: referrer·platform 정리';
  end if;
  -- 같은 방문자 30개가 차면 더 기록하지 않고 이동만
  for i in 1..40 loop
    select url into v_url from public.record_link_click('Ab3dEf7h', '10.0.0.1', null, 'youtube');
    if v_url is null then raise exception 'FAIL: 속도 제한 중에도 url 은 반환해야 함'; end if;
  end loop;
  if (select count(*) from public.link_clicks
      where visitor_hash = (select visitor_hash from public.link_clicks where referrer = 'm.youtube.com')) <> 30 then
    raise exception 'FAIL: 속도 제한 30건이 아님';
  end if;
  if (select count(*) from public.link_clicks where counted and affiliate_link_id = '00000000-0000-4000-f025-0000000004a1') <> 2 then raise exception 'FAIL: 반복 클릭이 집계됨'; end if;
  raise notice 'PASS 3 counted(10분 반복 제외)·속도 제한 30·IP 원문 없음·referrer 255자·platform 정리·없는 코드·naver.me 0행';
end $$;
reset role;

-- ── 4) 수집 대상: uploaded · youtube · connected · 33일 · 20시간 ──
set local role service_role;
do $$
declare v_ids uuid[];
begin
  select array_agg(publication_id) into v_ids from public.metrics_targets()
  where account_id in (select id from public.accounts where user_id = '00000000-0000-4000-f025-00000000000a');
  if v_ids is distinct from array['00000000-0000-4000-f025-0000000003a1'::uuid] then
    raise exception 'FAIL: 수집 대상 %', v_ids;
  end if;
  raise notice 'PASS 4 수집 대상은 업로드된 연결 YouTube 33일 이내·20시간 지난 발행만';
end $$;

-- ── 5) 지표 덮어쓰기: 클릭은 LA 날짜·counted 만, 수집 뒤 대상에서 빠짐 ──
do $$
declare v_day date := (now() at time zone 'America/Los_Angeles')::date; v_n int;
begin
  v_n := public.save_video_metrics('00000000-0000-4000-f025-0000000003a1', v_day - 2, v_day,
           jsonb_build_array(jsonb_build_object('date', v_day - 2, 'views', 120, 'avg_view_pct', 61.5),
                             jsonb_build_object('date', v_day - 1, 'views', 80, 'avg_view_pct', null)));
  if v_n <> 3 then raise exception 'FAIL: 쓴 행 % (기대 3)', v_n; end if;
  if (select link_clicks from public.video_metrics where publication_id = '00000000-0000-4000-f025-0000000003a1' and date = v_day) <> 2
     or (select views from public.video_metrics where publication_id = '00000000-0000-4000-f025-0000000003a1' and date = v_day - 2) <> 120
     or exists (select 1 from public.video_metrics where publication_id = '00000000-0000-4000-f025-0000000003a1' and est_revenue is not null) then
    raise exception 'FAIL: 지표 값';
  end if;
  -- 다시 수집하면 덮어쓴다(API 에 없는 날은 기존 값 유지)
  perform public.save_video_metrics('00000000-0000-4000-f025-0000000003a1', v_day - 2, v_day,
           jsonb_build_array(jsonb_build_object('date', v_day - 2, 'views', 150, 'avg_view_pct', 60)));
  if (select views from public.video_metrics where publication_id = '00000000-0000-4000-f025-0000000003a1' and date = v_day - 2) <> 150
     or (select views from public.video_metrics where publication_id = '00000000-0000-4000-f025-0000000003a1' and date = v_day - 1) <> 80 then
    raise exception 'FAIL: 덮어쓰기';
  end if;
  if exists (select 1 from public.metrics_targets() where publication_id = '00000000-0000-4000-f025-0000000003a1') then
    raise exception 'FAIL: 방금 수집한 발행이 다시 대상';
  end if;
  begin
    perform public.save_video_metrics('00000000-0000-4000-f025-0000000003a4', v_day, v_day, '[]');
    raise exception 'FAIL: 업로드 전 발행에 지표 저장';
  exception when sqlstate '55000' then null;
  end;
  raise notice 'PASS 5 지표 덮어쓰기·클릭 집계(counted)·est_revenue 비움·수집 뒤 대상 제외';
end $$;
reset role;

-- ── 6) RLS: 남의 클릭·지표 0행, 본인은 보임 ─────────────────
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f025-00000000000b","role":"authenticated"}', true);
do $$
begin
  if (select count(*) from public.link_clicks where affiliate_link_id = '00000000-0000-4000-f025-0000000004a1') <> 0
     or (select count(*) from public.video_metrics
         where publication_id in ('00000000-0000-4000-f025-0000000003a1', '00000000-0000-4000-f025-0000000003a6')) <> 0 then
    raise exception 'FAIL: 남의 클릭·지표가 보임';
  end if;
end $$;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f025-00000000000a","role":"authenticated"}', true);
do $$
begin
  if (select count(*) from public.link_clicks where affiliate_link_id = '00000000-0000-4000-f025-0000000004a1') <> 30 + 3 - 2
     or (select count(*) from public.video_metrics where publication_id = '00000000-0000-4000-f025-0000000003a1') <> 3 then
    raise exception 'FAIL: 본인 클릭·지표가 안 보임';
  end if;
  if (select count(platform) from public.link_clicks where counted) < 1 then raise exception 'FAIL: 허용 열 조회'; end if;
  begin
    perform visitor_hash from public.link_clicks limit 1;
    raise exception 'FAIL: authenticated 가 visitor_hash 조회';
  exception when insufficient_privilege then null;
  end;
  begin
    perform * from public.link_clicks limit 1;
    raise exception 'FAIL: authenticated 가 link_clicks * 조회';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS 6 남의 link_clicks·video_metrics 0행, 본인은 보임(visitor_hash·* 조회 거부)';
end $$;
reset role;

-- ── 7) 예약 호출: 설정 없으면 HTTP 없이 not_configured 기록 ──
delete from vault.secrets where name in ('internal_metrics_url', 'internal_metrics_key');
do $$
declare v_before bigint := (select count(*) from net.http_request_queue);
begin
  perform private.call_collect_metrics();
  if not exists (select 1 from private.metrics_runs where error = 'not_configured' and finished_at is not null) then
    raise exception 'FAIL: not_configured 기록 없음';
  end if;
  if (select count(*) from net.http_request_queue) <> v_before then raise exception 'FAIL: 설정 없이 HTTP 호출'; end if;
  perform private.set_internal_metrics('http://host.docker.internal:3000/api/internal/metrics', 'test-key');
  perform private.set_internal_metrics('http://web:3000/api/internal/metrics', 'test-key-2');
  if (select count(*) from vault.decrypted_secrets where name in ('internal_metrics_url', 'internal_metrics_key')) <> 2
     or (select decrypted_secret from vault.decrypted_secrets where name = 'internal_metrics_key') <> 'test-key-2' then
    raise exception 'FAIL: 설정 저장·갱신';
  end if;
  perform private.call_collect_metrics();
  if (select count(*) from net.http_request_queue) <> v_before + 1 then raise exception 'FAIL: 설정 뒤 HTTP 호출 없음'; end if;
  declare v_run bigint := public.metrics_run_start();
  begin
    perform public.metrics_run_finish(v_run, 0, 2, 'targets_failed');
    if not exists (select 1 from private.metrics_runs where id = v_run and finished_at is not null and skipped = 2
                   and error = 'targets_failed') then
      raise exception 'FAIL: 실패 분기 finished_at';
    end if;
  end;
  raise notice 'PASS 7 설정 없으면 not_configured, 설정 뒤 pg_net 호출 1건, 실패 분기도 finished_at 기록';
end $$;

-- ── 8) 보관 정리 ───────────────────────────────────────────
insert into public.link_clicks (affiliate_link_id, short_url, clicked_at, visitor_hash, counted) values
  ('00000000-0000-4000-f025-0000000004a1', 'Ab3dEf7h', now() - interval '2 days', repeat('a', 64), true),
  ('00000000-0000-4000-f025-0000000004a1', 'Ab3dEf7h', now() - interval '91 days', repeat('b', 64), true);
insert into private.click_salts (day, salt) values ((now() at time zone 'utc')::date - 1, '\x00');
do $$
begin
  perform private.cleanup_analytics();
  if exists (select 1 from public.link_clicks where visitor_hash in (repeat('a', 64), repeat('b', 64)))
     or not exists (select 1 from public.link_clicks where clicked_at = now() - interval '2 days' and visitor_hash is null)
     or exists (select 1 from public.link_clicks where clicked_at < now() - interval '90 days')
     or exists (select 1 from private.click_salts where day < (now() at time zone 'utc')::date)
     or not exists (select 1 from public.link_clicks where clicked_at = now() and visitor_hash is not null) then
    raise exception 'FAIL: 정리 결과';
  end if;
  raise notice 'PASS 8 1일 지난 visitor_hash 비움, 90일 지난 클릭·지난 소금 삭제, 오늘 기록 유지';
end $$;

rollback;
