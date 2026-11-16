-- 조직별 외부 API 키(BYOK) 보관: 원문은 vault.secrets, 메타(last4 등)만 provider_credentials.
-- 되돌림: drop function public.nomad_*_provider_credential*, public.nomad_org_provider_secret, nomad_core.*_provider_credential*, nomad_core.org_provider_secret; drop table nomad_core.provider_credentials, nomad_core.api_providers;
begin;

alter default privileges in schema nomad_core revoke execute on functions from public;

create table nomad_core.api_providers (
  code text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  name text not null
);
insert into nomad_core.api_providers (code, name) values
  ('youtube_data', 'YouTube Data API'),
  ('openai', 'OpenAI'),
  ('anthropic', 'Anthropic'),
  ('google_gemini', 'Google Gemini');

create table nomad_core.provider_credentials (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id),
  provider_code text not null references nomad_core.api_providers(code),
  label text not null check (label = trim(label) and char_length(label) between 1 and 60),
  secret_id uuid not null,
  last4 text not null check (char_length(last4) <= 4),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz
);
-- 같은 조직·제공자·label의 활성 키는 하나(교체 시 이전 키 삭제).
create unique index provider_credentials_active_label
  on nomad_core.provider_credentials(organization_id, provider_code, label) where revoked_at is null;
create index provider_credentials_by_organization on nomad_core.provider_credentials(organization_id);

create trigger provider_credentials_touch_updated_at
  before update on nomad_core.provider_credentials
  for each row execute function nomad_core.touch_updated_at();

comment on table nomad_core.api_providers is '외부 API 제공자 카탈로그(서버 전용).';
comment on table nomad_core.provider_credentials is '조직별 API 키 메타(원문은 vault.secrets). 서버 전용, set/list/revoke 함수로만 다룬다.';

alter table nomad_core.api_providers enable row level security;
alter table nomad_core.provider_credentials enable row level security;
revoke all on nomad_core.api_providers, nomad_core.provider_credentials from public, anon, authenticated;
grant select, insert, update, delete on nomad_core.api_providers, nomad_core.provider_credentials to service_role;

-- ── 등록·교체: owner·admin. vault 이름 nomad:<org>:<provider>:<label>:<credential id> ──
create function nomad_core.set_provider_credential(
  target_organization uuid, target_provider text, credential_label text, secret_value text
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  new_id uuid := gen_random_uuid();
  new_secret uuid;
  old record;
  lbl text := trim(credential_label);
begin
  if coalesce(nomad_core.organization_role(target_organization), '') not in ('owner', 'admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if secret_value is null or char_length(secret_value) < 20 or char_length(secret_value) > 4096 then
    raise exception 'invalid secret';
  end if;
  if lbl is null or lbl = '' or char_length(lbl) > 60 then raise exception 'invalid label'; end if;
  if not exists (select 1 from nomad_core.api_providers where code = target_provider) then
    raise exception 'unknown provider';
  end if;

  -- 같은 키 이름 동시 교체를 직렬화한다.
  perform pg_advisory_xact_lock(hashtextextended(target_organization::text || ':' || target_provider || ':' || lbl, 0));

  for old in
    select c.id, c.secret_id from nomad_core.provider_credentials c
    where c.organization_id = target_organization and c.provider_code = target_provider
      and c.label = lbl and c.revoked_at is null
    for update
  loop
    delete from vault.secrets where id = old.secret_id;
    update nomad_core.provider_credentials set revoked_at = now() where id = old.id;
  end loop;

  new_secret := vault.create_secret(
    secret_value,
    'nomad:' || target_organization || ':' || target_provider || ':' || lbl || ':' || new_id,
    'nomad provider credential'
  );
  insert into nomad_core.provider_credentials
    (id, organization_id, provider_code, label, secret_id, last4, created_by)
  values (new_id, target_organization, target_provider, lbl, new_secret,
          case when char_length(secret_value) >= 16 then right(secret_value, 4) else '' end, (select auth.uid()));
  return new_id;
end;
$$;

-- ── 목록: 멤버(원문·secret_id 없음) ──
create function nomad_core.list_provider_credentials(target_organization uuid)
returns table (
  id uuid, provider_code text, label text, last4 text,
  created_at timestamptz, last_used_at timestamptz
)
language sql stable security definer set search_path = ''
as $$
  select c.id, c.provider_code, c.label, c.last4, c.created_at, c.last_used_at
  from nomad_core.provider_credentials c
  where c.organization_id = target_organization and c.revoked_at is null
    and nomad_core.organization_role(target_organization) is not null
  order by c.provider_code, c.label
$$;

-- ── 폐기: owner·admin. vault 행 삭제 ──
create function nomad_core.revoke_provider_credential(credential_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare c nomad_core.provider_credentials;
begin
  select * into c from nomad_core.provider_credentials
  where id = credential_id and revoked_at is null for update;
  if not found
     or coalesce(nomad_core.organization_role(c.organization_id), '') not in ('owner', 'admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  delete from vault.secrets where id = c.secret_id;
  update nomad_core.provider_credentials set revoked_at = now() where id = c.id;
end;
$$;

-- ── 복호화: service_role 전용(Edge Function). 호출 때 last_used_at 갱신. 없으면 null ──
create function nomad_core.org_provider_secret(
  target_organization uuid, target_provider text, credential_label text default 'default'
)
returns text
language plpgsql security definer set search_path = ''
as $$
declare c nomad_core.provider_credentials; plain text;
begin
  select * into c from nomad_core.provider_credentials pc
  where pc.organization_id = target_organization and pc.provider_code = target_provider
    and pc.label = credential_label and pc.revoked_at is null
    and exists (select 1 from nomad_core.organizations o where o.id = pc.organization_id and o.active);
  if not found then return null; end if;
  select ds.decrypted_secret into plain from vault.decrypted_secrets ds where ds.id = c.secret_id;
  if plain is null then return null; end if;
  update nomad_core.provider_credentials set last_used_at = now() where id = c.id;
  return plain;
end;
$$;

revoke all on function
  nomad_core.set_provider_credential(uuid, text, text, text),
  nomad_core.list_provider_credentials(uuid),
  nomad_core.revoke_provider_credential(uuid),
  nomad_core.org_provider_secret(uuid, text, text)
from public, anon, authenticated;
grant execute on function
  nomad_core.set_provider_credential(uuid, text, text, text),
  nomad_core.list_provider_credentials(uuid),
  nomad_core.revoke_provider_credential(uuid)
to authenticated;
grant execute on function nomad_core.org_provider_secret(uuid, text, text) to service_role;

-- ── public invoker 래퍼(Data API) ──
create function public.nomad_set_provider_credential(
  target_organization uuid, target_provider text, credential_label text, secret_value text
)
returns uuid
language sql security invoker set search_path = ''
as $$ select nomad_core.set_provider_credential(target_organization, target_provider, credential_label, secret_value) $$;

create function public.nomad_list_provider_credentials(target_organization uuid)
returns table (
  id uuid, provider_code text, label text, last4 text,
  created_at timestamptz, last_used_at timestamptz
)
language sql stable security invoker set search_path = ''
as $$ select * from nomad_core.list_provider_credentials(target_organization) $$;

create function public.nomad_revoke_provider_credential(credential_id uuid)
returns void
language sql security invoker set search_path = ''
as $$ select nomad_core.revoke_provider_credential(credential_id) $$;

create function public.nomad_org_provider_secret(
  target_organization uuid, target_provider text, credential_label text default 'default'
)
returns text
language sql security invoker set search_path = ''
as $$ select nomad_core.org_provider_secret(target_organization, target_provider, credential_label) $$;

revoke all on function
  public.nomad_set_provider_credential(uuid, text, text, text),
  public.nomad_list_provider_credentials(uuid),
  public.nomad_revoke_provider_credential(uuid),
  public.nomad_org_provider_secret(uuid, text, text)
from public, anon, authenticated;
grant execute on function
  public.nomad_set_provider_credential(uuid, text, text, text),
  public.nomad_list_provider_credentials(uuid),
  public.nomad_revoke_provider_credential(uuid)
to authenticated;
grant execute on function public.nomad_org_provider_secret(uuid, text, text) to service_role;

commit;
