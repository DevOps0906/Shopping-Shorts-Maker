-- 코어 웨이브 0단계: 감사 로그(추가 전용) + write_audit + 원본(core.*) 헬퍼 대응 함수.
-- 이후 웨이브(credits·jobs·ai 등)는 아래 헬퍼와 write_audit만 쓴다.
-- 되돌림: drop function public.nomad_audit_log(uuid, integer, bigint), nomad_core.write_audit(uuid, text, text, text, jsonb, jsonb, jsonb),
--   nomad_core.is_service_caller(), nomad_core.is_privileged_session(), nomad_core.jwt_role(), nomad_core.audit_log_immutable();
--   drop table nomad_core.audit_log;
begin;

-- 원본 core.jwt_role 대응: JWT role 클레임, 없으면 'none'.
create function nomad_core.jwt_role()
returns text
language sql stable set search_path = ''
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
    'none'
  )
$$;

-- 원본 core.is_privileged_session 대응: service_role JWT, 또는 JWT 없는 DB 관리 세션.
-- current_user가 아니라 session_user 기준이다: SECURITY DEFINER 함수 안에서는 current_user가 소유자(postgres)로
-- 바뀌지만 session_user는 접속 계정(API 경유면 authenticator) 그대로라, definer 안에서 불러도 호출자 기준으로 판별된다.
-- 관리 세션이라도 사용자 JWT(authenticated·anon)를 실은 경우는 특권으로 보지 않는다.
create function nomad_core.is_privileged_session()
returns boolean
language sql stable set search_path = ''
as $$
  select nomad_core.jwt_role() = 'service_role'
      or (nomad_core.jwt_role() = 'none' and session_user in ('postgres', 'supabase_admin', 'supabase_auth_admin'))
$$;

-- 원본 core.is_service_caller 대응: service_role JWT, 또는 JWT 없는 관리 세션.
-- auth.uid() null(= anon 포함)만으로는 서버로 보지 않는다. session_user는 SECURITY DEFINER 안에서도 안 바뀐다.
create function nomad_core.is_service_caller()
returns boolean
language sql stable set search_path = ''
as $$
  select nomad_core.jwt_role() = 'service_role'
      or (nomad_core.jwt_role() = 'none' and session_user in ('postgres', 'supabase_admin', 'supabase_auth_admin'))
$$;

-- 불리언만 돌려주는 판별 함수라 authenticated 실행을 허용한다(RLS·트리거 안에서 호출).
revoke execute on function nomad_core.jwt_role(), nomad_core.is_privileged_session(), nomad_core.is_service_caller()
  from public, anon;
grant execute on function nomad_core.jwt_role(), nomad_core.is_privileged_session(), nomad_core.is_service_caller()
  to authenticated, service_role;

create table nomad_core.audit_log (
  id bigint generated always as identity primary key,
  organization_id uuid,
  actor_id uuid,
  actor_role text not null default 'user' check (actor_role in ('user', 'service', 'system')),
  action text not null check (length(action) between 1 and 120),
  target_type text,
  target_id text,
  before jsonb,
  after jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index audit_log_org_created_idx on nomad_core.audit_log (organization_id, created_at desc);
create index audit_log_actor_idx on nomad_core.audit_log (actor_id, created_at desc);
create index audit_log_target_idx on nomad_core.audit_log (target_type, target_id);
comment on table nomad_core.audit_log is
  '감사 로그(추가 전용). 쓰기는 write_audit(서버)만, 읽기는 owner·admin이 public.nomad_audit_log RPC로만. 정책 없음 = 직접 접근 거부. 조직 삭제 후에도 남도록 FK 없음.';

alter table nomad_core.audit_log enable row level security;
revoke all on nomad_core.audit_log from public, anon, authenticated;
grant select, insert on nomad_core.audit_log to service_role;

create function nomad_core.audit_log_immutable()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  raise exception 'nomad_core.audit_log is append-only (%)', tg_op using errcode = '42501';
end;
$$;
revoke execute on function nomad_core.audit_log_immutable() from public, anon, authenticated;
create trigger audit_log_immutable before update or delete on nomad_core.audit_log
  for each row execute function nomad_core.audit_log_immutable();
create trigger audit_log_immutable_truncate before truncate on nomad_core.audit_log
  for each statement execute function nomad_core.audit_log_immutable();

-- 감사 기록을 남기는 유일한 경로(서버 전용). 사용자 RPC는 SECURITY DEFINER 안에서 호출한다.
-- actor는 항상 auth.uid()로 강제한다(인자로 받지 않음).
create function nomad_core.write_audit(
  p_organization uuid,
  p_action text,
  p_target_type text default null,
  p_target_id text default null,
  p_before jsonb default null,
  p_after jsonb default null,
  p_metadata jsonb default '{}'::jsonb
)
returns bigint
language plpgsql security definer set search_path = ''
as $$
declare v_id bigint;
begin
  -- 실행 권한은 service_role·소유자만 있으므로, 로그인 사용자는 소유자의 SECURITY DEFINER RPC를 거쳐서만 여기 온다
  -- (그때 jwt_role='authenticated'라 is_service_caller는 false). 그래서 서버 호출이거나 auth.uid()가 있으면 허용한다.
  -- current_user는 definer 안에서 늘 소유자라 판별에 쓰지 않는다.
  if not (nomad_core.is_service_caller() or auth.uid() is not null) then
    raise exception 'write_audit: server only' using errcode = '42501';
  end if;
  insert into nomad_core.audit_log (organization_id, actor_id, actor_role, action, target_type, target_id, before, after, metadata)
  values (p_organization, auth.uid(),
          case when nomad_core.jwt_role() = 'service_role' then 'service'
               when auth.uid() is null then 'system' else 'user' end,
          p_action, p_target_type, p_target_id, p_before, p_after, coalesce(p_metadata, '{}'::jsonb))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function nomad_core.write_audit(uuid, text, text, text, jsonb, jsonb, jsonb) from public, anon, authenticated;
grant execute on function nomad_core.write_audit(uuid, text, text, text, jsonb, jsonb, jsonb) to service_role;

-- owner·admin이 자기 조직 기록만 최신순으로 읽는다(페이지: before_id 미만, 최대 200건).
create function public.nomad_audit_log(target_organization uuid, page_size integer default 50, before_id bigint default null)
returns table (id bigint, actor_id uuid, actor_role text, action text, target_type text, target_id text,
               before jsonb, after jsonb, metadata jsonb, created_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if coalesce(nomad_core.organization_role(target_organization), '') not in ('owner', 'admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
    select a.id, a.actor_id, a.actor_role, a.action, a.target_type, a.target_id, a.before, a.after, a.metadata, a.created_at
    from nomad_core.audit_log a
    where a.organization_id = target_organization and (before_id is null or a.id < before_id)
    order by a.id desc
    limit least(greatest(coalesce(page_size, 50), 1), 200);
end;
$$;
revoke execute on function public.nomad_audit_log(uuid, integer, bigint) from public, anon, authenticated;
grant execute on function public.nomad_audit_log(uuid, integer, bigint) to authenticated;

commit;
