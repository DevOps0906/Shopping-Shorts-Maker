-- products/shorts/org/0001_shorts.sql — Shopping-Shorts-Maker DB 이식(org안)
-- 근거: task-012, docs/design/04-products/survey-shopping-shorts-maker.md, products/shorts/existing.md
-- 원본 마이그레이션 51개의 최종 상태(public → nomad_shorts, private → nomad_shorts_private)를 옮겼다.
-- 자체 user_profiles·가입 트리거(handle_new_user)는 만들지 않는다(nomad_core.profiles 대체).
-- 전제: nomad_core 적용됨, nomad_core.touch_updated_at() 존재(core 20261119000100). 확장 pgmq·pg_cron·pg_net·vault 사용 가능.
begin;
set local check_function_bodies = false;

create extension if not exists pgmq;
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- 워커 전용 역할(로그인 비밀번호는 여기서 설정하지 않는다)
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'worker_role') then
    create role worker_role nologin nobypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'worker_login') then
    create role worker_login login inherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
  end if;
end
$$;
grant worker_role to worker_login;

create schema nomad_shorts;
create schema nomad_shorts_private;
revoke all on schema nomad_shorts_private from public, anon, authenticated;
alter default privileges in schema nomad_shorts_private revoke execute on functions from public;

-- Name: accounts_default_slot_guard(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.accounts_default_slot_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if new.is_default is distinct from old.is_default
     and old.external_channel_id is not null and old.disconnected_at is null
     and current_user not in ('postgres', 'service_role', 'supabase_admin')
     and nomad_shorts_private.channel_over_limit_self(old.organization_id) then
    raise exception '요금제 채널 수를 넘은 동안에는 기본 채널을 바꿀 수 없습니다' using errcode = 'CS006';
  end if;
  return new;
end;
$$;

-- Name: accounts_force_server_columns(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.accounts_force_server_columns() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if current_user not in ('postgres', 'service_role', 'supabase_admin') then
    new.oauth_token_ref := null;
    new.status := 'reconnect_required';
    new.external_channel_id := null;
    new.first_connected_at := null;
    new.disconnected_at := null;
  end if;
  return new;
end;
$$;

-- Name: add_direct_source(uuid, text, text, text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.add_direct_source(p_project_id uuid, p_url text, p_author text, p_title text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  v_url text := btrim(coalesce(p_url, ''));
  v_author text := btrim(coalesce(p_author, ''));
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
  v_authority text;
  v_host text;
  v_platform text;
  v_id uuid;
begin
  perform nomad_shorts_private.lock_source_step(p_project_id);
  if char_length(v_url) > 2000 or v_url !~* '^https?://[^\s/?#]+[^\s]*$' or nomad_shorts_private.has_unsafe_chars(v_url) then
    raise exception 'http(s) URL을 입력해 주세요' using errcode = '22023';
  end if;
  -- authority 에 userinfo(@)가 있으면 거부(https://www.tiktok.com@evil.example/ 같은 위장)
  v_authority := substring(v_url from '^[A-Za-z]+://([^/?#]*)');
  v_host := lower(regexp_replace(v_authority, ':[0-9]*$', ''));
  if v_authority like '%@%' or v_host !~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$' then
    raise exception 'URL 주소 형식이 올바르지 않습니다' using errcode = '22023';
  end if;
  if char_length(v_author) not between 1 and 100 or nomad_shorts_private.has_unsafe_chars(v_author) then
    raise exception '작성자를 확인해 주세요' using errcode = '22023';
  end if;
  if v_title is not null and (char_length(v_title) > 200 or nomad_shorts_private.has_unsafe_chars(v_title)) then
    raise exception '제목을 확인해 주세요' using errcode = '22023';
  end if;
  if (select count(*) from nomad_shorts.sources where project_id = p_project_id) >= 100 then
    raise exception '원본은 프로젝트당 100편까지 추가할 수 있습니다' using errcode = '22023';
  end if;
  if exists (select 1 from nomad_shorts.sources where project_id = p_project_id and url = v_url) then
    raise exception '이미 추가한 URL입니다' using errcode = '23505';
  end if;

  v_platform := case
    when v_host ~ '(^|\.)tiktok\.com$' then 'tiktok'
    when v_host ~ '(^|\.)(xiaohongshu\.com|xhslink\.com)$' then 'xiaohongshu'
    else 'direct'
  end;

  insert into nomad_shorts.sources (project_id, platform, url, author, title, collected_at)
  values (p_project_id, v_platform, v_url, v_author, v_title, now())
  returning id into v_id;
  return v_id;
end;
$_$;

-- Name: affiliate_links_invalidate(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.affiliate_links_invalidate() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  perform nomad_shorts_private.publish_invalidate(coalesce(new.project_id, old.project_id));
  if tg_op = 'UPDATE' and new.project_id is distinct from old.project_id then
    perform nomad_shorts_private.publish_invalidate(old.project_id);
  end if;
  return null;
end;
$$;

-- Name: analyze_job_project(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.analyze_job_project(p_job_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_project uuid;
begin
  select project_id into v_project
  from nomad_shorts.jobs
  where id = p_job_id and type = 'select_sources' and status = 'running';
  if v_project is null then
    raise exception '실행 중인 원본 선정 작업이 아닙니다' using errcode = '55000';
  end if;
  return v_project;
end;
$$;

-- Name: analyze_sources_context(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.analyze_sources_context(p_job_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_project uuid := nomad_shorts_private.analyze_job_project(p_job_id);
  v_user uuid;
  v_sources jsonb;
begin
  select organization_id into v_user from nomad_shorts.projects where id = v_project;
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'file_path', s.file_path)
                            order by s.collected_at, s.id), '[]'::jsonb)
    into v_sources
  from nomad_shorts.sources s
  where s.project_id = v_project and s.file_deleted_at is null;
  return jsonb_build_object('project_id', v_project, 'organization_id', v_user, 'sources', v_sources);
end;
$$;

-- Name: approve_step(uuid, integer); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.approve_step(p_project_id uuid, p_step integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_uid uuid := auth.uid();
  v_status jsonb;
  v_script_id uuid;
  v_lines jsonb;
  v_banned text;
  v_problem text;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  if p_step is null or p_step not between 1 and 5 then
    raise exception '승인할 수 없는 단계입니다: %', p_step using errcode = '22023';
  end if;

  select step_status into v_status
  from nomad_shorts.projects
  where id = p_project_id and nomad_core.organization_role(organization_id) IN ('owner', 'admin', 'editor')
  for update;
  if not found then
    raise exception '프로젝트를 찾을 수 없거나 권한이 없습니다' using errcode = '42501';
  end if;

  if exists (select 1 from generate_series(1, p_step - 1) as g(n)
             where v_status ->> g.n::text <> 'approved') then
    raise exception '앞 단계가 승인되지 않았습니다' using errcode = '55000';
  end if;
  if v_status ->> p_step::text <> 'ready' then
    raise exception '준비 완료(ready) 상태에서만 승인할 수 있습니다: %', v_status ->> p_step::text
      using errcode = '55000';
  end if;

  -- 02 소스 승인 = 사용 편수·부족 사유·고지 확인(3장 02, D7·D8)
  if p_step = 2 then
    v_problem := nomad_shorts_private.source_approval_problem(p_project_id);
    if v_problem = 'too_few' then
      raise exception '권리를 확인한 사용 원본이 3편 미만이라 승인할 수 없습니다' using errcode = '55000';
    elsif v_problem = 'reason_required' then
      raise exception '사용 원본이 5편 미만이면 부족 사유가 있어야 승인할 수 있습니다' using errcode = '55000';
    elsif v_problem = 'notice_required' then
      raise exception '출처 표기 고지를 확인해야 승인할 수 있습니다' using errcode = '55000';
    end if;
  end if;

  -- 03 대본 승인 = 최신 대본 버전 금지 표현 재검사 후 approved_at 기록
  if p_step = 3 then
    select id, lines into v_script_id, v_lines
    from nomad_shorts.scripts
    where project_id = p_project_id
    order by version desc
    limit 1;
    if v_script_id is null then
      raise exception '승인할 대본이 없습니다' using errcode = '55000';
    end if;
    v_banned := nomad_shorts_private.find_banned_term(p_project_id, v_lines);
    if v_banned is not null then
      raise exception '대본에 금지 표현이 있어 승인할 수 없습니다: %', v_banned using errcode = 'BT001';
    end if;
    update nomad_shorts.scripts set approved_at = now() where id = v_script_id;
  end if;

  -- 04 목소리 승인 = 쓸 수 있는 음성 테이크 1개 이상
  if p_step = 4 and not nomad_shorts_private.has_voice_output(p_project_id) then
    raise exception '음성 테이크가 없어 승인할 수 없습니다' using errcode = '55000';
  end if;

  -- 05 편집 승인 = 최신 버전 렌더가 성공 결과
  if p_step = 5 and not nomad_shorts_private.has_render_output(p_project_id) then
    raise exception '완성된 최신 렌더가 없어 승인할 수 없습니다' using errcode = '55000';
  end if;

  update nomad_shorts.projects
  set step_status = jsonb_set(step_status, array[p_step::text], '"approved"'::jsonb),
      current_step = p_step + 1
  where id = p_project_id
  returning step_status into v_status;

  insert into nomad_shorts.project_events (project_id, step, event)
  values (p_project_id, p_step, 'step_approved');

  return v_status;
end;
$$;

-- Name: assign_bio_number(uuid, text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.assign_bio_number(p_project_id uuid, p_service text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_account uuid;
  v_name text;
  v_link nomad_shorts.affiliate_links;
  v_page uuid;
  v_item uuid;
  v_item_account uuid;
  v_no integer;
begin
  perform nomad_shorts_private.publish_owned(p_project_id, true);
  if p_service is null or p_service not in ('inpock', 'litly', 'linktree', 'none') then
    raise exception '링크인바이오 서비스가 올바르지 않습니다' using errcode = '22023';
  end if;
  select * into v_link from nomad_shorts.affiliate_links where project_id = p_project_id;

  if p_service = 'none' then
    -- 서비스만 해제. 번호는 은퇴하지 않고 프로젝트에 남는다(다시 고르면 같은 번호)
    if v_link.id is not null then
      update nomad_shorts.affiliate_links set bio_service = null, bio_registered_at = null where id = v_link.id;
    end if;
    update nomad_shorts.bio_items set registered_at = null where project_id = p_project_id;
    insert into nomad_shorts.policy_checks (project_id, item, checked_by, checked_at)
    values (p_project_id, 'purchase_path', null, null)
    on conflict (project_id, item) do update set checked_by = null, checked_at = null;
    perform nomad_shorts_private.publish_invalidate(p_project_id);
    return v_link.bio_no;
  end if;

  if v_link.id is null or not nomad_shorts_private.publish_is_link_program(v_link.program) then
    raise exception '링크형 제휴 프로그램을 먼저 골라 주세요' using errcode = '55000';
  end if;

  select account_id, name into v_account, v_name from nomad_shorts.projects where id = p_project_id;
  -- 같은 채널의 번호 발급을 한 줄로 세운다
  perform 1 from nomad_shorts.accounts where id = v_account for update;

  insert into nomad_shorts.bio_pages (account_id, service) values (v_account, p_service)
  on conflict (account_id) do update set service = excluded.service
  returning id into v_page;

  select bi.id, bi.no, bp.account_id into v_item, v_no, v_item_account
  from nomad_shorts.bio_items bi
  join nomad_shorts.bio_pages bp on bp.id = bi.bio_page_id
  where bi.project_id = p_project_id;
  if v_item is not null and v_item_account is distinct from v_account then
    -- 프로젝트 채널이 바뀌었다: 옛 채널 번호는 은퇴(행은 남기고 프로젝트 연결만 해제)
    update nomad_shorts.bio_items set project_id = null where id = v_item;
    v_no := null;
  end if;

  if v_no is null then
    update nomad_shorts.accounts set last_bio_no = last_bio_no + 1 where id = v_account
    returning last_bio_no into v_no;
    insert into nomad_shorts.bio_items (bio_page_id, project_id, no, affiliate_link_id, short_url, title)
    values (v_page, p_project_id, v_no, v_link.id, v_link.short_url, v_name);
  end if;

  if v_link.bio_no is distinct from v_no then
    -- 번호가 바뀌면 이전 등록 완료는 무효
    update nomad_shorts.affiliate_links set bio_service = p_service, bio_no = v_no, bio_registered_at = null where id = v_link.id;
    update nomad_shorts.bio_items set registered_at = null where project_id = p_project_id;
    insert into nomad_shorts.policy_checks (project_id, item, checked_by, checked_at)
    values (p_project_id, 'purchase_path', null, null)
    on conflict (project_id, item) do update set checked_by = null, checked_at = null;
  else
    update nomad_shorts.affiliate_links set bio_service = p_service where id = v_link.id;
  end if;
  return v_no;
end;
$$;

-- Name: call_collect_metrics(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.call_collect_metrics() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_url text;
  v_key text;
begin
  select d.decrypted_secret into v_url from vault.decrypted_secrets d where d.name = 'internal_metrics_url';
  select d.decrypted_secret into v_key from vault.decrypted_secrets d where d.name = 'internal_metrics_key';
  if nullif(v_url, '') is null or nullif(v_key, '') is null then
    insert into nomad_shorts_private.metrics_runs (finished_at, error) values (now(), 'not_configured');
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

-- Name: channel_is_excess(uuid, uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.channel_is_excess(p_organization_id uuid, p_account_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select coalesce((
    select r.rn > nomad_shorts_private.channel_limit_of(p_organization_id)
    from (select a.id,
                 row_number() over (order by a.is_default desc, a.first_connected_at asc nulls last, a.id) as rn
          from nomad_shorts.accounts a
          where a.organization_id = p_organization_id and a.platform in ('youtube', 'instagram', 'tiktok')
            and a.external_channel_id is not null and a.disconnected_at is null) r
    where r.id = p_account_id), false);
$$;

-- Name: channel_limit_of(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.channel_limit_of(p_organization_id uuid) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select coalesce((select q.channel_limit from nomad_shorts_private.channel_quotas q where q.organization_id = p_organization_id), 1);
$$;

-- Name: channel_over_limit_self(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.channel_over_limit_self(p_organization_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select p_organization_id is not null and nomad_core.organization_role(p_organization_id) is not null
         and nomad_shorts_private.channel_slot_count(p_organization_id) > nomad_shorts_private.channel_limit_of(p_organization_id);
$$;

-- Name: channel_slot_count(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.channel_slot_count(p_organization_id uuid) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select count(*)::int from nomad_shorts.accounts a
  where a.organization_id = p_organization_id and a.platform in ('youtube', 'instagram', 'tiktok')
    and a.external_channel_id is not null and a.disconnected_at is null;
$$;

-- Name: channel_slot_log(uuid, uuid, text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.channel_slot_log(p_organization_id uuid, p_account_id uuid, p_kind text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  insert into nomad_shorts.channel_slot_events (organization_id, account_id, kind, slots, channel_limit)
  values (p_organization_id, p_account_id, p_kind, nomad_shorts_private.channel_slot_count(p_organization_id), nomad_shorts_private.channel_limit_of(p_organization_id));
$$;

-- Name: channel_slot_status(uuid, uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.channel_slot_status(p_organization_id uuid, p_account_id uuid DEFAULT NULL::uuid) RETURNS TABLE(slots integer, channel_limit integer, recent_new integer, allowed boolean, code text, next_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_acc nomad_shorts.accounts;
  v_holding boolean := false;
  v_first boolean := true;
  v_slots integer;
  v_limit integer;
  v_recent integer;
  v_code text;
  v_next timestamptz;
begin
  if p_organization_id is null then
    raise exception '연결할 수 없는 계정입니다' using errcode = '42501';
  end if;
  if p_account_id is not null then
    select a.* into v_acc from nomad_shorts.accounts a
    where a.id = p_account_id and a.organization_id = p_organization_id and a.platform = 'youtube';
    if v_acc.id is null then
      raise exception '연결할 수 없는 계정입니다' using errcode = '42501';
    end if;
    v_holding := v_acc.external_channel_id is not null and v_acc.disconnected_at is null;
    v_first := v_acc.first_connected_at is null;
  end if;
  v_slots := nomad_shorts_private.channel_slot_count(p_organization_id);
  v_limit := nomad_shorts_private.channel_limit_of(p_organization_id);
  select count(*)::int into v_recent from nomad_shorts.accounts a
  where a.organization_id = p_organization_id and a.platform in ('youtube', 'instagram', 'tiktok')
    and a.first_connected_at > now() - interval '30 days';

  if not v_holding then
    if v_slots >= v_limit then
      v_code := 'CS001';
    elsif v_first and v_recent >= 3 then
      v_code := 'CS002';
      -- 30일 창에서 3개 미만이 되는 시각 = (v_recent - 2)번째로 오래된 연결 + 30일
      select f.first_connected_at + interval '30 days' into v_next
      from nomad_shorts.accounts f
      where f.organization_id = p_organization_id and f.platform in ('youtube', 'instagram', 'tiktok')
        and f.first_connected_at > now() - interval '30 days'
      order by f.first_connected_at asc
      offset v_recent - 3 limit 1;
    end if;
  end if;
  return query select v_slots, v_limit, v_recent, v_code is null, v_code, v_next;
end;
$$;

-- Name: chat_consume_proposal(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.chat_consume_proposal(p_proposal_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_uid uuid := auth.uid();
  v_row nomad_shorts.chat_proposals;
  v_status jsonb;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  update nomad_shorts.chat_proposals
  set consumed_at = now()
  where id = p_proposal_id and nomad_core.organization_role(organization_id) IN ('owner', 'admin', 'editor') and consumed_at is null and expires_at > now()
  returning * into v_row;
  if not found then
    return jsonb_build_object('error', 'invalid');
  end if;
  select step_status into v_status from nomad_shorts.projects where id = v_row.project_id and nomad_core.organization_role(organization_id) IN ('owner', 'admin', 'editor');
  if not found or v_status is distinct from v_row.input_version or md5(v_row.args::text) <> v_row.args_hash then
    return jsonb_build_object('error', 'stale');
  end if;
  return jsonb_build_object('project_id', v_row.project_id, 'tool', v_row.tool, 'args', v_row.args);
end;
$$;

-- Name: chat_create_proposal(uuid, uuid, text, jsonb); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.chat_create_proposal(p_organization_id uuid, p_project_id uuid, p_tool text, p_args jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_status jsonb;
  v_id uuid;
begin
  select step_status into v_status from nomad_shorts.projects where id = p_project_id and organization_id = p_organization_id;
  if not found then
    raise exception '프로젝트를 찾을 수 없거나 권한이 없습니다' using errcode = '42501';
  end if;
  insert into nomad_shorts.chat_proposals (organization_id, project_id, tool, args, args_hash, input_version)
  values (p_organization_id, p_project_id, p_tool, coalesce(p_args, '{}'::jsonb), md5(coalesce(p_args, '{}'::jsonb)::text), v_status)
  returning id into v_id;
  return v_id;
end;
$$;

-- Name: chat_start_collect(uuid, text, text, text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.chat_start_collect(p_project_id uuid, p_platform text, p_query text, p_idempotency_key text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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
  perform 1 from nomad_shorts.projects where id = p_project_id and nomad_core.organization_role(organization_id) IN ('owner', 'admin', 'editor') for update;
  if not found then
    raise exception '프로젝트를 찾을 수 없거나 권한이 없습니다' using errcode = '42501';
  end if;
  select count(*) into v_rounds
  from nomad_shorts.jobs
  where project_id = p_project_id and type = 'collect'
    and status in ('queued', 'waiting_extension', 'running', 'succeeded');
  if v_rounds >= 3
     and not exists (select 1 from nomad_shorts.jobs where idempotency_key = v_uid::text || ':' || p_idempotency_key) then
    raise exception '탐색 회차를 모두 썼습니다' using errcode = 'CR003';
  end if;
  return nomad_shorts_private.create_job(p_project_id, 'collect', p_idempotency_key,
    jsonb_build_object('platform', p_platform, 'round', v_rounds + 1, 'query', left(coalesce(p_query, ''), 80)));
end;
$$;

-- Name: cleanup_analytics(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.cleanup_analytics() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  update nomad_shorts.link_clicks set visitor_hash = null
  where visitor_hash is not null and clicked_at < now() - interval '1 day';
  delete from nomad_shorts.link_clicks where clicked_at < now() - interval '90 days';
  delete from nomad_shorts_private.click_salts where day < (now() at time zone 'utc')::date;
  delete from nomad_shorts_private.metrics_runs where started_at < now() - interval '30 days';
end;
$$;

-- Name: confirm_policy_check(uuid, text, boolean); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.confirm_policy_check(p_project_id uuid, p_item text, p_checked boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_link nomad_shorts.affiliate_links;
  v_ack timestamptz;
  v_account uuid;
  v_on boolean := coalesce(p_checked, false);
begin
  perform nomad_shorts_private.publish_owned(p_project_id, true);
  if p_item is null or p_item not in ('attribution_notice', 'purchase_path') then
    raise exception '사용자가 확인하는 항목이 아닙니다: %', p_item using errcode = '22023';
  end if;
  select sources_notice_ack_at, account_id into v_ack, v_account from nomad_shorts.projects where id = p_project_id;

  if v_on and p_item = 'attribution_notice' and v_ack is null then
    raise exception '02 소스의 출처 표기 고지를 먼저 확인해 주세요' using errcode = '55000';
  end if;

  if p_item = 'purchase_path' then
    select * into v_link from nomad_shorts.affiliate_links where project_id = p_project_id;
    if v_on and (v_link.id is null or not nomad_shorts_private.publish_is_link_program(v_link.program)
                 or v_link.url is null or v_link.bio_service is null or v_link.bio_no is null
                 or not exists (select 1 from nomad_shorts.bio_items bi
                                join nomad_shorts.bio_pages bp on bp.id = bi.bio_page_id
                                where bi.project_id = p_project_id and bi.no = v_link.bio_no
                                  and bp.account_id = v_account)) then
      raise exception '이 채널의 링크인바이오 번호를 받은 제휴 링크가 있어야 등록 완료를 켤 수 있습니다' using errcode = '55000';
    end if;
    if v_link.id is not null then
      update nomad_shorts.affiliate_links
      set bio_registered_at = case when v_on then coalesce(bio_registered_at, now()) end
      where id = v_link.id;
      update nomad_shorts.bio_items
      set registered_at = case when v_on then coalesce(registered_at, now()) end
      where project_id = p_project_id;
    end if;
  end if;

  insert into nomad_shorts.policy_checks (project_id, item, checked_by, checked_at)
  values (p_project_id, p_item, case when v_on then auth.uid() end, case when v_on then now() end)
  on conflict (project_id, item) do update
    set checked_by = excluded.checked_by, checked_at = excluded.checked_at;

  if not v_on then
    perform nomad_shorts_private.publish_invalidate(p_project_id);
  end if;
end;
$$;

-- Name: create_job(uuid, text, text, jsonb); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.create_job(p_project_id uuid, p_type text, p_idempotency_key text, p_payload jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_key text;
  v_step smallint := nomad_shorts_private.job_step(p_type);
  v_status jsonb;
  v_job nomad_shorts.jobs;
  v_cost integer;
  v_balance bigint;
  v_limit integer := nomad_shorts_private.job_queue_limit(p_type);
  v_active integer;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  if v_step is null then
    raise exception '알 수 없는 작업 종류입니다: %', p_type using errcode = '22023';
  end if;
  if p_idempotency_key is null or length(p_idempotency_key) not between 8 and 200 then
    raise exception '멱등 키가 올바르지 않습니다' using errcode = '22023';
  end if;
  v_key := v_uid::text || ':' || p_idempotency_key;

  select step_status, organization_id into v_status, v_org
  from nomad_shorts.projects
  where id = p_project_id and nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')
  for update;
  if not found then
    raise exception '프로젝트를 찾을 수 없거나 권한이 없습니다' using errcode = '42501';
  end if;

  -- 사용자 단위 잠금: 다른 프로젝트에서 같은 사용자의 잔액·대기 수 경쟁도 직렬화
  perform pg_advisory_xact_lock(hashtextextended('credit:' || v_org::text, 0));

  select j.* into v_job from nomad_shorts.jobs j where j.idempotency_key = v_key;
  if found then
    if v_job.project_id <> p_project_id or v_job.type <> p_type then
      raise exception '같은 멱등 키가 다른 작업에 이미 쓰였습니다' using errcode = 'JK001';
    end if;
    return to_jsonb(v_job) - 'payload' - 'idempotency_key' || jsonb_build_object('created', false);
  end if;

  if exists (select 1 from generate_series(1, v_step - 1) as g(n)
             where v_status ->> g.n::text is distinct from 'approved') then
    raise exception '앞 단계가 승인되지 않았습니다' using errcode = '55000';
  end if;
  if v_status ->> v_step::text = 'approved' then
    raise exception '이미 승인된 단계입니다. 변경 요청 후 다시 시도하세요' using errcode = '55000';
  end if;

  -- 대기 상한: 크레딧 예약 전에 거부(예약·잔액 변화 없음)
  if v_limit is not null then
    select count(*)::integer into v_active
    from nomad_shorts.jobs j
    join nomad_shorts.projects p on p.id = j.project_id
    where p.organization_id = v_org and j.type = p_type and j.status in ('queued', 'running');
    if v_active >= v_limit then
      raise exception '진행 중인 % 작업이 너무 많습니다. 끝난 뒤 다시 시도하세요', p_type
        using errcode = 'JQ001',
              detail = jsonb_build_object('type', p_type, 'limit', v_limit, 'active', v_active)::text;
    end if;
  end if;

  v_cost := nomad_shorts_private.job_cost(p_type);
  select coalesce(sum(delta), 0) into v_balance from nomad_shorts.credit_ledger where organization_id = v_org;
  if v_balance < v_cost then
    raise exception '크레딧이 부족합니다'
      using errcode = 'CR001',
            detail = jsonb_build_object('required', v_cost, 'balance', v_balance)::text;
  end if;

  insert into nomad_shorts.jobs (project_id, step, type, status, idempotency_key, payload)
  values (p_project_id, v_step, p_type,
          case when p_type = 'collect' then 'waiting_extension' else 'queued' end,
          v_key, coalesce(p_payload, '{}'::jsonb))
  returning * into v_job;

  insert into nomad_shorts.credit_ledger (organization_id, project_id, job_id, kind, delta, reason, idempotency_key)
  values (v_org, p_project_id, v_job.id, 'reserve', -v_cost, p_type, 'reserve:' || v_job.id);

  if p_type <> 'collect' then
    perform pgmq.send(nomad_shorts_private.job_queue(p_type), jsonb_build_object('job_id', v_job.id));
  end if;

  return to_jsonb(v_job) - 'payload' - 'idempotency_key' || jsonb_build_object('created', true);
end;
$$;

-- Name: ext_claim_job(uuid, uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.ext_claim_job(p_extension_id uuid, p_job_id uuid) RETURNS TABLE(id uuid, type text, payload jsonb)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
#variable_conflict use_column
declare
  v_job nomad_shorts.jobs;
begin
  -- 작업 행: 다른 claim·스위퍼·취소와 직렬화. 기다린 뒤 상태가 바뀌었으면 0행
  select j.* into v_job
  from nomad_shorts.jobs j
  where j.id = p_job_id
    and j.status = 'waiting_extension'
    and j.type in ('collect', 'collect_download')
  for update;
  if not found then
    return;
  end if;

  -- 확장 행: 폐기와 직렬화. 폐기됐거나 프로젝트 소유자의 확장이 아니면 0행
  perform 1
  from nomad_shorts.extension_connections e
  where e.id = p_extension_id
    and e.revoked_at is null
    and e.organization_id = (select p.organization_id from nomad_shorts.projects p where p.id = v_job.project_id)
  for update;
  if not found then
    return;
  end if;

  update nomad_shorts.jobs j
  set status = 'running', extension_id = p_extension_id, started_at = now(), error = null
  where j.id = p_job_id;
  -- claim 직후 스위퍼가 끊김으로 보지 않게 연결 시각도 갱신
  update nomad_shorts.extension_connections e
  set last_heartbeat_at = now()
  where e.id = p_extension_id;

  return query select v_job.id, v_job.type, v_job.payload;
end;
$$;

-- Name: ext_collect_download(uuid, uuid, jsonb); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.ext_collect_download(p_extension_id uuid, p_job_id uuid, p_files jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  v_job record := nomad_shorts_private.ext_job_project(p_extension_id, p_job_id, 'collect_download');
  v_prefix text;
  v_total integer;
  v_valid integer;
  v_updated integer;
begin
  v_prefix := v_job.organization_id::text || '/' || v_job.project_id::text || '/';
  if jsonb_typeof(p_files) is distinct from 'array' then
    raise exception '파일 목록은 배열이어야 합니다' using errcode = '22023';
  end if;
  if jsonb_array_length(p_files) not between 1 and 60 then
    raise exception '한 번에 1~60개까지 보낼 수 있습니다' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_files) e
             where jsonb_typeof(e) is distinct from 'object'
                or exists (select 1 from jsonb_object_keys(e) k where k not in ('id', 'file_path'))
                or jsonb_typeof(e -> 'id') is distinct from 'string'
                or jsonb_typeof(e -> 'file_path') is distinct from 'string') then
    raise exception '허용되지 않은 필드나 형식이 있습니다' using errcode = '22023';
  end if;

  -- 대상 원본 행 잠금(체크 해제·격리와 직렬화)
  perform 1
  from nomad_shorts.sources s
  where s.project_id = v_job.project_id
    and s.id::text in (select e->>'id' from jsonb_array_elements(p_files) e)
  order by s.id
  for update;

  select count(*),
         count(*) filter (where s.id is not null
                            and s.checked
                            and not s.quarantined
                            and s.file_deleted_at is null
                            and left(e->>'file_path', char_length(v_prefix)) = v_prefix
                            and substr(e->>'file_path', char_length(v_prefix) + 1)
                                ~ '^[A-Za-z0-9_-][A-Za-z0-9._-]{0,199}$')
    into v_total, v_valid
  from jsonb_array_elements(p_files) e
  left join nomad_shorts.sources s
    on s.project_id = v_job.project_id
   and s.id::text = e->>'id';
  if v_total <> v_valid
     or v_total <> (select count(distinct e->>'id') from jsonb_array_elements(p_files) e) then
    raise exception '기록할 수 없는 파일이 있습니다(체크하지 않은 원본이거나 경로가 다름)' using errcode = '22023';
  end if;

  -- 최종 갱신에도 작업·확장·원본 조건을 다시 건다
  update nomad_shorts.sources s
  set file_path = e->>'file_path'
  from jsonb_array_elements(p_files) e, nomad_shorts.jobs j, nomad_shorts.extension_connections x
  where s.project_id = v_job.project_id and s.id::text = e->>'id'
    and s.checked and not s.quarantined and s.file_deleted_at is null
    and j.id = p_job_id and j.type = 'collect_download' and j.status = 'running'
    and j.extension_id = p_extension_id
    and x.id = p_extension_id and x.revoked_at is null and x.organization_id = v_job.organization_id;
  get diagnostics v_updated = row_count;
  if v_updated <> v_total then
    raise exception '작업 상태가 바뀌어 기록하지 않았습니다' using errcode = '40001';
  end if;
  return v_updated;
end;
$_$;

-- Name: ext_collect_list(uuid, uuid, jsonb); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.ext_collect_list(p_extension_id uuid, p_job_id uuid, p_items jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  v_job record := nomad_shorts_private.ext_job_project(p_extension_id, p_job_id, 'collect');
  v_prefix text;
  v_item jsonb;
  v_norm record;
  v_author text;
  v_title text;
  v_thumb text;
  v_urls text[] := '{}';
  v_ids uuid[] := '{}';
  v_id uuid;
  v_n integer;
begin
  v_prefix := v_job.organization_id::text || '/' || v_job.project_id::text || '/';
  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception '목록은 배열이어야 합니다' using errcode = '22023';
  end if;
  v_n := jsonb_array_length(p_items);
  if v_n not between 1 and 60 then
    raise exception '한 번에 1~60편까지 보낼 수 있습니다' using errcode = '22023';
  end if;
  if (select count(*) from nomad_shorts.sources where project_id = v_job.project_id) + v_n > 100 then
    raise exception '원본은 프로젝트당 100편까지 모을 수 있습니다' using errcode = '22023';
  end if;

  for v_item in select e from jsonb_array_elements(p_items) e loop
    if jsonb_typeof(v_item) is distinct from 'object'
       or exists (select 1 from jsonb_object_keys(v_item) k
                  where k not in ('url', 'author', 'title', 'thumbnail_path', 'platform'))
       or jsonb_typeof(v_item -> 'url') is distinct from 'string'
       or jsonb_typeof(v_item -> 'author') is distinct from 'string'
       or coalesce(jsonb_typeof(v_item -> 'title'), 'null') not in ('string', 'null')
       or coalesce(jsonb_typeof(v_item -> 'thumbnail_path'), 'null') not in ('string', 'null')
       or coalesce(jsonb_typeof(v_item -> 'platform'), 'null') not in ('string', 'null') then
      raise exception '허용되지 않은 필드나 형식이 있습니다' using errcode = '22023';
    end if;

    v_norm := nomad_shorts_private.normalize_collect_url(v_item ->> 'url');
    if v_item ->> 'platform' is not null and v_item ->> 'platform' <> v_norm.platform then
      raise exception '플랫폼이 URL 호스트와 다릅니다' using errcode = '22023';
    end if;

    v_author := btrim(v_item ->> 'author');
    if char_length(v_author) not between 1 and 100 or nomad_shorts_private.has_unsafe_chars(v_author) then
      raise exception '작성자를 확인해 주세요' using errcode = '22023';
    end if;
    if v_norm.platform = 'tiktok' and lower(regexp_replace(v_author, '^@', '')) <> v_norm.handle then
      raise exception '작성자가 URL의 @계정과 다릅니다' using errcode = '22023';
    end if;

    v_title := nullif(btrim(coalesce(v_item ->> 'title', '')), '');
    if v_title is not null and (char_length(v_title) > 200 or nomad_shorts_private.has_unsafe_chars(v_title)) then
      raise exception '제목을 확인해 주세요' using errcode = '22023';
    end if;

    v_thumb := v_item ->> 'thumbnail_path';
    if v_thumb is not null
       and (left(v_thumb, char_length(v_prefix)) <> v_prefix
            or substr(v_thumb, char_length(v_prefix) + 1) !~ '^[A-Za-z0-9_-][A-Za-z0-9._-]{0,199}$') then
      raise exception '썸네일 경로가 이 프로젝트 경로가 아닙니다' using errcode = '22023';
    end if;

    if v_norm.url = any (v_urls)
       or exists (select 1 from nomad_shorts.sources where project_id = v_job.project_id and url = v_norm.url) then
      raise exception '이미 수집한 URL입니다' using errcode = '23505';
    end if;
    v_urls := v_urls || v_norm.url;

    insert into nomad_shorts.sources (project_id, platform, url, author, title, thumbnail_path, collected_at)
    values (v_job.project_id, v_norm.platform, v_norm.url, v_author, v_title, v_thumb, now())
    returning id into v_id;
    v_ids := v_ids || v_id;
  end loop;

  return jsonb_build_object('inserted', cardinality(v_ids), 'ids', to_jsonb(v_ids));
end;
$_$;

-- Name: ext_heartbeat(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.ext_heartbeat(p_extension_id uuid) RETURNS TABLE(id uuid, type text, payload jsonb)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
#variable_conflict use_column
declare
  v_user uuid;
begin
  update nomad_shorts.extension_connections e
  set last_heartbeat_at = now()
  where e.id = p_extension_id and e.revoked_at is null
  returning e.organization_id into v_user;
  if v_user is null then
    raise exception '확장 연결을 찾을 수 없거나 폐기됐습니다' using errcode = '42501';
  end if;

  return query
  select j.id, j.type, j.payload
  from nomad_shorts.jobs j
  join nomad_shorts.projects p on p.id = j.project_id
  where p.organization_id = v_user
    and j.status = 'waiting_extension'
    and j.type in ('collect', 'collect_download')
  order by coalesce(j.waiting_since, j.created_at), j.id
  limit 1;
end;
$$;

-- Name: ext_job_project(uuid, uuid, text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.ext_job_project(p_extension_id uuid, p_job_id uuid, p_type text, OUT project_id uuid, OUT organization_id uuid) RETURNS record
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_pid uuid;
  v_uid uuid;
begin
  select j.project_id into v_pid from nomad_shorts.jobs j where j.id = p_job_id;

  select p.organization_id into v_uid
  from nomad_shorts.projects p
  where p.id = v_pid
  for update;

  perform 1
  from nomad_shorts.jobs j
  where j.id = p_job_id and j.project_id = v_pid and j.type = p_type
    and j.status = 'running' and j.extension_id = p_extension_id
  for update;
  if not found then
    raise exception '실행 중인 수집 작업이 아니거나 권한이 없습니다' using errcode = '42501';
  end if;

  perform 1
  from nomad_shorts.extension_connections e
  where e.id = p_extension_id and e.revoked_at is null and e.organization_id = v_uid
  for update;
  if not found then
    raise exception '실행 중인 수집 작업이 아니거나 권한이 없습니다' using errcode = '42501';
  end if;

  project_id := v_pid;
  organization_id := v_uid;
end;
$$;

-- Name: find_banned_term(uuid, jsonb); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.find_banned_term(p_project_id uuid, p_lines jsonb) RETURNS text
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
  with body as (
    select nomad_shorts_private.normalize_for_ban(string_agg(l.line, '' order by l.ord)) as text
    from jsonb_array_elements_text(coalesce(p_lines, '[]'::jsonb)) with ordinality as l(line, ord)
  )
  select t.term
  from nomad_shorts.projects p
  join nomad_shorts.categories c on c.id = p.category_id
  cross join lateral unnest(c.banned_terms) as t(term)
  cross join body
  where p.id = p_project_id
    and nomad_shorts_private.normalize_for_ban(t.term) <> ''
    and strpos(body.text, nomad_shorts_private.normalize_for_ban(t.term)) > 0
  limit 1;
$$;

-- Name: has_render_output(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.has_render_output(p_project_id uuid) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
  select coalesce((
    select r.mp4_path is not null and r.duration_sec > 0
    from nomad_shorts.renders r
    where r.project_id = p_project_id
    order by r.version desc
    limit 1
  ), false);
$$;

-- Name: has_unsafe_chars(text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.has_unsafe_chars(p_text text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select coalesce(p_text, '') ~ '[[:cntrl:]‪-‮⁦-⁩]';
$$;

-- Name: has_voice_output(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.has_voice_output(p_project_id uuid) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
  select exists (
    select 1 from nomad_shorts.voice_takes t
    where t.project_id = p_project_id
      and t.audio_path is not null
      and t.duration_sec > 0
  );
$$;

-- Name: job_cost(text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.job_cost(p_type text) RETURNS integer
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select case p_type
    when 'render' then 30
    when 'tts' then 10
    when 'analyze' then 5
    when 'select_sources' then 5
    else 0
  end;
$$;

-- Name: job_fail(text, bigint, uuid, text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.job_fail(p_queue text, p_msg_id bigint, p_job_id uuid, p_error text) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_changed boolean;
begin
  update nomad_shorts.jobs
  set status = 'failed', finished_at = now(), error = left(p_error, 500)
  where id = p_job_id and status = 'running';
  v_changed := found;
  perform nomad_shorts_private.release_job(p_job_id);
  perform pgmq.archive(p_queue, p_msg_id);
  return v_changed;
end;
$$;

-- Name: job_heartbeat(text, bigint, uuid, integer); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.job_heartbeat(p_queue text, p_msg_id bigint, p_job_id uuid, p_vt_seconds integer) RETURNS text
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_status text;
begin
  select status into v_status from nomad_shorts.jobs where id = p_job_id;
  if v_status = 'running' then
    perform pgmq.set_vt(p_queue, p_msg_id, p_vt_seconds);
  end if;
  return v_status;
end;
$$;

-- Name: job_queue(text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.job_queue(p_type text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select case p_type
    when 'render' then 'shorts_render'
    when 'tts' then 'shorts_tts'
    when 'analyze' then 'shorts_analyze'
    when 'select_sources' then 'shorts_analyze'
    when 'collect' then null
    when 'collect_download' then null
  end;
$$;

-- Name: job_queue_limit(text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.job_queue_limit(p_type text) RETURNS integer
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select case p_type when 'render' then 3 when 'tts' then 5 when 'analyze' then 5 end;
$$;

-- Name: job_retry(text, bigint, uuid, text, integer); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.job_retry(p_queue text, p_msg_id bigint, p_job_id uuid, p_error text, p_delay_seconds integer) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  update nomad_shorts.jobs
  set status = 'queued', error = left(p_error, 500)
  where id = p_job_id and status = 'running';
  if not found then
    perform nomad_shorts_private.release_job(p_job_id);
    perform pgmq.archive(p_queue, p_msg_id);
    return false;
  end if;
  perform pgmq.set_vt(p_queue, p_msg_id, greatest(p_delay_seconds, 0));
  return true;
end;
$$;

-- Name: job_start(text, bigint, uuid, integer); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.job_start(p_queue text, p_msg_id bigint, p_job_id uuid, p_read_ct integer) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
declare
  v_status text;
  v_max integer;
  v_type text;
  v_step smallint;
  v_attempts integer;
  v_payload jsonb;
begin
  select status, max_attempts into v_status, v_max from nomad_shorts.jobs where id = p_job_id;
  if v_status is null or v_status not in ('queued', 'running') then
    perform nomad_shorts_private.release_job(p_job_id);
    perform pgmq.archive(p_queue, p_msg_id);
    return jsonb_build_object('action', 'stop', 'status', v_status);
  end if;

  if p_read_ct > v_max then
    update nomad_shorts.jobs
    set status = 'failed', finished_at = now(), error = '재시도 횟수를 넘었습니다'
    where id = p_job_id and status in ('queued', 'running');
    perform nomad_shorts_private.release_job(p_job_id);
    perform pgmq.archive(p_queue, p_msg_id);
    return jsonb_build_object('action', 'failed');
  end if;

  -- 같은 사용자의 같은 종류가 이미 실행 중이면 미룬다. running 인 자기 자신(죽은 워커 복구)은 미루지 않는다.
  -- 미룸은 시도가 아니다: attempts 는 그대로, pgmq.read 가 올린 read_ct 는 되돌린다.
  if v_status = 'queued' and nomad_shorts_private.job_user_busy(p_job_id, p_queue) then
    execute format(
      'update pgmq.%I set vt = clock_timestamp() + interval ''20 seconds'', read_ct = greatest(read_ct - 1, 0) where msg_id = $1',
      'q_' || p_queue) using p_msg_id;
    return jsonb_build_object('action', 'deferred', 'delay', 20);
  end if;

  -- 조건부 전이. running 인데 메시지가 다시 보이면 앞선 워커가 vt 연장 없이 죽은 것(ADR-0001)
  update nomad_shorts.jobs
  set status = 'running', attempts = attempts + 1, started_at = now(), error = null
  where id = p_job_id and status in ('queued', 'running')
  returning type, step, attempts, payload into v_type, v_step, v_attempts, v_payload;
  if not found then
    perform pgmq.archive(p_queue, p_msg_id);
    return jsonb_build_object('action', 'stop');
  end if;

  return jsonb_build_object('action', 'run', 'type', v_type, 'step', v_step,
                            'attempts', v_attempts, 'payload', v_payload);
end;
$_$;

-- Name: job_step(text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.job_step(p_type text) RETURNS smallint
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select case p_type
    when 'collect' then 2
    when 'collect_download' then 2
    when 'select_sources' then 2
    when 'analyze' then 3
    when 'tts' then 4
    when 'render' then 5
  end::smallint;
$$;

-- Name: job_stop(text, bigint, uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.job_stop(p_queue text, p_msg_id bigint, p_job_id uuid) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  perform nomad_shorts_private.release_job(p_job_id);
  perform pgmq.archive(p_queue, p_msg_id);
end;
$$;

-- Name: job_succeed(text, bigint, uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.job_succeed(p_queue text, p_msg_id bigint, p_job_id uuid) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_ok boolean;
begin
  v_ok := nomad_shorts_private.settle_job(p_job_id);
  if not v_ok then
    perform nomad_shorts_private.release_job(p_job_id);
  end if;
  perform pgmq.archive(p_queue, p_msg_id);
  return v_ok;
end;
$$;

-- Name: job_time_limit(text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.job_time_limit(p_type text) RETURNS interval
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select case p_type
    when 'tts' then interval '2 minutes'
    when 'render' then interval '10 minutes'
    when 'analyze' then interval '5 minutes'
    when 'select_sources' then interval '5 minutes'
    when 'collect' then interval '15 minutes'
    when 'collect_download' then interval '15 minutes'
  end;
$$;

-- Name: job_user_busy(uuid, text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.job_user_busy(p_job_id uuid, p_type text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_uid uuid;
begin
  select p.organization_id into v_uid
  from nomad_shorts.jobs j join nomad_shorts.projects p on p.id = j.project_id
  where j.id = p_job_id;
  if v_uid is null then
    return false;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('jobstart:' || v_uid::text || ':' || p_type, 0));
  return exists (
    select 1 from nomad_shorts.jobs j join nomad_shorts.projects p on p.id = j.project_id
    where nomad_core.organization_role(p.organization_id) IN ('owner', 'admin', 'editor') and j.type = p_type and j.status = 'running' and j.id <> p_job_id);
end;
$$;

-- Name: jobs_waiting_since(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.jobs_waiting_since() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if new.status = 'waiting_extension' and old.status is distinct from 'waiting_extension' then
    new.waiting_since := now();
  end if;
  return new;
end;
$$;

-- Name: lock_source_step(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.lock_source_step(p_project_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_uid uuid := auth.uid();
  v_status jsonb;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  select step_status into v_status
  from nomad_shorts.projects
  where id = p_project_id and nomad_core.organization_role(organization_id) IN ('owner', 'admin', 'editor')
  for update;
  if not found then
    raise exception '프로젝트를 찾을 수 없거나 권한이 없습니다' using errcode = '42501';
  end if;
  if v_status ->> '1' <> 'approved' then
    raise exception '01 소재가 승인되지 않았습니다' using errcode = '55000';
  end if;
  if v_status ->> '2' not in ('idle', 'change', 'suggested', 'ready') then
    raise exception '지금 상태(%)에서는 원본을 바꿀 수 없습니다', v_status ->> '2' using errcode = '55000';
  end if;
  return v_status;
end;
$$;

-- Name: mark_step_ready(uuid, integer, text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.mark_step_ready(p_project_id uuid, p_step integer, p_status text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_uid uuid := auth.uid();
  v_status jsonb;
  v_current text;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  if p_step is null or p_step not between 1 and 6 then
    raise exception '잘못된 단계입니다: %', p_step using errcode = '22023';
  end if;
  if p_status is null or p_status not in ('suggested', 'ready') then
    raise exception '바꿀 수 없는 상태입니다: %', p_status using errcode = '22023';
  end if;

  select step_status into v_status
  from nomad_shorts.projects
  where id = p_project_id and nomad_core.organization_role(organization_id) IN ('owner', 'admin', 'editor')
  for update;
  if not found then
    raise exception '프로젝트를 찾을 수 없거나 권한이 없습니다' using errcode = '42501';
  end if;

  if exists (select 1 from generate_series(1, p_step - 1) as g(n)
             where v_status ->> g.n::text <> 'approved') then
    raise exception '앞 단계가 승인되지 않았습니다' using errcode = '55000';
  end if;

  v_current := v_status ->> p_step::text;
  if v_current = p_status then
    return v_status;
  end if;
  if v_current not in ('idle', 'change', 'suggested', 'ready') then
    raise exception '지금 상태(%)에서는 바꿀 수 없습니다', v_current using errcode = '55000';
  end if;

  -- ready 는 산출물이 있을 때만
  if p_status = 'ready' then
    if p_step = 1 and not exists (
         select 1 from nomad_shorts.topics t where t.project_id = p_project_id and t.picked) then
      raise exception '선택된 소재가 없어 준비 완료로 바꿀 수 없습니다' using errcode = '55000';
    end if;
    if p_step = 3 and not exists (
         select 1 from (
           select s.lines from nomad_shorts.scripts s
           where s.project_id = p_project_id
           order by s.version desc
           limit 1
         ) latest
         where jsonb_array_length(latest.lines) > 0) then
      raise exception '대본이 없어 준비 완료로 바꿀 수 없습니다' using errcode = '55000';
    end if;
    if p_step = 4 and not nomad_shorts_private.has_voice_output(p_project_id) then
      raise exception '음성 테이크가 없어 준비 완료로 바꿀 수 없습니다' using errcode = '55000';
    end if;
    if p_step = 5 and not nomad_shorts_private.has_render_output(p_project_id) then
      raise exception '완성된 최신 렌더가 없어 준비 완료로 바꿀 수 없습니다' using errcode = '55000';
    end if;
  end if;

  update nomad_shorts.projects
  set step_status = jsonb_set(step_status, array[p_step::text], to_jsonb(p_status))
  where id = p_project_id
  returning step_status into v_status;

  return v_status;
end;
$$;

-- Name: metrics_targets(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.metrics_targets() RETURNS TABLE(publication_id uuid, account_id uuid, organization_id uuid, platform_video_id text, published_at timestamp with time zone)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select pub.id, pub.account_id, a.organization_id, pub.platform_video_id, pub.published_at
  from nomad_shorts.publications pub
  join nomad_shorts.accounts a on a.id = pub.account_id
  where pub.status = 'uploaded'
    and pub.platform_video_id is not null
    and a.platform = 'youtube'
    and a.status = 'connected'
    and pub.published_at > now() - interval '33 days'
    and coalesce((select max(vm.collected_at) from nomad_shorts.video_metrics vm where vm.publication_id = pub.id),
                 '-infinity'::timestamptz) < now() - interval '20 hours'
  order by pub.account_id, pub.published_at;
$$;

-- Name: normalize_collect_url(text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.normalize_collect_url(p_url text, OUT url text, OUT platform text, OUT handle text) RETURNS record
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO ''
    AS $_$
declare
  v_url text := btrim(coalesce(p_url, ''));
  v_authority text;
  v_host text;
  v_path text;
  m text[];
begin
  if char_length(v_url) > 2000 or v_url !~* '^https?://[^\s/?#]+[^\s]*$' or nomad_shorts_private.has_unsafe_chars(v_url) then
    raise exception 'http(s) URL이 아닙니다' using errcode = '22023';
  end if;
  v_authority := substring(v_url from '^[A-Za-z]+://([^/?#]*)');
  if v_authority like '%@%' then
    raise exception 'URL에 사용자 정보(@)를 넣을 수 없습니다' using errcode = '22023';
  end if;
  v_host := lower(v_authority);
  v_path := regexp_replace(substring(v_url from '^[A-Za-z]+://[^/?#]*([^?#]*)'), '/+$', '');

  if v_host ~ '^(www\.|m\.)?tiktok\.com$' then
    m := regexp_match(v_path, '^/@([A-Za-z0-9._]{1,64})/video/([0-9]{1,30})$');
    if m is null then
      raise exception '틱톡 영상 주소 형식이 아닙니다' using errcode = '22023';
    end if;
    platform := 'tiktok';
    handle := lower(m[1]);
    url := 'https://www.tiktok.com/@' || handle || '/video/' || m[2];
  elsif v_host ~ '^(www\.)?xiaohongshu\.com$' then
    m := regexp_match(v_path, '^/(explore|discovery/item)/([0-9A-Fa-f]{24})$');
    if m is null then
      raise exception '샤오홍슈 노트 주소 형식이 아닙니다' using errcode = '22023';
    end if;
    platform := 'xiaohongshu';
    url := 'https://www.xiaohongshu.com/explore/' || lower(m[2]);
  else
    raise exception '틱톡·샤오홍슈 주소만 수집할 수 있습니다' using errcode = '22023';
  end if;
end;
$_$;

-- Name: normalize_for_ban(text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.normalize_for_ban(p_text text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select lower(regexp_replace(normalize(coalesce(p_text, ''), nfc), '[​-‍﻿⁠[:space:]]', '', 'g'));
$$;

-- Name: oauth_state_consume(uuid, text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.oauth_state_consume(p_organization_id uuid, p_state_hash text) RETURNS TABLE(account_id uuid, code_verifier text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
#variable_conflict use_column
declare
  v nomad_shorts.oauth_states;
begin
  update nomad_shorts.oauth_states s
  set used_at = now()
  where s.state_hash = p_state_hash and s.used_at is null
  returning s.* into v;
  if v.state_hash is null or v.expires_at <= now() or v.organization_id is distinct from p_organization_id then
    return;
  end if;
  return query select v.account_id, v.code_verifier;
end;
$$;

-- Name: oauth_state_create(uuid, uuid, text, text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.oauth_state_create(p_organization_id uuid, p_account_id uuid, p_state_hash text, p_verifier text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not exists (select 1 from nomad_shorts.accounts a
                 where a.id = p_account_id and a.organization_id = p_organization_id and a.platform = 'youtube') then
    raise exception '연결할 수 없는 계정입니다' using errcode = '42501';
  end if;
  -- 쓴 것·만료된 것은 정리, 진행 중인 시작 요청은 사용자당 10개까지
  delete from nomad_shorts.oauth_states s
  where s.organization_id = p_organization_id and (s.used_at is not null or s.expires_at <= now());
  if (select count(*) from nomad_shorts.oauth_states s where s.organization_id = p_organization_id) >= 10 then
    raise exception '연결 요청이 너무 많습니다. 잠시 후 다시 시도하세요' using errcode = '54000';
  end if;
  insert into nomad_shorts.oauth_states (state_hash, organization_id, account_id, code_verifier)
  values (p_state_hash, p_organization_id, p_account_id, p_verifier);
end;
$$;

-- Name: policy_checks_guard(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.policy_checks_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
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

-- Name: prepare_publication(uuid, text, timestamp with time zone, text, text, text[], boolean, boolean); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.prepare_publication(p_project_id uuid, p_mode text, p_scheduled_at timestamp with time zone, p_title text, p_body text, p_hashtags text[], p_purchase_guide boolean, p_pin_comment boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  v_status jsonb;
  v_account uuid;
  v_policy jsonb;
  v_tags text[] := nomad_shorts_private.publish_clean_hashtags(p_hashtags);
  v_title text := btrim(coalesce(p_title, ''));
  v_existing text;
  v_description text;
  v_row nomad_shorts.publications;
begin
  perform nomad_shorts_private.publish_owned(p_project_id, true);
  select step_status, account_id into v_status, v_account from nomad_shorts.projects where id = p_project_id;
  if v_status ->> '5' <> 'approved' then
    raise exception '05 편집을 먼저 승인해 주세요' using errcode = '55000';
  end if;
  if p_mode is null or p_mode not in ('scheduled', 'now') then
    raise exception '발행 방식이 올바르지 않습니다' using errcode = '22023';
  end if;
  if p_mode = 'scheduled' and (p_scheduled_at is null or p_scheduled_at <= now()) then
    raise exception '예약 시각은 지금보다 뒤여야 합니다' using errcode = '22023';
  end if;
  if char_length(v_title) not between 1 and 100 then
    raise exception '제목은 1~100자여야 합니다' using errcode = '22023';
  end if;
  if char_length(coalesce(p_body, '')) > 4000 or cardinality(v_tags) > 15
     or exists (select 1 from unnest(v_tags) t where t !~ '^[^[:space:]#]{1,30}$') then
    raise exception '설명·해시태그 형식이 올바르지 않습니다' using errcode = '22023';
  end if;

  select status into v_existing from nomad_shorts.publications where project_id = p_project_id;
  if v_existing is not null and v_existing not in ('pending', 'invalidated') then
    raise exception '이미 예약·업로드가 시작된 발행입니다' using errcode = '55000';
  end if;

  v_policy := nomad_shorts_private.publish_evaluate(p_project_id, v_title, p_body, v_tags);
  if (v_policy ->> 'passed')::int <> 6 then
    raise exception '정책 점검 6개 항목을 모두 통과해야 발행할 수 있습니다' using errcode = 'PC001';
  end if;

  v_description := nomad_shorts_private.publish_description(
    v_policy ->> 'disclosure',
    case when coalesce(p_purchase_guide, true) then v_policy ->> 'purchase' else '' end,
    p_body, v_policy ->> 'credits', v_tags);
  -- YouTube 한도(task-024a 보완): 설명란 5000바이트(UTF-8)·태그 합 500자. 제목 100자는 위에서 검사
  if octet_length(v_description) > 5000 then
    raise exception '설명란이 YouTube 한도(5000바이트)를 넘습니다. 본문을 줄여 다시 발행 준비해 주세요' using errcode = 'PC002';
  end if;
  if nomad_shorts_private.youtube_tags_length(v_tags) > 500 then
    raise exception '해시태그가 YouTube 태그 한도(500자)를 넘습니다' using errcode = 'PC003';
  end if;

  insert into nomad_shorts.publications (project_id, account_id, mode, scheduled_at, title, body, description, hashtags,
                                   pin_comment, prepared_at, status)
  values (p_project_id, v_account, p_mode, case when p_mode = 'scheduled' then p_scheduled_at end, v_title,
          nullif(btrim(coalesce(p_body, '')), ''), v_description, v_tags, coalesce(p_pin_comment, false), now(), 'pending')
  on conflict (project_id) do update
    set mode = excluded.mode, scheduled_at = excluded.scheduled_at, title = excluded.title, body = excluded.body,
        description = excluded.description, hashtags = excluded.hashtags, pin_comment = excluded.pin_comment,
        prepared_at = excluded.prepared_at, status = 'pending'
  returning * into v_row;

  update nomad_shorts.projects set status = 'awaiting_publish' where id = p_project_id;

  return jsonb_build_object('id', v_row.id, 'mode', v_row.mode, 'scheduled_at', v_row.scheduled_at,
                            'title', v_row.title, 'description', v_row.description,
                            'prepared_at', v_row.prepared_at, 'status', v_row.status);
end;
$_$;

-- Name: projects_channel_slot_guard(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.projects_channel_slot_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if tg_op = 'UPDATE' and new.account_id is not distinct from old.account_id then
    return new;
  end if;
  if nomad_shorts_private.channel_is_excess(new.organization_id, new.account_id) then
    raise exception '이 채널은 요금제 채널 수를 넘어 새 프로젝트를 만들 수 없습니다' using errcode = 'CS004';
  end if;
  return new;
end;
$$;

-- Name: projects_force_initial_state(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.projects_force_initial_state() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  -- 서버(SR)·마이그레이션 주체가 아니면 강제. 트리거 안에서 private 함수를 부르지 않는다(authenticated에 USAGE 없음).
  if current_user not in ('postgres', 'service_role', 'supabase_admin') then
    new.current_step := 1;
    new.step_status := '{"1":"idle","2":"idle","3":"idle","4":"idle","5":"idle","6":"idle"}'::jsonb;
    new.status := 'in_progress';
  end if;
  if current_user <> 'postgres' then
    new.sources_notice_ack_by := null;
    new.sources_notice_ack_at := null;
    new.sources_shortage_reason := null;
  end if;
  return new;
end;
$$;

-- Name: projects_publish_invalidate(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.projects_publish_invalidate() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if new.step_status ->> '5' is distinct from 'approved' then
    update nomad_shorts.publications set status = 'invalidated'
    where project_id = new.id and status = 'pending';
    if new.status = 'awaiting_publish' then
      new.status := 'in_progress';
    end if;
  end if;
  return new;
end;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

-- Name: publications; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.publications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    account_id uuid NOT NULL,
    mode text NOT NULL,
    scheduled_at timestamp with time zone,
    published_at timestamp with time zone,
    platform_video_id text,
    status text DEFAULT 'pending'::text NOT NULL,
    error text,
    retry_count integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    title text,
    description text,
    hashtags text[] DEFAULT '{}'::text[] NOT NULL,
    pin_comment boolean DEFAULT false NOT NULL,
    prepared_at timestamp with time zone,
    body text,
    attempt_token uuid,
    attempt_started_at timestamp with time zone,
    next_attempt_at timestamp with time zone,
    CONSTRAINT publications_body_check CHECK ((char_length(body) <= 4000)),
    CONSTRAINT publications_description_check CHECK ((char_length(description) <= 5000)),
    CONSTRAINT publications_mode_check CHECK ((mode = ANY (ARRAY['scheduled'::text, 'now'::text]))),
    CONSTRAINT publications_retry_count_check CHECK (((retry_count >= 0) AND (retry_count <= 3))),
    CONSTRAINT publications_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'invalidated'::text, 'uploading'::text, 'retry_wait'::text, 'reconnect_wait'::text, 'needs_check'::text, 'failed'::text, 'scheduled'::text, 'uploaded'::text]))),
    CONSTRAINT publications_title_check CHECK (((char_length(title) >= 1) AND (char_length(title) <= 100)))
);

-- Name: TABLE publications; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.publications IS '발행 1건(프로젝트당 1). 생성·예약은 함수 전용, 업로드 결과는 서버(SR)';

-- Name: COLUMN publications.error; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.publications.error IS '마지막 실패 분류 코드(kind:code). 원문 응답·토큰은 넣지 않는다';

-- Name: COLUMN publications.description; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.publications.description IS '설명란(고지 → 구매 안내 → 본문 → 출처 → 해시태그). prepare_publication 이 DB 값으로 만든다';

-- Name: COLUMN publications.body; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.publications.body IS '설명란 본문 입력값(고지·구매 안내·출처·해시태그 제외). prepare_publication 이 저장';

-- Name: COLUMN publications.attempt_token; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.publications.attempt_token IS '업로드 시도 토큰(publication_claim 발급). 결과 기록 함수는 이 토큰이 맞을 때만 쓴다';

-- Name: COLUMN publications.next_attempt_at; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.publications.next_attempt_at IS '다음 자동 시도 시각(일시 오류 백오프·쿼터 대기). 서버 전용';

-- Name: publication_attempt(uuid, uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publication_attempt(p_publication_id uuid, p_attempt_token uuid) RETURNS nomad_shorts.publications
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_pub nomad_shorts.publications;
begin
  select * into v_pub from nomad_shorts.publications
  where id = p_publication_id and status = 'uploading' and attempt_token = p_attempt_token
  for update;
  if v_pub.id is null then
    raise exception '선점이 끝난 업로드 시도입니다' using errcode = '55000';
  end if;
  return v_pub;
end;
$$;

-- Name: publication_attempt_fail(uuid, uuid, text, text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publication_attempt_fail(p_publication_id uuid, p_attempt_token uuid, p_kind text, p_code text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_pub nomad_shorts.publications := nomad_shorts_private.publication_attempt(p_publication_id, p_attempt_token);
  v_has_session boolean := exists (select 1 from nomad_shorts.publication_upload_sessions where publication_id = p_publication_id);
  v_code text := left(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9_.-]', '', 'g'), 60);
  v_n integer;
  v_status text;
  v_next timestamptz;
begin
  case p_kind
    when 'transient' then
      v_n := v_pub.retry_count + 1;
      if v_n >= 3 then
        -- 세션이 있으면 이미 올라갔을 수 있다 → 결과 불명
        v_status := case when v_has_session then 'needs_check' else 'failed' end;
      else
        v_status := 'retry_wait';
        v_next := now() + interval '1 minute' * power(4, v_n - 1);
      end if;
      update nomad_shorts.publications set retry_count = least(v_n, 3) where id = v_pub.id;
    when 'quota' then
      v_status := 'retry_wait';
      v_next := nomad_shorts_private.youtube_quota_reset_at();
      -- 프로젝트 쿼터 소진이면 오늘 남은 insert 를 막는다(채널 한도 uploadLimitExceeded 는 그 채널만)
      if v_code = 'quotaExceeded' then
        insert into nomad_shorts.youtube_upload_quota (day, used)
        values ((now() at time zone 'America/Los_Angeles')::date, 100)
        on conflict (day) do update set used = greatest(nomad_shorts.youtube_upload_quota.used, 100), updated_at = now();
      end if;
    when 'deferred' then
      v_status := 'retry_wait';
      v_next := now() + interval '5 minutes';
    when 'reconnect' then
      v_status := 'reconnect_wait';
    when 'unknown' then
      v_status := 'needs_check';
    when 'permanent' then
      v_status := 'failed';
    else
      raise exception '실패 분류가 올바르지 않습니다' using errcode = '22023';
  end case;
  update nomad_shorts.publications
  set status = v_status, next_attempt_at = v_next, attempt_token = null, error = p_kind || ':' || v_code
  where id = v_pub.id;
  return jsonb_build_object('status', v_status, 'next_attempt_at', v_next);
end;
$$;

-- Name: publication_block(nomad_shorts.publications, boolean, text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publication_block(p_pub nomad_shorts.publications, p_has_session boolean, p_code text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if p_has_session then
    update nomad_shorts.publications
    set status = 'needs_check', error = p_code, attempt_token = null, next_attempt_at = null
    where id = p_pub.id;
  else
    update nomad_shorts.publications
    set status = 'invalidated', error = p_code, attempt_token = null, next_attempt_at = null
    where id = p_pub.id;
    update nomad_shorts.projects set status = 'in_progress' where id = p_pub.project_id and status = 'awaiting_publish';
  end if;
end;
$$;

-- Name: publication_claim(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publication_claim() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_stale record;
  v_pub nomad_shorts.publications;
  v_session nomad_shorts.publication_upload_sessions;
  v_has_session boolean;
  v_ctx record;
  v_policy jsonb;
  v_mp4 text;
  v_token uuid := gen_random_uuid();
begin
  -- 멈춘 시도(30분 넘게 uploading): 일시 오류 1회. 세션이 있으면 다음 선점이 상태 조회로 결과를 확인한다
  for v_stale in
    select p.id, p.retry_count,
           exists (select 1 from nomad_shorts.publication_upload_sessions s where s.publication_id = p.id) as has_session
    from nomad_shorts.publications p
    where p.status = 'uploading' and p.attempt_started_at < now() - interval '30 minutes'
    for update of p skip locked
  loop
    update nomad_shorts.publications
    set status = case when v_stale.retry_count + 1 < 3 then 'retry_wait'
                      when v_stale.has_session then 'needs_check'
                      else 'failed' end,
        retry_count = least(retry_count + 1, 3),
        next_attempt_at = case when v_stale.retry_count + 1 < 3 then now() end,
        attempt_token = null,
        error = 'unknown:stale_attempt'
    where id = v_stale.id;
  end loop;

  select * into v_pub from nomad_shorts.publications
  where status in ('pending', 'retry_wait') and (next_attempt_at is null or next_attempt_at <= now())
  order by coalesce(next_attempt_at, prepared_at, created_at), id
  limit 1
  for update skip locked;
  if v_pub.id is null then
    return jsonb_build_object('claimed', false, 'reason', 'idle');
  end if;

  select * into v_session from nomad_shorts.publication_upload_sessions where publication_id = v_pub.id;
  v_has_session := v_session.publication_id is not null;

  select p.organization_id, p.account_id as project_account, a.platform, a.organization_id as account_user,
         a.external_channel_id, a.status as account_status
    into v_ctx
  from nomad_shorts.projects p
  join nomad_shorts.accounts a on a.id = p.account_id
  where p.id = v_pub.project_id;

  -- 채널: 프로젝트 채널 = 발행 채널, YouTube, 같은 소유자. 아니면 업로드하지 않는다
  if v_ctx.project_account is distinct from v_pub.account_id or v_ctx.platform is distinct from 'youtube'
     or v_ctx.account_user is distinct from v_ctx.organization_id then
    update nomad_shorts.publications
    set status = 'failed', error = 'permanent:channel_mismatch', attempt_token = null, next_attempt_at = null
    where id = v_pub.id;
    return jsonb_build_object('claimed', false, 'reason', 'channel_mismatch', 'publication_id', v_pub.id);
  end if;

  -- 연결이 끊긴 채널: 재시도 횟수를 쓰지 않고 재연결 대기(세션은 그대로, 재연결 뒤 상태 조회)
  if v_ctx.external_channel_id is null or v_ctx.account_status <> 'connected' then
    update nomad_shorts.publications
    set status = 'reconnect_wait', error = 'reconnect:reconnect_required', attempt_token = null, next_attempt_at = null
    where id = v_pub.id;
    return jsonb_build_object('claimed', false, 'reason', 'reconnect_wait', 'publication_id', v_pub.id);
  end if;

  -- 세션이 없을 때만 여기서 판정한다. 세션이 있으면 업로더가 상태 조회 → 완료면 기록, 덜 올라갔으면 publication_resume_check
  if not v_has_session then
    -- 예약 시각이 지금+5분보다 이르면 올리지 않는다(자동 즉시 공개 금지 → 사용자 확인)
    if v_pub.mode = 'scheduled' and (v_pub.scheduled_at is null or v_pub.scheduled_at < now() + interval '5 minutes') then
      perform nomad_shorts_private.publication_block(v_pub, false, 'confirm:schedule_passed');
      return jsonb_build_object('claimed', false, 'reason', 'schedule_passed', 'publication_id', v_pub.id);
    end if;

    -- 정책 6/6 재판정(publish_recheck 와 같은 판정, 저장된 문구)
    v_policy := nomad_shorts_private.publish_evaluate(v_pub.project_id, v_pub.title, v_pub.body, v_pub.hashtags);
    if (v_policy ->> 'passed')::int <> 6 then
      perform nomad_shorts_private.publication_block(v_pub, false, 'confirm:policy_failed');
      return jsonb_build_object('claimed', false, 'reason', 'policy_failed', 'publication_id', v_pub.id);
    end if;
  end if;

  select r.mp4_path into v_mp4 from nomad_shorts.renders r
  where r.project_id = v_pub.project_id
  order by r.version desc
  limit 1;

  update nomad_shorts.publications
  set status = 'uploading', attempt_token = v_token, attempt_started_at = now(), next_attempt_at = null
  where id = v_pub.id;

  return jsonb_build_object(
    'claimed', true,
    'publication_id', v_pub.id,
    'attempt_token', v_token,
    'project_id', v_pub.project_id,
    'organization_id', v_ctx.organization_id,
    'account_id', v_pub.account_id,
    'mode', v_pub.mode,
    'scheduled_at', v_pub.scheduled_at,
    'title', v_pub.title,
    'description', coalesce(v_pub.description, ''),
    'hashtags', to_jsonb(coalesce(v_pub.hashtags, '{}'::text[])),
    'mp4_path', v_mp4,
    'retry_count', v_pub.retry_count,
    'session', case when v_has_session then jsonb_build_object(
                 'uri', v_session.session_uri, 'total_bytes', v_session.total_bytes,
                 'restart_allowed', v_session.restart_allowed) end);
end;
$$;

-- Name: publication_confirm_absent(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publication_confirm_absent(p_project_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_pub nomad_shorts.publications;
begin
  perform nomad_shorts_private.publish_owned(p_project_id, true);
  select * into v_pub from nomad_shorts.publications where project_id = p_project_id for update;
  if v_pub.id is null or v_pub.status <> 'needs_check' or v_pub.platform_video_id is not null then
    raise exception '지금은 새로 업로드할 수 없습니다' using errcode = '55000';
  end if;
  if exists (select 1 from nomad_shorts.publication_upload_sessions
             where publication_id = v_pub.id and completed_at is not null) then
    raise exception '이미 업로드가 끝난 발행입니다' using errcode = '55000';
  end if;
  delete from nomad_shorts.publication_upload_sessions where publication_id = v_pub.id;
  update nomad_shorts.publications
  set status = 'retry_wait', retry_count = 0, error = null, attempt_token = null, next_attempt_at = now()
  where id = v_pub.id;
  insert into nomad_shorts.project_events (project_id, step, event) values (p_project_id, 6, 'upload_absent_confirmed');
  return jsonb_build_object('status', 'retry_wait');
end;
$$;

-- Name: publication_finish(uuid, uuid, text, boolean); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publication_finish(p_publication_id uuid, p_attempt_token uuid, p_video_id text, p_test_private boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  v_pub nomad_shorts.publications := nomad_shorts_private.publication_attempt(p_publication_id, p_attempt_token);
  v_status text;
begin
  if p_video_id is null or p_video_id !~ '^[A-Za-z0-9_-]{6,64}$' then
    raise exception '영상 ID 형식이 올바르지 않습니다' using errcode = '22023';
  end if;
  v_status := case when v_pub.mode = 'scheduled' and not coalesce(p_test_private, false) then 'scheduled' else 'uploaded' end;
  update nomad_shorts.publications
  set status = v_status, platform_video_id = p_video_id,
      published_at = case when v_status = 'scheduled' then v_pub.scheduled_at else now() end,
      error = null, attempt_token = null, next_attempt_at = null
  where id = v_pub.id;
  update nomad_shorts.publication_upload_sessions set completed_at = now() where publication_id = v_pub.id;
  update nomad_shorts.projects set status = v_status where id = v_pub.project_id;
  return jsonb_build_object('status', v_status);
end;
$_$;

-- Name: publication_reject_copy(uuid, uuid, text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publication_reject_copy(p_publication_id uuid, p_attempt_token uuid, p_code text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_pub nomad_shorts.publications := nomad_shorts_private.publication_attempt(p_publication_id, p_attempt_token);
begin
  if p_code is null or p_code not in ('title_too_long', 'description_too_long', 'tags_too_long') then
    raise exception '한도 코드가 올바르지 않습니다' using errcode = '22023';
  end if;
  -- 세션이 생긴 뒤에는 문구가 이미 YouTube 에 갔다 → 이 경로가 아니다
  if exists (select 1 from nomad_shorts.publication_upload_sessions where publication_id = v_pub.id) then
    raise exception '업로드 세션이 있는 발행입니다' using errcode = '55000';
  end if;
  perform nomad_shorts_private.publication_block(v_pub, false, 'confirm:' || p_code);
  return jsonb_build_object('status', 'invalidated');
end;
$$;

-- Name: publication_resume_check(uuid, uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publication_resume_check(p_publication_id uuid, p_attempt_token uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_pub nomad_shorts.publications := nomad_shorts_private.publication_attempt(p_publication_id, p_attempt_token);
  v_policy jsonb;
begin
  if not exists (select 1 from nomad_shorts.publication_upload_sessions where publication_id = v_pub.id) then
    raise exception '업로드 세션이 없습니다' using errcode = '55000';
  end if;
  if v_pub.mode = 'scheduled' and (v_pub.scheduled_at is null or v_pub.scheduled_at < now() + interval '5 minutes') then
    perform nomad_shorts_private.publication_block(v_pub, true, 'confirm:schedule_passed');
    return jsonb_build_object('ok', false, 'status', 'needs_check', 'reason', 'schedule_passed');
  end if;
  v_policy := nomad_shorts_private.publish_evaluate(v_pub.project_id, v_pub.title, v_pub.body, v_pub.hashtags);
  if (v_policy ->> 'passed')::int <> 6 then
    perform nomad_shorts_private.publication_block(v_pub, true, 'confirm:policy_failed');
    return jsonb_build_object('ok', false, 'status', 'needs_check', 'reason', 'policy_failed');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Name: publication_retry(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publication_retry(p_project_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_pub nomad_shorts.publications;
  v_session nomad_shorts.publication_upload_sessions;
begin
  perform nomad_shorts_private.publish_owned(p_project_id, true);
  select * into v_pub from nomad_shorts.publications where project_id = p_project_id for update;
  -- needs_check 는 여기서 다시 시도하지 않는다(중복 업로드 위험) → publication_confirm_absent
  if v_pub.id is null or v_pub.status not in ('failed', 'reconnect_wait')
     or v_pub.platform_video_id is not null then
    raise exception '지금은 다시 시도할 수 없습니다' using errcode = '55000';
  end if;
  select * into v_session from nomad_shorts.publication_upload_sessions where publication_id = v_pub.id for update;
  if v_session.completed_at is not null then
    raise exception '이미 업로드가 끝난 발행입니다' using errcode = '55000';
  end if;
  -- 세션이 있으면 업로더가 상태 조회로 이어 올린다(사라졌으면 needs_check)
  update nomad_shorts.publications
  set status = 'retry_wait', retry_count = 0, error = null, attempt_token = null, next_attempt_at = now()
  where id = v_pub.id;
  return jsonb_build_object('status', 'retry_wait');
end;
$$;

-- Name: publication_session_begin(uuid, uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publication_session_begin(p_publication_id uuid, p_attempt_token uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_pub nomad_shorts.publications := nomad_shorts_private.publication_attempt(p_publication_id, p_attempt_token);
  v_day date := (now() at time zone 'America/Los_Angeles')::date;
  v_used integer;
  v_next timestamptz;
begin
  if exists (select 1 from nomad_shorts.publication_upload_sessions where publication_id = v_pub.id) then
    raise exception '업로드 세션이 이미 있습니다. 상태 조회로 이어 올려 주세요' using errcode = '55000';
  end if;
  insert into nomad_shorts.youtube_upload_quota (day) values (v_day) on conflict (day) do nothing;
  select used into v_used from nomad_shorts.youtube_upload_quota where day = v_day for update;
  if v_used >= 100 then
    v_next := nomad_shorts_private.youtube_quota_reset_at();
    update nomad_shorts.publications
    set status = 'retry_wait', next_attempt_at = v_next, error = 'quota:daily_limit', attempt_token = null
    where id = v_pub.id;
    return jsonb_build_object('ok', false, 'reason', 'quota', 'next_attempt_at', v_next);
  end if;
  update nomad_shorts.youtube_upload_quota set used = used + 1, updated_at = now() where day = v_day;
  return jsonb_build_object('ok', true);
end;
$$;

-- Name: publication_session_save(uuid, uuid, text, bigint); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publication_session_save(p_publication_id uuid, p_attempt_token uuid, p_session_uri text, p_total_bytes bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_pub nomad_shorts.publications := nomad_shorts_private.publication_attempt(p_publication_id, p_attempt_token);
begin
  insert into nomad_shorts.publication_upload_sessions (publication_id, session_uri, total_bytes)
  values (v_pub.id, p_session_uri, p_total_bytes);
end;
$$;

-- Name: publications_channel_slot_guard(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publications_channel_slot_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_user uuid;
begin
  select p.organization_id into v_user from nomad_shorts.projects p where p.id = new.project_id;
  if exists (select 1 from nomad_shorts.publications x where x.project_id = new.project_id) then
    return new;
  end if;
  if v_user is not null and nomad_shorts_private.channel_is_excess(v_user, new.account_id) then
    raise exception '이 채널은 요금제 채널 수를 넘어 새로 발행할 수 없습니다' using errcode = 'CS005';
  end if;
  return new;
end;
$$;

-- Name: publications_guard(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publications_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
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

-- Name: publications_set_purge(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publications_set_purge() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_purge date;
  v_live timestamptz := now() - interval '30 minutes';
  v_deleting timestamptz := now() - interval '5 minutes';
begin
  if new.status in ('scheduled', 'uploaded')
     and (tg_op = 'INSERT'
          or (old.status, old.scheduled_at, old.published_at)
             is distinct from (new.status, new.scheduled_at, new.published_at)) then
    v_purge := (greatest(now(), coalesce(new.scheduled_at, now()), coalesce(new.published_at, now()))
                + interval '30 days')::date;
    perform 1 from nomad_shorts.sources where project_id = new.project_id order by id for update;
    perform 1 from nomad_shorts.voice_takes where project_id = new.project_id order by id for update;
    perform 1 from nomad_shorts.renders where project_id = new.project_id order by id for update;
    if exists (select 1 from nomad_shorts.sources
               where project_id = new.project_id
                 and ((file_deleted_at is null and retention_token is not null and retention_reserved_at > v_live)
                      or (thumbnail_deleted_at is null and thumbnail_retention_token is not null
                          and thumbnail_retention_reserved_at > v_live)
                      or retention_deleting_at > v_deleting
                      or thumbnail_retention_deleting_at > v_deleting))
       or exists (select 1 from nomad_shorts.voice_takes
                  where project_id = new.project_id
                    and ((file_deleted_at is null and retention_token is not null and retention_reserved_at > v_live)
                         or retention_deleting_at > v_deleting))
       or exists (select 1 from nomad_shorts.renders
                  where project_id = new.project_id
                    and ((file_deleted_at is null and retention_token is not null and retention_reserved_at > v_live)
                         or retention_deleting_at > v_deleting)) then
      raise exception '보관 정리 중인 파일이 있어 잠시 후 다시 시도해 주세요' using errcode = 'RT001';
    end if;
    update nomad_shorts.sources
    set purge_after = v_purge,
        retention_token = null, retention_reserved_at = null, retention_deleting_at = null,
        thumbnail_retention_token = null, thumbnail_retention_reserved_at = null, thumbnail_retention_deleting_at = null
    where project_id = new.project_id and file_deleted_at is null;
    update nomad_shorts.voice_takes
    set purge_after = v_purge, retention_token = null, retention_reserved_at = null, retention_deleting_at = null
    where project_id = new.project_id and file_deleted_at is null;
    update nomad_shorts.renders
    set purge_after = v_purge, retention_token = null, retention_reserved_at = null, retention_deleting_at = null
    where project_id = new.project_id and file_deleted_at is null;
  end if;
  return null;
end;
$$;

-- Name: publications_upload_guard(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publications_upload_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if new.project_id is distinct from old.project_id or new.account_id is distinct from old.account_id then
    raise exception '발행 채널은 바꿀 수 없습니다' using errcode = '42501';
  end if;
  if old.platform_video_id is not null
     and (new.platform_video_id is distinct from old.platform_video_id or new.status not in ('uploaded', 'scheduled')) then
    raise exception '이미 업로드된 발행입니다. 다시 올릴 수 없습니다' using errcode = '55000';
  end if;
  if new.status = 'pending' and old.status not in ('pending', 'invalidated') then
    raise exception '이미 예약·업로드가 시작된 발행입니다' using errcode = '55000';
  end if;
  -- 발행 준비를 다시 저장하면 이전 시도 기록을 비운다
  if old.status = 'invalidated' and new.status = 'pending' then
    new.error := null;
    new.retry_count := 0;
    new.next_attempt_at := null;
    new.attempt_token := null;
  end if;
  return new;
end;
$$;

-- Name: publish_banned_term(uuid, text[]); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publish_banned_term(p_project_id uuid, p_texts text[]) RETURNS text
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
  with body as (
    select nomad_shorts_private.normalize_for_ban(
             coalesce(array_to_string(p_texts, ''), '')
             || coalesce((select string_agg(l.line, '' order by l.ord)
                          from nomad_shorts.scripts s
                          cross join lateral jsonb_array_elements_text(s.lines) with ordinality as l(line, ord)
                          where s.id = (select s2.id from nomad_shorts.scripts s2
                                        where s2.project_id = p_project_id and s2.approved_at is not null
                                        order by s2.version desc limit 1)), '')) as text
  ),
  terms as (
    select unnest(array['최고', '완벽', '100%', '무조건', '기적', '치료']) as term
    union all
    select t.term
    from nomad_shorts.projects p
    join nomad_shorts.categories c on c.id = p.category_id
    cross join lateral unnest(c.banned_terms) as t(term)
    where p.id = p_project_id
  )
  select terms.term
  from terms cross join body
  where nomad_shorts_private.normalize_for_ban(terms.term) <> ''
    and strpos(body.text, nomad_shorts_private.normalize_for_ban(terms.term)) > 0
  limit 1;
$$;

-- Name: publish_clean_hashtags(text[]); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publish_clean_hashtags(p_hashtags text[]) RETURNS text[]
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select coalesce(array_agg(t order by first_o), '{}')
  from (
    select t, min(o) as first_o
    from (select btrim(ltrim(btrim(x), '#')) as t, o
          from unnest(coalesce(p_hashtags, '{}')) with ordinality u(x, o)) c
    where t <> ''
    group by t
  ) d;
$$;

-- Name: publish_description(text, text, text, text, text[]); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publish_description(p_disclosure text, p_purchase text, p_body text, p_credits text, p_hashtags text[]) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select array_to_string(array_remove(array[
    nullif(btrim(coalesce(p_disclosure, '')), ''),
    nullif(btrim(coalesce(p_purchase, '')), ''),
    nullif(btrim(coalesce(p_body, '')), ''),
    nullif(btrim(coalesce(p_credits, '')), ''),
    nullif((select string_agg('#' || t, ' ' order by o) from unnest(coalesce(p_hashtags, '{}')) with ordinality u(t, o)), '')
  ], null), E'\n\n');
$$;

-- Name: publish_disclosure_text(text, boolean); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publish_disclosure_text(p_program text, p_disclosed boolean) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select case
    when not coalesce(p_disclosed, false) or coalesce(p_program, 'none') = 'none' then ''
    when p_program = 'coupang_partners' then '이 영상은 쿠팡 파트너스 활동의 일환으로, 이에 따른 일정액의 수수료를 제공받습니다.'
    when p_program = 'youtube_shopping' then '이 영상에는 유튜브 쇼핑 제휴 상품 태그가 있으며, 구매 시 일정액의 수수료를 제공받습니다.'
    else '이 영상은 ' || case p_program
                          when 'naver_shopping_connect' then '네이버 쇼핑 커넥트'
                          when 'ohouse_curator' then '오늘의집 큐레이터'
                          when 'musinsa_curator' then '무신사 큐레이터'
                          when 'oliveyoung_curator' then '올리브영 쇼핑 큐레이터'
                          when 'aliexpress' then '알리익스프레스 어필리에이트'
                          else p_program end
         || ' 활동으로 일정액의 수수료를 제공받습니다.'
  end;
$$;

-- Name: publish_evaluate(uuid, text, text, text[]); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publish_evaluate(p_project_id uuid, p_title text, p_body text, p_hashtags text[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_status jsonb;
  v_ack timestamptz;
  v_platform text;
  v_account uuid;
  v_cuts jsonb;
  v_render_ok boolean := false;
  v_link nomad_shorts.affiliate_links;
  v_has_link boolean;
  v_bio_ok boolean := false;
  v_banned text;
  v_credits text := '';
  v_attr_checked timestamptz;
  v_path_checked timestamptz;
  v_results jsonb := '[]'::jsonb;
  v_item text;
  v_result text;
  v_detail text;
  v_passed integer := 0;
  v_other_fail boolean := false;
  v_tags text[] := nomad_shorts_private.publish_clean_hashtags(p_hashtags);
begin
  select p.step_status, p.sources_notice_ack_at, a.platform, p.account_id
    into v_status, v_ack, v_platform, v_account
  from nomad_shorts.projects p
  join nomad_shorts.accounts a on a.id = p.account_id
  where p.id = p_project_id;

  select r.cut_map -> 'cuts', r.mp4_path is not null
    into v_cuts, v_render_ok
  from nomad_shorts.renders r
  where r.project_id = p_project_id
  order by r.version desc
  limit 1;
  v_render_ok := coalesce(v_render_ok, false);
  if jsonb_typeof(v_cuts) = 'array' then
    v_credits := nomad_shorts_private.render_credits_text(v_cuts);
  else
    v_cuts := '[]'::jsonb;
  end if;

  select * into v_link from nomad_shorts.affiliate_links where project_id = p_project_id;
  v_has_link := v_link.id is not null and v_link.program <> 'none';
  if v_link.bio_no is not null then
    v_bio_ok := exists (select 1 from nomad_shorts.bio_items bi
                        join nomad_shorts.bio_pages bp on bp.id = bi.bio_page_id
                        where bi.project_id = p_project_id and bi.no = v_link.bio_no and bp.account_id = v_account);
  end if;

  select checked_at into v_attr_checked from nomad_shorts.policy_checks
  where project_id = p_project_id and item = 'attribution_notice' and checked_by is not null;
  select checked_at into v_path_checked from nomad_shorts.policy_checks
  where project_id = p_project_id and item = 'purchase_path' and checked_by is not null;

  v_banned := nomad_shorts_private.publish_banned_term(p_project_id,
                array[coalesce(p_title, ''), coalesce(p_body, ''), array_to_string(v_tags, '')]);

  foreach v_item in array array['source_record', 'attribution_notice', 'original_elements',
                                'banned_terms', 'affiliate_disclosure', 'purchase_path'] loop
    case v_item
      when 'source_record' then
        if jsonb_array_length(v_cuts) > 0 and not exists (
             select 1 from jsonb_array_elements(v_cuts) c
             where coalesce(btrim(c ->> 'source_url'), '') = ''
                or coalesce(btrim(c ->> 'author'), '') = ''
                or coalesce(c ->> 'collected_at', '') = '') then
          v_result := 'pass'; v_detail := '쓴 원본 ' || (select count(distinct c ->> 'source_id') from jsonb_array_elements(v_cuts) c) || '편의 URL·작성자·수집 시각이 기록되어 있습니다';
        else
          v_result := 'fail'; v_detail := '최신 검토본의 컷 원본 기록(URL·작성자·수집 시각)이 없습니다. 05 편집에서 MP4를 다시 만들어 주세요';
        end if;
      when 'attribution_notice' then
        if v_ack is null then
          v_result := 'fail'; v_detail := '02 소스의 출처 표기 고지를 먼저 확인해 주세요';
        elsif v_attr_checked is null then
          v_result := 'pending'; v_detail := '영상과 설명란에 출처가 들어갔는지 확인하고 체크해 주세요';
        else
          v_result := 'pass'; v_detail := '사용자가 확인했습니다';
        end if;
      when 'original_elements' then
        if v_status ->> '5' = 'approved' and v_render_ok then
          v_result := 'pass'; v_detail := '대본·AI 음성·자막·컷 구성을 새로 만들었습니다(05 편집 승인)';
        else
          v_result := 'fail'; v_detail := '05 편집을 승인해야 통과합니다';
        end if;
      when 'banned_terms' then
        if v_banned is null then
          v_result := 'pass'; v_detail := '제목·설명·해시태그·대본에 금지·과장 표현이 없습니다';
        else
          v_result := 'fail'; v_detail := '금지·과장 표현 "' || v_banned || '"을(를) 고쳐 주세요';
        end if;
      when 'affiliate_disclosure' then
        if not v_has_link then
          v_result := 'pass'; v_detail := '제휴 링크를 쓰지 않습니다';
        elsif v_link.disclosed then
          v_result := 'pass'; v_detail := '고지 문구가 설명란 첫머리에 들어갑니다';
        else
          v_result := 'fail'; v_detail := '제휴 링크가 있으면 고지 문구를 켜야 합니다';
        end if;
      when 'purchase_path' then
        if not v_has_link then
          v_result := 'pass'; v_detail := '제휴를 쓰지 않습니다';
        elsif v_link.program = 'youtube_shopping' then
          if v_platform = 'youtube' then
            v_result := 'pass'; v_detail := 'YouTube 채널의 상품 태그로 연결합니다';
          else
            v_result := 'fail'; v_detail := '유튜브 쇼핑 상품 태그는 YouTube 채널에서만 쓸 수 있습니다';
          end if;
        elsif v_link.url is null then
          v_result := 'fail'; v_detail := '상품 제휴 링크를 입력해 주세요';
        elsif v_link.bio_service is null or v_link.bio_no is null or not v_bio_ok then
          v_result := 'fail'; v_detail := '링크인바이오 서비스를 골라 이 채널의 번호를 받아 주세요';
        elsif v_link.bio_registered_at is null or v_path_checked is null then
          v_result := 'pending'; v_detail := '링크인바이오에 ' || v_link.bio_no || '번 항목을 등록한 뒤 등록 완료를 켜 주세요';
        else
          v_result := 'pass'; v_detail := '링크인바이오 ' || v_link.bio_no || '번 등록을 확인했습니다';
        end if;
    end case;

    if v_result = 'pass' then
      v_passed := v_passed + 1;
    elsif v_item <> 'banned_terms' then
      -- 금지어는 입력 중 문구로 판정하므로 저장된 발행 행 무효화 근거로 쓰지 않는다(publish_recheck 가 저장 문구로 다시 본다)
      v_other_fail := true;
    end if;
    insert into nomad_shorts.policy_checks (project_id, item, result, detail)
    values (p_project_id, v_item, v_result, v_detail)
    on conflict (project_id, item) do update set result = excluded.result, detail = excluded.detail;

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'item', v_item, 'result', v_result, 'detail', v_detail,
      'checked_at', case v_item when 'attribution_notice' then v_attr_checked
                                when 'purchase_path' then v_path_checked end));
  end loop;

  if v_other_fail then
    perform nomad_shorts_private.publish_invalidate(p_project_id);
  end if;

  return jsonb_build_object(
    'items', v_results,
    'passed', v_passed,
    'total', 6,
    'credits', v_credits,
    'disclosure', nomad_shorts_private.publish_disclosure_text(v_link.program, v_link.disclosed),
    'purchase', nomad_shorts_private.publish_purchase_text(v_link.program, v_link.bio_no));
end;
$$;

-- Name: publish_invalidate(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publish_invalidate(p_project_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  update nomad_shorts.publications set status = 'invalidated'
  where project_id = p_project_id and status = 'pending';
  update nomad_shorts.projects set status = 'in_progress'
  where id = p_project_id and status = 'awaiting_publish';
end;
$$;

-- Name: publish_is_link_program(text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publish_is_link_program(p_program text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select coalesce(p_program, 'none') not in ('none', 'youtube_shopping');
$$;

-- Name: publish_owned(uuid, boolean); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publish_owned(p_project_id uuid, p_lock boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  if p_lock then
    perform 1 from nomad_shorts.projects where id = p_project_id and nomad_core.organization_role(organization_id) IN ('owner', 'admin', 'editor') for update;
  else
    perform 1 from nomad_shorts.projects where id = p_project_id and nomad_core.organization_role(organization_id) IN ('owner', 'admin', 'editor');
  end if;
  if not found then
    raise exception '프로젝트를 찾을 수 없거나 권한이 없습니다' using errcode = '42501';
  end if;
end;
$$;

-- Name: publish_policy(uuid, text, text, text[]); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publish_policy(p_project_id uuid, p_title text, p_body text, p_hashtags text[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  perform nomad_shorts_private.publish_owned(p_project_id, false);
  return nomad_shorts_private.publish_evaluate(p_project_id, p_title, p_body, p_hashtags);
end;
$$;

-- Name: publish_purchase_text(text, integer); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publish_purchase_text(p_program text, p_bio_no integer) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select case
    when p_program = 'youtube_shopping' then '구매 정보: 영상 왼쪽 아래 상품 태그'
    when nomad_shorts_private.publish_is_link_program(p_program) and p_bio_no is not null then '구매 정보: 프로필 링크 ' || p_bio_no || '번'
    else ''
  end;
$$;

-- Name: publish_recheck(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.publish_recheck(p_project_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_pub nomad_shorts.publications;
  v_policy jsonb;
begin
  select * into v_pub from nomad_shorts.publications where project_id = p_project_id for update;
  if v_pub.id is null or v_pub.status <> 'pending' then
    return jsonb_build_object('ok', false, 'reason', 'not_pending', 'status', v_pub.status);
  end if;
  v_policy := nomad_shorts_private.publish_evaluate(p_project_id, v_pub.title, v_pub.body, v_pub.hashtags);
  if (v_policy ->> 'passed')::int <> 6 then
    perform nomad_shorts_private.publish_invalidate(p_project_id);
    return jsonb_build_object('ok', false, 'reason', 'policy_failed', 'policy', v_policy);
  end if;
  return jsonb_build_object('ok', true, 'policy', v_policy);
end;
$$;

-- Name: release_job(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.release_job(p_job_id uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_status text;
  v_count integer;
begin
  select status into v_status from nomad_shorts.jobs where id = p_job_id for update;
  if v_status is null or v_status not in ('failed', 'canceled') then
    return false;
  end if;

  insert into nomad_shorts.credit_ledger (organization_id, project_id, job_id, kind, delta, reason, idempotency_key)
  select r.organization_id, r.project_id, r.job_id, 'release', -r.delta, v_status, 'release:' || r.job_id
  from nomad_shorts.credit_ledger r
  where r.job_id = p_job_id and r.kind = 'reserve'
  on conflict do nothing;
  get diagnostics v_count = row_count;
  return v_count > 0;
end;
$$;

-- Name: render_credits_text(jsonb); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.render_credits_text(p_cuts jsonb) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select coalesce('영상 출처: ' || string_agg(item, ', ' order by first_no), '')
  from (
    select item, min(no) as first_no
    from (
      select (c ->> 'no')::numeric as no,
             '@' || ltrim(btrim(c ->> 'author'), '@')
               || case when coalesce(c ->> 'platform', '') = '' then ''
                       else '(' || case c ->> 'platform'
                                     when 'tiktok' then 'TikTok'
                                     when 'xiaohongshu' then '小红书'
                                     when 'direct' then '직접 추가'
                                     else c ->> 'platform' end || ')' end as item
      from jsonb_array_elements(p_cuts) c
      where ltrim(btrim(coalesce(c ->> 'author', '')), '@') <> ''
    ) labeled
    group by item
  ) items;
$$;

-- Name: sources; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.sources (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    platform text NOT NULL,
    url text NOT NULL,
    author text NOT NULL,
    title text,
    collected_at timestamp with time zone DEFAULT now() NOT NULL,
    width integer,
    height integer,
    duration_sec numeric,
    score numeric,
    file_path text,
    checked boolean DEFAULT false NOT NULL,
    used boolean DEFAULT false NOT NULL,
    exclude_reason text,
    rights_basis text,
    rights_confirmed_by uuid,
    rights_confirmed_at timestamp with time zone,
    purge_after date NOT NULL,
    file_deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    quarantined boolean DEFAULT false NOT NULL,
    thumbnail_path text,
    thumbnail_deleted_at timestamp with time zone,
    retention_token uuid,
    thumbnail_retention_token uuid,
    retention_reserved_at timestamp with time zone,
    thumbnail_retention_reserved_at timestamp with time zone,
    retention_deleting_at timestamp with time zone,
    thumbnail_retention_deleting_at timestamp with time zone,
    CONSTRAINT sources_platform_check CHECK ((platform = ANY (ARRAY['tiktok'::text, 'xiaohongshu'::text, 'direct'::text]))),
    CONSTRAINT sources_rights_basis_check CHECK ((rights_basis = ANY (ARRAY['attribution_notice'::text, 'own'::text, 'seller'::text, 'licensed'::text]))),
    CONSTRAINT sources_url_http_check CHECK ((url ~* '^https?://'::text))
);

-- Name: TABLE sources; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.sources IS '02 원본. URL·작성자·수집 시각 필수, 권리 열은 함수 전용, 파일은 purge_after 뒤 삭제하고 행은 남긴다';

-- Name: COLUMN sources.quarantined; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.sources.quarantined IS '워커가 형식 위장·경로 오류로 거부한 원본. 함수 전용, 사용·편집 입력 제외';

-- Name: COLUMN sources.thumbnail_path; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.sources.thumbnail_path IS '비공개 버킷 thumbnails 의 객체 경로(<organization_id>/<project_id>/<파일명>). 미선정(체크·사용 안 함) 원본은 수집 7일 뒤 파일 삭제';

-- Name: COLUMN sources.thumbnail_deleted_at; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.sources.thumbnail_deleted_at IS '썸네일 객체를 지운 시각(미선정 7일, 선정 원본은 파일과 같은 기준). 서버 전용';

-- Name: COLUMN sources.retention_token; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.sources.retention_token IS '원본 파일 삭제 예약 토큰(retention_reserve). 서버 전용';

-- Name: COLUMN sources.thumbnail_retention_token; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.sources.thumbnail_retention_token IS '썸네일 삭제 예약 토큰(retention_reserve). 서버 전용';

-- Name: COLUMN sources.retention_reserved_at; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.sources.retention_reserved_at IS '원본 파일 삭제 예약 시각(30분 TTL). 서버 전용';

-- Name: COLUMN sources.thumbnail_retention_reserved_at; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.sources.thumbnail_retention_reserved_at IS '썸네일 삭제 예약 시각(30분 TTL). 서버 전용';

-- Name: COLUMN sources.retention_deleting_at; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.sources.retention_deleting_at IS '원본 파일 Storage 삭제 직전 확인 시각(5분간 발행 전환 거부). 서버 전용';

-- Name: COLUMN sources.thumbnail_retention_deleting_at; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.sources.thumbnail_retention_deleting_at IS '썸네일 Storage 삭제 직전 확인 시각(5분간 발행 전환 거부). 서버 전용';

-- Name: render_input_sources(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.render_input_sources(p_project_id uuid) RETURNS SETOF nomad_shorts.sources
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select s.*
  from nomad_shorts.sources s
  join nomad_shorts.projects p on p.id = s.project_id
  where s.project_id = p_project_id
    and s.used
    and not s.quarantined
    and s.rights_basis is not null
    and s.rights_confirmed_at is not null
    and s.file_path is not null
    and s.file_deleted_at is null
    and (s.rights_basis <> 'attribution_notice' or p.sources_notice_ack_at is not null)
  order by s.score desc nulls last, s.id;
$$;

-- Name: render_job_context(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.render_job_context(p_job_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_project uuid := nomad_shorts_private.render_job_project(p_job_id);
  v_user uuid;
  v_target smallint;
  v_lines jsonb;
  v_take jsonb;
  v_sources jsonb;
begin
  select organization_id, target_sec into v_user, v_target from nomad_shorts.projects where id = v_project;
  select s.lines into v_lines
  from nomad_shorts.scripts s
  where s.project_id = v_project and s.approved_at is not null
  order by s.version desc
  limit 1;
  select jsonb_build_object('id', t.id, 'source', t.source, 'audio_path', t.audio_path,
                            'duration_sec', t.duration_sec, 'sentences', coalesce(t.sentences, '[]'::jsonb),
                            'words', coalesce(t.words, '[]'::jsonb))
    into v_take
  from nomad_shorts.voice_takes t
  where t.project_id = v_project and t.audio_path is not null and t.file_deleted_at is null
  order by t.created_at desc, t.id desc
  limit 1;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'platform', s.platform, 'author', s.author, 'url', s.url, 'collected_at', s.collected_at,
           'file_path', s.file_path, 'duration_sec', s.duration_sec, 'score', s.score,
           'rights_basis', s.rights_basis)), '[]'::jsonb)
    into v_sources
  from nomad_shorts_private.render_input_sources(v_project) s;

  if (v_take is null
      and exists (select 1 from nomad_shorts.voice_takes t
                  where t.project_id = v_project and t.audio_path is not null and t.file_deleted_at is not null))
     or (jsonb_array_length(v_sources) = 0
         and exists (select 1 from nomad_shorts.sources s
                     where s.project_id = v_project and s.used and s.file_path is not null
                       and s.file_deleted_at is not null)) then
    raise exception '보관 기간이 지나 원본/음성 파일이 삭제되어 다시 렌더할 수 없습니다' using errcode = 'RD001';
  end if;

  return jsonb_build_object('project_id', v_project, 'organization_id', v_user, 'target_sec', v_target,
                            'lines', coalesce(v_lines, '[]'::jsonb), 'take', v_take, 'sources', v_sources);
end;
$$;

-- Name: render_job_project(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.render_job_project(p_job_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_project uuid;
begin
  select project_id into v_project
  from nomad_shorts.jobs
  where id = p_job_id and type = 'render' and status = 'running';
  if v_project is null then
    raise exception '실행 중인 렌더 작업이 아닙니다' using errcode = '55000';
  end if;
  return v_project;
end;
$$;

-- Name: renders_guard_clean(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.renders_guard_clean() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if new.clean_status <> 'none'
     and (tg_op = 'INSERT' or old.clean_status = 'none')
     and exists (
       select 1 from nomad_shorts.sources s
       where s.project_id = new.project_id
         and s.used
         and (s.rights_basis is null or s.rights_basis not in ('own', 'seller', 'licensed'))
     ) then
    raise exception '권리를 확인하지 않은 원본(출처 표기 포함)이 있어 워터마크 제거를 할 수 없습니다'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

-- Name: request_step_change(uuid, integer); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.request_step_change(p_project_id uuid, p_step integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_uid uuid := auth.uid();
  v_status jsonb;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  if p_step is null or p_step not between 1 and 6 then
    raise exception '변경할 수 없는 단계입니다: %', p_step using errcode = '22023';
  end if;

  select step_status into v_status
  from nomad_shorts.projects
  where id = p_project_id and nomad_core.organization_role(organization_id) IN ('owner', 'admin', 'editor')
  for update;
  if not found then
    raise exception '프로젝트를 찾을 수 없거나 권한이 없습니다' using errcode = '42501';
  end if;

  if v_status ->> p_step::text not in ('ready', 'approved') then
    raise exception '준비 완료·승인 상태에서만 변경을 요청할 수 있습니다: %', v_status ->> p_step::text
      using errcode = '55000';
  end if;

  -- 이 단계는 change, 뒤 단계는 모두 idle 로 초기화(6장)
  select jsonb_object_agg(
           e.k,
           case
             when e.k::int = p_step then to_jsonb('change'::text)
             when e.k::int > p_step then to_jsonb('idle'::text)
             else e.v
           end)
  into v_status
  from jsonb_each(v_status) as e(k, v);

  update nomad_shorts.projects
  set step_status = v_status,
      current_step = p_step
  where id = p_project_id;

  -- 대본(03) 이하를 바꾸면 대본 승인도 풀린다
  if p_step <= 3 then
    update nomad_shorts.scripts set approved_at = null
    where project_id = p_project_id and approved_at is not null;
  end if;

  -- 초기화된 뒤 단계의 진행 중 작업 취소(17-5). 크레딧 반환(release)은 서버·워커가 jobs 상태를 보고 처리
  update nomad_shorts.jobs
  set status = 'canceled', finished_at = now()
  where project_id = p_project_id
    and step > p_step
    and status in ('queued', 'waiting_extension', 'running');

  insert into nomad_shorts.project_events (project_id, step, event)
  values (p_project_id, p_step, 'step_change_requested');

  return v_status;
end;
$$;

-- Name: retention_candidates(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.retention_candidates() RETURNS TABLE(kind text, id uuid, bucket text, path text, organization_id uuid, project_id uuid, due_on date)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  with proj as (
    select p.id, p.organization_id,
           exists (select 1 from nomad_shorts.publications pub
                   where pub.project_id = p.id and pub.status in ('scheduled', 'uploaded')) as published,
           (p.updated_at + interval '30 days')::date as active_until
    from nomad_shorts.projects p
  )
  select 'source'::text, s.id, 'shorts-sources'::text, s.file_path, pr.organization_id, pr.id,
         case when pr.published then s.purge_after else greatest(s.purge_after, pr.active_until) end
  from nomad_shorts.sources s join proj pr on pr.id = s.project_id
  where s.file_path is not null and s.file_deleted_at is null
  union all
  select 'thumbnail', s.id, 'shorts-thumbnails', s.thumbnail_path, pr.organization_id, pr.id,
         case when not s.checked and not s.used then (s.collected_at + interval '7 days')::date
              when pr.published then s.purge_after
              else greatest(s.purge_after, pr.active_until) end
  from nomad_shorts.sources s join proj pr on pr.id = s.project_id
  where s.thumbnail_path is not null and s.thumbnail_deleted_at is null
  union all
  select 'voice', t.id, 'shorts-voices', t.audio_path, pr.organization_id, pr.id,
         case when pr.published then t.purge_after else greatest(t.purge_after, pr.active_until) end
  from nomad_shorts.voice_takes t join proj pr on pr.id = t.project_id
  where t.audio_path is not null and t.file_deleted_at is null
  union all
  select 'render', r.id, 'shorts-renders', r.mp4_path, pr.organization_id, pr.id,
         case when pr.published then r.purge_after else greatest(r.purge_after, pr.active_until) end
  from nomad_shorts.renders r join proj pr on pr.id = r.project_id
  where r.mp4_path is not null and r.file_deleted_at is null;
$$;

-- Name: retention_confirm(text, uuid[], uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.retention_confirm(p_kind text, p_ids uuid[], p_token uuid) RETURNS SETOF uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_live timestamptz := now() - interval '30 minutes';
  v_ok uuid[];
begin
  if p_kind not in ('source', 'thumbnail', 'voice', 'render') then
    raise exception '알 수 없는 종류입니다' using errcode = '22023';
  end if;
  if p_token is null then
    raise exception '예약 토큰이 없습니다' using errcode = '22023';
  end if;
  if p_ids is null or cardinality(p_ids) = 0 then
    return;
  end if;
  if cardinality(p_ids) > 1000 then
    raise exception '한 번에 확인할 수 있는 개수를 넘었습니다' using errcode = '22023';
  end if;
  -- 발행 트리거와 같은 순서(id)로 잠근 뒤, 토큰·예약 시각·기준일을 최신 커밋으로 다시 판정한다
  if p_kind = 'source' then
    perform 1 from nomad_shorts.sources s where s.id = any (p_ids) order by s.id for update;
    select coalesce(array_agg(s.id), '{}') into v_ok from nomad_shorts.sources s
    where s.id = any (p_ids) and s.retention_token = p_token and s.retention_reserved_at > v_live;
  elsif p_kind = 'thumbnail' then
    perform 1 from nomad_shorts.sources s where s.id = any (p_ids) order by s.id for update;
    select coalesce(array_agg(s.id), '{}') into v_ok from nomad_shorts.sources s
    where s.id = any (p_ids) and s.thumbnail_retention_token = p_token and s.thumbnail_retention_reserved_at > v_live;
  elsif p_kind = 'voice' then
    perform 1 from nomad_shorts.voice_takes t where t.id = any (p_ids) order by t.id for update;
    select coalesce(array_agg(t.id), '{}') into v_ok from nomad_shorts.voice_takes t
    where t.id = any (p_ids) and t.retention_token = p_token and t.retention_reserved_at > v_live;
  else
    perform 1 from nomad_shorts.renders r where r.id = any (p_ids) order by r.id for update;
    select coalesce(array_agg(r.id), '{}') into v_ok from nomad_shorts.renders r
    where r.id = any (p_ids) and r.retention_token = p_token and r.retention_reserved_at > v_live;
  end if;

  select coalesce(array_agg(c.id), '{}') into v_ok
  from nomad_shorts_private.retention_candidates() c
  where c.kind = p_kind and c.id = any (v_ok) and c.due_on <= current_date;

  if p_kind = 'source' then
    update nomad_shorts.sources s set retention_deleting_at = now() where s.id = any (v_ok);
  elsif p_kind = 'thumbnail' then
    update nomad_shorts.sources s set thumbnail_retention_deleting_at = now() where s.id = any (v_ok);
  elsif p_kind = 'voice' then
    update nomad_shorts.voice_takes t set retention_deleting_at = now() where t.id = any (v_ok);
  else
    update nomad_shorts.renders r set retention_deleting_at = now() where r.id = any (v_ok);
  end if;
  return query select unnest(v_ok);
end;
$$;

-- Name: retention_due(integer, date, text, uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.retention_due(p_limit integer, p_after_due date DEFAULT NULL::date, p_after_kind text DEFAULT NULL::text, p_after_id uuid DEFAULT NULL::uuid) RETURNS TABLE(kind text, id uuid, bucket text, path text, organization_id uuid, project_id uuid, due_on date)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select c.kind, c.id, c.bucket, c.path, c.organization_id, c.project_id, c.due_on
  from nomad_shorts_private.retention_candidates() c
  where c.due_on <= current_date
    and (p_after_due is null
         or (c.due_on, c.kind, c.id) > (p_after_due, coalesce(p_after_kind, ''), coalesce(p_after_id, '00000000-0000-0000-0000-000000000000'::uuid)))
  order by c.due_on, c.kind, c.id
  limit greatest(1, least(coalesce(p_limit, 500), 1000));
$$;

-- Name: retention_mark_deleted(text, uuid[], uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.retention_mark_deleted(p_kind text, p_ids uuid[], p_token uuid) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_count integer;
begin
  if p_ids is null or cardinality(p_ids) = 0 then
    return 0;
  end if;
  if cardinality(p_ids) > 1000 then
    raise exception '한 번에 표시할 수 있는 개수를 넘었습니다' using errcode = '22023';
  end if;
  if p_token is null then
    raise exception '예약 토큰이 없습니다' using errcode = '22023';
  end if;
  case p_kind
    when 'source' then
      update nomad_shorts.sources
      set file_deleted_at = now(), retention_token = null, retention_reserved_at = null, retention_deleting_at = null
      where id = any (p_ids) and retention_token = p_token and retention_deleting_at is not null
        and file_path is not null and file_deleted_at is null;
    when 'thumbnail' then
      update nomad_shorts.sources
      set thumbnail_deleted_at = now(), thumbnail_retention_token = null, thumbnail_retention_reserved_at = null,
          thumbnail_retention_deleting_at = null
      where id = any (p_ids) and thumbnail_retention_token = p_token and thumbnail_retention_deleting_at is not null
        and thumbnail_path is not null and thumbnail_deleted_at is null;
    when 'voice' then
      update nomad_shorts.voice_takes
      set file_deleted_at = now(), retention_token = null, retention_reserved_at = null, retention_deleting_at = null
      where id = any (p_ids) and retention_token = p_token and retention_deleting_at is not null
        and audio_path is not null and file_deleted_at is null;
    when 'render' then
      update nomad_shorts.renders
      set file_deleted_at = now(), retention_token = null, retention_reserved_at = null, retention_deleting_at = null
      where id = any (p_ids) and retention_token = p_token and retention_deleting_at is not null
        and mp4_path is not null and file_deleted_at is null;
    else
      raise exception '알 수 없는 종류입니다' using errcode = '22023';
  end case;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Name: retention_reserve(text, uuid[]); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.retention_reserve(p_kind text, p_ids uuid[]) RETURNS TABLE(id uuid, path text, organization_id uuid, project_id uuid, token uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_token uuid := gen_random_uuid();
  v_ok uuid[];
begin
  if p_kind not in ('source', 'thumbnail', 'voice', 'render') then
    raise exception '알 수 없는 종류입니다' using errcode = '22023';
  end if;
  if p_ids is null or cardinality(p_ids) = 0 then
    return;
  end if;
  if cardinality(p_ids) > 1000 then
    raise exception '한 번에 예약할 수 있는 개수를 넘었습니다' using errcode = '22023';
  end if;
  -- 발행 트리거와 같은 순서(id)로 잠근다. 잠금을 얻은 뒤의 문장은 최신 커밋(발행 상태·기준일)을 본다.
  if p_kind in ('source', 'thumbnail') then
    perform 1 from nomad_shorts.sources s where s.id = any (p_ids) order by s.id for update;
  elsif p_kind = 'voice' then
    perform 1 from nomad_shorts.voice_takes t where t.id = any (p_ids) order by t.id for update;
  else
    perform 1 from nomad_shorts.renders r where r.id = any (p_ids) order by r.id for update;
  end if;

  select coalesce(array_agg(c.id), '{}') into v_ok
  from nomad_shorts_private.retention_candidates() c
  where c.kind = p_kind and c.id = any (p_ids) and c.due_on <= current_date;

  if p_kind = 'source' then
    update nomad_shorts.sources s set retention_token = v_token, retention_reserved_at = now() where s.id = any (v_ok);
  elsif p_kind = 'thumbnail' then
    update nomad_shorts.sources s set thumbnail_retention_token = v_token, thumbnail_retention_reserved_at = now()
    where s.id = any (v_ok);
  elsif p_kind = 'voice' then
    update nomad_shorts.voice_takes t set retention_token = v_token, retention_reserved_at = now() where t.id = any (v_ok);
  else
    update nomad_shorts.renders r set retention_token = v_token, retention_reserved_at = now() where r.id = any (v_ok);
  end if;

  return query
  select c.id, c.path, c.organization_id, c.project_id, v_token
  from nomad_shorts_private.retention_candidates() c
  where c.kind = p_kind and c.id = any (v_ok)
  order by c.id;
end;
$$;

-- Name: save_render(uuid, text, numeric, jsonb); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.save_render(p_job_id uuid, p_mp4_path text, p_duration_sec numeric, p_cut_map jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  v_project uuid := nomad_shorts_private.render_job_project(p_job_id);
  v_user uuid;
  v_target smallint;
  v_cuts jsonb;
  v_map jsonb;
  v_id uuid;
  v_version integer;
  v_inserted boolean;
begin
  -- 버전 번호를 겹치지 않게 프로젝트 행을 잠근다
  select organization_id, target_sec into v_user, v_target from nomad_shorts.projects where id = v_project for update;
  if p_mp4_path is null
     or p_mp4_path !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[A-Za-z0-9._-]{1,120}\.mp4$'
     or not starts_with(p_mp4_path, v_user::text || '/' || v_project::text || '/') then
    raise exception '영상 파일 경로가 올바르지 않습니다' using errcode = '22023';
  end if;
  if p_duration_sec is null or abs(p_duration_sec - v_target) > 0.1 then
    raise exception '영상 길이가 목표 길이와 다릅니다' using errcode = '22023';
  end if;
  if jsonb_typeof(p_cut_map) is distinct from 'object'
     or jsonb_typeof(p_cut_map -> 'cuts') is distinct from 'array'
     or jsonb_array_length(p_cut_map -> 'cuts') = 0
     or jsonb_array_length(p_cut_map -> 'cuts') > 20 then
    raise exception '컷 정보가 올바르지 않습니다' using errcode = '22023';
  end if;
  if exists (
       select 1 from jsonb_array_elements(p_cut_map -> 'cuts') c
       where jsonb_typeof(c) is distinct from 'object'
          or (c ->> 'source_id') is null
          or (c ->> 'source_id') !~ '^[0-9a-f-]{36}$'
          or not exists (select 1 from nomad_shorts_private.render_input_sources(v_project) s
                         where s.id::text = c ->> 'source_id')) then
    raise exception '편집에 쓸 수 없는 원본(권리 미확인·격리·삭제)이 컷에 있습니다' using errcode = '42501';
  end if;

  -- 컷 원본 스냅샷은 DB 값으로 덮어쓴다(워커 입력 무시)
  select jsonb_agg(c.value || jsonb_build_object('source_url', s.url, 'author', s.author,
                                                 'platform', s.platform, 'collected_at', s.collected_at)
                   order by c.ordinality)
    into v_cuts
  from jsonb_array_elements(p_cut_map -> 'cuts') with ordinality c
  join nomad_shorts_private.render_input_sources(v_project) s on s.id::text = c.value ->> 'source_id';
  v_map := p_cut_map || jsonb_build_object('cuts', v_cuts, 'credits', nomad_shorts_private.render_credits_text(v_cuts));

  select coalesce(max(version), 0) + 1 into v_version from nomad_shorts.renders where project_id = v_project;
  insert into nomad_shorts.renders (project_id, version, job_id, mp4_path, duration_sec, cut_map)
  values (v_project, v_version, p_job_id, p_mp4_path, p_duration_sec, v_map)
  on conflict (job_id) where job_id is not null do update
    set mp4_path = excluded.mp4_path, duration_sec = excluded.duration_sec, cut_map = excluded.cut_map
  returning id, version, (xmax = 0) into v_id, v_version, v_inserted;

  if v_inserted then
    insert into nomad_shorts.project_events (project_id, step, event) values (v_project, 5, 'render_succeeded');
  end if;
  return jsonb_build_object('id', v_id, 'version', v_version);
end;
$_$;

-- Name: save_source_scores(uuid, jsonb); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.save_source_scores(p_job_id uuid, p_results jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_project uuid := nomad_shorts_private.analyze_job_project(p_job_id);
  v_selecting boolean;
  v_total integer;
  v_valid integer;
  v_updated integer;
begin
  if jsonb_typeof(p_results) is distinct from 'array' then
    raise exception '결과는 배열이어야 합니다' using errcode = '22023';
  end if;

  -- 승인 함수와 직렬화(02 승인 여부를 읽는 사이 바뀌지 않게)
  select coalesce(step_status->>'2', '') <> 'approved' into v_selecting
  from nomad_shorts.projects where id = v_project
  for update;

  select count(*),
         count(*) filter (where s.id is not null
                            and (e->'score' = 'null'::jsonb
                                 or (jsonb_typeof(e->'score') = 'number' and (e->>'score')::numeric between 0 and 100))
                            and (e->'exclude_reason' is null or e->'exclude_reason' = 'null'::jsonb
                                 or (jsonb_typeof(e->'exclude_reason') = 'string'
                                     and length(e->>'exclude_reason') <= 200))
                            and (e->'quarantined' is null or jsonb_typeof(e->'quarantined') = 'boolean'))
    into v_total, v_valid
  from jsonb_array_elements(p_results) e
  left join nomad_shorts.sources s
    on s.project_id = v_project
   and s.id::text = e->>'id';
  if v_total <> v_valid then
    raise exception '저장할 수 없는 결과가 있습니다(다른 프로젝트 원본이거나 값 범위 밖)' using errcode = '22023';
  end if;

  update nomad_shorts.sources s
  set score = (e->>'score')::numeric,
      exclude_reason = e->>'exclude_reason',
      quarantined = coalesce((e->>'quarantined')::boolean,
                             (e->>'score') is null and (e->>'exclude_reason') is not null),
      checked = case when v_selecting then false else s.checked end
  from jsonb_array_elements(p_results) e
  where s.project_id = v_project and s.id::text = e->>'id';
  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;

-- Name: save_source_use(uuid, jsonb, boolean, text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.save_source_use(p_project_id uuid, p_uses jsonb, p_notice_ack boolean, p_reason text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_uid uuid := auth.uid();
  v_status jsonb := nomad_shorts_private.lock_source_step(p_project_id);
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_old_reason text;
  v_total integer;
  v_valid integer;
  v_problem text;
  v_next text;
begin
  if jsonb_typeof(p_uses) is distinct from 'array' then
    raise exception '사용 목록은 배열이어야 합니다' using errcode = '22023';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception '부족 사유는 500자까지 쓸 수 있습니다' using errcode = '22023';
  end if;

  select count(*),
         count(*) filter (where s.id is not null
                            and s.file_path is not null
                            and s.file_deleted_at is null
                            and not s.quarantined
                            and e->>'rights_basis' in ('attribution_notice', 'own', 'seller', 'licensed'))
    into v_total, v_valid
  from jsonb_array_elements(p_uses) e
  left join nomad_shorts.sources s
    on s.project_id = p_project_id
   and s.id::text = e->>'id';
  if v_total <> v_valid
     or v_total <> (select count(distinct e->>'id') from jsonb_array_elements(p_uses) e) then
    raise exception '사용할 수 없는 원본이 있습니다(내려받지 않았거나 격리됐거나 권리 근거가 없음)' using errcode = '22023';
  end if;

  update nomad_shorts.sources s
  set used = true,
      rights_basis = e->>'rights_basis',
      rights_confirmed_by = case when s.rights_basis is distinct from e->>'rights_basis' or s.rights_confirmed_at is null
                                 then v_uid else s.rights_confirmed_by end,
      rights_confirmed_at = case when s.rights_basis is distinct from e->>'rights_basis' or s.rights_confirmed_at is null
                                 then now() else s.rights_confirmed_at end
  from jsonb_array_elements(p_uses) e
  where s.project_id = p_project_id and s.id::text = e->>'id';

  update nomad_shorts.sources s
  set used = false, rights_basis = null, rights_confirmed_by = null, rights_confirmed_at = null
  where s.project_id = p_project_id
    and not exists (select 1 from jsonb_array_elements(p_uses) e where e->>'id' = s.id::text)
    and (s.used or s.rights_basis is not null);

  select sources_shortage_reason into v_old_reason from nomad_shorts.projects where id = p_project_id;
  update nomad_shorts.projects
  set sources_notice_ack_at = case when coalesce(p_notice_ack, false)
                                   then coalesce(sources_notice_ack_at, now()) end,
      sources_notice_ack_by = case when coalesce(p_notice_ack, false)
                                   then coalesce(sources_notice_ack_by, v_uid) end,
      sources_shortage_reason = v_reason
  where id = p_project_id;

  if v_reason is not null and v_reason is distinct from v_old_reason then
    insert into nomad_shorts.chat_messages (project_id, role, kind, text)
    values (p_project_id, 'user', 'text', '02 소스 부족 사유: ' || v_reason);
  end if;

  v_problem := nomad_shorts_private.source_approval_problem(p_project_id);
  v_next := case
    when v_problem is null then 'ready'
    when v_status ->> '2' = 'ready' then 'suggested'
    else v_status ->> '2'
  end;
  if v_next <> v_status ->> '2' then
    update nomad_shorts.projects
    set step_status = jsonb_set(step_status, '{2}', to_jsonb(v_next))
    where id = p_project_id
    returning step_status into v_status;
  end if;

  return jsonb_build_object('status', v_status, 'problem', v_problem);
end;
$$;

-- Name: save_video_metrics(uuid, date, date, jsonb); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.save_video_metrics(p_publication_id uuid, p_start date, p_end date, p_rows jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_link_id uuid;
  v_count integer;
begin
  if p_start is null or p_end is null or p_end < p_start or p_end - p_start > 40
     or jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array' then
    raise exception '잘못된 수집 범위입니다' using errcode = '22023';
  end if;
  if not exists (select 1 from nomad_shorts.publications pub where pub.id = p_publication_id and pub.status = 'uploaded') then
    raise exception '수집할 수 없는 발행입니다' using errcode = '55000';
  end if;
  select al.id into v_link_id
  from nomad_shorts.publications pub join nomad_shorts.affiliate_links al on al.project_id = pub.project_id
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
           (select count(*) from nomad_shorts.link_clicks lc
            where lc.affiliate_link_id = v_link_id and lc.counted
              and (lc.clicked_at at time zone 'America/Los_Angeles')::date = days.d)::integer as clicks,
           api.d is not null as has_api,
           vm.id is not null as has_row
    from days
    left join api on api.d = days.d
    left join nomad_shorts.video_metrics vm on vm.publication_id = p_publication_id and vm.date = days.d
  ), up as (
    insert into nomad_shorts.video_metrics (publication_id, date, views, avg_view_pct, link_clicks, est_revenue, collected_at)
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

-- Name: save_voice_take(uuid, text, text, numeric, jsonb, jsonb, jsonb); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.save_voice_take(p_job_id uuid, p_voice_id text, p_audio_path text, p_duration_sec numeric, p_sentences jsonb, p_words jsonb, p_pauses jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  v_project uuid := nomad_shorts_private.tts_job_project(p_job_id);
  v_user uuid;
  v_id uuid;
begin
  select organization_id into v_user from nomad_shorts.projects where id = v_project;
  if p_audio_path is null
     or p_audio_path !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[A-Za-z0-9._-]{1,120}$'
     or not starts_with(p_audio_path, v_user::text || '/' || v_project::text || '/') then
    raise exception '음성 파일 경로가 올바르지 않습니다' using errcode = '22023';
  end if;
  if p_voice_id is null or length(p_voice_id) not between 1 and 100 then
    raise exception '목소리 ID가 올바르지 않습니다' using errcode = '22023';
  end if;
  if p_duration_sec is null or p_duration_sec <= 0 or p_duration_sec > 600 then
    raise exception '음성 길이가 올바르지 않습니다' using errcode = '22023';
  end if;
  if jsonb_typeof(p_sentences) is distinct from 'array' or jsonb_typeof(p_words) is distinct from 'array'
     or jsonb_typeof(p_pauses) is distinct from 'array' then
    raise exception '타이밍은 배열이어야 합니다' using errcode = '22023';
  end if;

  insert into nomad_shorts.voice_takes (project_id, job_id, voice_id, source, audio_path, duration_sec, sentences, words, pauses)
  values (v_project, p_job_id, p_voice_id, 'tts', p_audio_path, p_duration_sec, p_sentences, p_words, p_pauses)
  on conflict (job_id) where job_id is not null do update
    set voice_id = excluded.voice_id, audio_path = excluded.audio_path, duration_sec = excluded.duration_sec,
        sentences = excluded.sentences, words = excluded.words, pauses = excluded.pauses
  returning id into v_id;
  return v_id;
end;
$_$;

-- Name: scripts_guard(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.scripts_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if current_user <> 'postgres' then
    if tg_op = 'INSERT' then
      new.approved_at := null;
    elsif new.approved_at is distinct from old.approved_at then
      raise exception 'approved_at은 단계 승인 함수로만 바꿀 수 있습니다' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

-- Name: scripts_lock_after_approval(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.scripts_lock_after_approval() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if tg_op = 'UPDATE' then
    if old.approved_at is not null
       and (new.lines, new.est_sec) is distinct from (old.lines, old.est_sec) then
      raise exception '승인된 대본은 바꿀 수 없습니다. 변경 요청으로 승인을 해제하세요'
        using errcode = '55000';
    end if;
  elsif exists (select 1 from nomad_shorts.projects p
                where p.id = new.project_id and p.step_status ->> '3' = 'approved') then
    raise exception '대본 단계가 승인된 동안 새 대본을 만들 수 없습니다. 변경 요청으로 승인을 해제하세요'
      using errcode = '55000';
  end if;
  return new;
end;
$$;

-- Name: set_internal_metrics(text, text); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.set_internal_metrics(p_url text, p_key text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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

-- Name: set_source_checks(uuid, uuid[]); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.set_source_checks(p_project_id uuid, p_source_ids uuid[]) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_ids uuid[] := coalesce(p_source_ids, '{}');
  v_found integer;
  v_checked integer;
begin
  perform nomad_shorts_private.lock_source_step(p_project_id);
  if cardinality(v_ids) > 10 then
    raise exception '다운로드는 10편까지 체크할 수 있습니다' using errcode = '22023';
  end if;
  select count(*) into v_found
  from nomad_shorts.sources s
  where s.project_id = p_project_id and s.id = any (v_ids);
  if v_found <> (select count(distinct x) from unnest(v_ids) as x) then
    raise exception '이 프로젝트의 원본이 아닙니다' using errcode = '22023';
  end if;

  update nomad_shorts.sources s
  set checked = (s.id = any (v_ids))
  where s.project_id = p_project_id and s.checked is distinct from (s.id = any (v_ids));

  select count(*) into v_checked from nomad_shorts.sources where project_id = p_project_id and checked;
  return v_checked;
end;
$$;

-- Name: set_updated_at(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Name: settle_job(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.settle_job(p_job_id uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_status text;
  v_reserve nomad_shorts.credit_ledger;
begin
  select status into v_status from nomad_shorts.jobs where id = p_job_id for update;
  if v_status is distinct from 'running' then
    return false;
  end if;

  select * into v_reserve from nomad_shorts.credit_ledger where job_id = p_job_id and kind = 'reserve';
  if not found then
    raise exception '예약 기록이 없는 작업입니다' using errcode = '55000';
  end if;

  update nomad_shorts.jobs set status = 'succeeded', finished_at = now(), error = null where id = p_job_id;

  insert into nomad_shorts.credit_ledger (organization_id, project_id, job_id, kind, delta, reason, idempotency_key)
  values (v_reserve.organization_id, v_reserve.project_id, p_job_id, 'settle', 0,
          'succeeded:' || (-v_reserve.delta), 'settle:' || p_job_id);
  return true;
end;
$$;

-- Name: source_approval_problem(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.source_approval_problem(p_project_id uuid) RETURNS text
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
  with u as (
    select count(*) as n
    from nomad_shorts.sources s
    where s.project_id = p_project_id
      and s.used
      and not s.quarantined
      and s.rights_basis is not null
      and s.rights_confirmed_at is not null
      and s.file_path is not null
      and s.file_deleted_at is null
  )
  select case
    when u.n < 3 then 'too_few'
    when u.n < 5 and coalesce(btrim(p.sources_shortage_reason), '') = '' then 'reason_required'
    when p.sources_notice_ack_at is null then 'notice_required'
  end
  from u
  cross join nomad_shorts.projects p
  where p.id = p_project_id;
$$;

-- Name: sources_guard(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.sources_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if tg_op = 'INSERT' then
    if current_user <> 'postgres' then
      new.rights_basis := null;
      new.rights_confirmed_by := null;
      new.rights_confirmed_at := null;
      new.quarantined := false;
    end if;
    if new.purge_after is null then
      new.purge_after := (new.collected_at + interval '30 days')::date;
    end if;
  elsif current_user <> 'postgres'
    and (new.rights_basis, new.rights_confirmed_by, new.rights_confirmed_at, new.quarantined)
        is distinct from (old.rights_basis, old.rights_confirmed_by, old.rights_confirmed_at, old.quarantined) then
    raise exception '권리·격리 열은 확인 함수로만 바꿀 수 있습니다' using errcode = '42501';
  end if;
  return new;
end;
$$;

-- Name: sweep_jobs(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.sweep_jobs() RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_timed_out integer;
  v_stale integer;
  v_waiting integer;
  v_released integer;
begin
  -- 1) 실행 시간 초과. 확장 작업은 claim 마다 started_at 을 새로 쓰므로 claim 마다 15분
  with t as (
    update nomad_shorts.jobs j
    set status = 'failed', finished_at = now(), error = '시간 초과'
    where j.status = 'running'
      and j.started_at < now() - nomad_shorts_private.job_time_limit(j.type)
    returning j.id
  )
  select count(*) into v_timed_out from t;

  -- 2) 확장 하트비트 2분 끊김(폐기·삭제된 확장 포함) → 대기로 되돌림. 이미 받은 행·파일은 그대로 둔다(진행분 보존)
  with t as (
    update nomad_shorts.jobs j
    set status = 'waiting_extension', extension_id = null, error = '확장 연결이 끊겼습니다'
    where j.status = 'running' and j.type in ('collect', 'collect_download')
      and not exists (select 1 from nomad_shorts.extension_connections e
                      where e.id = j.extension_id
                        and e.revoked_at is null
                        and greatest(e.last_heartbeat_at, j.started_at) >= now() - interval '2 minutes')
    returning j.id
  )
  select count(*) into v_stale from t;

  -- 3) 확장 대기 24시간: 대기 진입 시각(waiting_since, 없으면 생성 시각) 기준
  with t as (
    update nomad_shorts.jobs j
    set status = 'failed', finished_at = now(), error = '확장 대기 시간 초과'
    where j.status = 'waiting_extension'
      and coalesce(j.waiting_since, j.created_at) < now() - interval '24 hours'
    returning j.id
  )
  select count(*) into v_waiting from t;

  -- 4) 실패·취소인데 반환이 없는 예약분 반환
  with t as (
    insert into nomad_shorts.credit_ledger (organization_id, project_id, job_id, kind, delta, reason, idempotency_key)
    select r.organization_id, r.project_id, r.job_id, 'release', -r.delta, 'sweeper:' || j.status, 'release:' || r.job_id
    from nomad_shorts.credit_ledger r
    join nomad_shorts.jobs j on j.id = r.job_id
    where r.kind = 'reserve' and j.status in ('failed', 'canceled')
      and not exists (select 1 from nomad_shorts.credit_ledger f
                      where f.job_id = r.job_id and f.kind in ('settle', 'release'))
    on conflict do nothing
    returning 1
  )
  select count(*) into v_released from t;

  return jsonb_build_object('timed_out', v_timed_out, 'heartbeat_lost', v_stale,
                            'waiting_expired', v_waiting, 'released', v_released);
end;
$$;

-- Name: tts_job_context(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.tts_job_context(p_job_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_project uuid := nomad_shorts_private.tts_job_project(p_job_id);
  v_user uuid;
  v_lines jsonb;
begin
  select organization_id into v_user from nomad_shorts.projects where id = v_project;
  select s.lines into v_lines
  from nomad_shorts.scripts s
  where s.project_id = v_project and s.approved_at is not null
  order by s.version desc
  limit 1;
  return jsonb_build_object('project_id', v_project, 'organization_id', v_user, 'lines', coalesce(v_lines, '[]'::jsonb));
end;
$$;

-- Name: tts_job_project(uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.tts_job_project(p_job_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_project uuid;
begin
  select project_id into v_project
  from nomad_shorts.jobs
  where id = p_job_id and type = 'tts' and status = 'running';
  if v_project is null then
    raise exception '실행 중인 음성 생성 작업이 아닙니다' using errcode = '55000';
  end if;
  return v_project;
end;
$$;

-- Name: vault_secret_cleanup(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.vault_secret_cleanup() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_ref uuid;
begin
  if tg_table_name = 'accounts' then
    v_ref := old.oauth_token_ref;
  elsif tg_table_name = 'api_keys' then
    v_ref := old.secret_ref;
  end if;
  if v_ref is not null then
    delete from vault.secrets s where s.id = v_ref;
  end if;
  return old;
end;
$$;

-- Name: youtube_clear_token(uuid, uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.youtube_clear_token(p_account_id uuid, p_organization_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_acc nomad_shorts.accounts;
begin
  select a.* into v_acc from nomad_shorts.accounts a
  where a.id = p_account_id and a.platform = 'youtube'
  for update;
  if v_acc.id is null or (p_organization_id is not null and v_acc.organization_id <> p_organization_id) then
    raise exception '연결할 수 없는 계정입니다' using errcode = '42501';
  end if;
  -- p_organization_id 가 있으면 사용자 해제(슬롯 반환), 없으면 서버 내부 경로(만료와 같이 슬롯 유지)
  update nomad_shorts.accounts a
  set oauth_token_ref = null, status = 'reconnect_required',
      disconnected_at = case when p_organization_id is not null then now() else a.disconnected_at end
  where a.id = p_account_id;
  if v_acc.oauth_token_ref is not null then
    delete from vault.secrets s where s.id = v_acc.oauth_token_ref;
  end if;
  perform nomad_shorts_private.channel_slot_log(v_acc.organization_id, p_account_id,
                                   case when p_organization_id is not null then 'disconnect' else 'expire' end);
end;
$$;

-- Name: youtube_expire_token(uuid, uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.youtube_expire_token(p_account_id uuid, p_token_ref uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_user uuid;
begin
  if p_token_ref is null then
    return false;
  end if;
  update nomad_shorts.accounts a
  set oauth_token_ref = null, status = 'reconnect_required'
  where a.id = p_account_id and a.platform = 'youtube' and a.oauth_token_ref = p_token_ref
  returning a.organization_id into v_user;
  if not found then
    return false;
  end if;
  delete from vault.secrets s where s.id = p_token_ref;
  perform nomad_shorts_private.channel_slot_log(v_user, p_account_id, 'expire');
  return true;
end;
$$;

-- Name: youtube_quota_reset_at(); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.youtube_quota_reset_at() RETURNS timestamp with time zone
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
  select ((date_trunc('day', now() at time zone 'America/Los_Angeles') + interval '1 day')
          at time zone 'America/Los_Angeles') + interval '5 minutes';
$$;

-- Name: youtube_refresh_token(uuid, uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.youtube_refresh_token(p_account_id uuid, p_organization_id uuid) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_acc nomad_shorts.accounts;
begin
  select a.* into v_acc from nomad_shorts.accounts a
  where a.id = p_account_id and a.platform = 'youtube';
  if v_acc.id is null or (p_organization_id is not null and v_acc.organization_id <> p_organization_id) then
    raise exception '연결할 수 없는 계정입니다' using errcode = '42501';
  end if;
  if v_acc.oauth_token_ref is null then
    return null;
  end if;
  return (select d.decrypted_secret from vault.decrypted_secrets d where d.id = v_acc.oauth_token_ref);
end;
$$;

-- Name: youtube_save_connection(uuid, uuid, text, text, text[]); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.youtube_save_connection(p_organization_id uuid, p_account_id uuid, p_channel_id text, p_refresh_token text, p_scopes text[]) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_acc nomad_shorts.accounts;
  v_ref uuid;
  v_old uuid;
  v_token text := nullif(btrim(coalesce(p_refresh_token, '')), '');
  v_holding boolean;
  v_code text;
begin
  -- 같은 사용자의 동시 콜백은 줄 세운다(슬롯 수 판정 경쟁 방지)
  perform pg_advisory_xact_lock(hashtextextended('channel_slots:' || p_organization_id::text, 0));
  select a.* into v_acc from nomad_shorts.accounts a
  where a.id = p_account_id and a.organization_id = p_organization_id and a.platform = 'youtube'
  for update;
  if v_acc.id is null then
    raise exception '연결할 수 없는 계정입니다' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_channel_id, '')), '') is null then
    raise exception '채널 정보가 없습니다' using errcode = '22023';
  end if;
  if v_acc.external_channel_id is not null and v_acc.external_channel_id <> p_channel_id then
    raise exception '이 계정에 연결된 채널과 다른 채널입니다' using errcode = 'OA001';
  end if;
  if not (coalesce(p_scopes, '{}') @> array[
            'https://www.googleapis.com/auth/youtube.upload',
            'https://www.googleapis.com/auth/youtube.readonly',
            'https://www.googleapis.com/auth/yt-analytics.readonly']) then
    raise exception '필수 권한이 빠졌습니다' using errcode = 'OA002';
  end if;

  -- 이미 슬롯을 가진 행(같은 채널 재인증·만료 재연결)은 한도와 무관하게 통과
  v_holding := v_acc.external_channel_id is not null and v_acc.disconnected_at is null;
  if not v_holding then
    if exists (select 1 from nomad_shorts.accounts a
               where a.platform = 'youtube' and a.external_channel_id = p_channel_id
                 and a.id <> p_account_id and a.organization_id = p_organization_id) then
      perform nomad_shorts_private.channel_slot_log(p_organization_id, p_account_id, 'reject_duplicate');
      return 'CS003';
    end if;
    if exists (select 1 from nomad_shorts.accounts a
               where a.platform = 'youtube' and a.external_channel_id = p_channel_id
                 and a.organization_id <> p_organization_id) then
      raise exception '이미 다른 계정에 연결된 채널입니다' using errcode = '23505';
    end if;
    select s.code into v_code from nomad_shorts_private.channel_slot_status(p_organization_id, p_account_id) s;
    if v_code = 'CS001' then
      perform nomad_shorts_private.channel_slot_log(p_organization_id, p_account_id, 'reject_limit');
      return 'CS001';
    elsif v_code = 'CS002' then
      perform nomad_shorts_private.channel_slot_log(p_organization_id, p_account_id, 'reject_rotation');
      return 'CS002';
    end if;
  end if;

  v_ref := v_acc.oauth_token_ref;
  if v_ref is not null and not exists (select 1 from vault.secrets s where s.id = v_ref) then
    v_ref := null;
  end if;
  if v_token is not null then
    v_old := v_ref;
    v_ref := vault.create_secret(v_token, null, 'youtube refresh token');
  end if;

  update nomad_shorts.accounts a
  set external_channel_id = p_channel_id,
      oauth_token_ref = v_ref,
      status = case when v_ref is null then 'reconnect_required' else 'connected' end,
      first_connected_at = coalesce(a.first_connected_at, now()),
      disconnected_at = null
  where a.id = p_account_id;
  if v_old is not null then
    delete from vault.secrets s where s.id = v_old;
  end if;
  perform nomad_shorts_private.channel_slot_log(p_organization_id, p_account_id,
                                   case when v_holding then 'reconnect' else 'connect' end);
  return case when v_ref is null then 'reconnect_required' else 'connected' end;
end;
$$;

-- Name: youtube_tags_length(text[]); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.youtube_tags_length(p_tags text[]) RETURNS integer
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select coalesce(sum(char_length(t) + case when t ~ '[[:space:]]' then 2 else 0 end), 0)::int
         + greatest(coalesce(cardinality(p_tags), 0) - 1, 0)
  from unnest(coalesce(p_tags, '{}'::text[])) t;
$$;

-- Name: youtube_token_for(uuid, uuid); Type: FUNCTION; Schema: nomad_shorts_private; Owner: -
--

CREATE FUNCTION nomad_shorts_private.youtube_token_for(p_organization_id uuid, p_account_id uuid) RETURNS TABLE(token_ref uuid, refresh_token text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_acc nomad_shorts.accounts;
begin
  select a.* into v_acc from nomad_shorts.accounts a
  where a.id = p_account_id and a.platform = 'youtube';
  if v_acc.id is null or p_organization_id is null or v_acc.organization_id <> p_organization_id then
    raise exception '연결할 수 없는 계정입니다' using errcode = '42501';
  end if;
  if v_acc.oauth_token_ref is null then
    return;
  end if;
  return query
  select d.id, d.decrypted_secret from vault.decrypted_secrets d where d.id = v_acc.oauth_token_ref;
end;
$$;

-- Name: add_direct_source(uuid, text, text, text); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.add_direct_source(p_project_id uuid, p_url text, p_author text, p_title text) RETURNS uuid
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.add_direct_source(p_project_id, p_url, p_author, p_title);
$$;

-- Name: FUNCTION add_direct_source(p_project_id uuid, p_url text, p_author text, p_title text); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.add_direct_source(p_project_id uuid, p_url text, p_author text, p_title text) IS '사용자가 직접 추가한 원본(URL·작성자 필수). 권리 근거는 비워 둔다';

-- Name: approve_step(uuid, integer); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.approve_step(p_project_id uuid, p_step integer) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.approve_step(p_project_id, p_step);
$$;

-- Name: FUNCTION approve_step(p_project_id uuid, p_step integer); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.approve_step(p_project_id uuid, p_step integer) IS '사용자가 누른 단계 승인(1~5). Route Handler가 사용자 세션으로 호출';

-- Name: assign_bio_number(uuid, text); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.assign_bio_number(p_project_id uuid, p_service text) RETURNS integer
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.assign_bio_number(p_project_id, p_service);
$$;

-- Name: FUNCTION assign_bio_number(p_project_id uuid, p_service text); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.assign_bio_number(p_project_id uuid, p_service text) IS '링크인바이오 번호 받기(16-4, 채널별 1부터·재사용 없음)';

-- Name: channel_slot_status(uuid, uuid); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.channel_slot_status(p_organization_id uuid, p_account_id uuid DEFAULT NULL::uuid) RETURNS TABLE(slots integer, channel_limit integer, recent_new integer, allowed boolean, code text, next_at timestamp with time zone)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select * from nomad_shorts_private.channel_slot_status(p_organization_id, p_account_id);
$$;

-- Name: FUNCTION channel_slot_status(p_organization_id uuid, p_account_id uuid); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.channel_slot_status(p_organization_id uuid, p_account_id uuid) IS '채널 연결 사전 검사(서버 전용): 슬롯 수·한도·30일 새 연결 수·통과 여부·예상 코드(CS001·CS002)';

-- Name: chat_consume_proposal(uuid); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.chat_consume_proposal(p_proposal_id uuid) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.chat_consume_proposal(p_proposal_id);
$$;

-- Name: chat_create_proposal(uuid, uuid, text, jsonb); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.chat_create_proposal(p_organization_id uuid, p_project_id uuid, p_tool text, p_args jsonb) RETURNS uuid
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.chat_create_proposal(p_organization_id, p_project_id, p_tool, p_args);
$$;

-- Name: chat_start_collect(uuid, text, text, text); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.chat_start_collect(p_project_id uuid, p_platform text, p_query text, p_idempotency_key text) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.chat_start_collect(p_project_id, p_platform, p_query, p_idempotency_key);
$$;

-- Name: FUNCTION chat_start_collect(p_project_id uuid, p_platform text, p_query text, p_idempotency_key text); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.chat_start_collect(p_project_id uuid, p_platform text, p_query text, p_idempotency_key text) IS '제작 파트너 소스 검색: 탐색 회차(최대 3, CR003) 검사와 collect 작업 생성을 프로젝트 행 잠금 안에서 한 번에';

-- Name: confirm_policy_check(uuid, text, boolean); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.confirm_policy_check(p_project_id uuid, p_item text, p_checked boolean) RETURNS void
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.confirm_policy_check(p_project_id, p_item, p_checked);
$$;

-- Name: FUNCTION confirm_policy_check(p_project_id uuid, p_item text, p_checked boolean); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.confirm_policy_check(p_project_id uuid, p_item text, p_checked boolean) IS '사용자 체크(출처 표기·고지 / 링크인바이오 등록 완료). 사용자가 누른 요청만';

-- Name: create_job(uuid, text, text, jsonb); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.create_job(p_project_id uuid, p_type text, p_idempotency_key text, p_payload jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.create_job(p_project_id, p_type, p_idempotency_key, p_payload);
$$;

-- Name: FUNCTION create_job(p_project_id uuid, p_type text, p_idempotency_key text, p_payload jsonb); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.create_job(p_project_id uuid, p_type text, p_idempotency_key text, p_payload jsonb) IS '작업 생성(17-5). 단계는 종류로 결정, 단계 위반 55000, 같은 키 재요청은 기존 작업(다른 작업이면 JK001), 종류별 대기 상한 초과 JQ001, 잔액 부족 CR001. Route Handler가 사용자 세션으로 호출';

-- Name: edit_input_sources(uuid); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.edit_input_sources(p_project_id uuid) RETURNS SETOF nomad_shorts.sources
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
  select s.*
  from nomad_shorts.sources s
  join nomad_shorts.projects p on p.id = s.project_id
  where s.project_id = p_project_id
    and s.used
    and not s.quarantined
    and s.rights_basis is not null
    and s.rights_confirmed_at is not null
    and s.file_path is not null
    and s.file_deleted_at is null
    and (s.rights_basis <> 'attribution_notice' or p.sources_notice_ack_at is not null)
  order by s.score desc nulls last, s.id;
$$;

-- Name: FUNCTION edit_input_sources(p_project_id uuid); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.edit_input_sources(p_project_id uuid) IS '05 편집 입력 원본. 권리 근거 확인·사용·내려받은 원본만(미확인 제외)';

-- Name: extension_claim_job(uuid, uuid); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.extension_claim_job(p_extension_id uuid, p_job_id uuid) RETURNS TABLE(id uuid, type text, payload jsonb)
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select * from nomad_shorts_private.ext_claim_job(p_extension_id, p_job_id);
$$;

-- Name: FUNCTION extension_claim_job(p_extension_id uuid, p_job_id uuid); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.extension_claim_job(p_extension_id uuid, p_job_id uuid) IS '확장 작업 claim(서버 전용). 성공 1행, 실패 0행';

-- Name: extension_collect_download(uuid, uuid, jsonb); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.extension_collect_download(p_extension_id uuid, p_job_id uuid, p_files jsonb) RETURNS integer
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.ext_collect_download(p_extension_id, p_job_id, p_files);
$$;

-- Name: FUNCTION extension_collect_download(p_extension_id uuid, p_job_id uuid, p_files jsonb); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.extension_collect_download(p_extension_id uuid, p_job_id uuid, p_files jsonb) IS '확장 다운로드 파일 기록(서버 전용). 체크된 원본에만';

-- Name: extension_collect_list(uuid, uuid, jsonb); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.extension_collect_list(p_extension_id uuid, p_job_id uuid, p_items jsonb) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.ext_collect_list(p_extension_id, p_job_id, p_items);
$$;

-- Name: FUNCTION extension_collect_list(p_extension_id uuid, p_job_id uuid, p_items jsonb); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.extension_collect_list(p_extension_id uuid, p_job_id uuid, p_items jsonb) IS '확장 목록 수집 입력(서버 전용). platform·수집 시각은 서버가 정한다';

-- Name: extension_heartbeat(uuid); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.extension_heartbeat(p_extension_id uuid) RETURNS TABLE(id uuid, type text, payload jsonb)
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select * from nomad_shorts_private.ext_heartbeat(p_extension_id);
$$;

-- Name: FUNCTION extension_heartbeat(p_extension_id uuid); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.extension_heartbeat(p_extension_id uuid) IS '확장 하트비트(서버 전용). 대기 수집 작업 1건을 돌려준다';

-- Name: mark_step_ready(uuid, integer, text); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.mark_step_ready(p_project_id uuid, p_step integer, p_status text) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.mark_step_ready(p_project_id, p_step, p_status);
$$;

-- Name: FUNCTION mark_step_ready(p_project_id uuid, p_step integer, p_status text); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.mark_step_ready(p_project_id uuid, p_step integer, p_status text) IS 'AI 결과 도착 시 단계를 suggested·ready로(approved 불가). 서버가 사용자 세션으로 호출';

-- Name: metrics_run_finish(bigint, integer, integer, text); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.metrics_run_finish(p_id bigint, p_ok integer, p_skipped integer, p_error text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  update nomad_shorts_private.metrics_runs
  set finished_at = now(), ok = greatest(coalesce(p_ok, 0), 0), skipped = greatest(coalesce(p_skipped, 0), 0),
      error = left(p_error, 200)
  where id = p_id and finished_at is null;
$$;

-- Name: metrics_run_start(); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.metrics_run_start() RETURNS bigint
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  insert into nomad_shorts_private.metrics_runs default values returning id;
$$;

-- Name: metrics_targets(); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.metrics_targets() RETURNS TABLE(publication_id uuid, account_id uuid, organization_id uuid, platform_video_id text, published_at timestamp with time zone)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select * from nomad_shorts_private.metrics_targets();
$$;

-- Name: oauth_state_consume(uuid, text); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.oauth_state_consume(p_organization_id uuid, p_state_hash text) RETURNS TABLE(account_id uuid, code_verifier text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select * from nomad_shorts_private.oauth_state_consume(p_organization_id, p_state_hash);
$$;

-- Name: oauth_state_create(uuid, uuid, text, text); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.oauth_state_create(p_organization_id uuid, p_account_id uuid, p_state_hash text, p_verifier text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.oauth_state_create(p_organization_id, p_account_id, p_state_hash, p_verifier);
$$;

-- Name: prepare_publication(uuid, text, timestamp with time zone, text, text, text[], boolean, boolean); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.prepare_publication(p_project_id uuid, p_mode text, p_scheduled_at timestamp with time zone, p_title text, p_body text, p_hashtags text[], p_purchase_guide boolean, p_pin_comment boolean) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.prepare_publication(p_project_id, p_mode, p_scheduled_at, p_title, p_body,
                                     p_hashtags, p_purchase_guide, p_pin_comment);
$$;

-- Name: FUNCTION prepare_publication(p_project_id uuid, p_mode text, p_scheduled_at timestamp with time zone, p_title text, p_body text, p_hashtags text[], p_purchase_guide boolean, p_pin_comment boolean); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.prepare_publication(p_project_id uuid, p_mode text, p_scheduled_at timestamp with time zone, p_title text, p_body text, p_hashtags text[], p_purchase_guide boolean, p_pin_comment boolean) IS '발행 준비 저장(6/6 통과 시만). 업로드는 task-024';

-- Name: publication_attempt_fail(uuid, uuid, text, text); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.publication_attempt_fail(p_publication_id uuid, p_attempt_token uuid, p_kind text, p_code text) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$ select nomad_shorts_private.publication_attempt_fail(p_publication_id, p_attempt_token, p_kind, p_code); $$;

-- Name: publication_claim(); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.publication_claim() RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$ select nomad_shorts_private.publication_claim(); $$;

-- Name: FUNCTION publication_claim(); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.publication_claim() IS '업로드 선점(6/6 재판정 + uploading 전환 + 시도 토큰). 업로더(service_role) 전용';

-- Name: publication_confirm_absent(uuid); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.publication_confirm_absent(p_project_id uuid) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$ select nomad_shorts_private.publication_confirm_absent(p_project_id); $$;

-- Name: FUNCTION publication_confirm_absent(p_project_id uuid); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.publication_confirm_absent(p_project_id uuid) IS '결과 불명(needs_check)에서 사용자가 Studio 에 영상이 없음을 확인 → 세션 폐기·새 업로드. 사용자 세션으로 호출';

-- Name: publication_finish(uuid, uuid, text, boolean); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.publication_finish(p_publication_id uuid, p_attempt_token uuid, p_video_id text, p_test_private boolean) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$ select nomad_shorts_private.publication_finish(p_publication_id, p_attempt_token, p_video_id, p_test_private); $$;

-- Name: publication_reject_copy(uuid, uuid, text); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.publication_reject_copy(p_publication_id uuid, p_attempt_token uuid, p_code text) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$ select nomad_shorts_private.publication_reject_copy(p_publication_id, p_attempt_token, p_code); $$;

-- Name: publication_resume_check(uuid, uuid); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.publication_resume_check(p_publication_id uuid, p_attempt_token uuid) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$ select nomad_shorts_private.publication_resume_check(p_publication_id, p_attempt_token); $$;

-- Name: FUNCTION publication_resume_check(p_publication_id uuid, p_attempt_token uuid); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.publication_resume_check(p_publication_id uuid, p_attempt_token uuid) IS '이어 올리기 직전 예약 시각·정책 재판정(세션 있는 시도, 미통과면 needs_check). 업로더(service_role) 전용';

-- Name: publication_retry(uuid); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.publication_retry(p_project_id uuid) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$ select nomad_shorts_private.publication_retry(p_project_id); $$;

-- Name: FUNCTION publication_retry(p_project_id uuid); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.publication_retry(p_project_id uuid) IS '업로드 다시 시도(소유자, failed·reconnect_wait). needs_check 는 publication_confirm_absent 로만';

-- Name: publication_session_begin(uuid, uuid); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.publication_session_begin(p_publication_id uuid, p_attempt_token uuid) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$ select nomad_shorts_private.publication_session_begin(p_publication_id, p_attempt_token); $$;

-- Name: publication_session_save(uuid, uuid, text, bigint); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.publication_session_save(p_publication_id uuid, p_attempt_token uuid, p_session_uri text, p_total_bytes bigint) RETURNS void
    LANGUAGE sql
    SET search_path TO ''
    AS $$ select nomad_shorts_private.publication_session_save(p_publication_id, p_attempt_token, p_session_uri, p_total_bytes); $$;

-- Name: publish_policy(uuid, text, text, text[]); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.publish_policy(p_project_id uuid, p_title text, p_body text, p_hashtags text[]) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.publish_policy(p_project_id, p_title, p_body, p_hashtags);
$$;

-- Name: FUNCTION publish_policy(p_project_id uuid, p_title text, p_body text, p_hashtags text[]); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.publish_policy(p_project_id uuid, p_title text, p_body text, p_hashtags text[]) IS '06 정책 점검 6항목 판정(15-4) + 설명란 조각. 사용자 세션으로 호출';

-- Name: publish_recheck(uuid); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.publish_recheck(p_project_id uuid) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.publish_recheck(p_project_id);
$$;

-- Name: FUNCTION publish_recheck(p_project_id uuid); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.publish_recheck(p_project_id uuid) IS '업로드 직전 정책 6/6 재판정(저장된 문구). 서버(service_role, task-024) 전용, 미통과면 발행 준비 무효화';

-- Name: queue_health(); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.queue_health() RETURNS TABLE(queue_name text, queue_length bigint, oldest_msg_age_sec integer, queued bigint, running bigint)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select m.queue_name, m.queue_length, m.oldest_msg_age_sec,
         (select count(*) from nomad_shorts.jobs j where j.type = m.queue_name and j.status = 'queued'),
         (select count(*) from nomad_shorts.jobs j where j.type = m.queue_name and j.status = 'running')
  from pgmq.metrics_all() m
  where m.queue_name in ('shorts_render', 'shorts_tts', 'shorts_analyze')
  order by m.queue_name;
$$;

-- Name: FUNCTION queue_health(); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.queue_health() IS '큐별 적체(17-5-1): 메시지 수·가장 오래 기다린 초·queued·running 작업 수. service_role 전용, 감시 작업이 읽는다';

-- Name: record_link_click(text, text, text, text); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.record_link_click(p_code text, p_ip text, p_ref_host text, p_platform text) RETURNS TABLE(url text, program text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
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
  from nomad_shorts.affiliate_links al where al.short_url = p_code;
  -- naver.me 단축 주소로는 보내지 않으므로(404) 클릭도 기록하지 않는다
  if v_link_id is null or v_url is null or v_url ~* '^https://([a-z0-9-]+\.)*naver\.me([/?#]|$)' then
    return;
  end if;

  select s.salt into v_salt from nomad_shorts_private.click_salts s where s.day = v_day;
  if v_salt is null then
    insert into nomad_shorts_private.click_salts (day, salt) values (v_day, extensions.gen_random_bytes(32))
    on conflict do nothing;
    select s.salt into v_salt from nomad_shorts_private.click_salts s where s.day = v_day;
  end if;
  -- IP 만(UA 제외). IP 원문은 저장하지 않는다
  v_hash := encode(extensions.hmac(convert_to(coalesce(nullif(p_ip, ''), 'unknown'), 'UTF8'), v_salt, 'sha256'), 'hex');

  -- 같은 링크·같은 방문자의 동시 요청을 줄 세운다(중복 판정과 삽입 사이 경쟁 방지, 트랜잭션 끝에 풀림)
  perform pg_advisory_xact_lock(hashtextextended(v_link_id::text || v_hash, 0));

  -- 속도 제한: 같은 방문자의 최근 10분 기록이 30개 이상이면 기록하지 않고 이동만
  if (select count(*) from nomad_shorts.link_clicks c
      where c.visitor_hash = v_hash and c.clicked_at > now() - interval '10 minutes') < 30 then
    insert into nomad_shorts.link_clicks (affiliate_link_id, short_url, referrer, platform, visitor_hash, counted)
    values (
      v_link_id,
      p_code,
      left(nullif(lower(btrim(coalesce(p_ref_host, ''))), ''), 255),
      case when p_platform in ('youtube', 'instagram', 'tiktok', 'inpock', 'litly') then p_platform else 'other' end,
      v_hash,
      not exists (select 1 from nomad_shorts.link_clicks c
                  where c.affiliate_link_id = v_link_id and c.visitor_hash = v_hash
                    and c.clicked_at > now() - interval '10 minutes')
    );
  end if;

  url := v_url;
  program := v_program;
  return next;
end;
$_$;

-- Name: request_step_change(uuid, integer); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.request_step_change(p_project_id uuid, p_step integer) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.request_step_change(p_project_id, p_step);
$$;

-- Name: FUNCTION request_step_change(p_project_id uuid, p_step integer); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.request_step_change(p_project_id uuid, p_step integer) IS '사용자가 누른 변경 요청. 뒤 단계 초기화·진행 작업 취소';

-- Name: retention_confirm(text, uuid[], uuid); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.retention_confirm(p_kind text, p_ids uuid[], p_token uuid) RETURNS SETOF uuid
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.retention_confirm(p_kind, p_ids, p_token);
$$;

-- Name: FUNCTION retention_confirm(p_kind text, p_ids uuid[], p_token uuid); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.retention_confirm(p_kind text, p_ids uuid[], p_token uuid) IS 'Storage 삭제 직전 재판정(토큰·예약 30분·기준일)과 삭제 중 시각 기록(task-024b). 서버 retention(service_role) 전용';

-- Name: retention_due(integer, date, text, uuid); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.retention_due(p_limit integer, p_after_due date DEFAULT NULL::date, p_after_kind text DEFAULT NULL::text, p_after_id uuid DEFAULT NULL::uuid) RETURNS TABLE(kind text, id uuid, bucket text, path text, organization_id uuid, project_id uuid, due_on date)
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select * from nomad_shorts_private.retention_due(p_limit, p_after_due, p_after_kind, p_after_id);
$$;

-- Name: FUNCTION retention_due(p_limit integer, p_after_due date, p_after_kind text, p_after_id uuid); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.retention_due(p_limit integer, p_after_due date, p_after_kind text, p_after_id uuid) IS '보관 기간이 지난 파일 목록, (due_on, kind, id) 커서 페이지(task-024b). 서버 retention(service_role) 전용';

-- Name: retention_mark_deleted(text, uuid[], uuid); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.retention_mark_deleted(p_kind text, p_ids uuid[], p_token uuid) RETURNS integer
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.retention_mark_deleted(p_kind, p_ids, p_token);
$$;

-- Name: FUNCTION retention_mark_deleted(p_kind text, p_ids uuid[], p_token uuid); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.retention_mark_deleted(p_kind text, p_ids uuid[], p_token uuid) IS 'Storage 삭제 성공 뒤 같은 예약 토큰 행만 *_deleted_at 기록(task-024b). 서버 retention(service_role) 전용';

-- Name: retention_reserve(text, uuid[]); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.retention_reserve(p_kind text, p_ids uuid[]) RETURNS TABLE(id uuid, path text, organization_id uuid, project_id uuid, token uuid)
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select * from nomad_shorts_private.retention_reserve(p_kind, p_ids);
$$;

-- Name: FUNCTION retention_reserve(p_kind text, p_ids uuid[]); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.retention_reserve(p_kind text, p_ids uuid[]) IS 'Storage 삭제 직전 행 잠금·재판정·예약 토큰(task-024b). 서버 retention(service_role) 전용';

-- Name: save_source_use(uuid, jsonb, boolean, text); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.save_source_use(p_project_id uuid, p_uses jsonb, p_notice_ack boolean, p_reason text) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.save_source_use(p_project_id, p_uses, p_notice_ack, p_reason);
$$;

-- Name: FUNCTION save_source_use(p_project_id uuid, p_uses jsonb, p_notice_ack boolean, p_reason text); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.save_source_use(p_project_id uuid, p_uses jsonb, p_notice_ack boolean, p_reason text) IS '사용자가 누른 사용 선택·권리 근거·고지 확인·부족 사유 저장. 02 상태를 ready/suggested 로 다시 계산';

-- Name: save_video_metrics(uuid, date, date, jsonb); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.save_video_metrics(p_publication_id uuid, p_start date, p_end date, p_rows jsonb) RETURNS integer
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.save_video_metrics(p_publication_id, p_start, p_end, p_rows);
$$;

-- Name: set_source_checks(uuid, uuid[]); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.set_source_checks(p_project_id uuid, p_source_ids uuid[]) RETURNS integer
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.set_source_checks(p_project_id, p_source_ids);
$$;

-- Name: FUNCTION set_source_checks(p_project_id uuid, p_source_ids uuid[]); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.set_source_checks(p_project_id uuid, p_source_ids uuid[]) IS '사용자가 누른 다운로드 체크(10편까지). Route Handler·서버 액션이 사용자 세션으로 호출';

-- Name: youtube_clear_token(uuid, uuid); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.youtube_clear_token(p_account_id uuid, p_organization_id uuid DEFAULT NULL::uuid) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.youtube_clear_token(p_account_id, p_organization_id);
$$;

-- Name: youtube_expire_token(uuid, uuid); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.youtube_expire_token(p_account_id uuid, p_token_ref uuid) RETURNS boolean
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.youtube_expire_token(p_account_id, p_token_ref);
$$;

-- Name: youtube_refresh_token(uuid, uuid); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.youtube_refresh_token(p_account_id uuid, p_organization_id uuid DEFAULT NULL::uuid) RETURNS text
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.youtube_refresh_token(p_account_id, p_organization_id);
$$;

-- Name: FUNCTION youtube_refresh_token(p_account_id uuid, p_organization_id uuid); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.youtube_refresh_token(p_account_id uuid, p_organization_id uuid) IS 'YouTube 갱신 토큰 원문(서버 전용, service_role). 브라우저·로그로 내보내지 않는다';

-- Name: youtube_save_connection(uuid, uuid, text, text, text[]); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.youtube_save_connection(p_organization_id uuid, p_account_id uuid, p_channel_id text, p_refresh_token text, p_scopes text[]) RETURNS text
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select nomad_shorts_private.youtube_save_connection(p_organization_id, p_account_id, p_channel_id, p_refresh_token, p_scopes);
$$;

-- Name: youtube_token_for(uuid, uuid); Type: FUNCTION; Schema: nomad_shorts; Owner: -
--

CREATE FUNCTION nomad_shorts.youtube_token_for(p_organization_id uuid, p_account_id uuid) RETURNS TABLE(token_ref uuid, refresh_token text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select * from nomad_shorts_private.youtube_token_for(p_organization_id, p_account_id);
$$;

-- Name: FUNCTION youtube_token_for(p_organization_id uuid, p_account_id uuid); Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON FUNCTION nomad_shorts.youtube_token_for(p_organization_id uuid, p_account_id uuid) IS 'YouTube 갱신 토큰 원문 + 버전(서버 전용, 소유자 확인). 브라우저·로그로 내보내지 않는다';

-- Name: channel_quotas; Type: TABLE; Schema: nomad_shorts_private; Owner: -
--

CREATE TABLE nomad_shorts_private.channel_quotas (
    organization_id uuid NOT NULL,
    channel_limit integer NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT channel_quotas_channel_limit_check CHECK (((channel_limit >= 1) AND (channel_limit <= 50)))
);

-- Name: TABLE channel_quotas; Type: COMMENT; Schema: nomad_shorts_private; Owner: -
--

COMMENT ON TABLE nomad_shorts_private.channel_quotas IS '사용자별 채널 연결 한도(행 없음 = 1). 함수로만 읽는다. 요금제·구독은 P1 결제 작업';

-- Name: click_salts; Type: TABLE; Schema: nomad_shorts_private; Owner: -
--

CREATE TABLE nomad_shorts_private.click_salts (
    day date NOT NULL,
    salt bytea NOT NULL
);

-- Name: TABLE click_salts; Type: COMMENT; Schema: nomad_shorts_private; Owner: -
--

COMMENT ON TABLE nomad_shorts_private.click_salts IS '클릭 방문자 해시용 날짜별(UTC) 소금. 함수 전용, 지난 날짜는 정리 cron 이 삭제';

-- Name: metrics_runs; Type: TABLE; Schema: nomad_shorts_private; Owner: -
--

CREATE TABLE nomad_shorts_private.metrics_runs (
    id bigint NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    ok integer DEFAULT 0 NOT NULL,
    skipped integer DEFAULT 0 NOT NULL,
    error text
);

-- Name: TABLE metrics_runs; Type: COMMENT; Schema: nomad_shorts_private; Owner: -
--

COMMENT ON TABLE nomad_shorts_private.metrics_runs IS '성과 수집 실행 기록(시작·끝·성공·건너뜀·오류). 30일 보관';

-- Name: metrics_runs_id_seq; Type: SEQUENCE; Schema: nomad_shorts_private; Owner: -
--

ALTER TABLE nomad_shorts_private.metrics_runs ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME nomad_shorts_private.metrics_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

-- Name: accounts; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    platform text NOT NULL,
    channel_name text NOT NULL,
    category_id uuid,
    tone text,
    target text,
    weekly_goal integer DEFAULT 0 NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    oauth_token_ref uuid,
    status text DEFAULT 'reconnect_required'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_bio_no integer DEFAULT 0 NOT NULL,
    external_channel_id text,
    first_connected_at timestamp with time zone,
    disconnected_at timestamp with time zone,
    CONSTRAINT accounts_last_bio_no_check CHECK ((last_bio_no >= 0)),
    CONSTRAINT accounts_platform_check CHECK ((platform = ANY (ARRAY['youtube'::text, 'instagram'::text, 'tiktok'::text, 'xiaohongshu'::text]))),
    CONSTRAINT accounts_status_check CHECK ((status = ANY (ARRAY['connected'::text, 'reconnect_required'::text]))),
    CONSTRAINT accounts_weekly_goal_check CHECK ((weekly_goal >= 0))
);

-- Name: TABLE accounts; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.accounts IS '운영 채널(다중 계정, planning 12장). oauth_token_ref는 Vault id이며 authenticated 읽기 불가';

-- Name: COLUMN accounts.last_bio_no; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.accounts.last_bio_no IS '링크인바이오 번호 발급 최대값(16-4 재사용 금지). assign_bio_number 전용';

-- Name: COLUMN accounts.external_channel_id; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.accounts.external_channel_id IS '플랫폼 채널 id(YouTube channels.list mine=true). 서버(SR)만 쓰고 authenticated 는 읽지 못한다. 재연결 시 다른 채널이면 거부';

-- Name: COLUMN accounts.first_connected_at; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.accounts.first_connected_at IS '처음 external_channel_id 를 저장한 시각(이후 불변). 30일 새 채널 연결 수·초과 채널 순위. 서버 전용';

-- Name: COLUMN accounts.disconnected_at; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.accounts.disconnected_at IS '사용자 해제 시각(슬롯 반환). 재연결하면 null. 토큰 만료는 여기에 쓰지 않는다. 서버 전용';

-- Name: affiliate_links; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.affiliate_links (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    program text NOT NULL,
    url text,
    short_url text,
    partner_id_ref text,
    disclosed boolean DEFAULT true NOT NULL,
    bio_service text,
    bio_no integer,
    bio_registered_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT affiliate_links_bio_no_check CHECK ((bio_no >= 1)),
    CONSTRAINT affiliate_links_bio_service_check CHECK ((bio_service = ANY (ARRAY['inpock'::text, 'litly'::text, 'linktree'::text]))),
    CONSTRAINT affiliate_links_program_check CHECK ((program = ANY (ARRAY['coupang_partners'::text, 'naver_shopping_connect'::text, 'ohouse_curator'::text, 'musinsa_curator'::text, 'oliveyoung_curator'::text, 'youtube_shopping'::text, 'aliexpress'::text, 'none'::text]))),
    CONSTRAINT affiliate_links_url_check CHECK ((url ~* '^https://([a-z0-9-]+\.)*(coupang\.com|coupa\.ng|naver\.com|naver\.me|ohou\.se|musinsa\.com|oliveyoung\.co\.kr|youtube\.com|aliexpress\.com)(/[^\s]*)?$'::text))
);

-- Name: TABLE affiliate_links; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.affiliate_links IS '제휴 링크. 본인은 program·disclosed·bio 열만, url·short_url은 서버(SR)만';

-- Name: api_keys; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.api_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    provider text NOT NULL,
    secret_ref uuid,
    last4 text,
    status text DEFAULT 'unregistered'::text NOT NULL,
    tested_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT api_keys_last4_check CHECK ((char_length(last4) <= 4)),
    CONSTRAINT api_keys_provider_check CHECK ((provider = ANY (ARRAY['anthropic'::text, 'openai'::text, 'fish_audio'::text, 'elevenlabs'::text, 'fal'::text]))),
    CONSTRAINT api_keys_status_check CHECK ((status = ANY (ARRAY['unregistered'::text, 'registered'::text, 'verified'::text])))
);

-- Name: TABLE api_keys; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.api_keys IS '사용자 API 키 메타. 원문은 Vault, 쓰기는 서버(SR)만, 본인은 last4·status·tested_at만 읽기';

-- Name: bio_items; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.bio_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    bio_page_id uuid NOT NULL,
    project_id uuid,
    no integer NOT NULL,
    affiliate_link_id uuid,
    short_url text,
    title text,
    thumb_url text,
    registered_at timestamp with time zone,
    archived_at timestamp with time zone,
    CONSTRAINT bio_items_no_check CHECK ((no >= 1))
);

-- Name: TABLE bio_items; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.bio_items IS '링크인바이오 번호 항목. 본인 읽기만, 쓰기는 assign_bio_number·confirm_policy_check 함수 전용';

-- Name: bio_pages; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.bio_pages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    account_id uuid NOT NULL,
    service text NOT NULL,
    url text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bio_pages_service_check CHECK ((service = ANY (ARRAY['inpock'::text, 'litly'::text, 'linktree'::text])))
);

-- Name: TABLE bio_pages; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.bio_pages IS '채널별 링크인바이오 페이지(인포크링크·리틀리). 본인 읽기·쓰기';

-- Name: categories; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.categories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    keywords_ko text[] DEFAULT '{}'::text[] NOT NULL,
    keywords_en text[] DEFAULT '{}'::text[] NOT NULL,
    keywords_zh text[] DEFAULT '{}'::text[] NOT NULL,
    banned_terms text[] DEFAULT '{}'::text[] NOT NULL
);

-- Name: TABLE categories; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.categories IS '카테고리 10종(planning 11장). 로그인 읽기 전용, 쓰기는 서버(SR)만';

-- Name: channel_slot_events; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.channel_slot_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    account_id uuid,
    kind text NOT NULL,
    slots integer NOT NULL,
    channel_limit integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT channel_slot_events_channel_limit_check CHECK ((channel_limit >= 1)),
    CONSTRAINT channel_slot_events_kind_check CHECK ((kind = ANY (ARRAY['connect'::text, 'reconnect'::text, 'disconnect'::text, 'expire'::text, 'reject_limit'::text, 'reject_rotation'::text, 'reject_duplicate'::text]))),
    CONSTRAINT channel_slot_events_slots_check CHECK ((slots >= 0))
);

-- Name: TABLE channel_slot_events; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.channel_slot_events IS '채널 연결·해제·만료·한도 거부 감사 기록. 함수만 쓰고 본인만 읽는다. 토큰·이메일·code·state 원문 없음';

-- Name: chat_messages; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.chat_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    role text NOT NULL,
    kind text DEFAULT 'text'::text NOT NULL,
    text text,
    payload jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chat_messages_kind_check CHECK ((kind = ANY (ARRAY['screen'::text, 'text'::text, 'ai'::text]))),
    CONSTRAINT chat_messages_role_check CHECK ((role = ANY (ARRAY['user'::text, 'ai'::text])))
);

-- Name: TABLE chat_messages; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.chat_messages IS '제작 파트너 대화. 사용자는 role=user만 쓰고 AI 응답은 서버(SR)가 쓴다';

-- Name: chat_proposals; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.chat_proposals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    project_id uuid NOT NULL,
    tool text NOT NULL,
    args jsonb NOT NULL,
    args_hash text NOT NULL,
    input_version jsonb NOT NULL,
    expires_at timestamp with time zone DEFAULT (now() + '00:10:00'::interval) NOT NULL,
    consumed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chat_proposals_args_check CHECK (((jsonb_typeof(args) = 'object'::text) AND (length((args)::text) <= 2000))),
    CONSTRAINT chat_proposals_tool_check CHECK ((tool = ANY (ARRAY['search_topics'::text, 'search_sources'::text, 'draft_script'::text, 'synthesize_voice'::text, 'replace_cut'::text, 'render_mp4'::text])))
);

-- Name: TABLE chat_proposals; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.chat_proposals IS '제작 파트너 사전 확인 제안(서버 전용). 사용자는 chat_consume_proposal 로만 1회 소비';

-- Name: credit_ledger; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.credit_ledger (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    project_id uuid,
    job_id uuid,
    kind text NOT NULL,
    delta integer NOT NULL,
    reason text,
    idempotency_key text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT credit_ledger_kind_check CHECK ((kind = ANY (ARRAY['reserve'::text, 'settle'::text, 'release'::text, 'charge'::text])))
);

-- Name: TABLE credit_ledger; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.credit_ledger IS '크레딧 원장(추가 전용). 서버(SR)·워커만 INSERT, 작업당 settle·release 중 하나만';

-- Name: extension_connections; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.extension_connections (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    access_token_hash text NOT NULL,
    access_expires_at timestamp with time zone NOT NULL,
    refresh_token_hash text NOT NULL,
    refresh_expires_at timestamp with time zone NOT NULL,
    family_id uuid NOT NULL,
    last_heartbeat_at timestamp with time zone,
    revoked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

-- Name: TABLE extension_connections; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.extension_connections IS '브라우저 확장 연결(ADR-0003). 토큰은 해시만, 쓰기는 서버(SR)만, 본인은 해시 제외 읽기';

-- Name: jobs; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    step smallint NOT NULL,
    type text NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    idempotency_key text NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 3 NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    error text,
    started_at timestamp with time zone,
    finished_at timestamp with time zone,
    extension_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    waiting_since timestamp with time zone,
    CONSTRAINT jobs_attempts_check CHECK ((attempts >= 0)),
    CONSTRAINT jobs_max_attempts_check CHECK ((max_attempts >= 1)),
    CONSTRAINT jobs_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'waiting_extension'::text, 'running'::text, 'succeeded'::text, 'failed'::text, 'canceled'::text]))),
    CONSTRAINT jobs_step_check CHECK (((step >= 1) AND (step <= 6))),
    CONSTRAINT jobs_type_check CHECK ((type = ANY (ARRAY['render'::text, 'tts'::text, 'analyze'::text, 'collect'::text, 'select_sources'::text, 'collect_download'::text])))
);

-- Name: TABLE jobs; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.jobs IS '오래 걸리는 작업 1건 = 1행(17-5). 생성·취소는 서버(SR), 상태 갱신은 워커(worker_role)';

-- Name: COLUMN jobs.waiting_since; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.jobs.waiting_since IS '확장 대기(waiting_extension) 재진입 시각(트리거). null 이면 생성 시 대기 = created_at. 대기 24시간 기준';

-- Name: link_clicks; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.link_clicks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    affiliate_link_id uuid NOT NULL,
    short_url text,
    clicked_at timestamp with time zone DEFAULT now() NOT NULL,
    referrer text,
    platform text,
    visitor_hash text,
    counted boolean DEFAULT true NOT NULL
);

-- Name: TABLE link_clicks; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.link_clicks IS '단축 링크 클릭. 익명 클릭을 서버(SR)가 기록, 본인은 affiliate_links 경유로 읽기. IP 원문 없음';

-- Name: COLUMN link_clicks.visitor_hash; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.link_clicks.visitor_hash IS '그날 소금으로 IP 만 HMAC-SHA256(hex). 1일 뒤 null. IP 원문은 어디에도 없음';

-- Name: COLUMN link_clicks.counted; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.link_clicks.counted IS '같은 링크·같은 방문자 10분 안 반복 클릭이면 false(집계 제외)';

-- Name: oauth_states; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.oauth_states (
    state_hash text NOT NULL,
    organization_id uuid NOT NULL,
    account_id uuid NOT NULL,
    provider text DEFAULT 'youtube'::text NOT NULL,
    code_verifier text NOT NULL,
    expires_at timestamp with time zone DEFAULT (now() + '00:10:00'::interval) NOT NULL,
    used_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT oauth_states_code_verifier_check CHECK ((code_verifier ~ '^[A-Za-z0-9._~-]{43,128}$'::text)),
    CONSTRAINT oauth_states_provider_check CHECK ((provider = 'youtube'::text)),
    CONSTRAINT oauth_states_state_hash_check CHECK ((state_hash ~ '^[0-9a-f]{64}$'::text))
);

-- Name: TABLE oauth_states; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.oauth_states IS 'OAuth 시작 요청의 state·PKCE verifier(10분·1회 사용). 사용자 접근 불가, private 함수로만 읽고 쓴다';

-- Name: policy_checks; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.policy_checks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    item text NOT NULL,
    result text DEFAULT 'pending'::text NOT NULL,
    detail text,
    checked_by uuid,
    checked_at timestamp with time zone,
    CONSTRAINT policy_checks_item_check CHECK ((item = ANY (ARRAY['source_record'::text, 'attribution_notice'::text, 'original_elements'::text, 'banned_terms'::text, 'affiliate_disclosure'::text, 'purchase_path'::text]))),
    CONSTRAINT policy_checks_result_check CHECK ((result = ANY (ARRAY['pending'::text, 'pass'::text, 'fail'::text])))
);

-- Name: TABLE policy_checks; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.policy_checks IS '발행 전 정책 점검. 자동 항목은 서버(SR), 사용자 체크(checked_by·checked_at)는 함수 전용';

-- Name: project_events; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.project_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    step smallint NOT NULL,
    event text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT project_events_event_check CHECK ((event = ANY (ARRAY['step_started'::text, 'step_approved'::text, 'step_change_requested'::text, 'render_succeeded'::text, 'upload_absent_confirmed'::text]))),
    CONSTRAINT project_events_step_check CHECK (((step >= 1) AND (step <= 6)))
);

-- Name: TABLE project_events; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.project_events IS '단계 이벤트(17-9 지표). 본인 읽기, 쓰기는 서버(SR)만(추가 전용)';

-- Name: projects; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.projects (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    account_id uuid NOT NULL,
    category_id uuid,
    name text NOT NULL,
    current_step smallint DEFAULT 1 NOT NULL,
    step_status jsonb DEFAULT '{"1": "idle", "2": "idle", "3": "idle", "4": "idle", "5": "idle", "6": "idle"}'::jsonb NOT NULL,
    status text DEFAULT 'in_progress'::text NOT NULL,
    target_sec smallint DEFAULT 15 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    sources_notice_ack_by uuid,
    sources_notice_ack_at timestamp with time zone,
    sources_shortage_reason text,
    CONSTRAINT projects_current_step_check CHECK (((current_step >= 1) AND (current_step <= 6))),
    CONSTRAINT projects_sources_shortage_reason_check CHECK (((sources_shortage_reason IS NULL) OR ((char_length(sources_shortage_reason) >= 1) AND (char_length(sources_shortage_reason) <= 500)))),
    CONSTRAINT projects_status_check CHECK ((status = ANY (ARRAY['in_progress'::text, 'awaiting_publish'::text, 'scheduled'::text, 'uploaded'::text]))),
    CONSTRAINT projects_step_status_check CHECK (((jsonb_typeof(step_status) = 'object'::text) AND (step_status ?& ARRAY['1'::text, '2'::text, '3'::text, '4'::text, '5'::text, '6'::text]) AND (NOT jsonb_path_exists(step_status, '$.*?(!(((((@ == "idle" || @ == "running") || @ == "suggested") || @ == "ready") || @ == "change") || @ == "approved"))'::jsonpath)))),
    CONSTRAINT projects_target_sec_check CHECK ((target_sec = ANY (ARRAY[15, 20])))
);

-- Name: TABLE projects; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.projects IS '숏폼 프로젝트. 1 프로젝트 = 1 채널, current_step·step_status는 함수 전용, status는 서버(SR) 전용';

-- Name: COLUMN projects.sources_notice_ack_by; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.projects.sources_notice_ack_by IS '02 소스 출처 표기 고지 확인자(D7). 함수 전용';

-- Name: COLUMN projects.sources_notice_ack_at; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.projects.sources_notice_ack_at IS '02 소스 출처 표기 고지 확인 시각(D7). 함수 전용, 사용자 클릭만';

-- Name: COLUMN projects.sources_shortage_reason; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.projects.sources_shortage_reason IS '02 소스 사용 3~4편 예외 승인 부족 사유. 함수 전용';

-- Name: publication_upload_sessions; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.publication_upload_sessions (
    publication_id uuid NOT NULL,
    session_uri text NOT NULL,
    total_bytes bigint NOT NULL,
    restart_allowed boolean DEFAULT false NOT NULL,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT publication_upload_sessions_no_restart CHECK ((NOT restart_allowed)),
    CONSTRAINT publication_upload_sessions_session_uri_check CHECK (((char_length(session_uri) <= 2048) AND (session_uri ~ '^https://www\.googleapis\.com/upload/youtube/v3/videos\?'::text))),
    CONSTRAINT publication_upload_sessions_total_bytes_check CHECK ((total_bytes > 0))
);

-- Name: TABLE publication_upload_sessions; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.publication_upload_sessions IS 'YouTube resumable 업로드 세션. 서버(업로더) 함수 전용, 브라우저 반환 금지';

-- Name: COLUMN publication_upload_sessions.restart_allowed; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.publication_upload_sessions.restart_allowed IS '사용 안 함(20261113120200). 새 업로드는 publication_confirm_absent 가 세션을 지운 뒤에만';

-- Name: renders; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.renders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    version integer NOT NULL,
    cut_map jsonb,
    upscale_status text DEFAULT 'none'::text NOT NULL,
    clean_status text DEFAULT 'none'::text NOT NULL,
    mp4_path text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    job_id uuid,
    duration_sec numeric,
    purge_after date DEFAULT ((now() + '30 days'::interval))::date NOT NULL,
    file_deleted_at timestamp with time zone,
    retention_token uuid,
    retention_reserved_at timestamp with time zone,
    retention_deleting_at timestamp with time zone,
    CONSTRAINT renders_clean_status_check CHECK ((clean_status = ANY (ARRAY['none'::text, 'queued'::text, 'running'::text, 'succeeded'::text, 'failed'::text]))),
    CONSTRAINT renders_duration_sec_check CHECK (((duration_sec IS NULL) OR (duration_sec > (0)::numeric))),
    CONSTRAINT renders_upscale_status_check CHECK ((upscale_status = ANY (ARRAY['none'::text, 'queued'::text, 'running'::text, 'succeeded'::text, 'failed'::text]))),
    CONSTRAINT renders_version_check CHECK ((version >= 1))
);

-- Name: TABLE renders; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.renders IS '05 렌더 버전. 쓰기는 서버(SR), 워터마크 제거는 권리 확인 원본에만';

-- Name: COLUMN renders.job_id; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.renders.job_id IS '이 버전을 만든 render 작업. 같은 작업 재시도는 이 행을 덮어쓴다';

-- Name: COLUMN renders.duration_sec; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.renders.duration_sec IS '결과 MP4 길이(초, ffprobe 실측)';

-- Name: COLUMN renders.purge_after; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.renders.purge_after IS '파일 삭제 예정일. 미발행 created_at + 30일, 발행 시 발행일 + 30일(트리거). 서버 전용';

-- Name: COLUMN renders.file_deleted_at; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.renders.file_deleted_at IS '보관 기간이 지나 Storage 객체를 지운 시각. 행은 남긴다. 서버 전용';

-- Name: COLUMN renders.retention_token; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.renders.retention_token IS 'MP4 삭제 예약 토큰(retention_reserve). 서버 전용';

-- Name: COLUMN renders.retention_reserved_at; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.renders.retention_reserved_at IS 'MP4 삭제 예약 시각(30분 TTL). 서버 전용';

-- Name: COLUMN renders.retention_deleting_at; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.renders.retention_deleting_at IS 'MP4 Storage 삭제 직전 확인 시각(5분간 발행 전환 거부). 서버 전용';

-- Name: scripts; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.scripts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    version integer NOT NULL,
    lines jsonb DEFAULT '[]'::jsonb NOT NULL,
    est_sec numeric,
    approved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT scripts_lines_check CHECK ((jsonb_typeof(lines) = 'array'::text)),
    CONSTRAINT scripts_version_check CHECK ((version >= 1))
);

-- Name: TABLE scripts; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.scripts IS '03 대본 버전. 본인·서버(SR) 작성, approved_at은 함수 전용';

-- Name: topics; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.topics (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    round integer DEFAULT 1 NOT NULL,
    name text NOT NULL,
    reason text,
    evidence_urls text[] DEFAULT '{}'::text[] NOT NULL,
    picked boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    product_url text,
    CONSTRAINT topics_product_url_check CHECK (((product_url ~* '^https?://'::text) AND (char_length(product_url) <= 2048))),
    CONSTRAINT topics_round_check CHECK ((round >= 1))
);

-- Name: TABLE topics; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.topics IS '01 소재 후보. 생성은 서버(SR, search_topics), 사용자는 picked만 바꾼다';

-- Name: trend_items; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.trend_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    category_id uuid NOT NULL,
    name text NOT NULL,
    period text NOT NULL,
    overseas_growth numeric,
    kr_search_growth numeric,
    kr_competition numeric,
    opportunity_score numeric,
    sellable boolean DEFAULT true NOT NULL,
    captured_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT trend_items_kr_competition_check CHECK (((kr_competition >= (0)::numeric) AND (kr_competition <= (100)::numeric))),
    CONSTRAINT trend_items_opportunity_score_check CHECK (((opportunity_score >= (0)::numeric) AND (opportunity_score <= (100)::numeric))),
    CONSTRAINT trend_items_period_check CHECK ((period = ANY (ARRAY['today'::text, '7d'::text, '30d'::text])))
);

-- Name: TABLE trend_items; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.trend_items IS '트렌드 급상승 상품(planning 10장·17-4). 로그인 읽기 전용, 쓰기는 서버(SR)만';

-- Name: video_metrics; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.video_metrics (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    publication_id uuid NOT NULL,
    date date NOT NULL,
    views integer DEFAULT 0 NOT NULL,
    link_clicks integer DEFAULT 0 NOT NULL,
    avg_view_pct numeric,
    est_revenue integer,
    collected_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT video_metrics_link_clicks_check CHECK ((link_clicks >= 0)),
    CONSTRAINT video_metrics_views_check CHECK ((views >= 0))
);

-- Name: TABLE video_metrics; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.video_metrics IS '발행 영상 일별 성과. 쓰기는 서버(SR, 분석 API 수집)만';

-- Name: COLUMN video_metrics.collected_at; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.video_metrics.collected_at IS '마지막 수집(덮어쓰기) 시각. 수집 대상 선정(20시간)과 화면 "지표 수집 시각"';

-- Name: voice_takes; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.voice_takes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    voice_id text,
    source text NOT NULL,
    audio_path text,
    words jsonb,
    pauses jsonb,
    duration_sec numeric,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    job_id uuid,
    sentences jsonb,
    purge_after date DEFAULT ((now() + '30 days'::interval))::date NOT NULL,
    file_deleted_at timestamp with time zone,
    retention_token uuid,
    retention_reserved_at timestamp with time zone,
    retention_deleting_at timestamp with time zone,
    CONSTRAINT voice_takes_sentences_check CHECK (((sentences IS NULL) OR (jsonb_typeof(sentences) = 'array'::text))),
    CONSTRAINT voice_takes_source_check CHECK ((source = ANY (ARRAY['tts'::text, 'recording'::text]))),
    CONSTRAINT voice_takes_words_array CHECK (((words IS NULL) OR (jsonb_typeof(words) = 'array'::text)))
);

-- Name: TABLE voice_takes; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.voice_takes IS '04 음성 테이크. 쓰기는 서버(SR), 워커 쓰기 여부는 확인 필요(05 4절 3번)';

-- Name: COLUMN voice_takes.job_id; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.voice_takes.job_id IS 'TTS 결과를 만든 tts 작업. 같은 작업 재시도는 이 행을 덮어쓴다(녹음은 null)';

-- Name: COLUMN voice_takes.sentences; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.voice_takes.sentences IS '문장 단위 타이밍 [{i, text, start, end}] (초). 대본 줄 수와 같다';

-- Name: COLUMN voice_takes.purge_after; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.voice_takes.purge_after IS '파일 삭제 예정일. 미발행 created_at + 30일, 발행 시 발행일 + 30일(트리거). 서버 전용';

-- Name: COLUMN voice_takes.file_deleted_at; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.voice_takes.file_deleted_at IS '보관 기간이 지나 Storage 객체를 지운 시각. 행은 남긴다. 서버 전용';

-- Name: COLUMN voice_takes.retention_token; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.voice_takes.retention_token IS '음성 파일 삭제 예약 토큰(retention_reserve). 서버 전용';

-- Name: COLUMN voice_takes.retention_reserved_at; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.voice_takes.retention_reserved_at IS '음성 파일 삭제 예약 시각(30분 TTL). 서버 전용';

-- Name: COLUMN voice_takes.retention_deleting_at; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON COLUMN nomad_shorts.voice_takes.retention_deleting_at IS '음성 Storage 삭제 직전 확인 시각(5분간 발행 전환 거부). 서버 전용';

-- Name: youtube_upload_quota; Type: TABLE; Schema: nomad_shorts; Owner: -
--

CREATE TABLE nomad_shorts.youtube_upload_quota (
    day date NOT NULL,
    used integer DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT youtube_upload_quota_used_check CHECK ((used >= 0))
);

-- Name: TABLE youtube_upload_quota; Type: COMMENT; Schema: nomad_shorts; Owner: -
--

COMMENT ON TABLE nomad_shorts.youtube_upload_quota IS 'videos.insert 일일 사용 수(PT 날짜, GCP 프로젝트 공유 100회). 업로더 함수 전용';

-- Name: channel_quotas channel_quotas_pkey; Type: CONSTRAINT; Schema: nomad_shorts_private; Owner: -
--

ALTER TABLE ONLY nomad_shorts_private.channel_quotas
    ADD CONSTRAINT channel_quotas_pkey PRIMARY KEY (organization_id);

-- Name: click_salts click_salts_pkey; Type: CONSTRAINT; Schema: nomad_shorts_private; Owner: -
--

ALTER TABLE ONLY nomad_shorts_private.click_salts
    ADD CONSTRAINT click_salts_pkey PRIMARY KEY (day);

-- Name: metrics_runs metrics_runs_pkey; Type: CONSTRAINT; Schema: nomad_shorts_private; Owner: -
--

ALTER TABLE ONLY nomad_shorts_private.metrics_runs
    ADD CONSTRAINT metrics_runs_pkey PRIMARY KEY (id);

-- Name: accounts accounts_id_organization_id_key; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.accounts
    ADD CONSTRAINT accounts_id_organization_id_key UNIQUE (id, organization_id);

-- Name: accounts accounts_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.accounts
    ADD CONSTRAINT accounts_pkey PRIMARY KEY (id);

-- Name: affiliate_links affiliate_links_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.affiliate_links
    ADD CONSTRAINT affiliate_links_pkey PRIMARY KEY (id);

-- Name: affiliate_links affiliate_links_project_id_key; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.affiliate_links
    ADD CONSTRAINT affiliate_links_project_id_key UNIQUE (project_id);

-- Name: affiliate_links affiliate_links_short_url_key; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.affiliate_links
    ADD CONSTRAINT affiliate_links_short_url_key UNIQUE (short_url);

-- Name: api_keys api_keys_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.api_keys
    ADD CONSTRAINT api_keys_pkey PRIMARY KEY (id);

-- Name: api_keys api_keys_organization_id_provider_key; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.api_keys
    ADD CONSTRAINT api_keys_organization_id_provider_key UNIQUE (organization_id, provider);

-- Name: bio_items bio_items_bio_page_id_no_key; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.bio_items
    ADD CONSTRAINT bio_items_bio_page_id_no_key UNIQUE (bio_page_id, no);

-- Name: bio_items bio_items_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.bio_items
    ADD CONSTRAINT bio_items_pkey PRIMARY KEY (id);

-- Name: bio_pages bio_pages_account_id_key; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.bio_pages
    ADD CONSTRAINT bio_pages_account_id_key UNIQUE (account_id);

-- Name: bio_pages bio_pages_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.bio_pages
    ADD CONSTRAINT bio_pages_pkey PRIMARY KEY (id);

-- Name: categories categories_name_key; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.categories
    ADD CONSTRAINT categories_name_key UNIQUE (name);

-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (id);

-- Name: channel_slot_events channel_slot_events_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.channel_slot_events
    ADD CONSTRAINT channel_slot_events_pkey PRIMARY KEY (id);

-- Name: chat_messages chat_messages_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.chat_messages
    ADD CONSTRAINT chat_messages_pkey PRIMARY KEY (id);

-- Name: chat_proposals chat_proposals_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.chat_proposals
    ADD CONSTRAINT chat_proposals_pkey PRIMARY KEY (id);

-- Name: credit_ledger credit_ledger_idempotency_key_key; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.credit_ledger
    ADD CONSTRAINT credit_ledger_idempotency_key_key UNIQUE (idempotency_key);

-- Name: credit_ledger credit_ledger_job_id_kind_key; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.credit_ledger
    ADD CONSTRAINT credit_ledger_job_id_kind_key UNIQUE (job_id, kind);

-- Name: credit_ledger credit_ledger_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.credit_ledger
    ADD CONSTRAINT credit_ledger_pkey PRIMARY KEY (id);

-- Name: extension_connections extension_connections_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.extension_connections
    ADD CONSTRAINT extension_connections_pkey PRIMARY KEY (id);

-- Name: jobs jobs_idempotency_key_key; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.jobs
    ADD CONSTRAINT jobs_idempotency_key_key UNIQUE (idempotency_key);

-- Name: jobs jobs_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.jobs
    ADD CONSTRAINT jobs_pkey PRIMARY KEY (id);

-- Name: link_clicks link_clicks_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.link_clicks
    ADD CONSTRAINT link_clicks_pkey PRIMARY KEY (id);

-- Name: oauth_states oauth_states_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.oauth_states
    ADD CONSTRAINT oauth_states_pkey PRIMARY KEY (state_hash);

-- Name: policy_checks policy_checks_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.policy_checks
    ADD CONSTRAINT policy_checks_pkey PRIMARY KEY (id);

-- Name: policy_checks policy_checks_project_id_item_key; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.policy_checks
    ADD CONSTRAINT policy_checks_project_id_item_key UNIQUE (project_id, item);

-- Name: project_events project_events_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.project_events
    ADD CONSTRAINT project_events_pkey PRIMARY KEY (id);

-- Name: projects projects_id_account_id_key; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.projects
    ADD CONSTRAINT projects_id_account_id_key UNIQUE (id, account_id);

-- Name: projects projects_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (id);

-- Name: publication_upload_sessions publication_upload_sessions_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.publication_upload_sessions
    ADD CONSTRAINT publication_upload_sessions_pkey PRIMARY KEY (publication_id);

-- Name: publications publications_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.publications
    ADD CONSTRAINT publications_pkey PRIMARY KEY (id);

-- Name: publications publications_project_id_key; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.publications
    ADD CONSTRAINT publications_project_id_key UNIQUE (project_id);

-- Name: renders renders_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.renders
    ADD CONSTRAINT renders_pkey PRIMARY KEY (id);

-- Name: renders renders_project_id_version_key; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.renders
    ADD CONSTRAINT renders_project_id_version_key UNIQUE (project_id, version);

-- Name: scripts scripts_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.scripts
    ADD CONSTRAINT scripts_pkey PRIMARY KEY (id);

-- Name: scripts scripts_project_id_version_key; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.scripts
    ADD CONSTRAINT scripts_project_id_version_key UNIQUE (project_id, version);

-- Name: sources sources_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.sources
    ADD CONSTRAINT sources_pkey PRIMARY KEY (id);

-- Name: topics topics_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.topics
    ADD CONSTRAINT topics_pkey PRIMARY KEY (id);

-- Name: trend_items trend_items_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.trend_items
    ADD CONSTRAINT trend_items_pkey PRIMARY KEY (id);

-- Name: video_metrics video_metrics_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.video_metrics
    ADD CONSTRAINT video_metrics_pkey PRIMARY KEY (id);

-- Name: video_metrics video_metrics_publication_id_date_key; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.video_metrics
    ADD CONSTRAINT video_metrics_publication_id_date_key UNIQUE (publication_id, date);

-- Name: voice_takes voice_takes_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.voice_takes
    ADD CONSTRAINT voice_takes_pkey PRIMARY KEY (id);

-- Name: youtube_upload_quota youtube_upload_quota_pkey; Type: CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.youtube_upload_quota
    ADD CONSTRAINT youtube_upload_quota_pkey PRIMARY KEY (day);

-- Name: accounts_category_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX accounts_category_id_idx ON nomad_shorts.accounts USING btree (category_id);

-- Name: accounts_one_default_per_organization_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE UNIQUE INDEX accounts_one_default_per_organization_idx ON nomad_shorts.accounts USING btree (organization_id) WHERE is_default;

-- Name: accounts_platform_external_channel_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE UNIQUE INDEX accounts_platform_external_channel_idx ON nomad_shorts.accounts USING btree (platform, external_channel_id) WHERE (external_channel_id IS NOT NULL);

-- Name: accounts_organization_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX accounts_organization_id_idx ON nomad_shorts.accounts USING btree (organization_id);

-- Name: affiliate_links_project_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX affiliate_links_project_id_idx ON nomad_shorts.affiliate_links USING btree (project_id);

-- Name: bio_items_affiliate_link_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX bio_items_affiliate_link_id_idx ON nomad_shorts.bio_items USING btree (affiliate_link_id);

-- Name: bio_items_bio_page_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX bio_items_bio_page_id_idx ON nomad_shorts.bio_items USING btree (bio_page_id);

-- Name: bio_items_project_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX bio_items_project_id_idx ON nomad_shorts.bio_items USING btree (project_id);

-- Name: bio_items_project_id_key; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE UNIQUE INDEX bio_items_project_id_key ON nomad_shorts.bio_items USING btree (project_id) WHERE (project_id IS NOT NULL);

-- Name: bio_pages_account_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX bio_pages_account_id_idx ON nomad_shorts.bio_pages USING btree (account_id);

-- Name: channel_slot_events_account_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX channel_slot_events_account_id_idx ON nomad_shorts.channel_slot_events USING btree (account_id);

-- Name: channel_slot_events_organization_id_created_at_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX channel_slot_events_organization_id_created_at_idx ON nomad_shorts.channel_slot_events USING btree (organization_id, created_at DESC);

-- Name: chat_messages_project_id_created_at_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX chat_messages_project_id_created_at_idx ON nomad_shorts.chat_messages USING btree (project_id, created_at);

-- Name: chat_proposals_project_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX chat_proposals_project_id_idx ON nomad_shorts.chat_proposals USING btree (project_id);

-- Name: chat_proposals_organization_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX chat_proposals_organization_id_idx ON nomad_shorts.chat_proposals USING btree (organization_id);

-- Name: credit_ledger_one_final_per_job_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE UNIQUE INDEX credit_ledger_one_final_per_job_idx ON nomad_shorts.credit_ledger USING btree (job_id) WHERE (kind = ANY (ARRAY['settle'::text, 'release'::text]));

-- Name: credit_ledger_project_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX credit_ledger_project_id_idx ON nomad_shorts.credit_ledger USING btree (project_id);

-- Name: credit_ledger_organization_id_created_at_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX credit_ledger_organization_id_created_at_idx ON nomad_shorts.credit_ledger USING btree (organization_id, created_at);

-- Name: extension_connections_access_hash_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE UNIQUE INDEX extension_connections_access_hash_idx ON nomad_shorts.extension_connections USING btree (access_token_hash);

-- Name: extension_connections_family_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX extension_connections_family_id_idx ON nomad_shorts.extension_connections USING btree (family_id);

-- Name: extension_connections_refresh_hash_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE UNIQUE INDEX extension_connections_refresh_hash_idx ON nomad_shorts.extension_connections USING btree (refresh_token_hash);

-- Name: extension_connections_organization_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX extension_connections_organization_id_idx ON nomad_shorts.extension_connections USING btree (organization_id);

-- Name: jobs_extension_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX jobs_extension_id_idx ON nomad_shorts.jobs USING btree (extension_id);

-- Name: jobs_project_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX jobs_project_id_idx ON nomad_shorts.jobs USING btree (project_id);

-- Name: jobs_status_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX jobs_status_idx ON nomad_shorts.jobs USING btree (status) WHERE (status = ANY (ARRAY['queued'::text, 'waiting_extension'::text, 'running'::text]));

-- Name: link_clicks_affiliate_link_id_clicked_at_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX link_clicks_affiliate_link_id_clicked_at_idx ON nomad_shorts.link_clicks USING btree (affiliate_link_id, clicked_at);

-- Name: link_clicks_clicked_at_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX link_clicks_clicked_at_idx ON nomad_shorts.link_clicks USING btree (clicked_at);

-- Name: link_clicks_visitor_hash_clicked_at_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX link_clicks_visitor_hash_clicked_at_idx ON nomad_shorts.link_clicks USING btree (visitor_hash, clicked_at) WHERE (visitor_hash IS NOT NULL);

-- Name: oauth_states_account_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX oauth_states_account_id_idx ON nomad_shorts.oauth_states USING btree (account_id, organization_id);

-- Name: oauth_states_organization_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX oauth_states_organization_id_idx ON nomad_shorts.oauth_states USING btree (organization_id);

-- Name: project_events_project_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX project_events_project_id_idx ON nomad_shorts.project_events USING btree (project_id);

-- Name: projects_account_id_organization_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX projects_account_id_organization_id_idx ON nomad_shorts.projects USING btree (account_id, organization_id);

-- Name: projects_category_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX projects_category_id_idx ON nomad_shorts.projects USING btree (category_id);

-- Name: projects_organization_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX projects_organization_id_idx ON nomad_shorts.projects USING btree (organization_id);

-- Name: publications_account_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX publications_account_id_idx ON nomad_shorts.publications USING btree (account_id);

-- Name: publications_upload_due_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX publications_upload_due_idx ON nomad_shorts.publications USING btree (next_attempt_at) WHERE (status = ANY (ARRAY['pending'::text, 'retry_wait'::text]));

-- Name: renders_job_id_key; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE UNIQUE INDEX renders_job_id_key ON nomad_shorts.renders USING btree (job_id) WHERE (job_id IS NOT NULL);

-- Name: renders_project_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX renders_project_id_idx ON nomad_shorts.renders USING btree (project_id);

-- Name: renders_purge_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX renders_purge_idx ON nomad_shorts.renders USING btree (purge_after) WHERE (file_deleted_at IS NULL);

-- Name: scripts_project_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX scripts_project_id_idx ON nomad_shorts.scripts USING btree (project_id);

-- Name: sources_project_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX sources_project_id_idx ON nomad_shorts.sources USING btree (project_id);

-- Name: sources_purge_after_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX sources_purge_after_idx ON nomad_shorts.sources USING btree (purge_after) WHERE (file_deleted_at IS NULL);

-- Name: topics_project_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX topics_project_id_idx ON nomad_shorts.topics USING btree (project_id);

-- Name: trend_items_category_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX trend_items_category_id_idx ON nomad_shorts.trend_items USING btree (category_id);

-- Name: trend_items_period_score_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX trend_items_period_score_idx ON nomad_shorts.trend_items USING btree (period, opportunity_score DESC);

-- Name: voice_takes_job_id_key; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE UNIQUE INDEX voice_takes_job_id_key ON nomad_shorts.voice_takes USING btree (job_id) WHERE (job_id IS NOT NULL);

-- Name: voice_takes_project_id_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX voice_takes_project_id_idx ON nomad_shorts.voice_takes USING btree (project_id);

-- Name: voice_takes_purge_idx; Type: INDEX; Schema: nomad_shorts; Owner: -
--

CREATE INDEX voice_takes_purge_idx ON nomad_shorts.voice_takes USING btree (purge_after) WHERE (file_deleted_at IS NULL);

-- Name: accounts accounts_default_slot_guard; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER accounts_default_slot_guard BEFORE UPDATE OF is_default ON nomad_shorts.accounts FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.accounts_default_slot_guard();

-- Name: accounts accounts_force_server_columns; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER accounts_force_server_columns BEFORE INSERT ON nomad_shorts.accounts FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.accounts_force_server_columns();

-- Name: accounts accounts_vault_cleanup; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER accounts_vault_cleanup AFTER DELETE ON nomad_shorts.accounts FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.vault_secret_cleanup();

-- Name: affiliate_links affiliate_links_invalidate_ins_del; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER affiliate_links_invalidate_ins_del AFTER INSERT OR DELETE ON nomad_shorts.affiliate_links FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.affiliate_links_invalidate();

-- Name: affiliate_links affiliate_links_invalidate_upd; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER affiliate_links_invalidate_upd AFTER UPDATE ON nomad_shorts.affiliate_links FOR EACH ROW WHEN ((((((((new.project_id IS DISTINCT FROM old.project_id) OR (new.program IS DISTINCT FROM old.program)) OR (new.url IS DISTINCT FROM old.url)) OR (new.disclosed IS DISTINCT FROM old.disclosed)) OR (new.bio_service IS DISTINCT FROM old.bio_service)) OR (new.bio_no IS DISTINCT FROM old.bio_no)) OR ((new.bio_registered_at IS NULL) AND (old.bio_registered_at IS NOT NULL)))) EXECUTE FUNCTION nomad_shorts_private.affiliate_links_invalidate();

-- Name: api_keys api_keys_vault_cleanup; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER api_keys_vault_cleanup AFTER DELETE ON nomad_shorts.api_keys FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.vault_secret_cleanup();

-- Name: jobs jobs_waiting_since; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER jobs_waiting_since BEFORE UPDATE OF status ON nomad_shorts.jobs FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.jobs_waiting_since();

-- Name: policy_checks policy_checks_guard; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER policy_checks_guard BEFORE INSERT OR UPDATE ON nomad_shorts.policy_checks FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.policy_checks_guard();

-- Name: projects projects_channel_slot_guard; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER projects_channel_slot_guard BEFORE INSERT OR UPDATE OF account_id ON nomad_shorts.projects FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.projects_channel_slot_guard();

-- Name: projects projects_force_initial_state; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER projects_force_initial_state BEFORE INSERT ON nomad_shorts.projects FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.projects_force_initial_state();

-- Name: projects projects_publish_invalidate; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER projects_publish_invalidate BEFORE UPDATE OF step_status ON nomad_shorts.projects FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.projects_publish_invalidate();

-- Name: projects projects_set_updated_at; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER projects_set_updated_at BEFORE UPDATE ON nomad_shorts.projects FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.set_updated_at();

-- Name: publications publications_channel_slot_guard; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER publications_channel_slot_guard BEFORE INSERT ON nomad_shorts.publications FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.publications_channel_slot_guard();

-- Name: publications publications_guard; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER publications_guard BEFORE INSERT OR UPDATE ON nomad_shorts.publications FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.publications_guard();

-- Name: publications publications_set_purge; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER publications_set_purge AFTER INSERT OR UPDATE ON nomad_shorts.publications FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.publications_set_purge();

-- Name: publications publications_upload_guard; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER publications_upload_guard BEFORE UPDATE ON nomad_shorts.publications FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.publications_upload_guard();

-- Name: renders renders_guard_clean; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER renders_guard_clean BEFORE INSERT OR UPDATE ON nomad_shorts.renders FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.renders_guard_clean();

-- Name: scripts scripts_guard; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER scripts_guard BEFORE INSERT OR UPDATE ON nomad_shorts.scripts FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.scripts_guard();

-- Name: scripts scripts_lock_after_approval; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER scripts_lock_after_approval BEFORE INSERT OR UPDATE ON nomad_shorts.scripts FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.scripts_lock_after_approval();

-- Name: sources sources_guard; Type: TRIGGER; Schema: nomad_shorts; Owner: -
--

CREATE TRIGGER sources_guard BEFORE INSERT OR UPDATE ON nomad_shorts.sources FOR EACH ROW EXECUTE FUNCTION nomad_shorts_private.sources_guard();

-- Name: channel_quotas channel_quotas_organization_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts_private; Owner: -
--

ALTER TABLE ONLY nomad_shorts_private.channel_quotas
    ADD CONSTRAINT channel_quotas_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES nomad_core.organizations(id) ON DELETE CASCADE;

-- Name: accounts accounts_category_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.accounts
    ADD CONSTRAINT accounts_category_id_fkey FOREIGN KEY (category_id) REFERENCES nomad_shorts.categories(id);

-- Name: accounts accounts_organization_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.accounts
    ADD CONSTRAINT accounts_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES nomad_core.organizations(id) ON DELETE CASCADE;

-- Name: affiliate_links affiliate_links_project_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.affiliate_links
    ADD CONSTRAINT affiliate_links_project_id_fkey FOREIGN KEY (project_id) REFERENCES nomad_shorts.projects(id) ON DELETE CASCADE;

-- Name: api_keys api_keys_organization_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.api_keys
    ADD CONSTRAINT api_keys_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES nomad_core.organizations(id) ON DELETE CASCADE;

-- Name: bio_items bio_items_affiliate_link_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.bio_items
    ADD CONSTRAINT bio_items_affiliate_link_id_fkey FOREIGN KEY (affiliate_link_id) REFERENCES nomad_shorts.affiliate_links(id) ON DELETE SET NULL;

-- Name: bio_items bio_items_bio_page_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.bio_items
    ADD CONSTRAINT bio_items_bio_page_id_fkey FOREIGN KEY (bio_page_id) REFERENCES nomad_shorts.bio_pages(id) ON DELETE CASCADE;

-- Name: bio_items bio_items_project_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.bio_items
    ADD CONSTRAINT bio_items_project_id_fkey FOREIGN KEY (project_id) REFERENCES nomad_shorts.projects(id) ON DELETE SET NULL;

-- Name: bio_pages bio_pages_account_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.bio_pages
    ADD CONSTRAINT bio_pages_account_id_fkey FOREIGN KEY (account_id) REFERENCES nomad_shorts.accounts(id) ON DELETE CASCADE;

-- Name: channel_slot_events channel_slot_events_account_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.channel_slot_events
    ADD CONSTRAINT channel_slot_events_account_id_fkey FOREIGN KEY (account_id) REFERENCES nomad_shorts.accounts(id) ON DELETE SET NULL;

-- Name: channel_slot_events channel_slot_events_organization_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.channel_slot_events
    ADD CONSTRAINT channel_slot_events_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES nomad_core.organizations(id) ON DELETE CASCADE;

-- Name: chat_messages chat_messages_project_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.chat_messages
    ADD CONSTRAINT chat_messages_project_id_fkey FOREIGN KEY (project_id) REFERENCES nomad_shorts.projects(id) ON DELETE CASCADE;

-- Name: chat_proposals chat_proposals_project_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.chat_proposals
    ADD CONSTRAINT chat_proposals_project_id_fkey FOREIGN KEY (project_id) REFERENCES nomad_shorts.projects(id) ON DELETE CASCADE;

-- Name: chat_proposals chat_proposals_organization_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.chat_proposals
    ADD CONSTRAINT chat_proposals_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES nomad_core.organizations(id) ON DELETE CASCADE;

-- Name: credit_ledger credit_ledger_job_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.credit_ledger
    ADD CONSTRAINT credit_ledger_job_id_fkey FOREIGN KEY (job_id) REFERENCES nomad_shorts.jobs(id) ON DELETE SET NULL;

-- Name: credit_ledger credit_ledger_project_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.credit_ledger
    ADD CONSTRAINT credit_ledger_project_id_fkey FOREIGN KEY (project_id) REFERENCES nomad_shorts.projects(id) ON DELETE SET NULL;

-- Name: credit_ledger credit_ledger_organization_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.credit_ledger
    ADD CONSTRAINT credit_ledger_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES nomad_core.organizations(id) ON DELETE CASCADE;

-- Name: extension_connections extension_connections_organization_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.extension_connections
    ADD CONSTRAINT extension_connections_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES nomad_core.organizations(id) ON DELETE CASCADE;

-- Name: jobs jobs_extension_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.jobs
    ADD CONSTRAINT jobs_extension_id_fkey FOREIGN KEY (extension_id) REFERENCES nomad_shorts.extension_connections(id) ON DELETE SET NULL;

-- Name: jobs jobs_project_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.jobs
    ADD CONSTRAINT jobs_project_id_fkey FOREIGN KEY (project_id) REFERENCES nomad_shorts.projects(id) ON DELETE CASCADE;

-- Name: link_clicks link_clicks_affiliate_link_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.link_clicks
    ADD CONSTRAINT link_clicks_affiliate_link_id_fkey FOREIGN KEY (affiliate_link_id) REFERENCES nomad_shorts.affiliate_links(id) ON DELETE CASCADE;

-- Name: oauth_states oauth_states_account_id_organization_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.oauth_states
    ADD CONSTRAINT oauth_states_account_id_organization_id_fkey FOREIGN KEY (account_id, organization_id) REFERENCES nomad_shorts.accounts(id, organization_id) ON DELETE CASCADE;

-- Name: oauth_states oauth_states_organization_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.oauth_states
    ADD CONSTRAINT oauth_states_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES nomad_core.organizations(id) ON DELETE CASCADE;

-- Name: policy_checks policy_checks_checked_by_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.policy_checks
    ADD CONSTRAINT policy_checks_checked_by_fkey FOREIGN KEY (checked_by) REFERENCES auth.users(id) ON DELETE SET NULL;

-- Name: policy_checks policy_checks_project_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.policy_checks
    ADD CONSTRAINT policy_checks_project_id_fkey FOREIGN KEY (project_id) REFERENCES nomad_shorts.projects(id) ON DELETE CASCADE;

-- Name: project_events project_events_project_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.project_events
    ADD CONSTRAINT project_events_project_id_fkey FOREIGN KEY (project_id) REFERENCES nomad_shorts.projects(id) ON DELETE CASCADE;

-- Name: projects projects_account_id_organization_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.projects
    ADD CONSTRAINT projects_account_id_organization_id_fkey FOREIGN KEY (account_id, organization_id) REFERENCES nomad_shorts.accounts(id, organization_id);

-- Name: projects projects_category_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.projects
    ADD CONSTRAINT projects_category_id_fkey FOREIGN KEY (category_id) REFERENCES nomad_shorts.categories(id);

-- Name: projects projects_sources_notice_ack_by_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.projects
    ADD CONSTRAINT projects_sources_notice_ack_by_fkey FOREIGN KEY (sources_notice_ack_by) REFERENCES auth.users(id) ON DELETE SET NULL;

-- Name: projects projects_organization_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.projects
    ADD CONSTRAINT projects_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES nomad_core.organizations(id) ON DELETE CASCADE;

-- Name: publication_upload_sessions publication_upload_sessions_publication_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.publication_upload_sessions
    ADD CONSTRAINT publication_upload_sessions_publication_id_fkey FOREIGN KEY (publication_id) REFERENCES nomad_shorts.publications(id) ON DELETE CASCADE;

-- Name: publications publications_project_id_account_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.publications
    ADD CONSTRAINT publications_project_id_account_id_fkey FOREIGN KEY (project_id, account_id) REFERENCES nomad_shorts.projects(id, account_id) ON DELETE CASCADE;

-- Name: renders renders_job_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.renders
    ADD CONSTRAINT renders_job_id_fkey FOREIGN KEY (job_id) REFERENCES nomad_shorts.jobs(id) ON DELETE SET NULL;

-- Name: renders renders_project_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.renders
    ADD CONSTRAINT renders_project_id_fkey FOREIGN KEY (project_id) REFERENCES nomad_shorts.projects(id) ON DELETE CASCADE;

-- Name: scripts scripts_project_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.scripts
    ADD CONSTRAINT scripts_project_id_fkey FOREIGN KEY (project_id) REFERENCES nomad_shorts.projects(id) ON DELETE CASCADE;

-- Name: sources sources_project_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.sources
    ADD CONSTRAINT sources_project_id_fkey FOREIGN KEY (project_id) REFERENCES nomad_shorts.projects(id) ON DELETE CASCADE;

-- Name: sources sources_rights_confirmed_by_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.sources
    ADD CONSTRAINT sources_rights_confirmed_by_fkey FOREIGN KEY (rights_confirmed_by) REFERENCES auth.users(id) ON DELETE SET NULL;

-- Name: topics topics_project_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.topics
    ADD CONSTRAINT topics_project_id_fkey FOREIGN KEY (project_id) REFERENCES nomad_shorts.projects(id) ON DELETE CASCADE;

-- Name: trend_items trend_items_category_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.trend_items
    ADD CONSTRAINT trend_items_category_id_fkey FOREIGN KEY (category_id) REFERENCES nomad_shorts.categories(id) ON DELETE CASCADE;

-- Name: video_metrics video_metrics_publication_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.video_metrics
    ADD CONSTRAINT video_metrics_publication_id_fkey FOREIGN KEY (publication_id) REFERENCES nomad_shorts.publications(id) ON DELETE CASCADE;

-- Name: voice_takes voice_takes_job_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.voice_takes
    ADD CONSTRAINT voice_takes_job_id_fkey FOREIGN KEY (job_id) REFERENCES nomad_shorts.jobs(id) ON DELETE SET NULL;

-- Name: voice_takes voice_takes_project_id_fkey; Type: FK CONSTRAINT; Schema: nomad_shorts; Owner: -
--

ALTER TABLE ONLY nomad_shorts.voice_takes
    ADD CONSTRAINT voice_takes_project_id_fkey FOREIGN KEY (project_id) REFERENCES nomad_shorts.projects(id) ON DELETE CASCADE;

-- Name: channel_quotas; Type: ROW SECURITY; Schema: nomad_shorts_private; Owner: -
--

ALTER TABLE nomad_shorts_private.channel_quotas ENABLE ROW LEVEL SECURITY;

-- Name: click_salts; Type: ROW SECURITY; Schema: nomad_shorts_private; Owner: -
--

ALTER TABLE nomad_shorts_private.click_salts ENABLE ROW LEVEL SECURITY;

-- Name: metrics_runs; Type: ROW SECURITY; Schema: nomad_shorts_private; Owner: -
--

ALTER TABLE nomad_shorts_private.metrics_runs ENABLE ROW LEVEL SECURITY;

-- Name: accounts; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.accounts ENABLE ROW LEVEL SECURITY;

-- Name: accounts accounts_insert_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY accounts_insert_own ON nomad_shorts.accounts FOR INSERT TO authenticated WITH CHECK ((nomad_core.organization_role(organization_id) IN ('owner', 'admin', 'editor')));

-- Name: accounts accounts_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY accounts_select_own ON nomad_shorts.accounts FOR SELECT TO authenticated USING ((nomad_core.organization_role(organization_id) IS NOT NULL));

-- Name: accounts accounts_update_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY accounts_update_own ON nomad_shorts.accounts FOR UPDATE TO authenticated USING ((nomad_core.organization_role(organization_id) IN ('owner', 'admin', 'editor'))) WITH CHECK ((nomad_core.organization_role(organization_id) IN ('owner', 'admin', 'editor')));

-- Name: affiliate_links; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.affiliate_links ENABLE ROW LEVEL SECURITY;

-- Name: affiliate_links affiliate_links_delete_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY affiliate_links_delete_own ON nomad_shorts.affiliate_links FOR DELETE TO authenticated USING ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = affiliate_links.project_id) AND (nomad_core.organization_role(p.organization_id) IN ('owner', 'admin', 'editor'))))));

-- Name: affiliate_links affiliate_links_insert_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY affiliate_links_insert_own ON nomad_shorts.affiliate_links FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = affiliate_links.project_id) AND (nomad_core.organization_role(p.organization_id) IN ('owner', 'admin', 'editor'))))));

-- Name: affiliate_links affiliate_links_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY affiliate_links_select_own ON nomad_shorts.affiliate_links FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = affiliate_links.project_id) AND (nomad_core.organization_role(p.organization_id) IS NOT NULL)))));

-- Name: affiliate_links affiliate_links_update_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY affiliate_links_update_own ON nomad_shorts.affiliate_links FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = affiliate_links.project_id) AND (nomad_core.organization_role(p.organization_id) IN ('owner', 'admin', 'editor')))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = affiliate_links.project_id) AND (nomad_core.organization_role(p.organization_id) IN ('owner', 'admin', 'editor'))))));

-- Name: api_keys; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.api_keys ENABLE ROW LEVEL SECURITY;

-- Name: api_keys api_keys_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY api_keys_select_own ON nomad_shorts.api_keys FOR SELECT TO authenticated USING ((nomad_core.organization_role(organization_id) IS NOT NULL));

-- Name: bio_items; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.bio_items ENABLE ROW LEVEL SECURITY;

-- Name: bio_items bio_items_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY bio_items_select_own ON nomad_shorts.bio_items FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM (nomad_shorts.bio_pages bp
     JOIN nomad_shorts.accounts a ON ((a.id = bp.account_id)))
  WHERE ((bp.id = bio_items.bio_page_id) AND (nomad_core.organization_role(a.organization_id) IS NOT NULL)))));

-- Name: bio_pages; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.bio_pages ENABLE ROW LEVEL SECURITY;

-- Name: bio_pages bio_pages_insert_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY bio_pages_insert_own ON nomad_shorts.bio_pages FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM nomad_shorts.accounts a
  WHERE ((a.id = bio_pages.account_id) AND (nomad_core.organization_role(a.organization_id) IN ('owner', 'admin', 'editor'))))));

-- Name: bio_pages bio_pages_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY bio_pages_select_own ON nomad_shorts.bio_pages FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM nomad_shorts.accounts a
  WHERE ((a.id = bio_pages.account_id) AND (nomad_core.organization_role(a.organization_id) IS NOT NULL)))));

-- Name: bio_pages bio_pages_update_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY bio_pages_update_own ON nomad_shorts.bio_pages FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM nomad_shorts.accounts a
  WHERE ((a.id = bio_pages.account_id) AND (nomad_core.organization_role(a.organization_id) IN ('owner', 'admin', 'editor')))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM nomad_shorts.accounts a
  WHERE ((a.id = bio_pages.account_id) AND (nomad_core.organization_role(a.organization_id) IN ('owner', 'admin', 'editor'))))));

-- Name: categories; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.categories ENABLE ROW LEVEL SECURITY;

-- Name: categories categories_select_authenticated; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY categories_select_authenticated ON nomad_shorts.categories FOR SELECT TO authenticated USING (true);

-- Name: channel_slot_events; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.channel_slot_events ENABLE ROW LEVEL SECURITY;

-- Name: channel_slot_events channel_slot_events_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY channel_slot_events_select_own ON nomad_shorts.channel_slot_events FOR SELECT TO authenticated USING ((nomad_core.organization_role(organization_id) IS NOT NULL));

-- Name: chat_messages; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.chat_messages ENABLE ROW LEVEL SECURITY;

-- Name: chat_messages chat_messages_insert_own_user; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY chat_messages_insert_own_user ON nomad_shorts.chat_messages FOR INSERT TO authenticated WITH CHECK (((role = 'user'::text) AND (EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = chat_messages.project_id) AND (nomad_core.organization_role(p.organization_id) IN ('owner', 'admin', 'editor')))))));

-- Name: chat_messages chat_messages_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY chat_messages_select_own ON nomad_shorts.chat_messages FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = chat_messages.project_id) AND (nomad_core.organization_role(p.organization_id) IS NOT NULL)))));

-- Name: chat_proposals; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.chat_proposals ENABLE ROW LEVEL SECURITY;

-- Name: chat_proposals chat_proposals_no_client; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY chat_proposals_no_client ON nomad_shorts.chat_proposals TO authenticated USING (false) WITH CHECK (false);

-- Name: credit_ledger; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.credit_ledger ENABLE ROW LEVEL SECURITY;

-- Name: credit_ledger credit_ledger_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY credit_ledger_select_own ON nomad_shorts.credit_ledger FOR SELECT TO authenticated USING ((nomad_core.organization_role(organization_id) IS NOT NULL));

-- Name: extension_connections; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.extension_connections ENABLE ROW LEVEL SECURITY;

-- Name: extension_connections extension_connections_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY extension_connections_select_own ON nomad_shorts.extension_connections FOR SELECT TO authenticated USING ((nomad_core.organization_role(organization_id) IS NOT NULL));

-- Name: jobs; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.jobs ENABLE ROW LEVEL SECURITY;

-- Name: jobs jobs_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY jobs_select_own ON nomad_shorts.jobs FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = jobs.project_id) AND (nomad_core.organization_role(p.organization_id) IS NOT NULL)))));

-- Name: jobs jobs_select_worker; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY jobs_select_worker ON nomad_shorts.jobs FOR SELECT TO worker_role USING (true);

-- Name: jobs jobs_update_worker; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY jobs_update_worker ON nomad_shorts.jobs FOR UPDATE TO worker_role USING ((status = ANY (ARRAY['queued'::text, 'running'::text]))) WITH CHECK ((status = ANY (ARRAY['running'::text, 'succeeded'::text, 'failed'::text, 'queued'::text])));

-- Name: link_clicks; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.link_clicks ENABLE ROW LEVEL SECURITY;

-- Name: link_clicks link_clicks_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY link_clicks_select_own ON nomad_shorts.link_clicks FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM (nomad_shorts.affiliate_links al
     JOIN nomad_shorts.projects p ON ((p.id = al.project_id)))
  WHERE ((al.id = link_clicks.affiliate_link_id) AND (nomad_core.organization_role(p.organization_id) IS NOT NULL)))));

-- Name: oauth_states; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.oauth_states ENABLE ROW LEVEL SECURITY;

-- Name: policy_checks; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.policy_checks ENABLE ROW LEVEL SECURITY;

-- Name: policy_checks policy_checks_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY policy_checks_select_own ON nomad_shorts.policy_checks FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = policy_checks.project_id) AND (nomad_core.organization_role(p.organization_id) IS NOT NULL)))));

-- Name: project_events; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.project_events ENABLE ROW LEVEL SECURITY;

-- Name: project_events project_events_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY project_events_select_own ON nomad_shorts.project_events FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = project_events.project_id) AND (nomad_core.organization_role(p.organization_id) IS NOT NULL)))));

-- Name: projects; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.projects ENABLE ROW LEVEL SECURITY;

-- Name: projects projects_delete_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY projects_delete_own ON nomad_shorts.projects FOR DELETE TO authenticated USING ((nomad_core.organization_role(organization_id) IN ('owner', 'admin', 'editor')));

-- Name: projects projects_insert_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY projects_insert_own ON nomad_shorts.projects FOR INSERT TO authenticated WITH CHECK ((nomad_core.organization_role(organization_id) IN ('owner', 'admin', 'editor')));

-- Name: projects projects_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY projects_select_own ON nomad_shorts.projects FOR SELECT TO authenticated USING ((nomad_core.organization_role(organization_id) IS NOT NULL));

-- Name: projects projects_update_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY projects_update_own ON nomad_shorts.projects FOR UPDATE TO authenticated USING ((nomad_core.organization_role(organization_id) IN ('owner', 'admin', 'editor'))) WITH CHECK ((nomad_core.organization_role(organization_id) IN ('owner', 'admin', 'editor')));

-- Name: publication_upload_sessions; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.publication_upload_sessions ENABLE ROW LEVEL SECURITY;

-- Name: publications; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.publications ENABLE ROW LEVEL SECURITY;

-- Name: publications publications_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY publications_select_own ON nomad_shorts.publications FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = publications.project_id) AND (nomad_core.organization_role(p.organization_id) IS NOT NULL)))));

-- Name: renders; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.renders ENABLE ROW LEVEL SECURITY;

-- Name: renders renders_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY renders_select_own ON nomad_shorts.renders FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = renders.project_id) AND (nomad_core.organization_role(p.organization_id) IS NOT NULL)))));

-- Name: scripts; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.scripts ENABLE ROW LEVEL SECURITY;

-- Name: scripts scripts_insert_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY scripts_insert_own ON nomad_shorts.scripts FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = scripts.project_id) AND (nomad_core.organization_role(p.organization_id) IN ('owner', 'admin', 'editor'))))));

-- Name: scripts scripts_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY scripts_select_own ON nomad_shorts.scripts FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = scripts.project_id) AND (nomad_core.organization_role(p.organization_id) IS NOT NULL)))));

-- Name: scripts scripts_update_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY scripts_update_own ON nomad_shorts.scripts FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = scripts.project_id) AND (nomad_core.organization_role(p.organization_id) IN ('owner', 'admin', 'editor')))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = scripts.project_id) AND (nomad_core.organization_role(p.organization_id) IN ('owner', 'admin', 'editor'))))));

-- Name: sources; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.sources ENABLE ROW LEVEL SECURITY;

-- Name: sources sources_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY sources_select_own ON nomad_shorts.sources FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = sources.project_id) AND (nomad_core.organization_role(p.organization_id) IS NOT NULL)))));

-- Name: topics; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.topics ENABLE ROW LEVEL SECURITY;

-- Name: topics topics_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY topics_select_own ON nomad_shorts.topics FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = topics.project_id) AND (nomad_core.organization_role(p.organization_id) IS NOT NULL)))));

-- Name: topics topics_update_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY topics_update_own ON nomad_shorts.topics FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = topics.project_id) AND (nomad_core.organization_role(p.organization_id) IN ('owner', 'admin', 'editor')))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = topics.project_id) AND (nomad_core.organization_role(p.organization_id) IN ('owner', 'admin', 'editor'))))));

-- Name: trend_items; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.trend_items ENABLE ROW LEVEL SECURITY;

-- Name: trend_items trend_items_select_authenticated; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY trend_items_select_authenticated ON nomad_shorts.trend_items FOR SELECT TO authenticated USING (true);

-- Name: video_metrics; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.video_metrics ENABLE ROW LEVEL SECURITY;

-- Name: video_metrics video_metrics_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY video_metrics_select_own ON nomad_shorts.video_metrics FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM (nomad_shorts.publications pub
     JOIN nomad_shorts.projects p ON ((p.id = pub.project_id)))
  WHERE ((pub.id = video_metrics.publication_id) AND (nomad_core.organization_role(p.organization_id) IS NOT NULL)))));

-- Name: voice_takes; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.voice_takes ENABLE ROW LEVEL SECURITY;

-- Name: voice_takes voice_takes_select_own; Type: POLICY; Schema: nomad_shorts; Owner: -
--

CREATE POLICY voice_takes_select_own ON nomad_shorts.voice_takes FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM nomad_shorts.projects p
  WHERE ((p.id = voice_takes.project_id) AND (nomad_core.organization_role(p.organization_id) IS NOT NULL)))));

-- Name: youtube_upload_quota; Type: ROW SECURITY; Schema: nomad_shorts; Owner: -
--

ALTER TABLE nomad_shorts.youtube_upload_quota ENABLE ROW LEVEL SECURITY;

-- Name: SCHEMA private; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA nomad_shorts_private TO authenticated;
GRANT USAGE ON SCHEMA nomad_shorts_private TO worker_role;
GRANT USAGE ON SCHEMA nomad_shorts_private TO service_role;

-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

REVOKE USAGE ON SCHEMA nomad_shorts FROM PUBLIC;
GRANT USAGE ON SCHEMA nomad_shorts TO anon;
GRANT USAGE ON SCHEMA nomad_shorts TO authenticated;
GRANT USAGE ON SCHEMA nomad_shorts TO service_role;
GRANT USAGE ON SCHEMA nomad_shorts TO worker_role;

-- Name: FUNCTION accounts_default_slot_guard(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.accounts_default_slot_guard() FROM PUBLIC;

-- Name: FUNCTION accounts_force_server_columns(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.accounts_force_server_columns() FROM PUBLIC;

-- Name: FUNCTION add_direct_source(p_project_id uuid, p_url text, p_author text, p_title text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.add_direct_source(p_project_id uuid, p_url text, p_author text, p_title text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.add_direct_source(p_project_id uuid, p_url text, p_author text, p_title text) TO authenticated;

-- Name: FUNCTION affiliate_links_invalidate(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.affiliate_links_invalidate() FROM PUBLIC;

-- Name: FUNCTION analyze_job_project(p_job_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.analyze_job_project(p_job_id uuid) FROM PUBLIC;

-- Name: FUNCTION analyze_sources_context(p_job_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.analyze_sources_context(p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.analyze_sources_context(p_job_id uuid) TO worker_role;

-- Name: FUNCTION approve_step(p_project_id uuid, p_step integer); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.approve_step(p_project_id uuid, p_step integer) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.approve_step(p_project_id uuid, p_step integer) TO authenticated;

-- Name: FUNCTION assign_bio_number(p_project_id uuid, p_service text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.assign_bio_number(p_project_id uuid, p_service text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.assign_bio_number(p_project_id uuid, p_service text) TO authenticated;

-- Name: FUNCTION call_collect_metrics(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.call_collect_metrics() FROM PUBLIC;

-- Name: FUNCTION channel_is_excess(p_organization_id uuid, p_account_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.channel_is_excess(p_organization_id uuid, p_account_id uuid) FROM PUBLIC;

-- Name: FUNCTION channel_limit_of(p_organization_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.channel_limit_of(p_organization_id uuid) FROM PUBLIC;

-- Name: FUNCTION channel_over_limit_self(p_organization_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.channel_over_limit_self(p_organization_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.channel_over_limit_self(p_organization_id uuid) TO authenticated;

-- Name: FUNCTION channel_slot_count(p_organization_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.channel_slot_count(p_organization_id uuid) FROM PUBLIC;

-- Name: FUNCTION channel_slot_log(p_organization_id uuid, p_account_id uuid, p_kind text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.channel_slot_log(p_organization_id uuid, p_account_id uuid, p_kind text) FROM PUBLIC;

-- Name: FUNCTION channel_slot_status(p_organization_id uuid, p_account_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.channel_slot_status(p_organization_id uuid, p_account_id uuid) FROM PUBLIC;

-- Name: FUNCTION chat_consume_proposal(p_proposal_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.chat_consume_proposal(p_proposal_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.chat_consume_proposal(p_proposal_id uuid) TO authenticated;

-- Name: FUNCTION chat_create_proposal(p_organization_id uuid, p_project_id uuid, p_tool text, p_args jsonb); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.chat_create_proposal(p_organization_id uuid, p_project_id uuid, p_tool text, p_args jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.chat_create_proposal(p_organization_id uuid, p_project_id uuid, p_tool text, p_args jsonb) TO service_role;

-- Name: FUNCTION chat_start_collect(p_project_id uuid, p_platform text, p_query text, p_idempotency_key text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.chat_start_collect(p_project_id uuid, p_platform text, p_query text, p_idempotency_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.chat_start_collect(p_project_id uuid, p_platform text, p_query text, p_idempotency_key text) TO authenticated;

-- Name: FUNCTION cleanup_analytics(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.cleanup_analytics() FROM PUBLIC;

-- Name: FUNCTION confirm_policy_check(p_project_id uuid, p_item text, p_checked boolean); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.confirm_policy_check(p_project_id uuid, p_item text, p_checked boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.confirm_policy_check(p_project_id uuid, p_item text, p_checked boolean) TO authenticated;

-- Name: FUNCTION create_job(p_project_id uuid, p_type text, p_idempotency_key text, p_payload jsonb); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.create_job(p_project_id uuid, p_type text, p_idempotency_key text, p_payload jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.create_job(p_project_id uuid, p_type text, p_idempotency_key text, p_payload jsonb) TO authenticated;

-- Name: FUNCTION ext_claim_job(p_extension_id uuid, p_job_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.ext_claim_job(p_extension_id uuid, p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.ext_claim_job(p_extension_id uuid, p_job_id uuid) TO service_role;

-- Name: FUNCTION ext_collect_download(p_extension_id uuid, p_job_id uuid, p_files jsonb); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.ext_collect_download(p_extension_id uuid, p_job_id uuid, p_files jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.ext_collect_download(p_extension_id uuid, p_job_id uuid, p_files jsonb) TO service_role;

-- Name: FUNCTION ext_collect_list(p_extension_id uuid, p_job_id uuid, p_items jsonb); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.ext_collect_list(p_extension_id uuid, p_job_id uuid, p_items jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.ext_collect_list(p_extension_id uuid, p_job_id uuid, p_items jsonb) TO service_role;

-- Name: FUNCTION ext_heartbeat(p_extension_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.ext_heartbeat(p_extension_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.ext_heartbeat(p_extension_id uuid) TO service_role;

-- Name: FUNCTION ext_job_project(p_extension_id uuid, p_job_id uuid, p_type text, OUT project_id uuid, OUT organization_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.ext_job_project(p_extension_id uuid, p_job_id uuid, p_type text, OUT project_id uuid, OUT organization_id uuid) FROM PUBLIC;

-- Name: FUNCTION find_banned_term(p_project_id uuid, p_lines jsonb); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.find_banned_term(p_project_id uuid, p_lines jsonb) FROM PUBLIC;

-- Name: FUNCTION has_render_output(p_project_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.has_render_output(p_project_id uuid) FROM PUBLIC;

-- Name: FUNCTION has_unsafe_chars(p_text text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.has_unsafe_chars(p_text text) FROM PUBLIC;

-- Name: FUNCTION has_voice_output(p_project_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.has_voice_output(p_project_id uuid) FROM PUBLIC;

-- Name: FUNCTION job_cost(p_type text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.job_cost(p_type text) FROM PUBLIC;

-- Name: FUNCTION job_fail(p_queue text, p_msg_id bigint, p_job_id uuid, p_error text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.job_fail(p_queue text, p_msg_id bigint, p_job_id uuid, p_error text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.job_fail(p_queue text, p_msg_id bigint, p_job_id uuid, p_error text) TO worker_role;

-- Name: FUNCTION job_heartbeat(p_queue text, p_msg_id bigint, p_job_id uuid, p_vt_seconds integer); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.job_heartbeat(p_queue text, p_msg_id bigint, p_job_id uuid, p_vt_seconds integer) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.job_heartbeat(p_queue text, p_msg_id bigint, p_job_id uuid, p_vt_seconds integer) TO worker_role;

-- Name: FUNCTION job_queue(p_type text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.job_queue(p_type text) FROM PUBLIC;

-- Name: FUNCTION job_queue_limit(p_type text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.job_queue_limit(p_type text) FROM PUBLIC;

-- Name: FUNCTION job_retry(p_queue text, p_msg_id bigint, p_job_id uuid, p_error text, p_delay_seconds integer); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.job_retry(p_queue text, p_msg_id bigint, p_job_id uuid, p_error text, p_delay_seconds integer) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.job_retry(p_queue text, p_msg_id bigint, p_job_id uuid, p_error text, p_delay_seconds integer) TO worker_role;

-- Name: FUNCTION job_start(p_queue text, p_msg_id bigint, p_job_id uuid, p_read_ct integer); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.job_start(p_queue text, p_msg_id bigint, p_job_id uuid, p_read_ct integer) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.job_start(p_queue text, p_msg_id bigint, p_job_id uuid, p_read_ct integer) TO worker_role;

-- Name: FUNCTION job_step(p_type text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.job_step(p_type text) FROM PUBLIC;

-- Name: FUNCTION job_stop(p_queue text, p_msg_id bigint, p_job_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.job_stop(p_queue text, p_msg_id bigint, p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.job_stop(p_queue text, p_msg_id bigint, p_job_id uuid) TO worker_role;

-- Name: FUNCTION job_succeed(p_queue text, p_msg_id bigint, p_job_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.job_succeed(p_queue text, p_msg_id bigint, p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.job_succeed(p_queue text, p_msg_id bigint, p_job_id uuid) TO worker_role;

-- Name: FUNCTION job_time_limit(p_type text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.job_time_limit(p_type text) FROM PUBLIC;

-- Name: FUNCTION job_user_busy(p_job_id uuid, p_type text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.job_user_busy(p_job_id uuid, p_type text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.job_user_busy(p_job_id uuid, p_type text) TO worker_role;

-- Name: FUNCTION jobs_waiting_since(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.jobs_waiting_since() FROM PUBLIC;

-- Name: FUNCTION lock_source_step(p_project_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.lock_source_step(p_project_id uuid) FROM PUBLIC;

-- Name: FUNCTION mark_step_ready(p_project_id uuid, p_step integer, p_status text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.mark_step_ready(p_project_id uuid, p_step integer, p_status text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.mark_step_ready(p_project_id uuid, p_step integer, p_status text) TO authenticated;

-- Name: FUNCTION metrics_targets(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.metrics_targets() FROM PUBLIC;

-- Name: FUNCTION normalize_collect_url(p_url text, OUT url text, OUT platform text, OUT handle text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.normalize_collect_url(p_url text, OUT url text, OUT platform text, OUT handle text) FROM PUBLIC;

-- Name: FUNCTION normalize_for_ban(p_text text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.normalize_for_ban(p_text text) FROM PUBLIC;

-- Name: FUNCTION oauth_state_consume(p_organization_id uuid, p_state_hash text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.oauth_state_consume(p_organization_id uuid, p_state_hash text) FROM PUBLIC;

-- Name: FUNCTION oauth_state_create(p_organization_id uuid, p_account_id uuid, p_state_hash text, p_verifier text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.oauth_state_create(p_organization_id uuid, p_account_id uuid, p_state_hash text, p_verifier text) FROM PUBLIC;

-- Name: FUNCTION policy_checks_guard(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.policy_checks_guard() FROM PUBLIC;

-- Name: FUNCTION prepare_publication(p_project_id uuid, p_mode text, p_scheduled_at timestamp with time zone, p_title text, p_body text, p_hashtags text[], p_purchase_guide boolean, p_pin_comment boolean); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.prepare_publication(p_project_id uuid, p_mode text, p_scheduled_at timestamp with time zone, p_title text, p_body text, p_hashtags text[], p_purchase_guide boolean, p_pin_comment boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.prepare_publication(p_project_id uuid, p_mode text, p_scheduled_at timestamp with time zone, p_title text, p_body text, p_hashtags text[], p_purchase_guide boolean, p_pin_comment boolean) TO authenticated;

-- Name: FUNCTION projects_channel_slot_guard(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.projects_channel_slot_guard() FROM PUBLIC;

-- Name: FUNCTION projects_force_initial_state(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.projects_force_initial_state() FROM PUBLIC;

-- Name: FUNCTION projects_publish_invalidate(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.projects_publish_invalidate() FROM PUBLIC;

-- Name: TABLE publications; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT ON TABLE nomad_shorts.publications TO authenticated;

-- Name: FUNCTION publication_attempt(p_publication_id uuid, p_attempt_token uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publication_attempt(p_publication_id uuid, p_attempt_token uuid) FROM PUBLIC;

-- Name: FUNCTION publication_attempt_fail(p_publication_id uuid, p_attempt_token uuid, p_kind text, p_code text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publication_attempt_fail(p_publication_id uuid, p_attempt_token uuid, p_kind text, p_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.publication_attempt_fail(p_publication_id uuid, p_attempt_token uuid, p_kind text, p_code text) TO service_role;

-- Name: FUNCTION publication_block(p_pub nomad_shorts.publications, p_has_session boolean, p_code text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publication_block(p_pub nomad_shorts.publications, p_has_session boolean, p_code text) FROM PUBLIC;

-- Name: FUNCTION publication_claim(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publication_claim() FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.publication_claim() TO service_role;

-- Name: FUNCTION publication_confirm_absent(p_project_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publication_confirm_absent(p_project_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.publication_confirm_absent(p_project_id uuid) TO authenticated;

-- Name: FUNCTION publication_finish(p_publication_id uuid, p_attempt_token uuid, p_video_id text, p_test_private boolean); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publication_finish(p_publication_id uuid, p_attempt_token uuid, p_video_id text, p_test_private boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.publication_finish(p_publication_id uuid, p_attempt_token uuid, p_video_id text, p_test_private boolean) TO service_role;

-- Name: FUNCTION publication_reject_copy(p_publication_id uuid, p_attempt_token uuid, p_code text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publication_reject_copy(p_publication_id uuid, p_attempt_token uuid, p_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.publication_reject_copy(p_publication_id uuid, p_attempt_token uuid, p_code text) TO service_role;

-- Name: FUNCTION publication_resume_check(p_publication_id uuid, p_attempt_token uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publication_resume_check(p_publication_id uuid, p_attempt_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.publication_resume_check(p_publication_id uuid, p_attempt_token uuid) TO service_role;

-- Name: FUNCTION publication_retry(p_project_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publication_retry(p_project_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.publication_retry(p_project_id uuid) TO authenticated;

-- Name: FUNCTION publication_session_begin(p_publication_id uuid, p_attempt_token uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publication_session_begin(p_publication_id uuid, p_attempt_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.publication_session_begin(p_publication_id uuid, p_attempt_token uuid) TO service_role;

-- Name: FUNCTION publication_session_save(p_publication_id uuid, p_attempt_token uuid, p_session_uri text, p_total_bytes bigint); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publication_session_save(p_publication_id uuid, p_attempt_token uuid, p_session_uri text, p_total_bytes bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.publication_session_save(p_publication_id uuid, p_attempt_token uuid, p_session_uri text, p_total_bytes bigint) TO service_role;

-- Name: FUNCTION publications_channel_slot_guard(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publications_channel_slot_guard() FROM PUBLIC;

-- Name: FUNCTION publications_guard(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publications_guard() FROM PUBLIC;

-- Name: FUNCTION publications_set_purge(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publications_set_purge() FROM PUBLIC;

-- Name: FUNCTION publications_upload_guard(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publications_upload_guard() FROM PUBLIC;

-- Name: FUNCTION publish_banned_term(p_project_id uuid, p_texts text[]); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publish_banned_term(p_project_id uuid, p_texts text[]) FROM PUBLIC;

-- Name: FUNCTION publish_clean_hashtags(p_hashtags text[]); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publish_clean_hashtags(p_hashtags text[]) FROM PUBLIC;

-- Name: FUNCTION publish_description(p_disclosure text, p_purchase text, p_body text, p_credits text, p_hashtags text[]); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publish_description(p_disclosure text, p_purchase text, p_body text, p_credits text, p_hashtags text[]) FROM PUBLIC;

-- Name: FUNCTION publish_disclosure_text(p_program text, p_disclosed boolean); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publish_disclosure_text(p_program text, p_disclosed boolean) FROM PUBLIC;

-- Name: FUNCTION publish_evaluate(p_project_id uuid, p_title text, p_body text, p_hashtags text[]); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publish_evaluate(p_project_id uuid, p_title text, p_body text, p_hashtags text[]) FROM PUBLIC;

-- Name: FUNCTION publish_invalidate(p_project_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publish_invalidate(p_project_id uuid) FROM PUBLIC;

-- Name: FUNCTION publish_is_link_program(p_program text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publish_is_link_program(p_program text) FROM PUBLIC;

-- Name: FUNCTION publish_owned(p_project_id uuid, p_lock boolean); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publish_owned(p_project_id uuid, p_lock boolean) FROM PUBLIC;

-- Name: FUNCTION publish_policy(p_project_id uuid, p_title text, p_body text, p_hashtags text[]); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publish_policy(p_project_id uuid, p_title text, p_body text, p_hashtags text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.publish_policy(p_project_id uuid, p_title text, p_body text, p_hashtags text[]) TO authenticated;

-- Name: FUNCTION publish_purchase_text(p_program text, p_bio_no integer); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publish_purchase_text(p_program text, p_bio_no integer) FROM PUBLIC;

-- Name: FUNCTION publish_recheck(p_project_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.publish_recheck(p_project_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.publish_recheck(p_project_id uuid) TO service_role;

-- Name: FUNCTION release_job(p_job_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.release_job(p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.release_job(p_job_id uuid) TO worker_role;

-- Name: FUNCTION render_credits_text(p_cuts jsonb); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.render_credits_text(p_cuts jsonb) FROM PUBLIC;

-- Name: TABLE sources; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT ON TABLE nomad_shorts.sources TO authenticated;

-- Name: FUNCTION render_input_sources(p_project_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.render_input_sources(p_project_id uuid) FROM PUBLIC;

-- Name: FUNCTION render_job_context(p_job_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.render_job_context(p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.render_job_context(p_job_id uuid) TO worker_role;

-- Name: FUNCTION render_job_project(p_job_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.render_job_project(p_job_id uuid) FROM PUBLIC;

-- Name: FUNCTION renders_guard_clean(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.renders_guard_clean() FROM PUBLIC;

-- Name: FUNCTION request_step_change(p_project_id uuid, p_step integer); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.request_step_change(p_project_id uuid, p_step integer) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.request_step_change(p_project_id uuid, p_step integer) TO authenticated;

-- Name: FUNCTION retention_candidates(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.retention_candidates() FROM PUBLIC;

-- Name: FUNCTION retention_confirm(p_kind text, p_ids uuid[], p_token uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.retention_confirm(p_kind text, p_ids uuid[], p_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.retention_confirm(p_kind text, p_ids uuid[], p_token uuid) TO service_role;

-- Name: FUNCTION retention_due(p_limit integer, p_after_due date, p_after_kind text, p_after_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.retention_due(p_limit integer, p_after_due date, p_after_kind text, p_after_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.retention_due(p_limit integer, p_after_due date, p_after_kind text, p_after_id uuid) TO service_role;

-- Name: FUNCTION retention_mark_deleted(p_kind text, p_ids uuid[], p_token uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.retention_mark_deleted(p_kind text, p_ids uuid[], p_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.retention_mark_deleted(p_kind text, p_ids uuid[], p_token uuid) TO service_role;

-- Name: FUNCTION retention_reserve(p_kind text, p_ids uuid[]); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.retention_reserve(p_kind text, p_ids uuid[]) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.retention_reserve(p_kind text, p_ids uuid[]) TO service_role;

-- Name: FUNCTION save_render(p_job_id uuid, p_mp4_path text, p_duration_sec numeric, p_cut_map jsonb); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.save_render(p_job_id uuid, p_mp4_path text, p_duration_sec numeric, p_cut_map jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.save_render(p_job_id uuid, p_mp4_path text, p_duration_sec numeric, p_cut_map jsonb) TO worker_role;

-- Name: FUNCTION save_source_scores(p_job_id uuid, p_results jsonb); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.save_source_scores(p_job_id uuid, p_results jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.save_source_scores(p_job_id uuid, p_results jsonb) TO worker_role;

-- Name: FUNCTION save_source_use(p_project_id uuid, p_uses jsonb, p_notice_ack boolean, p_reason text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.save_source_use(p_project_id uuid, p_uses jsonb, p_notice_ack boolean, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.save_source_use(p_project_id uuid, p_uses jsonb, p_notice_ack boolean, p_reason text) TO authenticated;

-- Name: FUNCTION save_video_metrics(p_publication_id uuid, p_start date, p_end date, p_rows jsonb); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.save_video_metrics(p_publication_id uuid, p_start date, p_end date, p_rows jsonb) FROM PUBLIC;

-- Name: FUNCTION save_voice_take(p_job_id uuid, p_voice_id text, p_audio_path text, p_duration_sec numeric, p_sentences jsonb, p_words jsonb, p_pauses jsonb); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.save_voice_take(p_job_id uuid, p_voice_id text, p_audio_path text, p_duration_sec numeric, p_sentences jsonb, p_words jsonb, p_pauses jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.save_voice_take(p_job_id uuid, p_voice_id text, p_audio_path text, p_duration_sec numeric, p_sentences jsonb, p_words jsonb, p_pauses jsonb) TO worker_role;

-- Name: FUNCTION scripts_guard(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.scripts_guard() FROM PUBLIC;

-- Name: FUNCTION scripts_lock_after_approval(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.scripts_lock_after_approval() FROM PUBLIC;

-- Name: FUNCTION set_internal_metrics(p_url text, p_key text); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.set_internal_metrics(p_url text, p_key text) FROM PUBLIC;

-- Name: FUNCTION set_source_checks(p_project_id uuid, p_source_ids uuid[]); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.set_source_checks(p_project_id uuid, p_source_ids uuid[]) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.set_source_checks(p_project_id uuid, p_source_ids uuid[]) TO authenticated;

-- Name: FUNCTION set_updated_at(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.set_updated_at() FROM PUBLIC;

-- Name: FUNCTION settle_job(p_job_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.settle_job(p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.settle_job(p_job_id uuid) TO worker_role;

-- Name: FUNCTION source_approval_problem(p_project_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.source_approval_problem(p_project_id uuid) FROM PUBLIC;

-- Name: FUNCTION sources_guard(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.sources_guard() FROM PUBLIC;

-- Name: FUNCTION sweep_jobs(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.sweep_jobs() FROM PUBLIC;

-- Name: FUNCTION tts_job_context(p_job_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.tts_job_context(p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts_private.tts_job_context(p_job_id uuid) TO worker_role;

-- Name: FUNCTION tts_job_project(p_job_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.tts_job_project(p_job_id uuid) FROM PUBLIC;

-- Name: FUNCTION vault_secret_cleanup(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.vault_secret_cleanup() FROM PUBLIC;

-- Name: FUNCTION youtube_clear_token(p_account_id uuid, p_organization_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.youtube_clear_token(p_account_id uuid, p_organization_id uuid) FROM PUBLIC;

-- Name: FUNCTION youtube_expire_token(p_account_id uuid, p_token_ref uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.youtube_expire_token(p_account_id uuid, p_token_ref uuid) FROM PUBLIC;

-- Name: FUNCTION youtube_quota_reset_at(); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.youtube_quota_reset_at() FROM PUBLIC;

-- Name: FUNCTION youtube_refresh_token(p_account_id uuid, p_organization_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.youtube_refresh_token(p_account_id uuid, p_organization_id uuid) FROM PUBLIC;

-- Name: FUNCTION youtube_save_connection(p_organization_id uuid, p_account_id uuid, p_channel_id text, p_refresh_token text, p_scopes text[]); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.youtube_save_connection(p_organization_id uuid, p_account_id uuid, p_channel_id text, p_refresh_token text, p_scopes text[]) FROM PUBLIC;

-- Name: FUNCTION youtube_tags_length(p_tags text[]); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.youtube_tags_length(p_tags text[]) FROM PUBLIC;

-- Name: FUNCTION youtube_token_for(p_organization_id uuid, p_account_id uuid); Type: ACL; Schema: nomad_shorts_private; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts_private.youtube_token_for(p_organization_id uuid, p_account_id uuid) FROM PUBLIC;

-- Name: FUNCTION add_direct_source(p_project_id uuid, p_url text, p_author text, p_title text); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.add_direct_source(p_project_id uuid, p_url text, p_author text, p_title text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.add_direct_source(p_project_id uuid, p_url text, p_author text, p_title text) TO authenticated;

-- Name: FUNCTION approve_step(p_project_id uuid, p_step integer); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.approve_step(p_project_id uuid, p_step integer) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.approve_step(p_project_id uuid, p_step integer) TO authenticated;

-- Name: FUNCTION assign_bio_number(p_project_id uuid, p_service text); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.assign_bio_number(p_project_id uuid, p_service text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.assign_bio_number(p_project_id uuid, p_service text) TO authenticated;

-- Name: FUNCTION channel_slot_status(p_organization_id uuid, p_account_id uuid); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.channel_slot_status(p_organization_id uuid, p_account_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.channel_slot_status(p_organization_id uuid, p_account_id uuid) TO service_role;

-- Name: FUNCTION chat_consume_proposal(p_proposal_id uuid); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.chat_consume_proposal(p_proposal_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.chat_consume_proposal(p_proposal_id uuid) TO authenticated;

-- Name: FUNCTION chat_create_proposal(p_organization_id uuid, p_project_id uuid, p_tool text, p_args jsonb); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.chat_create_proposal(p_organization_id uuid, p_project_id uuid, p_tool text, p_args jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.chat_create_proposal(p_organization_id uuid, p_project_id uuid, p_tool text, p_args jsonb) TO service_role;

-- Name: FUNCTION chat_start_collect(p_project_id uuid, p_platform text, p_query text, p_idempotency_key text); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.chat_start_collect(p_project_id uuid, p_platform text, p_query text, p_idempotency_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.chat_start_collect(p_project_id uuid, p_platform text, p_query text, p_idempotency_key text) TO authenticated;

-- Name: FUNCTION confirm_policy_check(p_project_id uuid, p_item text, p_checked boolean); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.confirm_policy_check(p_project_id uuid, p_item text, p_checked boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.confirm_policy_check(p_project_id uuid, p_item text, p_checked boolean) TO authenticated;

-- Name: FUNCTION create_job(p_project_id uuid, p_type text, p_idempotency_key text, p_payload jsonb); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.create_job(p_project_id uuid, p_type text, p_idempotency_key text, p_payload jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.create_job(p_project_id uuid, p_type text, p_idempotency_key text, p_payload jsonb) TO authenticated;

-- Name: FUNCTION edit_input_sources(p_project_id uuid); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.edit_input_sources(p_project_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.edit_input_sources(p_project_id uuid) TO authenticated;

-- Name: FUNCTION extension_claim_job(p_extension_id uuid, p_job_id uuid); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.extension_claim_job(p_extension_id uuid, p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.extension_claim_job(p_extension_id uuid, p_job_id uuid) TO service_role;

-- Name: FUNCTION extension_collect_download(p_extension_id uuid, p_job_id uuid, p_files jsonb); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.extension_collect_download(p_extension_id uuid, p_job_id uuid, p_files jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.extension_collect_download(p_extension_id uuid, p_job_id uuid, p_files jsonb) TO service_role;

-- Name: FUNCTION extension_collect_list(p_extension_id uuid, p_job_id uuid, p_items jsonb); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.extension_collect_list(p_extension_id uuid, p_job_id uuid, p_items jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.extension_collect_list(p_extension_id uuid, p_job_id uuid, p_items jsonb) TO service_role;

-- Name: FUNCTION extension_heartbeat(p_extension_id uuid); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.extension_heartbeat(p_extension_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.extension_heartbeat(p_extension_id uuid) TO service_role;

-- Name: FUNCTION mark_step_ready(p_project_id uuid, p_step integer, p_status text); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.mark_step_ready(p_project_id uuid, p_step integer, p_status text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.mark_step_ready(p_project_id uuid, p_step integer, p_status text) TO authenticated;

-- Name: FUNCTION metrics_run_finish(p_id bigint, p_ok integer, p_skipped integer, p_error text); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.metrics_run_finish(p_id bigint, p_ok integer, p_skipped integer, p_error text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.metrics_run_finish(p_id bigint, p_ok integer, p_skipped integer, p_error text) TO service_role;

-- Name: FUNCTION metrics_run_start(); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.metrics_run_start() FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.metrics_run_start() TO service_role;

-- Name: FUNCTION metrics_targets(); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.metrics_targets() FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.metrics_targets() TO service_role;

-- Name: FUNCTION oauth_state_consume(p_organization_id uuid, p_state_hash text); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.oauth_state_consume(p_organization_id uuid, p_state_hash text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.oauth_state_consume(p_organization_id uuid, p_state_hash text) TO service_role;

-- Name: FUNCTION oauth_state_create(p_organization_id uuid, p_account_id uuid, p_state_hash text, p_verifier text); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.oauth_state_create(p_organization_id uuid, p_account_id uuid, p_state_hash text, p_verifier text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.oauth_state_create(p_organization_id uuid, p_account_id uuid, p_state_hash text, p_verifier text) TO service_role;

-- Name: FUNCTION prepare_publication(p_project_id uuid, p_mode text, p_scheduled_at timestamp with time zone, p_title text, p_body text, p_hashtags text[], p_purchase_guide boolean, p_pin_comment boolean); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.prepare_publication(p_project_id uuid, p_mode text, p_scheduled_at timestamp with time zone, p_title text, p_body text, p_hashtags text[], p_purchase_guide boolean, p_pin_comment boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.prepare_publication(p_project_id uuid, p_mode text, p_scheduled_at timestamp with time zone, p_title text, p_body text, p_hashtags text[], p_purchase_guide boolean, p_pin_comment boolean) TO authenticated;

-- Name: FUNCTION publication_attempt_fail(p_publication_id uuid, p_attempt_token uuid, p_kind text, p_code text); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.publication_attempt_fail(p_publication_id uuid, p_attempt_token uuid, p_kind text, p_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.publication_attempt_fail(p_publication_id uuid, p_attempt_token uuid, p_kind text, p_code text) TO service_role;

-- Name: FUNCTION publication_claim(); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.publication_claim() FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.publication_claim() TO service_role;

-- Name: FUNCTION publication_confirm_absent(p_project_id uuid); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.publication_confirm_absent(p_project_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.publication_confirm_absent(p_project_id uuid) TO authenticated;

-- Name: FUNCTION publication_finish(p_publication_id uuid, p_attempt_token uuid, p_video_id text, p_test_private boolean); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.publication_finish(p_publication_id uuid, p_attempt_token uuid, p_video_id text, p_test_private boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.publication_finish(p_publication_id uuid, p_attempt_token uuid, p_video_id text, p_test_private boolean) TO service_role;

-- Name: FUNCTION publication_reject_copy(p_publication_id uuid, p_attempt_token uuid, p_code text); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.publication_reject_copy(p_publication_id uuid, p_attempt_token uuid, p_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.publication_reject_copy(p_publication_id uuid, p_attempt_token uuid, p_code text) TO service_role;

-- Name: FUNCTION publication_resume_check(p_publication_id uuid, p_attempt_token uuid); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.publication_resume_check(p_publication_id uuid, p_attempt_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.publication_resume_check(p_publication_id uuid, p_attempt_token uuid) TO service_role;

-- Name: FUNCTION publication_retry(p_project_id uuid); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.publication_retry(p_project_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.publication_retry(p_project_id uuid) TO authenticated;

-- Name: FUNCTION publication_session_begin(p_publication_id uuid, p_attempt_token uuid); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.publication_session_begin(p_publication_id uuid, p_attempt_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.publication_session_begin(p_publication_id uuid, p_attempt_token uuid) TO service_role;

-- Name: FUNCTION publication_session_save(p_publication_id uuid, p_attempt_token uuid, p_session_uri text, p_total_bytes bigint); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.publication_session_save(p_publication_id uuid, p_attempt_token uuid, p_session_uri text, p_total_bytes bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.publication_session_save(p_publication_id uuid, p_attempt_token uuid, p_session_uri text, p_total_bytes bigint) TO service_role;

-- Name: FUNCTION publish_policy(p_project_id uuid, p_title text, p_body text, p_hashtags text[]); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.publish_policy(p_project_id uuid, p_title text, p_body text, p_hashtags text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.publish_policy(p_project_id uuid, p_title text, p_body text, p_hashtags text[]) TO authenticated;

-- Name: FUNCTION publish_recheck(p_project_id uuid); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.publish_recheck(p_project_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.publish_recheck(p_project_id uuid) TO service_role;

-- Name: FUNCTION queue_health(); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.queue_health() FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.queue_health() TO service_role;

-- Name: FUNCTION record_link_click(p_code text, p_ip text, p_ref_host text, p_platform text); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.record_link_click(p_code text, p_ip text, p_ref_host text, p_platform text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.record_link_click(p_code text, p_ip text, p_ref_host text, p_platform text) TO service_role;

-- Name: FUNCTION request_step_change(p_project_id uuid, p_step integer); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.request_step_change(p_project_id uuid, p_step integer) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.request_step_change(p_project_id uuid, p_step integer) TO authenticated;

-- Name: FUNCTION retention_confirm(p_kind text, p_ids uuid[], p_token uuid); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.retention_confirm(p_kind text, p_ids uuid[], p_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.retention_confirm(p_kind text, p_ids uuid[], p_token uuid) TO service_role;

-- Name: FUNCTION retention_due(p_limit integer, p_after_due date, p_after_kind text, p_after_id uuid); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.retention_due(p_limit integer, p_after_due date, p_after_kind text, p_after_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.retention_due(p_limit integer, p_after_due date, p_after_kind text, p_after_id uuid) TO service_role;

-- Name: FUNCTION retention_mark_deleted(p_kind text, p_ids uuid[], p_token uuid); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.retention_mark_deleted(p_kind text, p_ids uuid[], p_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.retention_mark_deleted(p_kind text, p_ids uuid[], p_token uuid) TO service_role;

-- Name: FUNCTION retention_reserve(p_kind text, p_ids uuid[]); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.retention_reserve(p_kind text, p_ids uuid[]) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.retention_reserve(p_kind text, p_ids uuid[]) TO service_role;

-- Name: FUNCTION save_source_use(p_project_id uuid, p_uses jsonb, p_notice_ack boolean, p_reason text); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.save_source_use(p_project_id uuid, p_uses jsonb, p_notice_ack boolean, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.save_source_use(p_project_id uuid, p_uses jsonb, p_notice_ack boolean, p_reason text) TO authenticated;

-- Name: FUNCTION save_video_metrics(p_publication_id uuid, p_start date, p_end date, p_rows jsonb); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.save_video_metrics(p_publication_id uuid, p_start date, p_end date, p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.save_video_metrics(p_publication_id uuid, p_start date, p_end date, p_rows jsonb) TO service_role;

-- Name: FUNCTION set_source_checks(p_project_id uuid, p_source_ids uuid[]); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.set_source_checks(p_project_id uuid, p_source_ids uuid[]) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.set_source_checks(p_project_id uuid, p_source_ids uuid[]) TO authenticated;

-- Name: FUNCTION youtube_clear_token(p_account_id uuid, p_organization_id uuid); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.youtube_clear_token(p_account_id uuid, p_organization_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.youtube_clear_token(p_account_id uuid, p_organization_id uuid) TO service_role;

-- Name: FUNCTION youtube_expire_token(p_account_id uuid, p_token_ref uuid); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.youtube_expire_token(p_account_id uuid, p_token_ref uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.youtube_expire_token(p_account_id uuid, p_token_ref uuid) TO service_role;

-- Name: FUNCTION youtube_refresh_token(p_account_id uuid, p_organization_id uuid); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.youtube_refresh_token(p_account_id uuid, p_organization_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.youtube_refresh_token(p_account_id uuid, p_organization_id uuid) TO service_role;

-- Name: FUNCTION youtube_save_connection(p_organization_id uuid, p_account_id uuid, p_channel_id text, p_refresh_token text, p_scopes text[]); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.youtube_save_connection(p_organization_id uuid, p_account_id uuid, p_channel_id text, p_refresh_token text, p_scopes text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.youtube_save_connection(p_organization_id uuid, p_account_id uuid, p_channel_id text, p_refresh_token text, p_scopes text[]) TO service_role;

-- Name: FUNCTION youtube_token_for(p_organization_id uuid, p_account_id uuid); Type: ACL; Schema: nomad_shorts; Owner: -
--

REVOKE ALL ON FUNCTION nomad_shorts.youtube_token_for(p_organization_id uuid, p_account_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION nomad_shorts.youtube_token_for(p_organization_id uuid, p_account_id uuid) TO service_role;

-- Name: COLUMN accounts.id; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(id) ON TABLE nomad_shorts.accounts TO authenticated;

-- Name: COLUMN accounts.organization_id; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(organization_id),INSERT(organization_id) ON TABLE nomad_shorts.accounts TO authenticated;

-- Name: COLUMN accounts.platform; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(platform),INSERT(platform) ON TABLE nomad_shorts.accounts TO authenticated;

-- Name: COLUMN accounts.channel_name; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(channel_name),INSERT(channel_name),UPDATE(channel_name) ON TABLE nomad_shorts.accounts TO authenticated;

-- Name: COLUMN accounts.category_id; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(category_id),INSERT(category_id),UPDATE(category_id) ON TABLE nomad_shorts.accounts TO authenticated;

-- Name: COLUMN accounts.tone; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(tone),INSERT(tone),UPDATE(tone) ON TABLE nomad_shorts.accounts TO authenticated;

-- Name: COLUMN accounts.target; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(target),INSERT(target),UPDATE(target) ON TABLE nomad_shorts.accounts TO authenticated;

-- Name: COLUMN accounts.weekly_goal; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(weekly_goal),INSERT(weekly_goal),UPDATE(weekly_goal) ON TABLE nomad_shorts.accounts TO authenticated;

-- Name: COLUMN accounts.is_default; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(is_default),INSERT(is_default),UPDATE(is_default) ON TABLE nomad_shorts.accounts TO authenticated;

-- Name: COLUMN accounts.status; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(status) ON TABLE nomad_shorts.accounts TO authenticated;

-- Name: COLUMN accounts.created_at; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(created_at) ON TABLE nomad_shorts.accounts TO authenticated;

-- Name: COLUMN accounts.first_connected_at; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(first_connected_at) ON TABLE nomad_shorts.accounts TO authenticated;

-- Name: COLUMN accounts.disconnected_at; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(disconnected_at) ON TABLE nomad_shorts.accounts TO authenticated;

-- Name: TABLE affiliate_links; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT,DELETE ON TABLE nomad_shorts.affiliate_links TO authenticated;

-- Name: COLUMN affiliate_links.project_id; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT INSERT(project_id) ON TABLE nomad_shorts.affiliate_links TO authenticated;

-- Name: COLUMN affiliate_links.program; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT INSERT(program),UPDATE(program) ON TABLE nomad_shorts.affiliate_links TO authenticated;

-- Name: COLUMN affiliate_links.disclosed; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT INSERT(disclosed),UPDATE(disclosed) ON TABLE nomad_shorts.affiliate_links TO authenticated;

-- Name: COLUMN api_keys.id; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(id) ON TABLE nomad_shorts.api_keys TO authenticated;

-- Name: COLUMN api_keys.organization_id; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(organization_id) ON TABLE nomad_shorts.api_keys TO authenticated;

-- Name: COLUMN api_keys.provider; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(provider) ON TABLE nomad_shorts.api_keys TO authenticated;

-- Name: COLUMN api_keys.last4; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(last4) ON TABLE nomad_shorts.api_keys TO authenticated;

-- Name: COLUMN api_keys.status; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(status) ON TABLE nomad_shorts.api_keys TO authenticated;

-- Name: COLUMN api_keys.tested_at; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(tested_at) ON TABLE nomad_shorts.api_keys TO authenticated;

-- Name: TABLE bio_items; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT ON TABLE nomad_shorts.bio_items TO authenticated;

-- Name: TABLE bio_pages; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT,INSERT ON TABLE nomad_shorts.bio_pages TO authenticated;

-- Name: COLUMN bio_pages.service; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT UPDATE(service) ON TABLE nomad_shorts.bio_pages TO authenticated;

-- Name: COLUMN bio_pages.url; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT UPDATE(url) ON TABLE nomad_shorts.bio_pages TO authenticated;

-- Name: TABLE categories; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT ON TABLE nomad_shorts.categories TO authenticated;

-- Name: TABLE channel_slot_events; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT ON TABLE nomad_shorts.channel_slot_events TO authenticated;

-- Name: TABLE chat_messages; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT ON TABLE nomad_shorts.chat_messages TO authenticated;

-- Name: COLUMN chat_messages.project_id; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT INSERT(project_id) ON TABLE nomad_shorts.chat_messages TO authenticated;

-- Name: COLUMN chat_messages.role; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT INSERT(role) ON TABLE nomad_shorts.chat_messages TO authenticated;

-- Name: COLUMN chat_messages.kind; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT INSERT(kind) ON TABLE nomad_shorts.chat_messages TO authenticated;

-- Name: COLUMN chat_messages.text; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT INSERT(text) ON TABLE nomad_shorts.chat_messages TO authenticated;

-- Name: COLUMN chat_messages.payload; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT INSERT(payload) ON TABLE nomad_shorts.chat_messages TO authenticated;

-- Name: TABLE credit_ledger; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT ON TABLE nomad_shorts.credit_ledger TO authenticated;

-- Name: COLUMN extension_connections.id; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(id) ON TABLE nomad_shorts.extension_connections TO authenticated;

-- Name: COLUMN extension_connections.organization_id; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(organization_id) ON TABLE nomad_shorts.extension_connections TO authenticated;

-- Name: COLUMN extension_connections.access_expires_at; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(access_expires_at) ON TABLE nomad_shorts.extension_connections TO authenticated;

-- Name: COLUMN extension_connections.refresh_expires_at; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(refresh_expires_at) ON TABLE nomad_shorts.extension_connections TO authenticated;

-- Name: COLUMN extension_connections.family_id; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(family_id) ON TABLE nomad_shorts.extension_connections TO authenticated;

-- Name: COLUMN extension_connections.last_heartbeat_at; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(last_heartbeat_at) ON TABLE nomad_shorts.extension_connections TO authenticated;

-- Name: COLUMN extension_connections.revoked_at; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(revoked_at) ON TABLE nomad_shorts.extension_connections TO authenticated;

-- Name: COLUMN extension_connections.created_at; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(created_at) ON TABLE nomad_shorts.extension_connections TO authenticated;

-- Name: TABLE jobs; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT ON TABLE nomad_shorts.jobs TO authenticated;

-- Name: COLUMN jobs.id; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(id) ON TABLE nomad_shorts.jobs TO worker_role;

-- Name: COLUMN jobs.step; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(step) ON TABLE nomad_shorts.jobs TO worker_role;

-- Name: COLUMN jobs.type; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(type) ON TABLE nomad_shorts.jobs TO worker_role;

-- Name: COLUMN jobs.status; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(status),UPDATE(status) ON TABLE nomad_shorts.jobs TO worker_role;

-- Name: COLUMN jobs.attempts; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(attempts),UPDATE(attempts) ON TABLE nomad_shorts.jobs TO worker_role;

-- Name: COLUMN jobs.max_attempts; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(max_attempts) ON TABLE nomad_shorts.jobs TO worker_role;

-- Name: COLUMN jobs.payload; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(payload) ON TABLE nomad_shorts.jobs TO worker_role;

-- Name: COLUMN jobs.error; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT UPDATE(error) ON TABLE nomad_shorts.jobs TO worker_role;

-- Name: COLUMN jobs.started_at; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT UPDATE(started_at) ON TABLE nomad_shorts.jobs TO worker_role;

-- Name: COLUMN jobs.finished_at; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT UPDATE(finished_at) ON TABLE nomad_shorts.jobs TO worker_role;

-- Name: COLUMN link_clicks.id; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(id) ON TABLE nomad_shorts.link_clicks TO authenticated;

-- Name: COLUMN link_clicks.affiliate_link_id; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(affiliate_link_id) ON TABLE nomad_shorts.link_clicks TO authenticated;

-- Name: COLUMN link_clicks.short_url; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(short_url) ON TABLE nomad_shorts.link_clicks TO authenticated;

-- Name: COLUMN link_clicks.clicked_at; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(clicked_at) ON TABLE nomad_shorts.link_clicks TO authenticated;

-- Name: COLUMN link_clicks.referrer; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(referrer) ON TABLE nomad_shorts.link_clicks TO authenticated;

-- Name: COLUMN link_clicks.platform; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(platform) ON TABLE nomad_shorts.link_clicks TO authenticated;

-- Name: COLUMN link_clicks.counted; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT(counted) ON TABLE nomad_shorts.link_clicks TO authenticated;

-- Name: TABLE policy_checks; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT ON TABLE nomad_shorts.policy_checks TO authenticated;

-- Name: TABLE project_events; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT ON TABLE nomad_shorts.project_events TO authenticated;

-- Name: TABLE projects; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT,DELETE ON TABLE nomad_shorts.projects TO authenticated;

-- Name: COLUMN projects.organization_id; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT INSERT(organization_id) ON TABLE nomad_shorts.projects TO authenticated;

-- Name: COLUMN projects.account_id; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT INSERT(account_id),UPDATE(account_id) ON TABLE nomad_shorts.projects TO authenticated;

-- Name: COLUMN projects.category_id; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT INSERT(category_id),UPDATE(category_id) ON TABLE nomad_shorts.projects TO authenticated;

-- Name: COLUMN projects.name; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT INSERT(name),UPDATE(name) ON TABLE nomad_shorts.projects TO authenticated;

-- Name: COLUMN projects.target_sec; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT INSERT(target_sec),UPDATE(target_sec) ON TABLE nomad_shorts.projects TO authenticated;

-- Name: TABLE renders; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT ON TABLE nomad_shorts.renders TO authenticated;

-- Name: TABLE scripts; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT ON TABLE nomad_shorts.scripts TO authenticated;

-- Name: COLUMN scripts.project_id; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT INSERT(project_id) ON TABLE nomad_shorts.scripts TO authenticated;

-- Name: COLUMN scripts.version; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT INSERT(version) ON TABLE nomad_shorts.scripts TO authenticated;

-- Name: COLUMN scripts.lines; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT INSERT(lines),UPDATE(lines) ON TABLE nomad_shorts.scripts TO authenticated;

-- Name: COLUMN scripts.est_sec; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT INSERT(est_sec),UPDATE(est_sec) ON TABLE nomad_shorts.scripts TO authenticated;

-- Name: TABLE topics; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT ON TABLE nomad_shorts.topics TO authenticated;

-- Name: COLUMN topics.picked; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT UPDATE(picked) ON TABLE nomad_shorts.topics TO authenticated;

-- Name: COLUMN topics.product_url; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT UPDATE(product_url) ON TABLE nomad_shorts.topics TO authenticated;

-- Name: TABLE trend_items; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT ON TABLE nomad_shorts.trend_items TO authenticated;

-- Name: TABLE video_metrics; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT ON TABLE nomad_shorts.video_metrics TO authenticated;

-- Name: TABLE voice_takes; Type: ACL; Schema: nomad_shorts; Owner: -
--

GRANT SELECT ON TABLE nomad_shorts.voice_takes TO authenticated;

-- ── user_settings (원본 user_profiles 의 제품 설정 컬럼) ─────────────
-- 이름·이메일은 nomad_core.profiles(display_name)·auth.users 가 소유한다. 개인 기본값만 이 제품에 둔다.
-- 동기화 대상(로컬 캐시): updated_at 증분 + deleted_at 소프트 삭제 + touch 트리거.
create table nomad_shorts.user_settings (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  default_tone text,
  default_lang text,
  subtitle_style text,
  default_len smallint not null default 15 check (default_len in (15, 20)),
  notify_done boolean not null default true,
  notify_weekly boolean not null default false,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
comment on table nomad_shorts.user_settings is '개인 환경설정 기본값(원본 user_profiles 이관). 본인만 읽기·쓰기';
create index user_settings_user_updated_idx on nomad_shorts.user_settings (user_id, updated_at);
alter table nomad_shorts.user_settings enable row level security;
create policy user_settings_select_own on nomad_shorts.user_settings for select to authenticated
  using (user_id = (select auth.uid()));
create policy user_settings_insert_own on nomad_shorts.user_settings for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy user_settings_update_own on nomad_shorts.user_settings for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
revoke all on nomad_shorts.user_settings from anon, authenticated;
grant select, insert, update on nomad_shorts.user_settings to authenticated;
create trigger user_settings_touch before update on nomad_shorts.user_settings
  for each row execute function nomad_core.touch_updated_at();

-- ── 작업 큐(pgmq): 종류별 render·tts·analyze. pgmq 스키마는 API 비노출 ──
-- 큐 이름이 DB 전역이라 다른 제품과 겹치면 안 된다(products/shorts/existing.md 참고).
select pgmq.create(q) from unnest(array['shorts_render', 'shorts_tts', 'shorts_analyze']) as q
where not exists (select 1 from pgmq.meta m where m.queue_name = q);

do $$
declare q text;
begin
  foreach q in array array['shorts_render', 'shorts_tts', 'shorts_analyze'] loop
    execute format('alter table pgmq.%I enable row level security', 'q_' || q);
    execute format('alter table pgmq.%I enable row level security', 'a_' || q);
    execute format('revoke all on pgmq.%I from public, anon, authenticated, service_role', 'q_' || q);
    execute format('revoke all on pgmq.%I from public, anon, authenticated, service_role', 'a_' || q);
    execute format('grant select, delete on pgmq.%I to worker_role', 'q_' || q);
    execute format('grant update (vt, read_ct) on pgmq.%I to worker_role', 'q_' || q);
    execute format('grant insert on pgmq.%I to worker_role', 'a_' || q);
    execute format('grant select (msg_id) on pgmq.%I to worker_role', 'a_' || q);
    execute format('create policy worker_select on pgmq.%I for select to worker_role using (true)', 'q_' || q);
    execute format('create policy worker_update on pgmq.%I for update to worker_role using (true) with check (true)', 'q_' || q);
    execute format('create policy worker_delete on pgmq.%I for delete to worker_role using (true)', 'q_' || q);
    execute format('create policy worker_insert on pgmq.%I for insert to worker_role with check (true)', 'a_' || q);
    execute format('create policy worker_select on pgmq.%I for select to worker_role using (true)', 'a_' || q);
  end loop;
end
$$;
grant usage on schema pgmq to worker_role;
grant execute on function pgmq.read(text, integer, integer, jsonb) to worker_role;
grant execute on function pgmq.set_vt(text, bigint, integer) to worker_role;
grant execute on function pgmq.archive(text, bigint) to worker_role;
grant execute on function pgmq.delete(text, bigint) to worker_role;
grant execute on function pgmq.format_table_name(text, text) to worker_role;

-- ── 예약 작업(pg_cron) ─────────────────────────────────────
select cron.schedule('shorts_sweep_jobs', '* * * * *', 'select nomad_shorts_private.sweep_jobs()');
select cron.schedule('shorts_collect_metrics', '30 0 * * *', 'select nomad_shorts_private.call_collect_metrics()');
select cron.schedule('shorts_cleanup_analytics', '10 0 * * *', 'select nomad_shorts_private.cleanup_analytics()');

-- ── Realtime: 단계 상태 변경을 다른 탭·기기에 전달(구독자 RLS 적용) ──
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table nomad_shorts.projects;
  end if;
end
$$;

commit;
