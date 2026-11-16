-- 코어 웨이브 3단계 C5: AI 계층(제공자·단가·라우팅·국외 이전 동의 · RAG 컬렉션·문서·청크(pgvector) · 지식 위키 · 대화·실행 기록 · 사용량).
-- 원본: platform-docs _supabase-modular 0008_core_ai.sql(+ 0003 ai_usage). 이름 대응: core → nomad_core, org_id → organization_id, app_id → product_code.
-- 원본과 다른 점
--   - 서버(service_role) 전용: authenticated·anon에는 표·함수 권한 0, 사용자 정책 0, public 래퍼 0개(tests/ai.sql이 고정).
--     원본의 set_ai_routing·set_ai_cross_border_ack 사용자 실행은 없앴다 — 서버가 요청 사용자를 p_actor로 넘기면
--     함수가 그 조직 owner·admin인지 확인하고 ack_by·updated_by·감사 metadata.actor_id에 남긴다.
--   - 위키 이력 불변 트리거는 외래키 연쇄 삭제(조직 삭제·purge_wiki_page)만 허용(allow_purge 설정 없음). wiki_pages 직접 DELETE 권한 없음.
--   - 위키에서 만든 문서는 ai_documents.wiki_page_id로 연결해 페이지 삭제 시 문서·청크도 지운다.
--   - ai_runtime(LangGraph 체크포인트) 스키마는 만들지 않는다.
--   - 임베딩은 vector(1024) 고정(nomad-docker-module TEI bge-m3와 일치).
--   - ai_usage는 새로 만든다: 원본 단위 비용(cost_usd_micros) + cost_krw integer(원, 환산은 앱). 크레딧 원장 연결은 credit_ledger(uuid).
--   - ai_runs.job_id는 외래키 없이 uuid만 둔다(jobs는 같은 웨이브 다른 파일, 의존을 만들지 않음).
--   - 단가(ai_model_prices) 수치는 넣지 않는다. 제공자 목록(9개)만 시드한다(제품 라우팅 시드가 이 id를 쓴다).
-- 되돌림: drop function nomad_core.purge_wiki_page(uuid, uuid, text), nomad_core.set_ai_cross_border_ack(uuid, boolean, text, uuid),
--   nomad_core.set_ai_routing(uuid, text, text, text, text, jsonb, boolean, uuid), nomad_core.resolve_ai_route(uuid, text, text, text),
--   nomad_core.match_ai_chunks(uuid, text, extensions.vector, integer, uuid, real), nomad_core.ai_filter_chain(jsonb, text, boolean, boolean);
--   drop table nomad_core.ai_usage, nomad_core.ai_run_steps, nomad_core.ai_runs, nomad_core.ai_messages, nomad_core.ai_conversations,
--     nomad_core.wiki_revisions, nomad_core.wiki_links, nomad_core.wiki_pages, nomad_core.ai_chunks, nomad_core.ai_documents,
--     nomad_core.ai_collections, nomad_core.ai_org_settings, nomad_core.ai_routing_settings, nomad_core.ai_model_prices, nomad_core.ai_providers;
--   drop function nomad_core.wiki_revisions_immutable();
begin;

create extension if not exists vector with schema extensions;

-- ── 1. 제공자 · 모델 단가 · 라우팅 · 조직 AI 설정 ─────────────────
create table nomad_core.ai_providers (
  id text primary key,                          -- anthropic, openai, google, openrouter, oss-llm, voyage, oss-embed, elevenlabs, oss-voice
  name text not null,
  source text not null check (source in ('commercial', 'open_source')),
  kinds text[] not null check (kinds <@ array['llm', 'embedding', 'stt', 'tts']::text[] and cardinality(kinds) > 0),
  cross_border boolean not null default false,  -- 국외 이전(개인정보 처리방침 고지 대상)
  is_active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ai_providers_oss_domestic_check check (source = 'commercial' or not cross_border)
);

create table nomad_core.ai_model_prices (
  id uuid primary key default gen_random_uuid(),
  provider_id text not null references nomad_core.ai_providers(id) on delete cascade,
  model text not null default '*',              -- '*' = 그 제공자의 기본 단가
  kind text not null check (kind in ('llm', 'embedding', 'stt', 'tts')),
  unit text not null check (unit in ('1k_input_tokens', '1k_output_tokens', '1k_tokens', 'minute', '1k_characters')),
  credits_per_unit numeric(12, 4) not null check (credits_per_unit >= 0),
  license text,                                 -- 오픈소스 모델 라이선스(상업 이용 가능 여부 확인 결과)
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (provider_id, model, kind, unit)
);

-- organization_id null = 플랫폼 기본값, product_code null = 모든 제품, feature '*' = 제품 기본값.
-- 범위 유일성은 nulls not distinct(제품 시드의 on conflict do nothing이 이 제약에 걸린다).
create table nomad_core.ai_routing_settings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references nomad_core.organizations(id) on delete cascade,
  product_code text references nomad_core.products(code) on delete cascade,
  feature text not null default '*' check (feature = lower(btrim(feature)) and feature <> ''),
  kind text not null check (kind in ('llm', 'embedding', 'stt', 'tts')),
  mode text not null default 'auto' check (mode in ('commercial', 'open_source', 'auto')),
  chain jsonb not null default '[]'::jsonb check (jsonb_typeof(chain) = 'array'),  -- [{"provider":"anthropic","model":"*"}, ...] 대체 순서
  force_open_source boolean not null default false,  -- 민감 데이터: 상용 API로 보내지 않는다
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ai_routing_settings_force_check check (not force_open_source or mode = 'open_source'),
  constraint ai_routing_settings_scope_uniq unique nulls not distinct (organization_id, product_code, feature, kind)
);
create index ai_routing_settings_product_idx on nomad_core.ai_routing_settings (product_code, kind);

-- 조직 AI 설정: 국외 이전(상용 제공자) 동의. 동의가 없으면 라우터는 국외 제공자를 쓰지 않는다.
create table nomad_core.ai_org_settings (
  organization_id uuid primary key references nomad_core.organizations(id) on delete cascade,
  cross_border_ack_at timestamptz,
  cross_border_notice text,                     -- 동의한 고지문 버전
  ack_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ── 2. RAG: 컬렉션 · 문서 · 청크 ─────────────────────────────
create table nomad_core.ai_collections (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  product_code text not null references nomad_core.products(code),
  kind text not null check (kind in ('rag', 'wiki')),
  name text not null,
  embedding_provider text not null references nomad_core.ai_providers(id),
  embedding_model text not null,
  embedding_dim integer not null default 1024 check (embedding_dim = 1024),
  status text not null default 'active' check (status in ('active', 'reindexing', 'archived')),
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, product_code, name),
  unique (id, organization_id, product_code)
);

-- ── 3. 제품 지식 위키(LLM Wiki) — ai_documents가 페이지를 가리키므로 먼저 만든다 ─────
create table nomad_core.wiki_pages (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  product_code text not null references nomad_core.products(code),
  collection_id uuid,                                -- 위키 임베딩 컬렉션(kind=wiki). 같은 조직·제품만(복합 외래키)
  slug text not null check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*(/[a-z0-9]+(-[a-z0-9]+)*)*$'),
  title text not null,
  summary text,
  body_md text not null default '',
  page_type text not null default 'topic' check (page_type in ('index', 'topic', 'entity', 'concept', 'source', 'log')),
  version integer not null default 1,
  status text not null default 'published' check (status in ('draft', 'published', 'archived')),
  last_editor text not null default 'agent' check (last_editor in ('agent', 'user')),
  last_edited_by uuid,
  source_document_ids uuid[] not null default '{}',  -- 근거 원본(낡음 판정, 개인정보 유래 추적)
  derived_from_pii boolean not null default false,   -- 개인정보 원본 유래면 오픈소스로만 처리(앱 게이트웨이 책임)
  stale_since timestamptz,                           -- lint가 원본보다 오래됐다고 판정한 시각
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, product_code, slug),
  unique (id, organization_id),
  foreign key (collection_id, organization_id, product_code)
    references nomad_core.ai_collections(id, organization_id, product_code) on delete set null (collection_id)
);
create index wiki_pages_collection_idx on nomad_core.wiki_pages (collection_id);

create table nomad_core.ai_documents (
  id uuid primary key default gen_random_uuid(),
  collection_id uuid not null,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  product_code text not null references nomad_core.products(code),
  source_type text not null check (source_type in ('upload', 'url', 'text', 'product', 'wiki')),
  title text,
  storage_path text,
  source_url text,
  content_hash text not null,
  mime text,
  byte_size bigint,
  status text not null default 'pending' check (status in ('pending', 'indexing', 'ready', 'failed', 'deleted')),
  -- true면 오픈소스 임베딩·LLM만 써야 한다. DB는 표시만 하고 강제는 앱 게이트웨이 책임(라우팅 요청 시 force로 넘긴다).
  contains_pii boolean not null default false,
  wiki_page_id uuid,                            -- source_type='wiki'일 때 원본 위키 페이지. 페이지 삭제 시 문서·청크도 연쇄 삭제
  error text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (collection_id, content_hash),
  unique (id, organization_id, product_code, collection_id),
  constraint ai_documents_wiki_page_check check ((source_type = 'wiki') = (wiki_page_id is not null)),
  foreign key (collection_id, organization_id, product_code)
    references nomad_core.ai_collections(id, organization_id, product_code) on delete cascade,
  foreign key (wiki_page_id, organization_id) references nomad_core.wiki_pages(id, organization_id) on delete cascade
);
create index ai_documents_org_idx on nomad_core.ai_documents (organization_id, product_code, status);
create index ai_documents_wiki_page_idx on nomad_core.ai_documents (wiki_page_id) where wiki_page_id is not null;

create table nomad_core.ai_chunks (
  id bigint generated always as identity primary key,
  document_id uuid not null,
  collection_id uuid not null,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  product_code text not null references nomad_core.products(code),
  chunk_index integer not null,
  content text not null,
  token_count integer,
  embedding extensions.vector(1024) not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (document_id, chunk_index),
  foreign key (document_id, organization_id, product_code, collection_id)
    references nomad_core.ai_documents(id, organization_id, product_code, collection_id) on delete cascade
);
create index ai_chunks_scope_idx on nomad_core.ai_chunks (organization_id, product_code, collection_id);
create index ai_chunks_embedding_hnsw on nomad_core.ai_chunks using hnsw (embedding extensions.vector_cosine_ops);

-- 위키 링크 · 이력
create table nomad_core.wiki_links (
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  from_page_id uuid not null,
  to_page_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (from_page_id, to_page_id),
  constraint wiki_links_self_check check (from_page_id <> to_page_id),
  foreign key (from_page_id, organization_id) references nomad_core.wiki_pages(id, organization_id) on delete cascade,
  foreign key (to_page_id, organization_id) references nomad_core.wiki_pages(id, organization_id) on delete cascade
);
create index wiki_links_to_idx on nomad_core.wiki_links (to_page_id, organization_id);
create index wiki_links_org_idx on nomad_core.wiki_links (organization_id);

create table nomad_core.wiki_revisions (
  id bigint generated always as identity primary key,
  page_id uuid not null,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  version integer not null,
  body_md text not null,
  editor_kind text not null check (editor_kind in ('agent', 'user')),
  edited_by uuid,
  reason text,
  source_document_ids uuid[] not null default '{}',
  created_at timestamptz not null default now(),
  unique (page_id, version),
  foreign key (page_id, organization_id) references nomad_core.wiki_pages(id, organization_id) on delete cascade
);
create index wiki_revisions_org_idx on nomad_core.wiki_revisions (organization_id);

-- ── 4. 대화(플랫폼 대화 id ↔ Dify) · 메시지 · 실행 기록 · 사용량 ─────
create table nomad_core.ai_conversations (
  id uuid primary key default gen_random_uuid(),     -- 플랫폼 대화 id(Dify 입력 platform_conversation_id)
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  product_code text not null references nomad_core.products(code),
  user_id uuid,                                      -- 로그인 사용자
  visitor_key text,                                  -- 비로그인 방문자: 서버가 만든 쿠키 값의 해시
  dify_user text not null,                           -- 서버가 만든 불투명 값. 클라이언트 입력 금지
  dify_conversation_id text,                         -- 첫 응답 후 서버가 채운다
  channel text not null default 'text' check (channel in ('text', 'voice')),
  status text not null default 'active' check (status in ('active', 'closed')),
  title text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (product_code, dify_conversation_id),
  unique (id, organization_id),
  constraint ai_conversations_owner_check check (user_id is not null or visitor_key is not null)
);
create index ai_conversations_user_idx on nomad_core.ai_conversations (organization_id, user_id, updated_at desc);

create table nomad_core.ai_messages (
  id bigint generated always as identity primary key,
  conversation_id uuid not null,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  role text not null check (role in ('user', 'assistant', 'tool')),
  content text not null,
  citations jsonb not null default '[]'::jsonb,      -- [{"type":"chunk","id":..},{"type":"wiki","slug":..}]
  provider_id text references nomad_core.ai_providers(id),
  model text,
  input_tokens integer not null default 0,
  output_tokens integer not null default 0,
  credits integer not null default 0,
  credit_ledger_id uuid references nomad_core.credit_ledger(id),
  created_at timestamptz not null default now(),
  foreign key (conversation_id, organization_id) references nomad_core.ai_conversations(id, organization_id) on delete cascade
);
create index ai_messages_conv_idx on nomad_core.ai_messages (conversation_id, id);
create index ai_messages_org_idx on nomad_core.ai_messages (organization_id);

create table nomad_core.ai_runs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  product_code text not null references nomad_core.products(code),
  graph text not null,                               -- 예: astro.reading, blog.post_draft
  status text not null default 'queued' check (status in ('queued', 'running', 'succeeded', 'failed', 'canceled')),
  input jsonb not null default '{}'::jsonb,
  output jsonb,
  error text,
  provider_id text references nomad_core.ai_providers(id),
  model text,
  input_tokens integer not null default 0,
  output_tokens integer not null default 0,
  credits integer not null default 0,
  credit_ledger_id uuid references nomad_core.credit_ledger(id),
  job_id uuid,                                       -- nomad_core.jobs.id(외래키 없음)
  trace_id text,
  thread_id text,                                    -- LangGraph 체크포인트 thread
  created_by uuid,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (id, organization_id)
);
create index ai_runs_org_idx on nomad_core.ai_runs (organization_id, product_code, created_at desc);
create index ai_runs_job_idx on nomad_core.ai_runs (job_id) where job_id is not null;

create table nomad_core.ai_run_steps (
  id bigint generated always as identity primary key,
  run_id uuid not null,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  node text not null,
  status text not null check (status in ('running', 'succeeded', 'failed', 'skipped')),
  provider_id text references nomad_core.ai_providers(id),
  model text,
  tokens integer not null default 0,
  detail jsonb not null default '{}'::jsonb,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  foreign key (run_id, organization_id) references nomad_core.ai_runs(id, organization_id) on delete cascade
);
create index ai_run_steps_run_idx on nomad_core.ai_run_steps (run_id, id);
create index ai_run_steps_org_idx on nomad_core.ai_run_steps (organization_id);

-- 사용량: 게이트웨이가 호출마다 1행. 비용은 원본 단위(cost_usd_micros) + 원 단위 정수(cost_krw, 환산은 앱).
-- 과금: 시작 때 예상 크레딧 선차감(consume_credits, 멱등 키) → 실사용 기록 → settled_at이 빈 행을 정산 잡이 처리.
create table nomad_core.ai_usage (
  id bigint generated always as identity primary key,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  product_code text references nomad_core.products(code),
  provider text not null,
  model text not null,
  kind text not null default 'llm' check (kind in ('llm', 'embedding', 'stt', 'tts', 'image')),
  source text check (source is null or source in ('commercial', 'open_source')),
  feature text,
  purpose text,
  input_tokens integer not null default 0 check (input_tokens >= 0),
  output_tokens integer not null default 0 check (output_tokens >= 0),
  audio_seconds numeric(10, 2) check (audio_seconds >= 0),
  characters integer check (characters >= 0),
  cost_usd_micros bigint not null default 0 check (cost_usd_micros >= 0),
  cost_krw integer not null default 0 check (cost_krw >= 0),
  credits integer not null default 0,
  credit_ledger_id uuid references nomad_core.credit_ledger(id),
  run_id uuid,
  conversation_id uuid,
  latency_ms integer,
  status text not null default 'ok' check (status in ('ok', 'error', 'fallback')),
  error_code text,
  request_id text,
  settled_at timestamptz,
  created_at timestamptz not null default now()
);
create index ai_usage_org_created_idx on nomad_core.ai_usage (organization_id, created_at desc);
create index ai_usage_unsettled_idx on nomad_core.ai_usage (created_at) where settled_at is null;
create index ai_usage_run_idx on nomad_core.ai_usage (run_id) where run_id is not null;
create index ai_usage_conversation_idx on nomad_core.ai_usage (conversation_id) where conversation_id is not null;
-- 게이트웨이 재시도로 같은 요청이 두 번 기록되지 않게(멱등). request_id 없는 행은 제약 밖.
create unique index ai_usage_request_uniq on nomad_core.ai_usage (organization_id, request_id) where request_id is not null;

comment on table nomad_core.ai_providers is 'AI 제공자 목록(상용/오픈소스, 국외 이전 여부). 서버 전용.';
comment on table nomad_core.ai_model_prices is '제공자·모델별 크레딧 단가. 서버 전용, 수치는 운영자가 넣는다.';
comment on table nomad_core.ai_routing_settings is 'AI 라우팅(플랫폼·제품·조직 범위별 모드와 대체 체인). 서버 전용, 조직 변경은 set_ai_routing.';
comment on table nomad_core.ai_org_settings is '조직 AI 설정(국외 이전 동의). 서버 전용, set_ai_cross_border_ack로만 바꾼다.';
comment on table nomad_core.ai_collections is 'RAG·위키 임베딩 컬렉션(vector 1024). 서버 전용.';
comment on table nomad_core.ai_documents is 'RAG 원본 문서 메타데이터. 서버 전용.';
comment on table nomad_core.ai_chunks is 'RAG 청크와 임베딩. 서버 전용, 검색은 match_ai_chunks로만.';
comment on table nomad_core.wiki_pages is '제품 지식 위키 페이지. 서버 전용, 개인정보 삭제는 purge_wiki_page.';
comment on table nomad_core.wiki_links is '위키 페이지 간 링크(같은 조직만). 서버 전용.';
comment on table nomad_core.wiki_revisions is '위키 수정 이력(추가 전용). 서버 전용.';
comment on table nomad_core.ai_conversations is '플랫폼 대화 id ↔ Dify 대화 매핑. 서버 전용.';
comment on table nomad_core.ai_messages is '대화 메시지와 토큰·크레딧. 서버 전용.';
comment on table nomad_core.ai_runs is 'LangGraph 실행 기록. 서버 전용.';
comment on table nomad_core.ai_run_steps is 'LangGraph 실행 단계 기록. 서버 전용.';
comment on table nomad_core.ai_usage is 'AI 호출 사용량(원본 단위 비용 + cost_krw 원 정수). 서버 전용.';

-- ── 5. updated_at · 위키 이력 불변 ─────────────────────────
do $$
declare t text;
begin
  foreach t in array array['ai_providers', 'ai_model_prices', 'ai_routing_settings', 'ai_org_settings', 'ai_collections',
                           'ai_documents', 'wiki_pages', 'ai_conversations', 'ai_runs'] loop
    execute format('create trigger %1$s_touch_updated_at before update on nomad_core.%1$s '
                   'for each row execute function nomad_core.touch_updated_at()', t);
  end loop;
end $$;

-- 위키 이력은 수정·삭제 불가. 예외: 외래키 연쇄 삭제(트리거 깊이 2 이상) — 조직 삭제, purge_wiki_page의 페이지 삭제.
-- 직접 UPDATE·DELETE는 service_role 포함 모두 거부. wiki_pages DELETE 권한은 service_role에도 주지 않아(7장)
-- 페이지 실삭제 경로는 purge_wiki_page와 조직 삭제뿐이다. 평소 삭제는 status='archived'.
create function nomad_core.wiki_revisions_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;
  raise exception 'wiki_revisions is append-only (%)', tg_op using errcode = '42501';
end;
$$;
create trigger wiki_revisions_immutable before update or delete on nomad_core.wiki_revisions
  for each row execute function nomad_core.wiki_revisions_immutable();

-- ── 6. 함수(전부 서버 전용) ───────────────────────────────
-- 체인 정규화(내부용): 존재·활성·종류가 맞는 제공자만, 강제 시 오픈소스만, 국외 동의가 없으면 국외 제공자 제외.
create function nomad_core.ai_filter_chain(p_chain jsonb, p_kind text, p_force boolean, p_cross_border_ok boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(e.item order by e.ord), '[]'::jsonb)
  from jsonb_array_elements(coalesce(p_chain, '[]'::jsonb)) with ordinality as e(item, ord)
  join nomad_core.ai_providers p on p.id = e.item ->> 'provider'
  where p.is_active
    and p_kind = any (p.kinds)
    and (not p_force or p.source = 'open_source')
    and (p_cross_border_ok or not p.cross_border);
$$;

-- 벡터 검색: 조직·제품 필터를 항상 강제한다. 컬렉션을 주면 그 조직·제품 소유인지 확인한다.
-- HNSW + 조직 필터에서 결과가 k보다 적게 나오는 문제를 줄이려고 반복 스캔을 켠다(pgvector 0.8 이상).
create function nomad_core.match_ai_chunks(
  p_organization uuid,
  p_product text,
  p_embedding extensions.vector,
  p_k integer default 8,
  p_collection uuid default null,
  p_min_similarity real default 0
)
returns table (chunk_id bigint, document_id uuid, collection_id uuid, content text, metadata jsonb, similarity real)
language plpgsql
stable
security definer
set search_path = ''
set hnsw.ef_search = 100
set hnsw.iterative_scan = relaxed_order
as $$
begin
  if not nomad_core.is_service_caller() then
    raise exception 'match_ai_chunks: service_role only' using errcode = '42501';
  end if;
  if p_organization is null or p_product is null then
    raise exception 'match_ai_chunks: organization and product are required' using errcode = '22023';
  end if;
  if p_k is null or p_k < 1 or p_k > 50 then
    raise exception 'match_ai_chunks: k must be 1..50' using errcode = '22023';
  end if;
  if p_embedding is null or p_min_similarity is null then
    raise exception 'match_ai_chunks: embedding and min_similarity are required' using errcode = '22023';
  end if;
  if p_collection is not null and not exists (
    select 1 from nomad_core.ai_collections c
    where c.id = p_collection and c.organization_id = p_organization and c.product_code = p_product
  ) then
    raise exception 'match_ai_chunks: collection not in organization/product' using errcode = '42501';
  end if;
  return query
    select ch.id, ch.document_id, ch.collection_id, ch.content, ch.metadata,
           (1 - (ch.embedding operator(extensions.<=>) p_embedding))::real as similarity
    from nomad_core.ai_chunks ch
    join nomad_core.ai_documents d on d.id = ch.document_id and d.organization_id = ch.organization_id and d.status = 'ready'
    where ch.organization_id = p_organization
      and ch.product_code = p_product
      and (p_collection is null or ch.collection_id = p_collection)
      and (1 - (ch.embedding operator(extensions.<=>) p_embedding)) >= p_min_similarity
    order by ch.embedding operator(extensions.<=>) p_embedding
    limit p_k;
end;
$$;

-- 유효 라우팅 계산.
--   1) 가장 구체적인 설정(조직 > 플랫폼, 제품 > 전체, 기능 > '*')의 모드와 체인을 고른다.
--   2) 범위 안의 어떤 행이라도 force_open_source면 오픈소스로 강제하고 체인에서 상용 제공자를 뺀다.
--   3) 조직이 국외 이전에 동의하지 않았으면 국외 제공자를 뺀다.
--      고른 행의 mode가 open_source여도 같은 규칙으로 상용 제공자를 뺀다.
--   4) 걸러진 체인이 비면 플랫폼 기본 체인(조직·제품 null, '*')을 같은 규칙으로 거르고, 그래도 비면 활성 오픈소스 제공자 전부.
--   5) 반환 mode는 실제 체인과 맞춘다: 강제이거나 체인에 상용 제공자가 하나도 없으면 open_source, 아니면 고른 행의 mode.
create function nomad_core.resolve_ai_route(p_organization uuid, p_product text, p_feature text, p_kind text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_feature text := lower(btrim(coalesce(p_feature, '*')));
  v_row nomad_core.ai_routing_settings;
  v_force boolean;
  v_ack boolean;
  v_chain jsonb;
  v_default jsonb;
  v_default_mode text;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'resolve_ai_route: service_role only' using errcode = '42501';
  end if;
  select * into v_row
  from nomad_core.ai_routing_settings s
  where s.kind = p_kind
    and (s.organization_id = p_organization or s.organization_id is null)
    and (s.product_code = p_product or s.product_code is null)
    and (s.feature = v_feature or s.feature = '*')
  order by (s.organization_id is not null) desc, (s.product_code is not null) desc, (s.feature <> '*') desc
  limit 1;

  select coalesce(bool_or(s.force_open_source), false) into v_force
  from nomad_core.ai_routing_settings s
  where s.kind = p_kind
    and (s.organization_id = p_organization or s.organization_id is null)
    and (s.product_code = p_product or s.product_code is null)
    and (s.feature = v_feature or s.feature = '*');

  select exists (select 1 from nomad_core.ai_org_settings o
                 where o.organization_id = p_organization and o.cross_border_ack_at is not null)
    into v_ack;

  v_chain := nomad_core.ai_filter_chain(v_row.chain, p_kind, v_force or coalesce(v_row.mode = 'open_source', false), v_ack);
  if jsonb_array_length(v_chain) = 0 then
    select s.chain, s.mode into v_default, v_default_mode from nomad_core.ai_routing_settings s
    where s.organization_id is null and s.product_code is null and s.feature = '*' and s.kind = p_kind;
    v_chain := nomad_core.ai_filter_chain(v_default, p_kind, v_force or coalesce(v_default_mode = 'open_source', false), v_ack);
    if jsonb_array_length(v_chain) = 0 then
      select coalesce(jsonb_agg(jsonb_build_object('provider', p.id, 'model', '*') order by p.id), '[]'::jsonb) into v_chain
      from nomad_core.ai_providers p
      where p.is_active and p_kind = any (p.kinds) and p.source = 'open_source';
    end if;
  end if;

  return jsonb_build_object(
    'mode', case when v_force or not exists (
                   select 1 from jsonb_array_elements(v_chain) e(item)
                   join nomad_core.ai_providers p on p.id = e.item ->> 'provider'
                   where p.source = 'commercial')
                 then 'open_source' else coalesce(v_row.mode, 'auto') end,
    'chain', v_chain,
    'force_open_source', v_force,
    'cross_border_ack', v_ack,
    'setting_id', v_row.id
  );
end;
$$;

-- 조직 라우팅 변경(서버 전용 — 제품 이용권 확인은 서버가 먼저 한다).
--   - p_actor: 요청한 사용자(서버 호출은 auth.uid()가 null이라 인자로 받는다). 주면 그 조직 owner·admin이어야 하고
--     updated_by와 감사 metadata.actor_id에 남는다. null이면 시스템 변경.
--   - 기능 키는 소문자·공백 제거로 정규화
--   - 체인 제공자는 존재·활성·종류 일치, open_source 모드·강제는 오픈소스 제공자만
--   - 국외 제공자를 넣으려면 조직의 국외 이전 동의가 먼저 있어야 한다(AI002)
--   - 플랫폼이 강제한 오픈소스 범위는 풀 수 없다(AI001)
create function nomad_core.set_ai_routing(
  p_organization uuid, p_product text, p_feature text, p_kind text, p_mode text,
  p_chain jsonb default '[]'::jsonb, p_force_open_source boolean default false, p_actor uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_feature text := lower(btrim(coalesce(p_feature, '*')));
  v_chain jsonb := coalesce(p_chain, '[]'::jsonb);
  v_force boolean := coalesce(p_force_open_source, false);
  v_platform_force boolean;
  v_bad integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'set_ai_routing: service_role only' using errcode = '42501';
  end if;
  if p_organization is null or p_product is null or v_feature = '' then
    raise exception 'set_ai_routing: organization, product and feature are required' using errcode = '22023';
  end if;
  if p_actor is not null and not exists (
    select 1 from nomad_core.memberships m
    where m.organization_id = p_organization and m.user_id = p_actor and m.role in ('owner', 'admin')
  ) then
    raise exception 'set_ai_routing: actor must be owner/admin' using errcode = '42501';
  end if;
  if p_mode is null or p_kind is null
     or p_mode not in ('commercial', 'open_source', 'auto') or p_kind not in ('llm', 'embedding', 'stt', 'tts') then
    raise exception 'set_ai_routing: invalid mode or kind' using errcode = '22023';
  end if;
  if jsonb_typeof(v_chain) <> 'array' then
    raise exception 'set_ai_routing: chain must be an array' using errcode = '22023';
  end if;
  select count(*) into v_bad
  from jsonb_array_elements(v_chain) e(item)
  left join nomad_core.ai_providers p on p.id = e.item ->> 'provider'
  where p.id is null or not p.is_active or not (p_kind = any (p.kinds))
     or ((p_mode = 'open_source' or v_force) and p.source <> 'open_source');
  if v_bad > 0 then
    raise exception 'set_ai_routing: chain has unknown, inactive, wrong-kind or non-open-source providers' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_chain) e(item)
    join nomad_core.ai_providers p on p.id = e.item ->> 'provider'
    where p.cross_border
  ) and not exists (
    select 1 from nomad_core.ai_org_settings o where o.organization_id = p_organization and o.cross_border_ack_at is not null
  ) then
    raise exception 'set_ai_routing: cross-border consent required' using errcode = 'AI002';
  end if;
  select coalesce(bool_or(s.force_open_source), false) into v_platform_force
  from nomad_core.ai_routing_settings s
  where s.organization_id is null and s.kind = p_kind
    and (s.product_code = p_product or s.product_code is null)
    and (s.feature = v_feature or s.feature = '*');
  if v_platform_force and (p_mode <> 'open_source' or not v_force) then
    raise exception 'set_ai_routing: platform requires open_source for this scope' using errcode = 'AI001';
  end if;
  insert into nomad_core.ai_routing_settings (organization_id, product_code, feature, kind, mode, chain, force_open_source, updated_by)
  values (p_organization, p_product, v_feature, p_kind, p_mode, v_chain, v_force, coalesce(p_actor, auth.uid()))
  on conflict on constraint ai_routing_settings_scope_uniq
  do update set mode = excluded.mode, chain = excluded.chain,
                force_open_source = excluded.force_open_source, updated_by = excluded.updated_by
  returning id into v_id;
  perform nomad_core.write_audit(p_organization, 'ai.routing.set', 'ai_routing_setting', v_id::text, null,
                                 jsonb_build_object('product', p_product, 'feature', v_feature, 'kind', p_kind,
                                                    'mode', p_mode, 'force_open_source', v_force),
                                 jsonb_build_object('actor_id', coalesce(p_actor, auth.uid())));
  return v_id;
end;
$$;

-- 국외 이전 동의 기록·철회(서버 전용). 철회하면 라우터는 국외 제공자를 즉시 뺀다.
--   p_actor: 동의한 사용자. 주면 그 조직 owner·admin이어야 하고 ack_by·감사 metadata.actor_id에 남는다.
create function nomad_core.set_ai_cross_border_ack(p_organization uuid, p_ack boolean, p_notice_version text default null,
                                                   p_actor uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not nomad_core.is_service_caller() then
    raise exception 'set_ai_cross_border_ack: service_role only' using errcode = '42501';
  end if;
  if p_organization is null or p_ack is null then
    raise exception 'set_ai_cross_border_ack: organization and ack are required' using errcode = '22023';
  end if;
  if p_ack and coalesce(btrim(p_notice_version), '') = '' then
    raise exception 'set_ai_cross_border_ack: notice version required' using errcode = '22023';
  end if;
  if p_actor is not null and not exists (
    select 1 from nomad_core.memberships m
    where m.organization_id = p_organization and m.user_id = p_actor and m.role in ('owner', 'admin')
  ) then
    raise exception 'set_ai_cross_border_ack: actor must be owner/admin' using errcode = '42501';
  end if;
  insert into nomad_core.ai_org_settings (organization_id, cross_border_ack_at, cross_border_notice, ack_by)
  values (p_organization, case when p_ack then now() end, case when p_ack then p_notice_version end, coalesce(p_actor, auth.uid()))
  on conflict (organization_id) do update
    set cross_border_ack_at = excluded.cross_border_ack_at,
        cross_border_notice = excluded.cross_border_notice,
        ack_by = excluded.ack_by;
  perform nomad_core.write_audit(p_organization, case when p_ack then 'ai.cross_border.ack' else 'ai.cross_border.revoke' end,
                                 'organization', p_organization::text, null, jsonb_build_object('notice', p_notice_version),
                                 jsonb_build_object('actor_id', coalesce(p_actor, auth.uid())));
end;
$$;

-- 위키 페이지 개인정보 삭제: 페이지·링크·이력, 그 페이지에서 만든 source_type='wiki' 문서(wiki_page_id)와 청크를
-- 외래키 연쇄로 함께 지운다. 평소 삭제는 status='archived'. 다른 조직의 페이지 id면 거부한다.
-- 다른 문서(업로드 원본 등)나 다른 페이지 본문에 남은 개인정보는 서버가 따로 찾아 지운다.
create function nomad_core.purge_wiki_page(p_organization uuid, p_page uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_org uuid;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'purge_wiki_page: service_role only' using errcode = '42501';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'purge_wiki_page: reason required' using errcode = '22023';
  end if;
  if p_organization is null or p_page is null then
    raise exception 'purge_wiki_page: organization and page are required' using errcode = '22023';
  end if;
  select organization_id into v_org from nomad_core.wiki_pages where id = p_page;
  if v_org is null then
    return;
  end if;
  if v_org <> p_organization then
    raise exception 'purge_wiki_page: page not in organization' using errcode = '42501';
  end if;
  delete from nomad_core.wiki_pages where id = p_page;
  perform nomad_core.write_audit(v_org, 'ai.wiki.purge', 'wiki_page', p_page::text, null, jsonb_build_object('reason', p_reason));
end;
$$;

-- ── 7. 권한 · RLS: 사용자 정책 0개(= authenticated·anon 접근 0), service_role만 ─────
do $$
declare t text;
begin
  foreach t in array array['ai_providers', 'ai_model_prices', 'ai_routing_settings', 'ai_org_settings', 'ai_collections',
                           'ai_documents', 'ai_chunks', 'wiki_pages', 'wiki_links', 'wiki_revisions', 'ai_conversations',
                           'ai_messages', 'ai_runs', 'ai_run_steps', 'ai_usage'] loop
    execute format('alter table nomad_core.%I enable row level security', t);
    execute format('revoke all on nomad_core.%I from public, anon, authenticated', t);
    execute format('grant select, insert, update, delete on nomad_core.%I to service_role', t);
  end loop;
end $$;
-- 위키 페이지 실삭제는 purge_wiki_page(소유자 권한)와 조직 삭제 연쇄로만. 이력은 추가 전용.
revoke delete on nomad_core.wiki_pages from service_role;
revoke update, delete on nomad_core.wiki_revisions from service_role;

revoke execute on function
  nomad_core.wiki_revisions_immutable(),
  nomad_core.ai_filter_chain(jsonb, text, boolean, boolean),
  nomad_core.match_ai_chunks(uuid, text, extensions.vector, integer, uuid, real),
  nomad_core.resolve_ai_route(uuid, text, text, text),
  nomad_core.set_ai_routing(uuid, text, text, text, text, jsonb, boolean, uuid),
  nomad_core.set_ai_cross_border_ack(uuid, boolean, text, uuid),
  nomad_core.purge_wiki_page(uuid, uuid, text)
from public, anon, authenticated;
grant execute on function
  nomad_core.ai_filter_chain(jsonb, text, boolean, boolean),
  nomad_core.match_ai_chunks(uuid, text, extensions.vector, integer, uuid, real),
  nomad_core.resolve_ai_route(uuid, text, text, text),
  nomad_core.set_ai_routing(uuid, text, text, text, text, jsonb, boolean, uuid),
  nomad_core.set_ai_cross_border_ack(uuid, boolean, text, uuid),
  nomad_core.purge_wiki_page(uuid, uuid, text)
to service_role;

-- ── 8. 제공자 목록 시드(단가 없음). 원본 seed.sql 그대로 ─────────
insert into nomad_core.ai_providers (id, name, source, kinds, cross_border, notes) values
  ('anthropic',  'Anthropic Claude',          'commercial',  array['llm'],        true,  '국외 이전 고지 대상'),
  ('openai',     'OpenAI ChatGPT',            'commercial',  array['llm'],        true,  '국외 이전 고지 대상'),
  ('google',     'Google Gemini',             'commercial',  array['llm'],        true,  '국외 이전 고지 대상'),
  ('openrouter', 'OpenRouter',                'commercial',  array['llm'],        true,  '대체 경로. 국외 이전 고지 대상'),
  ('oss-llm',    '오픈소스 LLM 서버(vLLM)',     'open_source', array['llm'],        false, '공용 GPU 서버. 상업 이용 가능 라이선스 모델만 등록'),
  ('voyage',     'Voyage AI',                 'commercial',  array['embedding'],  true,  '국외 이전 고지 대상'),
  ('oss-embed',  '오픈소스 임베딩(TEI bge-m3)', 'open_source', array['embedding'],  false, '기본·민감 데이터 컬렉션용(1024차원)'),
  ('elevenlabs', 'ElevenLabs',                'commercial',  array['stt', 'tts'], true,  '서버에서만 호출. 국외 이전 고지 대상'),
  ('oss-voice',  '오픈소스 음성 서버',           'open_source', array['stt', 'tts'], false, 'faster-whisper + 상업 이용 가능 TTS')
on conflict (id) do nothing;

commit;
