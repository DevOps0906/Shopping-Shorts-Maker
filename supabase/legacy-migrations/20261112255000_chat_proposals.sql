-- task-021 보안 리뷰 반영: 제작 파트너 사전 확인을 서버가 만든 제안에 묶는다 + 탐색 회차 원자 검사.
-- 1) chat_proposals: 도구가 "확인 필요"를 낼 때 서버(service_role)만 제안을 저장하고, 화면에는 proposal id만 준다.
--    사용자는 표에 직접 접근할 수 없다(RLS 정책 없음 + 권한 회수). 확인은 chat_consume_proposal 로 원자적 1회 소비.
--    소비 조건: 본인(auth.uid()) · 미소비 · 만료 전(10분). 소비 뒤 args 해시와 입력 버전(step_status 스냅샷)을 다시 맞춰 보고,
--    다르면 소비된 채로 error 를 돌려준다(같은 제안을 다시 쓸 수 없다).
-- 2) chat_start_collect: 탐색 회차(최대 3) 검사와 collect 작업 생성을 프로젝트 행 잠금(FOR UPDATE) 안에서 한 번에 한다.
--    같은 멱등 키 재요청은 회차 검사 없이 기존 작업을 돌려준다(private.create_job).

-- ── 1) 제안 표 ─────────────────────────────────────────────
create table public.chat_proposals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  project_id uuid not null references public.projects (id) on delete cascade,
  tool text not null check (tool in ('search_topics', 'search_sources', 'draft_script', 'synthesize_voice', 'replace_cut', 'render_mp4')),
  args jsonb not null check (jsonb_typeof(args) = 'object' and length(args::text) <= 2000),
  args_hash text not null,
  input_version jsonb not null,
  expires_at timestamptz not null default now() + interval '10 minutes',
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);
comment on table public.chat_proposals is '제작 파트너 사전 확인 제안(서버 전용). 사용자는 chat_consume_proposal 로만 1회 소비';
create index chat_proposals_project_id_idx on public.chat_proposals (project_id);
create index chat_proposals_user_id_idx on public.chat_proposals (user_id);

alter table public.chat_proposals enable row level security;
revoke all on public.chat_proposals from public, anon, authenticated;
-- 사용자 직접 접근 없음(권한도 회수). 정책은 의도를 남기는 전면 거부만 둔다. service_role 은 RLS 를 우회한다.
create policy chat_proposals_no_client on public.chat_proposals
  for all to authenticated using (false) with check (false);

-- 제안 생성: service_role 전용. 서버가 세션으로 소유권을 확인한 뒤 user_id 를 넘긴다. 여기서도 소유자를 다시 맞춘다.
create function private.chat_create_proposal(p_user_id uuid, p_project_id uuid, p_tool text, p_args jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status jsonb;
  v_id uuid;
begin
  select step_status into v_status from public.projects where id = p_project_id and user_id = p_user_id;
  if not found then
    raise exception '프로젝트를 찾을 수 없거나 권한이 없습니다' using errcode = '42501';
  end if;
  insert into public.chat_proposals (user_id, project_id, tool, args, args_hash, input_version)
  values (p_user_id, p_project_id, p_tool, coalesce(p_args, '{}'::jsonb), md5(coalesce(p_args, '{}'::jsonb)::text), v_status)
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function private.chat_create_proposal(uuid, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function private.chat_create_proposal(uuid, uuid, text, jsonb) to service_role;

create function public.chat_create_proposal(p_user_id uuid, p_project_id uuid, p_tool text, p_args jsonb)
returns uuid
language sql
security invoker
set search_path = ''
as $$
  select private.chat_create_proposal(p_user_id, p_project_id, p_tool, p_args);
$$;
revoke execute on function public.chat_create_proposal(uuid, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.chat_create_proposal(uuid, uuid, text, jsonb) to service_role;

-- 제안 소비: 사용자 세션. 반환 {project_id, tool, args} 또는 {error: 'invalid' | 'stale'}
create function private.chat_consume_proposal(p_proposal_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.chat_proposals;
  v_status jsonb;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  update public.chat_proposals
  set consumed_at = now()
  where id = p_proposal_id and user_id = v_uid and consumed_at is null and expires_at > now()
  returning * into v_row;
  if not found then
    return jsonb_build_object('error', 'invalid');
  end if;
  select step_status into v_status from public.projects where id = v_row.project_id and user_id = v_uid;
  if not found or v_status is distinct from v_row.input_version or md5(v_row.args::text) <> v_row.args_hash then
    return jsonb_build_object('error', 'stale');
  end if;
  return jsonb_build_object('project_id', v_row.project_id, 'tool', v_row.tool, 'args', v_row.args);
end;
$$;
revoke execute on function private.chat_consume_proposal(uuid) from public, anon, authenticated;
grant execute on function private.chat_consume_proposal(uuid) to authenticated;

create function public.chat_consume_proposal(p_proposal_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.chat_consume_proposal(p_proposal_id);
$$;
revoke execute on function public.chat_consume_proposal(uuid) from public, anon;
grant execute on function public.chat_consume_proposal(uuid) to authenticated;

-- ── 2) 탐색 회차 + collect 작업 생성(원자) ─────────────────
create function private.chat_start_collect(p_project_id uuid, p_platform text, p_query text, p_idempotency_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_rounds integer;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  if p_platform is null or p_platform not in ('tiktok', 'xiaohongshu') then
    raise exception '플랫폼이 올바르지 않습니다' using errcode = '22023';
  end if;
  if p_idempotency_key is null or length(p_idempotency_key) not between 8 and 200 then
    raise exception '멱등 키가 올바르지 않습니다' using errcode = '22023';
  end if;
  -- 같은 프로젝트의 회차 검사·생성을 직렬화
  perform 1 from public.projects where id = p_project_id and user_id = v_uid for update;
  if not found then
    raise exception '프로젝트를 찾을 수 없거나 권한이 없습니다' using errcode = '42501';
  end if;
  select count(*) into v_rounds
  from public.jobs
  where project_id = p_project_id and type = 'collect'
    and status in ('queued', 'waiting_extension', 'running', 'succeeded');
  if v_rounds >= 3
     and not exists (select 1 from public.jobs where idempotency_key = v_uid::text || ':' || p_idempotency_key) then
    raise exception '탐색 회차를 모두 썼습니다' using errcode = 'CR003';
  end if;
  return private.create_job(p_project_id, 'collect', p_idempotency_key,
    jsonb_build_object('platform', p_platform, 'round', v_rounds + 1, 'query', left(coalesce(p_query, ''), 80)));
end;
$$;
revoke execute on function private.chat_start_collect(uuid, text, text, text) from public, anon, authenticated;
grant execute on function private.chat_start_collect(uuid, text, text, text) to authenticated;

create function public.chat_start_collect(p_project_id uuid, p_platform text, p_query text, p_idempotency_key text)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.chat_start_collect(p_project_id, p_platform, p_query, p_idempotency_key);
$$;
comment on function public.chat_start_collect(uuid, text, text, text) is
  '제작 파트너 소스 검색: 탐색 회차(최대 3, CR003) 검사와 collect 작업 생성을 프로젝트 행 잠금 안에서 한 번에';
revoke execute on function public.chat_start_collect(uuid, text, text, text) from public, anon;
grant execute on function public.chat_start_collect(uuid, text, text, text) to authenticated;
