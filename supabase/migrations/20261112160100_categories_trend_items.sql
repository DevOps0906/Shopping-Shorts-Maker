-- task-010: categories · trend_items (로그인 읽기 전용, 쓰기는 서버(SR)만)
-- 근거: docs/05_DATA_MODEL.md 3절, docs/planning.md 10·11장, 17-4

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  keywords_ko text[] not null default '{}',
  keywords_en text[] not null default '{}',
  keywords_zh text[] not null default '{}',
  banned_terms text[] not null default '{}'
);

create table public.trend_items (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.categories (id) on delete cascade,
  name text not null,
  -- 기간: 오늘 · 7일 · 30일
  period text not null check (period in ('today', '7d', '30d')),
  overseas_growth numeric,
  kr_search_growth numeric,
  -- 국내 숏폼 경쟁: 0~100 수치로 가정(기회 점수식의 100 - 경쟁). 05_DATA_MODEL 4절 10번 확인 필요
  kr_competition numeric check (kr_competition between 0 and 100),
  opportunity_score numeric check (opportunity_score between 0 and 100),
  sellable boolean not null default true,
  captured_at timestamptz not null default now()
);

comment on table public.categories is '카테고리 10종(planning 11장). 로그인 읽기 전용, 쓰기는 서버(SR)만';
comment on table public.trend_items is '트렌드 급상승 상품(planning 10장·17-4). 로그인 읽기 전용, 쓰기는 서버(SR)만';

create index trend_items_category_id_idx on public.trend_items (category_id);
create index trend_items_period_score_idx on public.trend_items (period, opportunity_score desc);

alter table public.categories enable row level security;
alter table public.trend_items enable row level security;

-- 기본 권한(Supabase default privileges)으로 열린 쓰기·TRUNCATE를 회수하고 로그인 읽기만 남긴다.
revoke all on public.categories, public.trend_items from anon, authenticated;
grant select on public.categories, public.trend_items to authenticated;

create policy categories_select_authenticated on public.categories
  for select to authenticated using (true);

create policy trend_items_select_authenticated on public.trend_items
  for select to authenticated using (true);
