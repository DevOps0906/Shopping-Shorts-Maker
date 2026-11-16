-- 02_copy.sql — 옛 public·private 데이터를 nomad_shorts·nomad_shorts_private(org안)로 1회 복사.
-- 실행(postgres 역할):
--   dry-run(기본, 끝에서 rollback): psql "<DB 주소>" -f supabase/nomad-cutover/02_copy.sql
--   적용(commit):                  psql "<DB 주소>" -v apply=true -f supabase/nomad-cutover/02_copy.sql
-- 전제: 01_freeze 완료, 01_queue_check 통과, 새 migrations db push 완료(개인 조직 백필 포함).
-- 한 트랜잭션. 시작 검사 → 복사 → 끝 검사 중 하나라도 어긋나면 raise(전체 취소).
--
-- 대응(정본: nomad-supabase-module products/shorts/existing.md "운영 데이터 이관"):
--   - 소유 user_id → 그 사용자의 개인 조직 id(organizations.kind='personal', created_by=사용자, owner 멤버십)
--   - user_profiles → nomad_core.profiles.display_name(upsert, 이름이 있을 때만 덮음) + nomad_shorts.user_settings(기본값 열)
--     user_profiles.email 은 옮기지 않는다(auth.users.email 이 정본)
--   - 저장 경로 sources.file_path·thumbnail_path, voice_takes.audio_path, renders.mp4_path:
--     '<user_id>/<project_id>/…' → '<organization_id>/<project_id>/…' (객체 복사는 03_storage.mjs, 앱 전환 전에 끝낸다)
--   - 옛 플랜: Shorts 옛 스키마에는 플랜 열이 없다 → subscriptions 행을 만들지 않는다(구독 없는 조직 = C 플랜)
--   - id·created_at·updated_at·번호·상태는 원본 그대로(session_replication_role = replica 로 대상 트리거를 끈다)
\set ON_ERROR_STOP on
\if :{?apply}
\else
  \set apply false
\endif

begin;
set local session_replication_role = replica;

do $$
begin
  if current_setting('session_replication_role') <> 'replica' then
    raise exception 'session_replication_role = replica 가 적용되지 않았습니다(현재 %)', current_setting('session_replication_role');
  end if;
end $$;

-- ── 대응표 ────────────────────────────────────────────────
create temp table cut_tables (ord int primary key, src regclass not null, dst regclass not null, owner boolean not null) on commit drop;
insert into cut_tables values
  ( 1, 'public.categories',                  'nomad_shorts.categories',                  false),
  ( 2, 'public.trend_items',                 'nomad_shorts.trend_items',                 false),
  ( 3, 'public.accounts',                    'nomad_shorts.accounts',                    true),
  ( 4, 'public.projects',                    'nomad_shorts.projects',                    true),
  ( 5, 'public.project_events',              'nomad_shorts.project_events',              false),
  ( 6, 'public.topics',                      'nomad_shorts.topics',                      false),
  ( 7, 'public.sources',                     'nomad_shorts.sources',                     false),
  ( 8, 'public.scripts',                     'nomad_shorts.scripts',                     false),
  ( 9, 'public.voice_takes',                 'nomad_shorts.voice_takes',                 false),
  (10, 'public.renders',                     'nomad_shorts.renders',                     false),
  (11, 'public.chat_messages',               'nomad_shorts.chat_messages',               false),
  (12, 'public.chat_proposals',              'nomad_shorts.chat_proposals',              true),
  (13, 'public.extension_connections',       'nomad_shorts.extension_connections',       true),
  (14, 'public.jobs',                        'nomad_shorts.jobs',                        false),
  (15, 'public.credit_ledger',               'nomad_shorts.credit_ledger',               true),
  (16, 'public.publications',                'nomad_shorts.publications',                false),
  (17, 'public.video_metrics',               'nomad_shorts.video_metrics',               false),
  (18, 'public.policy_checks',               'nomad_shorts.policy_checks',               false),
  (19, 'public.affiliate_links',             'nomad_shorts.affiliate_links',             false),
  (20, 'public.bio_pages',                   'nomad_shorts.bio_pages',                   false),
  (21, 'public.bio_items',                   'nomad_shorts.bio_items',                   false),
  (22, 'public.link_clicks',                 'nomad_shorts.link_clicks',                 false),
  (23, 'public.api_keys',                    'nomad_shorts.api_keys',                    true),
  (24, 'public.oauth_states',                'nomad_shorts.oauth_states',                true),
  (25, 'public.channel_slot_events',         'nomad_shorts.channel_slot_events',         true),
  (26, 'public.publication_upload_sessions', 'nomad_shorts.publication_upload_sessions', false),
  (27, 'public.youtube_upload_quota',        'nomad_shorts.youtube_upload_quota',        false),
  (28, 'private.channel_quotas',             'nomad_shorts_private.channel_quotas',      true),
  (29, 'private.click_salts',                'nomad_shorts_private.click_salts',         false),
  (30, 'private.metrics_runs',               'nomad_shorts_private.metrics_runs',        false),
  (31, 'private.rate_counters',              'nomad_shorts_private.rate_counters',       false);

create temp table cut_paths (dst regclass, col text, primary key (dst, col)) on commit drop;
insert into cut_paths values
  ('nomad_shorts.sources', 'file_path'), ('nomad_shorts.sources', 'thumbnail_path'),
  ('nomad_shorts.voice_takes', 'audio_path'), ('nomad_shorts.renders', 'mp4_path');

-- 사용자 → 개인 조직
create temp table cut_user_org on commit drop as
select o.created_by as user_id, o.id as organization_id
from nomad_core.organizations o
join nomad_core.memberships m on m.organization_id = o.id and m.user_id = o.created_by and m.role = 'owner'
where o.kind = 'personal';

create function pg_temp.cut_path(p text, project uuid) returns text language plpgsql stable as $$
declare u uuid; o uuid; pre text;
begin
  if p is null then return null; end if;
  select pr.user_id, m.organization_id into u, o
  from public.projects pr join pg_temp.cut_user_org m on m.user_id = pr.user_id
  where pr.id = project;
  pre := u::text || '/' || project::text || '/';
  if o is null or left(p, char_length(pre)) <> pre then
    raise exception '저장 경로가 <user_id>/<project_id>/ 로 시작하지 않음: % (project %)', p, project;
  end if;
  return o::text || '/' || project::text || '/' || substr(p, char_length(pre) + 1);
end $$;

-- ── 시작 검사 ─────────────────────────────────────────────
do $$
declare
  issues text[] := '{}'; r record; n bigint; q text;
  owner_tables text[] := array['public.user_profiles', 'public.accounts', 'public.projects', 'public.chat_proposals',
    'public.extension_connections', 'public.credit_ledger', 'public.api_keys', 'public.oauth_states',
    'public.channel_slot_events', 'private.channel_quotas'];
  t text;
begin
  -- 재실행 방지: 대상 표가 하나라도 비어 있지 않으면 중단
  for r in select dst from pg_temp.cut_tables union all select 'nomad_shorts.user_settings'::regclass loop
    execute format('select count(*) from %s', r.dst) into n;
    if n > 0 then issues := issues || format('대상 표가 비어 있지 않음: %s (%s행) — 이미 복사했거나 앱이 썼음', r.dst, n); end if;
  end loop;

  if (select count(*) from pg_temp.cut_user_org) <> (select count(distinct user_id) from pg_temp.cut_user_org) then
    issues := issues || '개인 조직이 2개 이상인 사용자가 있음'::text;
  end if;

  -- 옛 큐(사용자 결정 3): 비어 있어야 한다
  foreach q in array array['render', 'tts', 'analyze', 'sources'] loop
    if to_regclass(format('pgmq.%I', 'q_' || q)) is null then continue; end if;
    execute format('select count(*) from pgmq.%I', 'q_' || q) into n;
    if n > 0 then issues := issues || format('옛 pgmq 큐 %s 에 메시지 %s건(01_queue_check 참고)', q, n); end if;
  end loop;

  foreach t in array owner_tables loop
    -- 익명 사용자 소유(사용자 결정 2): 건수만 보고하고 중단
    execute format('select count(*) from %s s join auth.users u on u.id = s.user_id where u.is_anonymous', t) into n;
    if n > 0 then issues := issues || format('익명 사용자 소유 행: %s %s건', t, n); end if;
    -- 개인 조직 없는 사용자
    execute format($q$select count(*) from %s s join auth.users u on u.id = s.user_id
                     where not coalesce(u.is_anonymous, false)
                       and not exists (select 1 from pg_temp.cut_user_org m where m.user_id = s.user_id)$q$, t) into n;
    if n > 0 then issues := issues || format('개인 조직 없는 사용자 소유 행: %s %s건', t, n); end if;
  end loop;

  -- 저장 경로 형식
  select count(*) into n from (
    select s.project_id, p from public.sources s, unnest(array[s.file_path, s.thumbnail_path]) p
    union all select project_id, audio_path from public.voice_takes
    union all select project_id, mp4_path from public.renders
  ) x join public.projects pr on pr.id = x.project_id
  where x.p is not null and left(x.p, 74) <> pr.user_id::text || '/' || pr.id::text || '/';
  if n > 0 then issues := issues || format('저장 경로가 <user_id>/<project_id>/ 형식이 아닌 행 %s건', n); end if;

  if cardinality(issues) > 0 then
    raise exception E'02_copy 중단(변경 없음):\n - %', array_to_string(issues, E'\n - ');
  end if;

  select count(*) into n from public.jobs where status in ('queued', 'running', 'waiting_extension');
  if n > 0 then
    raise notice '끝나지 않은 옛 작업 %건은 상태 그대로 복사됩니다(새 sweep_jobs 가 시간 초과·환불 처리)', n;
  end if;
end $$;

-- ── 복사 ──────────────────────────────────────────────────
create temp table cut_sql (dst regclass primary key, src regclass, cols text, exprs text, copied bigint) on commit drop;

do $$
declare
  t record; src_cols text[]; dst_cols text[]; expected text[]; cols text; exprs text; n bigint;
begin
  for t in select * from pg_temp.cut_tables order by ord loop
    src_cols := array(select attname::text from pg_attribute where attrelid = t.src and attnum > 0 and not attisdropped order by attnum);
    dst_cols := array(select attname::text from pg_attribute where attrelid = t.dst and attnum > 0 and not attisdropped order by attnum);
    expected := case when t.owner then array_append(array_remove(src_cols, 'user_id'), 'organization_id') else src_cols end;
    if t.owner and not ('user_id' = any (src_cols)) then
      raise exception '%: 소유 열 user_id 없음', t.src;
    end if;
    if array(select x from unnest(expected) x order by 1) <> array(select x from unnest(dst_cols) x order by 1) then
      raise exception '열 불일치 % → %: 원본 기준 기대 %, 대상 %', t.src, t.dst, expected, dst_cols;
    end if;

    select string_agg(format('%I', c), ', ' order by o),
           string_agg(case
             when t.owner and c = 'organization_id'
               then '(select m.organization_id from pg_temp.cut_user_org m where m.user_id = s.user_id)'
             when exists (select 1 from pg_temp.cut_paths p where p.dst = t.dst and p.col = c)
               then format('pg_temp.cut_path(s.%I, s.project_id)', c)
             else format('s.%I', c) end, ', ' order by o)
      into cols, exprs
    from unnest(dst_cols) with ordinality as d(c, o);

    execute format('insert into %s (%s) overriding system value select %s from %s s', t.dst, cols, exprs, t.src);
    get diagnostics n = row_count;
    insert into pg_temp.cut_sql values (t.dst, t.src, cols, exprs, n);
  end loop;
end $$;

-- user_profiles → profiles(upsert) + user_settings
create temp table cut_profiles_before on commit drop as
select up.user_id, p.display_name
from public.user_profiles up left join nomad_core.profiles p on p.user_id = up.user_id;

insert into nomad_core.profiles (user_id, display_name)
select up.user_id,
       coalesce(nullif(trim(up.name), ''), b.display_name,
                nullif(split_part(coalesce(au.email, ''), '@', 1), ''), '내 워크스페이스')
from public.user_profiles up
join auth.users au on au.id = up.user_id
join pg_temp.cut_profiles_before b on b.user_id = up.user_id
on conflict (user_id) do update set display_name = excluded.display_name;

insert into nomad_shorts.user_settings (user_id, default_tone, default_lang, subtitle_style, default_len, notify_done, notify_weekly)
select user_id, default_tone, default_lang, subtitle_style, default_len, notify_done, notify_weekly
from public.user_profiles;

-- 시퀀스: 원본 시퀀스 위치와 최대값 중 큰 값
do $$
declare s record; v bigint; sseq text;
begin
  for s in
    select t.src, t.dst, a.attname, pg_get_serial_sequence(t.dst::text, a.attname) as dseq
    from pg_temp.cut_tables t join pg_attribute a on a.attrelid = t.dst and a.attnum > 0 and not a.attisdropped
    where pg_get_serial_sequence(t.dst::text, a.attname) is not null
  loop
    sseq := pg_get_serial_sequence(s.src::text, s.attname);
    execute format('select greatest((select max(%I) from %s), %s)', s.attname, s.dst,
      case when sseq is null then 'null'
           else format('(select case when is_called then last_value end from %s)', sseq) end) into v;
    if v is not null then perform setval(s.dseq, v); end if;
  end loop;
end $$;

-- ── 끝 검사 ───────────────────────────────────────────────
do $$
declare
  c record; f record; n1 bigint; n2 bigint; ns bigint; nd bigint; issues text[] := '{}'; summary text := '';
  ccols text[]; pcols text[]; cond text;
begin
  -- 1) 표마다 행 수 + 전체 값(대응 규칙 적용 후) 양방향 대조
  for c in select * from pg_temp.cut_sql order by dst::text loop
    execute format('select count(*) from %s', c.src) into ns;
    execute format('select count(*) from %s', c.dst) into nd;
    execute format('select count(*) from (select %s from %s s except all select %s from %s) x', c.exprs, c.src, c.cols, c.dst) into n1;
    execute format('select count(*) from (select %s from %s except all select %s from %s s) x', c.cols, c.dst, c.exprs, c.src) into n2;
    if ns <> nd or n1 > 0 or n2 > 0 then
      issues := issues || format('%s: 원본 %s행 · 대상 %s행 · 원본에만 %s · 대상에만 %s', c.dst, ns, nd, n1, n2);
    end if;
    summary := summary || format(' %s=%s', c.dst, nd);
  end loop;

  -- 2) user_settings · profiles
  select count(*) into n1 from (
    select user_id, default_tone, default_lang, subtitle_style, default_len, notify_done, notify_weekly from public.user_profiles
    except all
    select user_id, default_tone, default_lang, subtitle_style, default_len, notify_done, notify_weekly from nomad_shorts.user_settings) x;
  select count(*) into n2 from nomad_shorts.user_settings;
  if n1 > 0 or n2 <> (select count(*) from public.user_profiles) then
    issues := issues || format('user_settings 불일치(원본에만 %s, 대상 %s행)', n1, n2);
  end if;
  select count(*) into n1
  from public.user_profiles up
  join pg_temp.cut_profiles_before b on b.user_id = up.user_id
  left join nomad_core.profiles p on p.user_id = up.user_id
  where p.user_id is null
     or (nullif(trim(up.name), '') is not null and p.display_name is distinct from trim(up.name))
     or (nullif(trim(up.name), '') is null and b.display_name is not null and p.display_name is distinct from b.display_name);
  if n1 > 0 then issues := issues || format('profiles.display_name 불일치 %s건', n1); end if;

  -- 3) FK 고아 행(복합 FK 포함). replica 모드에서는 FK 가 검사되지 않으므로 직접 센다
  for f in
    select con.conname, con.conrelid::regclass as child, con.confrelid::regclass as parent, con.conkey, con.confkey
    from pg_constraint con
    where con.contype = 'f'
      and con.connamespace in ('nomad_shorts'::regnamespace, 'nomad_shorts_private'::regnamespace)
  loop
    ccols := array(select a.attname::text from unnest(f.conkey) with ordinality k(n, o) join pg_attribute a on a.attrelid = f.child and a.attnum = k.n order by k.o);
    pcols := array(select a.attname::text from unnest(f.confkey) with ordinality k(n, o) join pg_attribute a on a.attrelid = f.parent and a.attnum = k.n order by k.o);
    select string_agg(format('p.%I = c.%I', pcols[i], ccols[i]), ' and ') into cond from generate_subscripts(ccols, 1) i;
    execute format('select count(*) from %s c where %s and not exists (select 1 from %s p where %s)',
      f.child, (select string_agg(format('c.%I is not null', x), ' and ') from unnest(ccols) x), f.parent, cond) into n1;
    if n1 > 0 then issues := issues || format('FK 고아 행 %s: %s건', f.conname, n1); end if;
  end loop;

  -- 4) 소유 조직 일치(서로 다른 경로로 정해지는 조직이 같아야 한다)
  for c in
    select 'chat_proposals↔project' as k, count(*) as n from nomad_shorts.chat_proposals x join nomad_shorts.projects p on p.id = x.project_id where x.organization_id <> p.organization_id
    union all select 'credit_ledger↔project', count(*) from nomad_shorts.credit_ledger x join nomad_shorts.projects p on p.id = x.project_id where x.organization_id <> p.organization_id
    union all select 'credit_ledger↔job', count(*) from nomad_shorts.credit_ledger x join nomad_shorts.jobs j on j.id = x.job_id join nomad_shorts.projects p on p.id = j.project_id where x.organization_id <> p.organization_id
    union all select 'jobs.extension↔project', count(*) from nomad_shorts.jobs j join nomad_shorts.extension_connections e on e.id = j.extension_id join nomad_shorts.projects p on p.id = j.project_id where e.organization_id <> p.organization_id
    union all select 'channel_slot_events↔account', count(*) from nomad_shorts.channel_slot_events x join nomad_shorts.accounts a on a.id = x.account_id where x.organization_id <> a.organization_id
    union all select 'bio_items.page↔project', count(*) from nomad_shorts.bio_items b join nomad_shorts.bio_pages g on g.id = b.bio_page_id join nomad_shorts.accounts a on a.id = g.account_id join nomad_shorts.projects p on p.id = b.project_id where a.organization_id <> p.organization_id
    union all select 'bio_items.link↔page', count(*) from nomad_shorts.bio_items b join nomad_shorts.affiliate_links l on l.id = b.affiliate_link_id join nomad_shorts.projects p on p.id = l.project_id join nomad_shorts.bio_pages g on g.id = b.bio_page_id join nomad_shorts.accounts a on a.id = g.account_id where a.organization_id <> p.organization_id
    union all select 'projects.organization↔원본 user', count(*) from nomad_shorts.projects x join public.projects o on o.id = x.id left join pg_temp.cut_user_org m on m.user_id = o.user_id where m.organization_id is distinct from x.organization_id
  loop
    if c.n > 0 then issues := issues || format('소유 조직 불일치 %s: %s건', c.k, c.n); end if;
  end loop;

  -- 5) 새 저장 경로 = <organization_id>/<project_id>/
  select count(*) into n1 from (
    select s.project_id, p from nomad_shorts.sources s, unnest(array[s.file_path, s.thumbnail_path]) p
    union all select project_id, audio_path from nomad_shorts.voice_takes
    union all select project_id, mp4_path from nomad_shorts.renders
  ) x join nomad_shorts.projects pr on pr.id = x.project_id
  where x.p is not null and left(x.p, 74) <> pr.organization_id::text || '/' || pr.id::text || '/';
  if n1 > 0 then issues := issues || format('새 저장 경로 형식 불일치 %s건', n1); end if;

  if cardinality(issues) > 0 then
    raise exception E'02_copy 끝 검사 실패(전체 취소):\n - %', array_to_string(issues, E'\n - ');
  end if;
  raise notice '02_copy 검사 통과. 행 수:% · user_settings=%', summary, (select count(*) from nomad_shorts.user_settings);
end $$;

\if :apply
commit;
\echo '02_copy: APPLY — 커밋했습니다. 다음: 03_storage.mjs(객체 복사) → 앱 전환'
\else
rollback;
\echo '02_copy: dry-run — 모든 검사를 통과했고 rollback 했습니다. 적용은 -v apply=true'
\endif
