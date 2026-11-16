-- 코어 웨이브 3단계 C6: 제휴마케팅 공용 모듈(affiliate 5개). contentflow(blog)·sceneflow(video) 등 제품이 함께 쓴다.
-- 원본: platform-docs _supabase-modular 0006_core_affiliate.sql(core.affiliate_* · brandconnect_applications).
-- 규칙
--   · 테이블 직접 접근은 service_role만(사용자 정책 없음 = authenticated·anon 0). 사용자는 아래 public.nomad_* RPC로만.
--   · 제공자 키·세션 원문은 provider_credentials(vault)에만. 여기에는 비밀이 아닌 식별자(partner_id)만 둔다.
--   · 대가성 문구는 끌 수 없다(끄는 컬럼 없음, 10자 미만 거부). 편집은 owner·admin.
--   · 브랜드커넥트 자동 지원은 약관·계정 정지 위험이 있어 owner·admin 위험 동의(risk_consented_at) 없이는 지원서를 만들 수 없다.
--   · 클릭은 리다이렉트 라우트가 record_affiliate_click(service_role)로만 기록한다. IP 원문 대신 서버가 만든 해시만.
--   · 원본의 source_app('video'·'blog')은 제품 코드(product_code → nomad_core.products)로 일반화한다.
-- 되돌림: drop function public.nomad_brandconnect_applications(uuid, integer),
--   public.nomad_create_brandconnect_application(uuid, text, text, text, text, text, text, text, text),
--   public.nomad_consent_brandconnect_risk(uuid), public.nomad_upsert_affiliate_disclosure(uuid, text, text, text),
--   public.nomad_effective_disclosure(uuid, text, text), public.nomad_affiliate_clicks(uuid, uuid, integer),
--   public.nomad_affiliate_links(uuid, integer), public.nomad_affiliate_accounts(uuid),
--   nomad_core.purge_affiliate_clicks(interval),
--   nomad_core.record_affiliate_click(text, text, text, text, text), nomad_core.new_affiliate_short_code(integer),
--   nomad_core.brandconnect_status_transition(), nomad_core.brandconnect_insert_guard();
--   drop table nomad_core.brandconnect_applications, nomad_core.affiliate_disclosures, nomad_core.affiliate_clicks,
--   nomad_core.affiliate_links, nomad_core.affiliate_accounts;
--   alter table nomad_core.jobs drop constraint jobs_id_organization_id_key;
--   alter table nomad_core.provider_credentials drop constraint provider_credentials_id_organization_id_key;
begin;

-- 조직 일치 복합 FK(참조 id, organization_id)의 대상. id가 이미 PK라 값 제약은 늘지 않는다.
alter table nomad_core.provider_credentials add constraint provider_credentials_id_organization_id_key unique (id, organization_id);
alter table nomad_core.jobs add constraint jobs_id_organization_id_key unique (id, organization_id);

-- ── 1. affiliate_accounts: 조직별 제공자 연결 ─────────────────
create table nomad_core.affiliate_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  provider text not null check (provider in ('coupang', 'naver_brandconnect', 'tenping', 'naver_shopping_connect')),
  credential_id uuid,
  partner_id text check (partner_id is null or length(partner_id) between 1 and 200),  -- 쿠팡 파트너스 ID 등 비밀 아닌 식별자
  label text check (label is null or length(label) <= 60),
  status text not null default 'active' check (status in ('active', 'paused', 'error', 'revoked')),
  risk_consented_at timestamptz,  -- 브랜드커넥트 자동 지원 위험 동의 시각
  risk_consented_by uuid references auth.users(id) on delete set null,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, provider, partner_id),
  unique (id, organization_id),
  -- 자격은 같은 조직 것만. 자격이 지워지면 credential_id만 비운다.
  foreign key (credential_id, organization_id) references nomad_core.provider_credentials (id, organization_id)
    on delete set null (credential_id)
);
create index affiliate_accounts_org_idx on nomad_core.affiliate_accounts (organization_id, provider);
create index affiliate_accounts_credential_idx on nomad_core.affiliate_accounts (credential_id) where credential_id is not null;
comment on table nomad_core.affiliate_accounts is
  '조직별 제휴 제공자 연결(비밀은 provider_credentials). 서버 전용, 사용자 읽기는 public.nomad_affiliate_accounts.';
create trigger affiliate_accounts_touch_updated_at
  before update on nomad_core.affiliate_accounts
  for each row execute function nomad_core.touch_updated_at();

-- ── 2. affiliate_links: 제휴 링크 + 단축 코드(/r/<code>) ───────
create table nomad_core.affiliate_links (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  account_id uuid,
  provider text not null check (provider in ('coupang', 'naver_brandconnect', 'tenping', 'naver_shopping_connect')),
  product_code text not null references nomad_core.products(code),  -- 링크를 만든 제품(원본 source_app)
  source_ref text check (source_ref is null or length(source_ref) <= 200),  -- 예: 영상 업로드 id, 블로그 글 id
  product_name text,
  original_url text not null,
  affiliate_url text not null,
  short_code text not null unique check (short_code ~ '^[a-z0-9]{6,32}$'),
  utm jsonb not null default '{}'::jsonb,
  click_count bigint not null default 0 check (click_count >= 0),  -- affiliate_clicks 집계 캐시
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint affiliate_links_url_check check (original_url ~* '^https?://' and affiliate_url ~* '^https?://'),
  unique (id, organization_id),
  -- 계정은 같은 조직 것만. 계정이 지워지면 account_id만 비운다.
  foreign key (account_id, organization_id) references nomad_core.affiliate_accounts (id, organization_id)
    on delete set null (account_id)
);
create index affiliate_links_org_idx on nomad_core.affiliate_links (organization_id, created_at desc);
create index affiliate_links_source_idx on nomad_core.affiliate_links (product_code, source_ref);
create index affiliate_links_account_idx on nomad_core.affiliate_links (account_id) where account_id is not null;
comment on table nomad_core.affiliate_links is
  '제휴 링크와 단축 코드. 서버 전용, 사용자 읽기는 public.nomad_affiliate_links, 클릭은 record_affiliate_click.';
-- 클릭 집계(click_count)만 바뀐 갱신은 수정 시각을 건드리지 않는다.
create trigger affiliate_links_touch_updated_at
  before update on nomad_core.affiliate_links
  for each row
  when ((to_jsonb(old) - 'click_count' - 'updated_at') is distinct from (to_jsonb(new) - 'click_count' - 'updated_at'))
  execute function nomad_core.touch_updated_at();

-- ── 3. affiliate_clicks: 클릭 로그(추가 전용 성격, service_role만 기록) ──
create table nomad_core.affiliate_clicks (
  id bigint generated always as identity primary key,
  link_id uuid not null,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  clicked_at timestamptz not null default now(),
  foreign key (link_id, organization_id) references nomad_core.affiliate_links (id, organization_id) on delete cascade,
  referrer text,
  ip_hash text check (ip_hash is null or length(ip_hash) <= 128),  -- 일 단위 솔트 해시(원문 IP 금지)
  user_agent text,
  country text check (country is null or length(country) <= 8)
);
create index affiliate_clicks_link_idx on nomad_core.affiliate_clicks (link_id, clicked_at desc);
create index affiliate_clicks_org_idx on nomad_core.affiliate_clicks (organization_id, clicked_at desc);
comment on table nomad_core.affiliate_clicks is
  '제휴 링크 클릭 로그(IP는 해시만). 서버 전용, 사용자 읽기는 owner·admin이 public.nomad_affiliate_clicks로.';

-- ── 4. affiliate_disclosures: 대가성 문구(끄는 컬럼 없음) ─────
--    organization_id null 행 = 플랫폼 기본값(서버가 넣는다). 조직 행이 있으면 그것을 우선한다.
create table nomad_core.affiliate_disclosures (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references nomad_core.organizations(id) on delete cascade,
  provider text not null check (provider in ('coupang', 'naver_brandconnect', 'tenping', 'naver_shopping_connect')),
  placement text not null check (placement in ('blog_top', 'video_description', 'video_pinned_comment')),
  body text not null check (length(btrim(body)) between 10 and 2000),
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index affiliate_disclosures_org_uniq
  on nomad_core.affiliate_disclosures (organization_id, provider, placement) where organization_id is not null;
create unique index affiliate_disclosures_default_uniq
  on nomad_core.affiliate_disclosures (provider, placement) where organization_id is null;
comment on table nomad_core.affiliate_disclosures is
  '대가성 문구(조직 null = 플랫폼 기본값). 끌 수 없음. 서버 전용, 조회·편집은 public.nomad_effective_disclosure·nomad_upsert_affiliate_disclosure.';
create trigger affiliate_disclosures_touch_updated_at
  before update on nomad_core.affiliate_disclosures
  for each row execute function nomad_core.touch_updated_at();

-- ── 5. brandconnect_applications: 네이버 브랜드커넥트 자동 지원 ──
--    상태 전이: draft → submitting → submitted → accepted | rejected, submitting → failed → (재시도) submitting
--    실제 제출은 jobs(job_type 'brandconnect.apply')로 서버 워커가 한다.
create table nomad_core.brandconnect_applications (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  account_id uuid not null,
  product_code text not null references nomad_core.products(code),  -- 지원서를 만든 제품(원본 source_app)
  campaign_id text not null check (length(campaign_id) between 1 and 200),
  brand_name text check (brand_name is null or length(brand_name) <= 200),
  product_name text check (product_name is null or length(product_name) <= 200),
  category text check (category is null or length(category) <= 100),
  target_url text not null check (target_url ~* '^https://[^/@[:space:]]+' and length(target_url) <= 2000),
  target_kind text not null check (target_kind in ('blog', 'clip')),
  message text check (message is null or length(message) <= 4000),
  status text not null default 'draft'
    check (status in ('draft', 'submitting', 'submitted', 'accepted', 'rejected', 'failed')),
  attempts integer not null default 0 check (attempts >= 0),
  job_id uuid,
  external_id text,
  last_error text,
  submitted_at timestamptz,
  decided_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (account_id, campaign_id),  -- 같은 계정·캠페인 재호출은 기존 지원서를 돌려준다(멱등)
  -- 계정·작업은 같은 조직 것만. 작업이 지워지면 job_id만 비운다.
  foreign key (account_id, organization_id) references nomad_core.affiliate_accounts (id, organization_id) on delete cascade,
  foreign key (job_id, organization_id) references nomad_core.jobs (id, organization_id) on delete set null (job_id)
);
create index brandconnect_applications_org_idx on nomad_core.brandconnect_applications (organization_id, created_at desc);
create index brandconnect_applications_job_idx on nomad_core.brandconnect_applications (job_id) where job_id is not null;
comment on table nomad_core.brandconnect_applications is
  '네이버 브랜드커넥트 지원서(위험 동의 필수, 상태 전이 트리거). 서버 전용, 사용자는 public.nomad_create_brandconnect_application·nomad_brandconnect_applications.';
create trigger brandconnect_applications_touch_updated_at
  before update on nomad_core.brandconnect_applications
  for each row execute function nomad_core.touch_updated_at();

-- 상태 전이 검증(service_role 직접 쓰기에도 적용)
create function nomad_core.brandconnect_status_transition()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.status is distinct from old.status and not (
       (old.status = 'draft'      and new.status = 'submitting')
    or (old.status = 'submitting' and new.status in ('submitted', 'failed'))
    or (old.status = 'failed'     and new.status = 'submitting')
    or (old.status = 'submitted'  and new.status in ('accepted', 'rejected'))
  ) then
    raise exception 'brandconnect: invalid status transition % -> %', old.status, new.status using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger brandconnect_applications_transition
  before update on nomad_core.brandconnect_applications
  for each row execute function nomad_core.brandconnect_status_transition();

-- 새 지원서는 draft로만 시작한다(service_role 직접 쓰기 포함). 제출 이후 상태는 전이로만.
create function nomad_core.brandconnect_insert_guard()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.status <> 'draft' then
    raise exception 'brandconnect: new application must start as draft (got %)', new.status using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger brandconnect_applications_insert_guard
  before insert on nomad_core.brandconnect_applications
  for each row execute function nomad_core.brandconnect_insert_guard();

-- ── 권한 · RLS: 사용자 정책 없음 = authenticated·anon 직접 접근 0 ──
alter table nomad_core.affiliate_accounts enable row level security;
alter table nomad_core.affiliate_links enable row level security;
alter table nomad_core.affiliate_clicks enable row level security;
alter table nomad_core.affiliate_disclosures enable row level security;
alter table nomad_core.brandconnect_applications enable row level security;
revoke all on nomad_core.affiliate_accounts, nomad_core.affiliate_links, nomad_core.affiliate_clicks,
              nomad_core.affiliate_disclosures, nomad_core.brandconnect_applications
  from public, anon, authenticated, service_role;
grant select, insert, update, delete on nomad_core.affiliate_accounts, nomad_core.affiliate_links,
  nomad_core.affiliate_disclosures, nomad_core.brandconnect_applications to service_role;
-- 클릭 로그는 고치지 않는다: 기록은 record_affiliate_click, 서버는 읽기·보존 정리(delete)만.
grant select, delete on nomad_core.affiliate_clicks to service_role;

-- ── 서버 함수 ─────────────────────────────────────────────
-- 단축 코드 생성(충돌 시 최대 5회 재시도). 서버가 링크를 만들 때 쓴다.
create function nomad_core.new_affiliate_short_code(p_len integer default 8)
returns text
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_alphabet constant text := 'abcdefghijkmnpqrstuvwxyz23456789';
  v_code text;
  v_bytes bytea;
  i integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'new_affiliate_short_code: server only' using errcode = '42501';
  end if;
  if p_len is null or p_len not between 6 and 32 then
    raise exception 'new_affiliate_short_code: length must be 6..32' using errcode = '22023';
  end if;
  for attempt in 1..5 loop
    v_bytes := extensions.gen_random_bytes(p_len);
    v_code := '';
    for i in 0..p_len - 1 loop
      v_code := v_code || substr(v_alphabet, (get_byte(v_bytes, i) % length(v_alphabet)) + 1, 1);
    end loop;
    if not exists (select 1 from nomad_core.affiliate_links where short_code = v_code) then
      return v_code;
    end if;
  end loop;
  raise exception 'new_affiliate_short_code: collision retries exhausted';
end;
$$;

-- 리다이렉트 라우트용: 클릭 기록 + 대상 URL 반환(없거나 비활성이면 null).
-- 공개 라우트라 호출 전에 nomad_core.rate_limit_hit(예: 'aff:' || ip_hash, 한도, 윈도우)로 거르고, 거부면 기록하지 않는다.
create function nomad_core.record_affiliate_click(
  p_short_code text, p_referrer text default null, p_ip_hash text default null,
  p_user_agent text default null, p_country text default null
)
returns text
language plpgsql security definer set search_path = ''
as $$
declare v_link nomad_core.affiliate_links;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'record_affiliate_click: server only' using errcode = '42501';
  end if;
  select * into v_link from nomad_core.affiliate_links where short_code = p_short_code and is_active;
  if v_link.id is null then
    return null;
  end if;
  insert into nomad_core.affiliate_clicks (link_id, organization_id, referrer, ip_hash, user_agent, country)
  values (v_link.id, v_link.organization_id, left(p_referrer, 500), left(p_ip_hash, 128), left(p_user_agent, 300), left(p_country, 8));
  update nomad_core.affiliate_links set click_count = click_count + 1 where id = v_link.id;
  return v_link.affiliate_url;
end;
$$;

-- 클릭 로그 보존 정리: clicked_at이 p_older_than보다 오래된 행 삭제. 스케줄링(pg_cron 등)은 제품 몫. 반환: 지운 행 수.
-- click_count(누적 집계)는 줄이지 않는다.
create function nomad_core.purge_affiliate_clicks(p_older_than interval)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_count integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'purge_affiliate_clicks: server only' using errcode = '42501';
  end if;
  if p_older_than is null or p_older_than < interval '0' then
    raise exception 'purge_affiliate_clicks: p_older_than must be >= 0' using errcode = '22023';
  end if;
  delete from nomad_core.affiliate_clicks where clicked_at < clock_timestamp() - p_older_than;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ── 사용자 RPC ────────────────────────────────────────────
-- 조직 멤버: 제공자 연결 목록(자격 연결 id·오류 원문은 주지 않음).
create function public.nomad_affiliate_accounts(target_organization uuid)
returns table (id uuid, provider text, partner_id text, label text, status text, has_credential boolean,
               risk_consented_at timestamptz, created_at timestamptz, updated_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if nomad_core.organization_role(target_organization) is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
    select a.id, a.provider, a.partner_id, a.label, a.status, a.credential_id is not null,
           a.risk_consented_at, a.created_at, a.updated_at
    from nomad_core.affiliate_accounts a
    where a.organization_id = target_organization
    order by a.provider, a.created_at;
end;
$$;

-- 조직 멤버: 제휴 링크 최신순(최대 200건).
create function public.nomad_affiliate_links(target_organization uuid, page_size integer default 50)
returns table (id uuid, account_id uuid, provider text, product_code text, source_ref text, product_name text,
               original_url text, affiliate_url text, short_code text, utm jsonb, click_count bigint, is_active boolean,
               created_by uuid, created_at timestamptz, updated_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if nomad_core.organization_role(target_organization) is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
    select l.id, l.account_id, l.provider, l.product_code, l.source_ref, l.product_name, l.original_url, l.affiliate_url,
           l.short_code, l.utm, l.click_count, l.is_active, l.created_by, l.created_at, l.updated_at
    from nomad_core.affiliate_links l
    where l.organization_id = target_organization
    order by l.created_at desc, l.id
    limit least(greatest(coalesce(page_size, 50), 1), 200);
end;
$$;

-- owner·admin: 클릭 로그 최신순(링크 한정 선택, 최대 200건). IP 해시·UA는 주지 않는다.
create function public.nomad_affiliate_clicks(target_organization uuid, target_link uuid default null, page_size integer default 50)
returns table (id bigint, link_id uuid, clicked_at timestamptz, referrer text, country text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if coalesce(nomad_core.organization_role(target_organization), '') not in ('owner', 'admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
    select c.id, c.link_id, c.clicked_at, c.referrer, c.country
    from nomad_core.affiliate_clicks c
    where c.organization_id = target_organization and (target_link is null or c.link_id = target_link)
    order by c.clicked_at desc, c.id desc
    limit least(greatest(coalesce(page_size, 50), 1), 200);
end;
$$;

-- 조직 멤버: 유효 대가성 문구(조직 문구 우선, 없으면 플랫폼 기본값, 둘 다 없으면 null).
create function public.nomad_effective_disclosure(target_organization uuid, target_provider text, target_placement text)
returns text
language plpgsql stable security definer set search_path = ''
as $$
begin
  if nomad_core.organization_role(target_organization) is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return (
    select d.body
    from nomad_core.affiliate_disclosures d
    where d.provider = target_provider and d.placement = target_placement
      and (d.organization_id = target_organization or d.organization_id is null)
    order by (d.organization_id is null)
    limit 1
  );
end;
$$;

-- owner·admin: 조직 문구 편집(끄기 불가, 10자 미만은 CHECK가 거부). 감사 기록.
create function public.nomad_upsert_affiliate_disclosure(
  target_organization uuid, target_provider text, target_placement text, disclosure_body text
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid; v_before text;
begin
  if coalesce(nomad_core.organization_role(target_organization), '') not in ('owner', 'admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select d.body into v_before from nomad_core.affiliate_disclosures d
  where d.organization_id = target_organization and d.provider = target_provider and d.placement = target_placement
  for update;
  insert into nomad_core.affiliate_disclosures (organization_id, provider, placement, body, updated_by)
  values (target_organization, target_provider, target_placement, disclosure_body, auth.uid())
  on conflict (organization_id, provider, placement) where organization_id is not null
  do update set body = excluded.body, updated_by = excluded.updated_by
  returning id into v_id;
  perform nomad_core.write_audit(target_organization, 'affiliate.disclosure.upsert', 'affiliate_disclosure', v_id::text,
                                 case when v_before is null then null else jsonb_build_object('body', v_before) end,
                                 jsonb_build_object('body', disclosure_body),
                                 jsonb_build_object('provider', target_provider, 'placement', target_placement));
  return v_id;
end;
$$;

-- owner·admin: 브랜드커넥트 자동 지원 위험 동의. 이미 동의했으면 시각을 바꾸지 않는다(멱등). 감사 기록.
create function public.nomad_consent_brandconnect_risk(account_id uuid)
returns timestamptz
language plpgsql security definer set search_path = ''
as $$
declare v_acc nomad_core.affiliate_accounts;
begin
  select * into v_acc from nomad_core.affiliate_accounts a where a.id = account_id for update;
  if v_acc.id is null or coalesce(nomad_core.organization_role(v_acc.organization_id), '') not in ('owner', 'admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_acc.provider <> 'naver_brandconnect' then
    raise exception 'consent_brandconnect_risk: not a brandconnect account' using errcode = '22023';
  end if;
  if v_acc.risk_consented_at is not null then
    return v_acc.risk_consented_at;
  end if;
  update nomad_core.affiliate_accounts a
     set risk_consented_at = now(), risk_consented_by = auth.uid()
   where a.id = v_acc.id;
  perform nomad_core.write_audit(v_acc.organization_id, 'affiliate.brandconnect.risk_consent', 'affiliate_account', v_acc.id::text);
  return now();
end;
$$;

-- owner·admin·editor: 지원서 생성(draft). 위험 동의·활성 계정 필수. 같은 계정·캠페인 재호출은 기존 id(멱등).
-- 제출은 서버 워커가 jobs로 한다.
create function public.nomad_create_brandconnect_application(
  account_id uuid, campaign_id text, target_url text, target_kind text, target_product text,
  brand_name text default null, product_name text default null, category text default null, message text default null
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_acc nomad_core.affiliate_accounts; v_id uuid; v_old nomad_core.brandconnect_applications;
begin
  select * into v_acc from nomad_core.affiliate_accounts a where a.id = account_id;
  if v_acc.id is null or coalesce(nomad_core.organization_role(v_acc.organization_id), '') not in ('owner', 'admin', 'editor') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_acc.provider <> 'naver_brandconnect' then
    raise exception 'create_brandconnect_application: not a brandconnect account' using errcode = '22023';
  end if;
  if v_acc.risk_consented_at is null then
    raise exception 'create_brandconnect_application: risk consent required' using errcode = '42501';
  end if;
  if v_acc.status <> 'active' then
    raise exception 'create_brandconnect_application: account is %', v_acc.status using errcode = '22023';
  end if;
  -- 기능 잠금: 제품이 plan_features·feature_grants로 'brandconnect'를 열어 준 조직만(시드 없으면 잠김).
  if not nomad_core.has_feature(v_acc.organization_id, target_product, 'brandconnect') then
    raise exception 'create_brandconnect_application: brandconnect feature locked' using errcode = '42501';
  end if;
  insert into nomad_core.brandconnect_applications as b
    (organization_id, account_id, product_code, campaign_id, brand_name, product_name, category,
     target_url, target_kind, message, created_by)
  values
    (v_acc.organization_id, v_acc.id, target_product, campaign_id, brand_name, product_name, category,
     target_url, target_kind, message, auth.uid())
  on conflict on constraint brandconnect_applications_account_id_campaign_id_key do nothing
  returning b.id into v_id;
  if v_id is null then
    -- 멱등 재호출: 같은 본문이면 기존 id, 다르면 거부(조용히 옛 지원서를 돌려주지 않는다).
    select * into v_old from nomad_core.brandconnect_applications b
    where b.account_id = v_acc.id and b.campaign_id = nomad_create_brandconnect_application.campaign_id;
    if v_old.target_url is distinct from nomad_create_brandconnect_application.target_url
       or v_old.target_kind is distinct from nomad_create_brandconnect_application.target_kind
       or v_old.product_code is distinct from target_product then
      raise exception 'create_brandconnect_application: campaign already applied with different body' using errcode = '22023';
    end if;
    return v_old.id;
  end if;
  perform nomad_core.write_audit(v_acc.organization_id, 'affiliate.brandconnect.application_create', 'brandconnect_application',
                                 v_id::text, null,
                                 jsonb_build_object('campaign_id', campaign_id, 'target_kind', target_kind, 'product_code', target_product));
  return v_id;
end;
$$;

-- 조직 멤버: 지원서 목록 최신순(최대 200건). 워커·오류 원문은 주지 않는다.
create function public.nomad_brandconnect_applications(target_organization uuid, page_size integer default 50)
returns table (id uuid, account_id uuid, product_code text, campaign_id text, brand_name text, product_name text,
               category text, target_url text, target_kind text, status text, attempts integer,
               submitted_at timestamptz, decided_at timestamptz, created_by uuid, created_at timestamptz, updated_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if nomad_core.organization_role(target_organization) is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
    select b.id, b.account_id, b.product_code, b.campaign_id, b.brand_name, b.product_name, b.category, b.target_url,
           b.target_kind, b.status, b.attempts, b.submitted_at, b.decided_at, b.created_by, b.created_at, b.updated_at
    from nomad_core.brandconnect_applications b
    where b.organization_id = target_organization
    order by b.created_at desc, b.id
    limit least(greatest(coalesce(page_size, 50), 1), 200);
end;
$$;

-- ── 함수 권한 ─────────────────────────────────────────────
revoke all on function
  nomad_core.brandconnect_status_transition(),
  nomad_core.brandconnect_insert_guard(),
  nomad_core.new_affiliate_short_code(integer),
  nomad_core.record_affiliate_click(text, text, text, text, text),
  nomad_core.purge_affiliate_clicks(interval),
  public.nomad_affiliate_accounts(uuid),
  public.nomad_affiliate_links(uuid, integer),
  public.nomad_affiliate_clicks(uuid, uuid, integer),
  public.nomad_effective_disclosure(uuid, text, text),
  public.nomad_upsert_affiliate_disclosure(uuid, text, text, text),
  public.nomad_consent_brandconnect_risk(uuid),
  public.nomad_create_brandconnect_application(uuid, text, text, text, text, text, text, text, text),
  public.nomad_brandconnect_applications(uuid, integer)
from public, anon, authenticated;
grant execute on function
  nomad_core.new_affiliate_short_code(integer),
  nomad_core.record_affiliate_click(text, text, text, text, text),
  nomad_core.purge_affiliate_clicks(interval)
to service_role;
grant execute on function
  public.nomad_affiliate_accounts(uuid),
  public.nomad_affiliate_links(uuid, integer),
  public.nomad_affiliate_clicks(uuid, uuid, integer),
  public.nomad_effective_disclosure(uuid, text, text),
  public.nomad_upsert_affiliate_disclosure(uuid, text, text, text),
  public.nomad_consent_brandconnect_risk(uuid),
  public.nomad_create_brandconnect_application(uuid, text, text, text, text, text, text, text, text),
  public.nomad_brandconnect_applications(uuid, integer)
to authenticated;

commit;
