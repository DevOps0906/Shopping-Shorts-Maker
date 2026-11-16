-- task-025: 단축 링크 클릭 기록 · YouTube 성과 하루 1회 수집 · 보관 정리
-- 근거: docs/planning.md 15-3 · 17-4 · 17-8, 팀장 확정 사양(2026-11-13)
--
-- - affiliate_links.short_url 에는 코드(8자, 혼동 문자 제외 base56)만 둔다. 형식은 앱·함수가 검사한다
--   (기존 값 보호를 위해 CHECK 는 추가하지 않는다).
-- - link_clicks 는 IP 원문을 저장하지 않는다. 날마다 바뀌는 소금으로 IP 만 HMAC 한 visitor_hash 를 두고, 1일 뒤 지운다.
-- - 클릭 기록은 public.record_link_click 한 번(서버 service_role 만 실행).
-- - 성과 수집: pg_cron(매일 00:30 UTC) → private.call_collect_metrics() → pg_net 으로 웹 POST /api/internal/metrics.
--
-- ── 예약 수집 설정(운영자, postgres 로 1회) ──────────────────
--   begin; set local log_statement = 'none';
--   select private.set_internal_metrics('<URL>', '<INTERNAL_METRICS_KEY 와 같은 값>');
--   commit;
--   키가 로그·pg_stat_statements 에 남지 않도록 실행 세션에서 `set local log_statement = 'none'` 후 실행한다.
--   개발(호스트에서 pnpm dev): 'http://host.docker.internal:3000/api/internal/metrics'
--   compose web 프로필:        'http://web:3000/api/internal/metrics'
--   값은 Vault 비밀 internal_metrics_url · internal_metrics_key 에 들어간다. `migrate.sh reset`(db reset) 뒤에는 다시 실행한다.
--   설정이 없으면 HTTP 호출 없이 private.metrics_runs 에 error = 'not_configured' 행만 남긴다.
--   net 스키마는 PostgREST 노출 스키마(PGRST_DB_SCHEMAS)에 넣지 않는다.

create extension if not exists pg_net;
create extension if not exists pg_cron;

-- ── link_clicks: 방문자 해시 · 집계 포함 여부 ───────────────
alter table public.link_clicks
  add column visitor_hash text,
  add column counted boolean not null default true;
comment on column public.link_clicks.visitor_hash is '그날 소금으로 IP 만 HMAC-SHA256(hex). 1일 뒤 null. IP 원문은 어디에도 없음';
comment on column public.link_clicks.counted is '같은 링크·같은 방문자 10분 안 반복 클릭이면 false(집계 제외)';
create index link_clicks_visitor_hash_clicked_at_idx on public.link_clicks (visitor_hash, clicked_at)
  where visitor_hash is not null;
create index link_clicks_clicked_at_idx on public.link_clicks (clicked_at);
-- 소유자 읽기는 visitor_hash 를 뺀 열만(해시도 방문자 식별에 쓰일 수 있으므로 서버 전용)
revoke select on public.link_clicks from authenticated;
grant select (id, affiliate_link_id, short_url, clicked_at, referrer, platform, counted) on public.link_clicks to authenticated;

-- ── video_metrics: 수집 시각 ────────────────────────────────
alter table public.video_metrics add column collected_at timestamptz not null default now();
comment on column public.video_metrics.collected_at is '마지막 수집(덮어쓰기) 시각. 수집 대상 선정(20시간)과 화면 "지표 수집 시각"';

-- ── 비공개 테이블: 날마다 바뀌는 소금 · 수집 실행 기록 ─────────
create table private.click_salts (
  day date primary key,
  salt bytea not null
);
comment on table private.click_salts is '클릭 방문자 해시용 날짜별(UTC) 소금. 함수 전용, 지난 날짜는 정리 cron 이 삭제';
alter table private.click_salts enable row level security;
revoke all on private.click_salts from public, anon, authenticated, service_role;

create table private.metrics_runs (
  id bigint generated always as identity primary key,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  ok integer not null default 0,
  skipped integer not null default 0,
  error text
);
comment on table private.metrics_runs is '성과 수집 실행 기록(시작·끝·성공·건너뜀·오류). 30일 보관';
alter table private.metrics_runs enable row level security;
revoke all on private.metrics_runs from public, anon, authenticated, service_role;

-- ── 클릭 기록(익명 요청을 서버가 대신 기록) ─────────────────
-- 반환: 코드에 맞는 (url, program). 없으면 0행. 리다이렉트 허용 여부는 서버가 다시 검사한다.
create function public.record_link_click(p_code text, p_ip text, p_ref_host text, p_platform text)
returns table (url text, program text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link_id uuid;
  v_url text;
  v_program text;
  v_day date := (now() at time zone 'utc')::date;
  v_salt bytea;
  v_hash text;
begin
  if p_code is null or p_code !~ '^[2-9A-HJ-NP-Za-km-np-z]{8}$' then
    return;
  end if;
  select al.id, al.url, al.program into v_link_id, v_url, v_program
  from public.affiliate_links al where al.short_url = p_code;
  -- naver.me 단축 주소로는 보내지 않으므로(404) 클릭도 기록하지 않는다
  if v_link_id is null or v_url is null or v_url ~* '^https://([a-z0-9-]+\.)*naver\.me([/?#]|$)' then
    return;
  end if;

  select s.salt into v_salt from private.click_salts s where s.day = v_day;
  if v_salt is null then
    insert into private.click_salts (day, salt) values (v_day, extensions.gen_random_bytes(32))
    on conflict do nothing;
    select s.salt into v_salt from private.click_salts s where s.day = v_day;
  end if;
  -- IP 만(UA 제외). IP 원문은 저장하지 않는다
  v_hash := encode(extensions.hmac(convert_to(coalesce(nullif(p_ip, ''), 'unknown'), 'UTF8'), v_salt, 'sha256'), 'hex');

  -- 같은 링크·같은 방문자의 동시 요청을 줄 세운다(중복 판정과 삽입 사이 경쟁 방지, 트랜잭션 끝에 풀림)
  perform pg_advisory_xact_lock(hashtextextended(v_link_id::text || v_hash, 0));

  -- 속도 제한: 같은 방문자의 최근 10분 기록이 30개 이상이면 기록하지 않고 이동만
  if (select count(*) from public.link_clicks c
      where c.visitor_hash = v_hash and c.clicked_at > now() - interval '10 minutes') < 30 then
    insert into public.link_clicks (affiliate_link_id, short_url, referrer, platform, visitor_hash, counted)
    values (
      v_link_id,
      p_code,
      left(nullif(lower(btrim(coalesce(p_ref_host, ''))), ''), 255),
      case when p_platform in ('youtube', 'instagram', 'tiktok', 'inpock', 'litly') then p_platform else 'other' end,
      v_hash,
      not exists (select 1 from public.link_clicks c
                  where c.affiliate_link_id = v_link_id and c.visitor_hash = v_hash
                    and c.clicked_at > now() - interval '10 minutes')
    );
  end if;

  url := v_url;
  program := v_program;
  return next;
end;
$$;
revoke execute on function public.record_link_click(text, text, text, text) from public, anon, authenticated;
grant execute on function public.record_link_click(text, text, text, text) to service_role;

-- ── 수집 대상 선정 ─────────────────────────────────────────
-- 업로드 완료 + 영상 id 있음 + 연결된 YouTube 계정 + 발행 후 33일 이내 + 최근 수집이 없거나 20시간보다 오래됨
create function private.metrics_targets()
returns table (publication_id uuid, account_id uuid, user_id uuid, platform_video_id text, published_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select pub.id, pub.account_id, a.user_id, pub.platform_video_id, pub.published_at
  from public.publications pub
  join public.accounts a on a.id = pub.account_id
  where pub.status = 'uploaded'
    and pub.platform_video_id is not null
    and a.platform = 'youtube'
    and a.status = 'connected'
    and pub.published_at > now() - interval '33 days'
    and coalesce((select max(vm.collected_at) from public.video_metrics vm where vm.publication_id = pub.id),
                 '-infinity'::timestamptz) < now() - interval '20 hours'
  order by pub.account_id, pub.published_at;
$$;
revoke execute on function private.metrics_targets() from public, anon, authenticated, service_role;

create function public.metrics_targets()
returns table (publication_id uuid, account_id uuid, user_id uuid, platform_video_id text, published_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select * from private.metrics_targets();
$$;
revoke execute on function public.metrics_targets() from public, anon, authenticated;
grant execute on function public.metrics_targets() to service_role;

-- ── 일별 지표 덮어쓰기 ─────────────────────────────────────
-- p_rows: [{date:'YYYY-MM-DD', views:int, avg_view_pct:number|null}] (Analytics day = America/Los_Angeles)
-- link_clicks 는 같은 날짜 기준(clicked_at at time zone 'America/Los_Angeles')으로 counted 만 센다. est_revenue 는 비운다.
-- 반환: 쓴 행 수
create function private.save_video_metrics(p_publication_id uuid, p_start date, p_end date, p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link_id uuid;
  v_count integer;
begin
  if p_start is null or p_end is null or p_end < p_start or p_end - p_start > 40
     or jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array' then
    raise exception '잘못된 수집 범위입니다' using errcode = '22023';
  end if;
  if not exists (select 1 from public.publications pub where pub.id = p_publication_id and pub.status = 'uploaded') then
    raise exception '수집할 수 없는 발행입니다' using errcode = '55000';
  end if;
  select al.id into v_link_id
  from public.publications pub join public.affiliate_links al on al.project_id = pub.project_id
  where pub.id = p_publication_id;

  with days as (
    select g::date as d from generate_series(p_start::timestamp, p_end::timestamp, interval '1 day') g
  ), api as (
    select (e ->> 'date')::date as d,
           greatest(coalesce((e ->> 'views')::numeric, 0), 0)::integer as views,
           (e ->> 'avg_view_pct')::numeric as avg_view_pct
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) e
  ), rows as (
    select days.d,
           coalesce(api.views, vm.views, 0) as views,
           coalesce(api.avg_view_pct, vm.avg_view_pct) as avg_view_pct,
           (select count(*) from public.link_clicks lc
            where lc.affiliate_link_id = v_link_id and lc.counted
              and (lc.clicked_at at time zone 'America/Los_Angeles')::date = days.d)::integer as clicks,
           api.d is not null as has_api,
           vm.id is not null as has_row
    from days
    left join api on api.d = days.d
    left join public.video_metrics vm on vm.publication_id = p_publication_id and vm.date = days.d
  ), up as (
    insert into public.video_metrics (publication_id, date, views, avg_view_pct, link_clicks, est_revenue, collected_at)
    select p_publication_id, r.d, r.views, r.avg_view_pct, r.clicks, null, now()
    from rows r
    where r.has_api or r.has_row or r.clicks > 0
    on conflict (publication_id, date) do update
      set views = excluded.views,
          avg_view_pct = excluded.avg_view_pct,
          link_clicks = excluded.link_clicks,
          est_revenue = null,
          collected_at = now()
    returning 1
  )
  select count(*) into v_count from up;
  return v_count;
end;
$$;
revoke execute on function private.save_video_metrics(uuid, date, date, jsonb) from public, anon, authenticated, service_role;

create function public.save_video_metrics(p_publication_id uuid, p_start date, p_end date, p_rows jsonb)
returns integer
language sql
security definer
set search_path = ''
as $$
  select private.save_video_metrics(p_publication_id, p_start, p_end, p_rows);
$$;
revoke execute on function public.save_video_metrics(uuid, date, date, jsonb) from public, anon, authenticated;
grant execute on function public.save_video_metrics(uuid, date, date, jsonb) to service_role;

-- ── 수집 실행 기록(웹이 시작·끝을 남긴다) ────────────────────
create function public.metrics_run_start()
returns bigint
language sql
security definer
set search_path = ''
as $$
  insert into private.metrics_runs default values returning id;
$$;
revoke execute on function public.metrics_run_start() from public, anon, authenticated;
grant execute on function public.metrics_run_start() to service_role;

create function public.metrics_run_finish(p_id bigint, p_ok integer, p_skipped integer, p_error text)
returns void
language sql
security definer
set search_path = ''
as $$
  update private.metrics_runs
  set finished_at = now(), ok = greatest(coalesce(p_ok, 0), 0), skipped = greatest(coalesce(p_skipped, 0), 0),
      error = left(p_error, 200)
  where id = p_id and finished_at is null;
$$;
revoke execute on function public.metrics_run_finish(bigint, integer, integer, text) from public, anon, authenticated;
grant execute on function public.metrics_run_finish(bigint, integer, integer, text) to service_role;

-- ── 예약 수집 설정 · 호출 ──────────────────────────────────
create function private.set_internal_metrics(p_url text, p_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
  v_value text;
  v_id uuid;
begin
  if nullif(btrim(coalesce(p_url, '')), '') is null or nullif(btrim(coalesce(p_key, '')), '') is null then
    raise exception 'URL 과 키가 모두 필요합니다' using errcode = '22023';
  end if;
  foreach v_name in array array['internal_metrics_url', 'internal_metrics_key'] loop
    v_value := case v_name when 'internal_metrics_url' then btrim(p_url) else btrim(p_key) end;
    select s.id into v_id from vault.secrets s where s.name = v_name;
    if v_id is null then
      perform vault.create_secret(v_value, v_name, 'task-025 성과 수집 호출');
    else
      perform vault.update_secret(v_id, v_value);
    end if;
    v_id := null;
  end loop;
end;
$$;
revoke execute on function private.set_internal_metrics(text, text) from public, anon, authenticated, service_role;

create function private.call_collect_metrics()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_key text;
begin
  select d.decrypted_secret into v_url from vault.decrypted_secrets d where d.name = 'internal_metrics_url';
  select d.decrypted_secret into v_key from vault.decrypted_secrets d where d.name = 'internal_metrics_key';
  if nullif(v_url, '') is null or nullif(v_key, '') is null then
    insert into private.metrics_runs (finished_at, error) values (now(), 'not_configured');
    return;
  end if;
  perform net.http_post(
    url := v_url,
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-internal-key', v_key),
    timeout_milliseconds := 10000
  );
end;
$$;
revoke execute on function private.call_collect_metrics() from public, anon, authenticated, service_role;

-- ── 보관 정리 ──────────────────────────────────────────────
create function private.cleanup_analytics()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.link_clicks set visitor_hash = null
  where visitor_hash is not null and clicked_at < now() - interval '1 day';
  delete from public.link_clicks where clicked_at < now() - interval '90 days';
  delete from private.click_salts where day < (now() at time zone 'utc')::date;
  delete from private.metrics_runs where started_at < now() - interval '30 days';
end;
$$;
revoke execute on function private.cleanup_analytics() from public, anon, authenticated, service_role;

-- 이름이 같으면 갱신(재적용 안전). 시각은 UTC
select cron.schedule('collect-metrics', '30 0 * * *', 'select private.call_collect_metrics()');
select cron.schedule('cleanup-analytics', '10 0 * * *', 'select private.cleanup_analytics()');
