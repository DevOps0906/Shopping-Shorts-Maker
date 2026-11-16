-- task-011: 발행·성과·정책 점검·제휴·링크인바이오·클릭·API 키
-- 근거: docs/05_DATA_MODEL.md 1·2절, 3절 해당 표, docs/planning.md 15장·16장·17-8

-- publications.account_id = projects.account_id 를 복합 FK로 강제하기 위한 대상 키.
-- 이 FK 때문에 발행 행이 생긴 프로젝트는 account_id를 바꿀 수 없다(1 프로젝트 = 1 채널).
alter table public.projects add constraint projects_id_account_id_key unique (id, account_id);

-- ── publications (06 발행) ──────────────────────────────────
create table public.publications (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null unique,
  account_id uuid not null,
  -- 함수 전용(행 생성 포함): scheduled = 예약, now = 지금
  mode text not null check (mode in ('scheduled', 'now')),
  scheduled_at timestamptz,
  -- sources.purge_after 기준
  published_at timestamptz,
  platform_video_id text,
  status text not null default 'pending'
    check (status in ('pending', 'scheduled', 'uploading', 'uploaded', 'failed')),
  error text,
  retry_count integer not null default 0 check (retry_count between 0 and 3),
  created_at timestamptz not null default now(),
  foreign key (project_id, account_id) references public.projects (id, account_id) on delete cascade
);
comment on table public.publications is '발행 1건(프로젝트당 1). 생성·예약은 함수 전용, 업로드 결과는 서버(SR)';
create index publications_account_id_idx on public.publications (account_id);

alter table public.publications enable row level security;
revoke all on public.publications from anon, authenticated;
grant select on public.publications to authenticated;

create policy publications_select_own on public.publications
  for select to authenticated
  using (exists (select 1 from public.projects p
                 where p.id = publications.project_id and p.user_id = (select auth.uid())));

create function private.publications_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user <> 'postgres' then
    if tg_op = 'INSERT' then
      raise exception '발행은 발행 함수로만 만들 수 있습니다' using errcode = '42501';
    elsif (new.mode, new.scheduled_at) is distinct from (old.mode, old.scheduled_at) then
      raise exception '발행 방식·예약 시각은 발행 함수로만 바꿀 수 있습니다' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function private.publications_guard() from public, anon, authenticated;

create trigger publications_guard
  before insert or update on public.publications
  for each row execute function private.publications_guard();

-- ── video_metrics (성과) ────────────────────────────────────
create table public.video_metrics (
  id uuid primary key default gen_random_uuid(),
  publication_id uuid not null references public.publications (id) on delete cascade,
  date date not null,
  views integer not null default 0 check (views >= 0),
  link_clicks integer not null default 0 check (link_clicks >= 0),
  avg_view_pct numeric,
  -- 원(정수)
  est_revenue integer,
  -- 하루 1행 가정(05 4절 11번 확인 필요)
  unique (publication_id, date)
);
comment on table public.video_metrics is '발행 영상 일별 성과. 쓰기는 서버(SR, 분석 API 수집)만';

alter table public.video_metrics enable row level security;
revoke all on public.video_metrics from anon, authenticated;
grant select on public.video_metrics to authenticated;

create policy video_metrics_select_own on public.video_metrics
  for select to authenticated
  using (exists (select 1 from public.publications pub
                 join public.projects p on p.id = pub.project_id
                 where pub.id = video_metrics.publication_id and p.user_id = (select auth.uid())));

-- ── policy_checks (15-4 정책 점검 6항목) ────────────────────
create table public.policy_checks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  -- 원본 출처 기록 · 출처 표기·고지 확인(사용자) · 새로 만든 요소 · 금지·과장 표현 · 제휴 고지 · 구매 경로(자동+사용자)
  item text not null check (item in ('source_record', 'attribution_notice', 'original_elements',
                                     'banned_terms', 'affiliate_disclosure', 'purchase_path')),
  result text not null default 'pending' check (result in ('pending', 'pass', 'fail')),
  detail text,
  -- 함수 전용: 사용자 체크 항목의 확인자·확인 시각
  checked_by uuid references auth.users (id) on delete set null,
  checked_at timestamptz,
  unique (project_id, item)
);
comment on table public.policy_checks is '발행 전 정책 점검. 자동 항목은 서버(SR), 사용자 체크(checked_by·checked_at)는 함수 전용';

alter table public.policy_checks enable row level security;
revoke all on public.policy_checks from anon, authenticated;
grant select on public.policy_checks to authenticated;

create policy policy_checks_select_own on public.policy_checks
  for select to authenticated
  using (exists (select 1 from public.projects p
                 where p.id = policy_checks.project_id and p.user_id = (select auth.uid())));

create function private.policy_checks_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user <> 'postgres' then
    if tg_op = 'INSERT' then
      new.checked_by := null;
      if new.item in ('attribution_notice', 'purchase_path') then
        new.checked_at := null;
      end if;
    elsif new.checked_by is distinct from old.checked_by
       or (new.item in ('attribution_notice', 'purchase_path')
           and new.checked_at is distinct from old.checked_at) then
      raise exception '사용자 확인 기록은 확인 함수로만 바꿀 수 있습니다' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function private.policy_checks_guard() from public, anon, authenticated;

create trigger policy_checks_guard
  before insert or update on public.policy_checks
  for each row execute function private.policy_checks_guard();

-- ── affiliate_links (15-1·16장) ─────────────────────────────
create table public.affiliate_links (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  program text not null check (program in ('coupang_partners', 'naver_shopping_connect', 'ohouse_curator',
                                           'musinsa_curator', 'oliveyoung_curator', 'youtube_shopping',
                                           'aliexpress', 'none')),
  -- 서버만 씀. 등록 제휴 도메인(https)만 허용, 리다이렉트 시 서버가 재검사(열린 리다이렉트 방지, 17-8)
  url text check (url ~* '^https://([a-z0-9-]+\.)*(coupang\.com|coupa\.ng|naver\.com|naver\.me|ohou\.se|musinsa\.com|oliveyoung\.co\.kr|youtube\.com|aliexpress\.com)(/[^\s]*)?$'),
  -- 자체 단축 링크, 서버 생성
  short_url text unique,
  -- 비밀 여부 확인 필요(05 4절 9번)
  partner_id_ref text,
  -- 꺼지면 정책 점검(제휴 고지) 실패
  disclosed boolean not null default true,
  bio_service text check (bio_service in ('inpock', 'litly')),
  bio_no integer check (bio_no >= 1),
  bio_registered_at timestamptz,
  created_at timestamptz not null default now()
);
comment on table public.affiliate_links is '제휴 링크. 본인은 program·disclosed·bio 열만, url·short_url은 서버(SR)만';
create index affiliate_links_project_id_idx on public.affiliate_links (project_id);

alter table public.affiliate_links enable row level security;
revoke all on public.affiliate_links from anon, authenticated;
grant select, delete on public.affiliate_links to authenticated;
grant insert (project_id, program, disclosed, bio_service, bio_no, bio_registered_at)
  on public.affiliate_links to authenticated;
grant update (program, disclosed, bio_service, bio_no, bio_registered_at)
  on public.affiliate_links to authenticated;

create policy affiliate_links_select_own on public.affiliate_links
  for select to authenticated
  using (exists (select 1 from public.projects p
                 where p.id = affiliate_links.project_id and p.user_id = (select auth.uid())));
create policy affiliate_links_insert_own on public.affiliate_links
  for insert to authenticated
  with check (exists (select 1 from public.projects p
                      where p.id = affiliate_links.project_id and p.user_id = (select auth.uid())));
create policy affiliate_links_update_own on public.affiliate_links
  for update to authenticated
  using (exists (select 1 from public.projects p
                 where p.id = affiliate_links.project_id and p.user_id = (select auth.uid())))
  with check (exists (select 1 from public.projects p
                      where p.id = affiliate_links.project_id and p.user_id = (select auth.uid())));
create policy affiliate_links_delete_own on public.affiliate_links
  for delete to authenticated
  using (exists (select 1 from public.projects p
                 where p.id = affiliate_links.project_id and p.user_id = (select auth.uid())));

-- ── bio_pages · bio_items (링크인바이오) ─────────────────────
create table public.bio_pages (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts (id) on delete cascade,
  service text not null check (service in ('inpock', 'litly')),
  url text,
  created_at timestamptz not null default now()
);
comment on table public.bio_pages is '채널별 링크인바이오 페이지(인포크링크·리틀리). 본인 읽기·쓰기';
create index bio_pages_account_id_idx on public.bio_pages (account_id);

alter table public.bio_pages enable row level security;
revoke all on public.bio_pages from anon, authenticated;
grant select, insert, update, delete on public.bio_pages to authenticated;

create policy bio_pages_select_own on public.bio_pages
  for select to authenticated
  using (exists (select 1 from public.accounts a
                 where a.id = bio_pages.account_id and a.user_id = (select auth.uid())));
create policy bio_pages_insert_own on public.bio_pages
  for insert to authenticated
  with check (exists (select 1 from public.accounts a
                      where a.id = bio_pages.account_id and a.user_id = (select auth.uid())));
create policy bio_pages_update_own on public.bio_pages
  for update to authenticated
  using (exists (select 1 from public.accounts a
                 where a.id = bio_pages.account_id and a.user_id = (select auth.uid())))
  with check (exists (select 1 from public.accounts a
                      where a.id = bio_pages.account_id and a.user_id = (select auth.uid())));
create policy bio_pages_delete_own on public.bio_pages
  for delete to authenticated
  using (exists (select 1 from public.accounts a
                 where a.id = bio_pages.account_id and a.user_id = (select auth.uid())));

create table public.bio_items (
  id uuid primary key default gen_random_uuid(),
  bio_page_id uuid not null references public.bio_pages (id) on delete cascade,
  project_id uuid references public.projects (id) on delete set null,
  no integer not null check (no >= 1),
  affiliate_link_id uuid references public.affiliate_links (id) on delete set null,
  short_url text,
  title text,
  thumb_url text,
  registered_at timestamptz,
  archived_at timestamptz
);
comment on table public.bio_items is '링크인바이오 번호 항목. 본인 읽기·쓰기(연결 프로젝트·제휴 링크도 본인 것만)';
create index bio_items_bio_page_id_idx on public.bio_items (bio_page_id);
create index bio_items_project_id_idx on public.bio_items (project_id);
create index bio_items_affiliate_link_id_idx on public.bio_items (affiliate_link_id);

alter table public.bio_items enable row level security;
revoke all on public.bio_items from anon, authenticated;
grant select, insert, update, delete on public.bio_items to authenticated;

create policy bio_items_select_own on public.bio_items
  for select to authenticated
  using (exists (select 1 from public.bio_pages bp join public.accounts a on a.id = bp.account_id
                 where bp.id = bio_items.bio_page_id and a.user_id = (select auth.uid())));
create policy bio_items_insert_own on public.bio_items
  for insert to authenticated
  with check (
    exists (select 1 from public.bio_pages bp join public.accounts a on a.id = bp.account_id
            where bp.id = bio_items.bio_page_id and a.user_id = (select auth.uid()))
    and (project_id is null or exists (select 1 from public.projects p
                                       where p.id = bio_items.project_id and p.user_id = (select auth.uid())))
    and (affiliate_link_id is null or exists (select 1 from public.affiliate_links al
                                              join public.projects p on p.id = al.project_id
                                              where al.id = bio_items.affiliate_link_id
                                                and p.user_id = (select auth.uid())))
  );
create policy bio_items_update_own on public.bio_items
  for update to authenticated
  using (exists (select 1 from public.bio_pages bp join public.accounts a on a.id = bp.account_id
                 where bp.id = bio_items.bio_page_id and a.user_id = (select auth.uid())))
  with check (
    exists (select 1 from public.bio_pages bp join public.accounts a on a.id = bp.account_id
            where bp.id = bio_items.bio_page_id and a.user_id = (select auth.uid()))
    and (project_id is null or exists (select 1 from public.projects p
                                       where p.id = bio_items.project_id and p.user_id = (select auth.uid())))
    and (affiliate_link_id is null or exists (select 1 from public.affiliate_links al
                                              join public.projects p on p.id = al.project_id
                                              where al.id = bio_items.affiliate_link_id
                                                and p.user_id = (select auth.uid())))
  );
create policy bio_items_delete_own on public.bio_items
  for delete to authenticated
  using (exists (select 1 from public.bio_pages bp join public.accounts a on a.id = bp.account_id
                 where bp.id = bio_items.bio_page_id and a.user_id = (select auth.uid())));

-- ── link_clicks (서버 쓰기 전용, IP 원문 저장 금지) ──────────
create table public.link_clicks (
  id uuid primary key default gen_random_uuid(),
  affiliate_link_id uuid not null references public.affiliate_links (id) on delete cascade,
  short_url text,
  clicked_at timestamptz not null default now(),
  referrer text,
  platform text
);
comment on table public.link_clicks is '단축 링크 클릭. 익명 클릭을 서버(SR)가 기록, 본인은 affiliate_links 경유로 읽기. IP 원문 없음';
create index link_clicks_affiliate_link_id_clicked_at_idx on public.link_clicks (affiliate_link_id, clicked_at);

alter table public.link_clicks enable row level security;
revoke all on public.link_clicks from anon, authenticated;
grant select on public.link_clicks to authenticated;

create policy link_clicks_select_own on public.link_clicks
  for select to authenticated
  using (exists (select 1 from public.affiliate_links al
                 join public.projects p on p.id = al.project_id
                 where al.id = link_clicks.affiliate_link_id and p.user_id = (select auth.uid())));

-- ── api_keys (원문은 Vault, 테이블에는 secret id) ───────────
create table public.api_keys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  provider text not null check (provider in ('anthropic', 'openai', 'fish_audio', 'elevenlabs', 'fal')),
  -- Vault secret id. authenticated 읽기 제외
  secret_ref uuid,
  last4 text check (char_length(last4) <= 4),
  -- 미등록 · 등록됨 · 연결 확인됨
  status text not null default 'unregistered' check (status in ('unregistered', 'registered', 'verified')),
  tested_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, provider)
);
comment on table public.api_keys is '사용자 API 키 메타. 원문은 Vault, 쓰기는 서버(SR)만, 본인은 last4·status·tested_at만 읽기';

alter table public.api_keys enable row level security;
revoke all on public.api_keys from anon, authenticated;
grant select (id, user_id, provider, last4, status, tested_at) on public.api_keys to authenticated;

create policy api_keys_select_own on public.api_keys
  for select to authenticated using (user_id = (select auth.uid()));
