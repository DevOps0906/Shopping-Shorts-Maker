-- task-024a: YouTube 업로더 — 업로드는 jobs·크레딧이 아니라 publications 상태만으로 관리한다.
-- 근거: tasks/task-024.md, docs/04_API.md YouTube 1·4절, 20261112260200(publish_recheck·무효화), 20261112270*(OAuth·Vault)
-- 실행 주체: Compose 서비스 uploader(web 코드, service_role). 워커에는 토큰을 넘기지 않는다.
--
-- 상태: pending(준비 완료, 아직 선점 전) → uploading(선점, 시도 토큰) → uploaded | scheduled
--       사용자 재시도(failed·needs_check·reconnect_wait) → retry_wait
--       uploading → retry_wait(일시 오류 백오프·쿼터 대기) → uploading …
--       uploading → reconnect_wait(invalid_grant·연결 해제, 재시도 횟수 미차감)
--       uploading → needs_check(결과 불명: 응답 유실·세션 확인 불가. 자동 재시도 안 함)
--       uploading → failed(일시 오류 3회·영구 오류)
--       pending → invalidated(정책 미통과·예약 시각 지남 → 사용자가 다시 발행 준비)
-- - 선점(publication_claim)은 publish_recheck 와 같은 6/6 판정 + 상태 전환을 한 트랜잭션(행 FOR UPDATE SKIP LOCKED)에서 한다.
-- - 바이트 전송 전에 resumable 세션 URI 를 서버 전용 테이블에 저장한다. 세션이 있으면 새 insert 대신 상태 조회로 이어 올린다.
-- - 세션이 한 번 생긴 행은 pending·invalidated 로 돌아가지 않는다(발행 준비 재저장으로 문구가 바뀌면 안 된다).
-- - 업로드 버킷 쿼터(프로젝트 GCP 공유 하루 100회)는 insert 전에 전역 카운터(태평양 날짜)로 센다.

-- ── 1) 열·상태 ───────────────────────────────────────────────
alter table public.publications drop constraint publications_status_check;
alter table public.publications add constraint publications_status_check
  check (status in ('pending', 'invalidated', 'uploading', 'retry_wait', 'reconnect_wait', 'needs_check',
                    'failed', 'scheduled', 'uploaded'));
alter table public.publications
  add column attempt_token uuid,
  add column attempt_started_at timestamptz,
  add column next_attempt_at timestamptz;
comment on column public.publications.attempt_token is '업로드 시도 토큰(publication_claim 발급). 결과 기록 함수는 이 토큰이 맞을 때만 쓴다';
comment on column public.publications.next_attempt_at is '다음 자동 시도 시각(일시 오류 백오프·쿼터 대기). 서버 전용';
comment on column public.publications.error is '마지막 실패 분류 코드(kind:code). 원문 응답·토큰은 넣지 않는다';
create index publications_upload_due_idx on public.publications (next_attempt_at)
  where status in ('pending', 'retry_wait');

-- resumable 세션(업로드 권한이 담긴 URI) — 서버 전용. authenticated·service_role 직접 접근 없음, 함수로만
create table public.publication_upload_sessions (
  publication_id uuid primary key references public.publications (id) on delete cascade,
  session_uri text not null
    check (char_length(session_uri) <= 2048
           and session_uri ~ '^https://www\.googleapis\.com/upload/youtube/v3/videos\?'),
  total_bytes bigint not null check (total_bytes > 0),
  -- 사용자가 needs_check 에서 "올라가지 않았음"을 확인하고 다시 시도함 → 세션이 사라졌으면 새로 insert 해도 된다
  restart_allowed boolean not null default false,
  completed_at timestamptz,
  created_at timestamptz not null default now()
);
comment on table public.publication_upload_sessions is 'YouTube resumable 업로드 세션. 서버(업로더) 함수 전용, 브라우저 반환 금지';
alter table public.publication_upload_sessions enable row level security;
revoke all on public.publication_upload_sessions from public, anon, authenticated, service_role;

-- 업로드 버킷 일일 사용 수(태평양 시간 날짜, 프로젝트 전체 공유)
create table public.youtube_upload_quota (
  day date primary key,
  used integer not null default 0 check (used >= 0),
  updated_at timestamptz not null default now()
);
comment on table public.youtube_upload_quota is 'videos.insert 일일 사용 수(PT 날짜, GCP 프로젝트 공유 100회). 업로더 함수 전용';
alter table public.youtube_upload_quota enable row level security;
revoke all on public.youtube_upload_quota from public, anon, authenticated, service_role;

-- ── 2) 상태 전환 보호 ────────────────────────────────────────
-- - 채널(account_id)·프로젝트는 바꿀 수 없다. 영상 ID가 생긴 행은 다시 올릴 수 없다(같은 영상 다른 채널 재업로드 금지).
-- - pending 으로는 pending·invalidated 에서만 갈 수 있다(선점 이후 행은 재시도해도 retry_wait).
--   prepare_publication 이 선점과 경합해 uploading 행을 pending 으로 덮어쓰는 것도 여기서 막는다.
--   invalidated 로의 전환은 기존 무효화(pending 행만)와 선점 판정 실패(publication_block)뿐이다.
create function private.publications_upload_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
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
revoke execute on function private.publications_upload_guard() from public, anon, authenticated, service_role;

create trigger publications_upload_guard
  before update on public.publications
  for each row execute function private.publications_upload_guard();

-- ── 3) 내부 도우미 ───────────────────────────────────────────
-- 다음 쿼터 초기화 시각(태평양 자정) + 5분 여유
create function private.youtube_quota_reset_at()
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select ((date_trunc('day', now() at time zone 'America/Los_Angeles') + interval '1 day')
          at time zone 'America/Los_Angeles') + interval '5 minutes';
$$;
revoke execute on function private.youtube_quota_reset_at() from public, anon, authenticated, service_role;

-- 시도 확인: 그 시도 토큰으로 선점 중인 행만(잠금). 아니면 55000
create function private.publication_attempt(p_publication_id uuid, p_attempt_token uuid)
returns public.publications
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pub public.publications;
begin
  select * into v_pub from public.publications
  where id = p_publication_id and status = 'uploading' and attempt_token = p_attempt_token
  for update;
  if v_pub.id is null then
    raise exception '선점이 끝난 업로드 시도입니다' using errcode = '55000';
  end if;
  return v_pub;
end;
$$;
revoke execute on function private.publication_attempt(uuid, uuid) from public, anon, authenticated, service_role;

-- 선점 전 판정 실패 처리: 세션이 있으면 결과 불명(needs_check), 없으면 발행 준비 무효화(사용자가 다시 확인)
create function private.publication_block(p_pub public.publications, p_has_session boolean, p_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_has_session then
    update public.publications
    set status = 'needs_check', error = p_code, attempt_token = null, next_attempt_at = null
    where id = p_pub.id;
  else
    update public.publications
    set status = 'invalidated', error = p_code, attempt_token = null, next_attempt_at = null
    where id = p_pub.id;
    update public.projects set status = 'in_progress' where id = p_pub.project_id and status = 'awaiting_publish';
  end if;
end;
$$;
revoke execute on function private.publication_block(public.publications, boolean, text)
  from public, anon, authenticated, service_role;

-- ── 4) 선점 ─────────────────────────────────────────────────
create function private.publication_claim()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stale record;
  v_pub public.publications;
  v_session public.publication_upload_sessions;
  v_has_session boolean;
  v_ctx record;
  v_policy jsonb;
  v_mp4 text;
  v_token uuid := gen_random_uuid();
begin
  -- 멈춘 시도(30분 넘게 uploading): 세션이 있으면 결과 불명 → needs_check, 없으면 일시 오류 1회
  for v_stale in
    select p.id, p.retry_count,
           exists (select 1 from public.publication_upload_sessions s where s.publication_id = p.id) as has_session
    from public.publications p
    where p.status = 'uploading' and p.attempt_started_at < now() - interval '30 minutes'
    for update of p skip locked
  loop
    update public.publications
    set status = case when v_stale.has_session then 'needs_check'
                      when v_stale.retry_count + 1 >= 3 then 'failed'
                      else 'retry_wait' end,
        retry_count = case when v_stale.has_session then retry_count else least(retry_count + 1, 3) end,
        next_attempt_at = case when not v_stale.has_session and v_stale.retry_count + 1 < 3 then now() end,
        attempt_token = null,
        error = 'unknown:stale_attempt'
    where id = v_stale.id;
  end loop;

  select * into v_pub from public.publications
  where status in ('pending', 'retry_wait') and (next_attempt_at is null or next_attempt_at <= now())
  order by coalesce(next_attempt_at, prepared_at, created_at), id
  limit 1
  for update skip locked;
  if v_pub.id is null then
    return jsonb_build_object('claimed', false, 'reason', 'idle');
  end if;

  select * into v_session from public.publication_upload_sessions where publication_id = v_pub.id;
  v_has_session := v_session.publication_id is not null;

  select p.user_id, p.account_id as project_account, a.platform, a.user_id as account_user,
         a.external_channel_id, a.status as account_status
    into v_ctx
  from public.projects p
  join public.accounts a on a.id = p.account_id
  where p.id = v_pub.project_id;

  -- 채널: 프로젝트 채널 = 발행 채널, YouTube, 같은 소유자. 아니면 업로드하지 않는다
  if v_ctx.project_account is distinct from v_pub.account_id or v_ctx.platform is distinct from 'youtube'
     or v_ctx.account_user is distinct from v_ctx.user_id then
    update public.publications
    set status = 'failed', error = 'permanent:channel_mismatch', attempt_token = null, next_attempt_at = null
    where id = v_pub.id;
    return jsonb_build_object('claimed', false, 'reason', 'channel_mismatch', 'publication_id', v_pub.id);
  end if;

  -- 연결이 끊긴 채널: 재시도 횟수를 쓰지 않고 재연결 대기
  if v_ctx.external_channel_id is null or v_ctx.account_status <> 'connected' then
    update public.publications
    set status = 'reconnect_wait', error = 'reconnect:reconnect_required', attempt_token = null, next_attempt_at = null
    where id = v_pub.id;
    return jsonb_build_object('claimed', false, 'reason', 'reconnect_wait', 'publication_id', v_pub.id);
  end if;

  -- 예약 시각이 지금+5분보다 이르면 올리지 않는다(자동 즉시 공개 금지 → 사용자 확인)
  if v_pub.mode = 'scheduled' and (v_pub.scheduled_at is null or v_pub.scheduled_at < now() + interval '5 minutes') then
    perform private.publication_block(v_pub, v_has_session, 'confirm:schedule_passed');
    return jsonb_build_object('claimed', false, 'reason', 'schedule_passed', 'publication_id', v_pub.id);
  end if;

  -- 정책 6/6 재판정(publish_recheck 와 같은 판정, 저장된 문구)
  v_policy := private.publish_evaluate(v_pub.project_id, v_pub.title, v_pub.body, v_pub.hashtags);
  if (v_policy ->> 'passed')::int <> 6 then
    perform private.publication_block(v_pub, v_has_session, 'confirm:policy_failed');
    return jsonb_build_object('claimed', false, 'reason', 'policy_failed', 'publication_id', v_pub.id);
  end if;

  select r.mp4_path into v_mp4 from public.renders r
  where r.project_id = v_pub.project_id
  order by r.version desc
  limit 1;

  update public.publications
  set status = 'uploading', attempt_token = v_token, attempt_started_at = now(), next_attempt_at = null
  where id = v_pub.id;

  return jsonb_build_object(
    'claimed', true,
    'publication_id', v_pub.id,
    'attempt_token', v_token,
    'project_id', v_pub.project_id,
    'user_id', v_ctx.user_id,
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
revoke execute on function private.publication_claim() from public, anon, authenticated;
grant execute on function private.publication_claim() to service_role;

-- ── 5) 세션 시작(쿼터 확인) · 저장 · 폐기 ─────────────────────
create function private.publication_session_begin(p_publication_id uuid, p_attempt_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pub public.publications := private.publication_attempt(p_publication_id, p_attempt_token);
  v_day date := (now() at time zone 'America/Los_Angeles')::date;
  v_used integer;
  v_next timestamptz;
begin
  if exists (select 1 from public.publication_upload_sessions where publication_id = v_pub.id) then
    raise exception '업로드 세션이 이미 있습니다. 상태 조회로 이어 올려 주세요' using errcode = '55000';
  end if;
  insert into public.youtube_upload_quota (day) values (v_day) on conflict (day) do nothing;
  select used into v_used from public.youtube_upload_quota where day = v_day for update;
  if v_used >= 100 then
    v_next := private.youtube_quota_reset_at();
    update public.publications
    set status = 'retry_wait', next_attempt_at = v_next, error = 'quota:daily_limit', attempt_token = null
    where id = v_pub.id;
    return jsonb_build_object('ok', false, 'reason', 'quota', 'next_attempt_at', v_next);
  end if;
  update public.youtube_upload_quota set used = used + 1, updated_at = now() where day = v_day;
  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function private.publication_session_begin(uuid, uuid) from public, anon, authenticated;
grant execute on function private.publication_session_begin(uuid, uuid) to service_role;

create function private.publication_session_save(p_publication_id uuid, p_attempt_token uuid,
                                                 p_session_uri text, p_total_bytes bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pub public.publications := private.publication_attempt(p_publication_id, p_attempt_token);
begin
  insert into public.publication_upload_sessions (publication_id, session_uri, total_bytes)
  values (v_pub.id, p_session_uri, p_total_bytes);
end;
$$;
revoke execute on function private.publication_session_save(uuid, uuid, text, bigint) from public, anon, authenticated;
grant execute on function private.publication_session_save(uuid, uuid, text, bigint) to service_role;

-- 세션이 사라졌을 때(404·410): 사용자가 needs_check 에서 다시 시도한 경우에만 세션을 지우고 새로 올린다
create function private.publication_session_discard(p_publication_id uuid, p_attempt_token uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pub public.publications := private.publication_attempt(p_publication_id, p_attempt_token);
begin
  delete from public.publication_upload_sessions
  where publication_id = v_pub.id and restart_allowed and completed_at is null;
  return found;
end;
$$;
revoke execute on function private.publication_session_discard(uuid, uuid) from public, anon, authenticated;
grant execute on function private.publication_session_discard(uuid, uuid) to service_role;

-- ── 6) 결과 기록 ─────────────────────────────────────────────
create function private.publication_finish(p_publication_id uuid, p_attempt_token uuid, p_video_id text,
                                           p_test_private boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pub public.publications := private.publication_attempt(p_publication_id, p_attempt_token);
  v_status text;
begin
  if p_video_id is null or p_video_id !~ '^[A-Za-z0-9_-]{6,64}$' then
    raise exception '영상 ID 형식이 올바르지 않습니다' using errcode = '22023';
  end if;
  v_status := case when v_pub.mode = 'scheduled' and not coalesce(p_test_private, false) then 'scheduled' else 'uploaded' end;
  update public.publications
  set status = v_status, platform_video_id = p_video_id,
      published_at = case when v_status = 'scheduled' then v_pub.scheduled_at else now() end,
      error = null, attempt_token = null, next_attempt_at = null
  where id = v_pub.id;
  update public.publication_upload_sessions set completed_at = now() where publication_id = v_pub.id;
  update public.projects set status = v_status where id = v_pub.project_id;
  return jsonb_build_object('status', v_status);
end;
$$;
revoke execute on function private.publication_finish(uuid, uuid, text, boolean) from public, anon, authenticated;
grant execute on function private.publication_finish(uuid, uuid, text, boolean) to service_role;

-- 실패 분류: transient(5xx·네트워크, 지수 백오프 최대 3회) · quota(횟수 미차감, PT 자정 이후) · reconnect(횟수 미차감)
--           · unknown(결과 불명 → needs_check) · permanent(failed)
create function private.publication_attempt_fail(p_publication_id uuid, p_attempt_token uuid, p_kind text, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pub public.publications := private.publication_attempt(p_publication_id, p_attempt_token);
  v_has_session boolean := exists (select 1 from public.publication_upload_sessions where publication_id = p_publication_id);
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
      update public.publications set retry_count = least(v_n, 3) where id = v_pub.id;
    when 'quota' then
      v_status := 'retry_wait';
      v_next := private.youtube_quota_reset_at();
      -- 프로젝트 쿼터 소진이면 오늘 남은 insert 를 막는다(채널 한도 uploadLimitExceeded 는 그 채널만)
      if v_code = 'quotaExceeded' then
        insert into public.youtube_upload_quota (day, used)
        values ((now() at time zone 'America/Los_Angeles')::date, 100)
        on conflict (day) do update set used = greatest(public.youtube_upload_quota.used, 100), updated_at = now();
      end if;
    when 'reconnect' then
      v_status := 'reconnect_wait';
    when 'unknown' then
      v_status := 'needs_check';
    when 'permanent' then
      v_status := 'failed';
    else
      raise exception '실패 분류가 올바르지 않습니다' using errcode = '22023';
  end case;
  update public.publications
  set status = v_status, next_attempt_at = v_next, attempt_token = null, error = p_kind || ':' || v_code
  where id = v_pub.id;
  return jsonb_build_object('status', v_status, 'next_attempt_at', v_next);
end;
$$;
revoke execute on function private.publication_attempt_fail(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function private.publication_attempt_fail(uuid, uuid, text, text) to service_role;

-- ── 7) 사용자 재시도(소유자) ──────────────────────────────────
-- failed · needs_check · reconnect_wait 에서, 영상 ID 없고 세션이 끝나지 않은 경우에만.
-- 바로 retry_wait(문구 고정, 선점 때 6/6 재판정). 세션이 있으면 상태 조회로 이어 올린다.
create function private.publication_retry(p_project_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pub public.publications;
  v_session public.publication_upload_sessions;
begin
  perform private.publish_owned(p_project_id, true);
  select * into v_pub from public.publications where project_id = p_project_id for update;
  if v_pub.id is null or v_pub.status not in ('failed', 'needs_check', 'reconnect_wait')
     or v_pub.platform_video_id is not null then
    raise exception '지금은 다시 시도할 수 없습니다' using errcode = '55000';
  end if;
  select * into v_session from public.publication_upload_sessions where publication_id = v_pub.id for update;
  if v_session.completed_at is not null then
    raise exception '이미 업로드가 끝난 발행입니다' using errcode = '55000';
  end if;
  -- 사용자가 결과 불명 상태를 확인함 → 세션이 사라졌으면 새로 올려도 된다
  if v_session.publication_id is not null and v_pub.status = 'needs_check' then
    update public.publication_upload_sessions set restart_allowed = true where publication_id = v_pub.id;
  end if;
  update public.publications
  set status = 'retry_wait', retry_count = 0, error = null, attempt_token = null, next_attempt_at = now()
  where id = v_pub.id;
  return jsonb_build_object('status', 'retry_wait');
end;
$$;
revoke execute on function private.publication_retry(uuid) from public, anon, service_role;
grant execute on function private.publication_retry(uuid) to authenticated;

-- ── 8) public 래퍼 ───────────────────────────────────────────
create function public.publication_claim()
returns jsonb language sql security invoker set search_path = ''
as $$ select private.publication_claim(); $$;
create function public.publication_session_begin(p_publication_id uuid, p_attempt_token uuid)
returns jsonb language sql security invoker set search_path = ''
as $$ select private.publication_session_begin(p_publication_id, p_attempt_token); $$;
create function public.publication_session_save(p_publication_id uuid, p_attempt_token uuid,
                                                p_session_uri text, p_total_bytes bigint)
returns void language sql security invoker set search_path = ''
as $$ select private.publication_session_save(p_publication_id, p_attempt_token, p_session_uri, p_total_bytes); $$;
create function public.publication_session_discard(p_publication_id uuid, p_attempt_token uuid)
returns boolean language sql security invoker set search_path = ''
as $$ select private.publication_session_discard(p_publication_id, p_attempt_token); $$;
create function public.publication_finish(p_publication_id uuid, p_attempt_token uuid, p_video_id text,
                                          p_test_private boolean)
returns jsonb language sql security invoker set search_path = ''
as $$ select private.publication_finish(p_publication_id, p_attempt_token, p_video_id, p_test_private); $$;
create function public.publication_attempt_fail(p_publication_id uuid, p_attempt_token uuid, p_kind text, p_code text)
returns jsonb language sql security invoker set search_path = ''
as $$ select private.publication_attempt_fail(p_publication_id, p_attempt_token, p_kind, p_code); $$;
create function public.publication_retry(p_project_id uuid)
returns jsonb language sql security invoker set search_path = ''
as $$ select private.publication_retry(p_project_id); $$;

comment on function public.publication_claim() is '업로드 선점(6/6 재판정 + uploading 전환 + 시도 토큰). 업로더(service_role) 전용';
comment on function public.publication_retry(uuid) is '업로드 다시 시도(소유자, failed·needs_check·reconnect_wait). 사용자 세션으로 호출';

revoke execute on function public.publication_claim() from public, anon, authenticated;
revoke execute on function public.publication_session_begin(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.publication_session_save(uuid, uuid, text, bigint) from public, anon, authenticated;
revoke execute on function public.publication_session_discard(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.publication_finish(uuid, uuid, text, boolean) from public, anon, authenticated;
revoke execute on function public.publication_attempt_fail(uuid, uuid, text, text) from public, anon, authenticated;
revoke execute on function public.publication_retry(uuid) from public, anon, service_role;
grant execute on function public.publication_claim() to service_role;
grant execute on function public.publication_session_begin(uuid, uuid) to service_role;
grant execute on function public.publication_session_save(uuid, uuid, text, bigint) to service_role;
grant execute on function public.publication_session_discard(uuid, uuid) to service_role;
grant execute on function public.publication_finish(uuid, uuid, text, boolean) to service_role;
grant execute on function public.publication_attempt_fail(uuid, uuid, text, text) to service_role;
grant execute on function public.publication_retry(uuid) to authenticated;
