-- task-024a 보완: YouTube 한도 검사 · needs_check 출구(사용자가 Studio 에서 영상 없음을 확인)
-- 1) 한도: 제목 100자 · 설명란 5000바이트(UTF-8) · 태그 합 500자(태그 길이 + 구분 쉼표, 공백 있는 태그는 따옴표 2자)
--    - 발행 준비(prepare_publication, 20261112260200 정의)에 검사만 더한다(create or replace, 다른 로직·시그니처·권한 그대로).
--    - 업로더는 session_begin 전에 같은 한도를 다시 보고, 넘으면 publication_reject_copy 로 자동 재시도 없이 발행 준비를 푼다
--      (invalidated, confirm:<코드>) → 사용자가 문구를 줄여 다시 발행 준비한다.
-- 2) publication_confirm_absent: needs_check 에서 사용자가 "YouTube Studio 에 영상이 없음"을 확인 → 세션 폐기 · retry_wait(새 업로드).
--    감사용으로 project_events 에 upload_absent_confirmed(6단계)를 남긴다.

create function private.youtube_tags_length(p_tags text[])
returns integer
language sql
immutable
set search_path = ''
as $$
  select coalesce(sum(char_length(t) + case when t ~ '[[:space:]]' then 2 else 0 end), 0)::int
         + greatest(coalesce(cardinality(p_tags), 0) - 1, 0)
  from unnest(coalesce(p_tags, '{}'::text[])) t;
$$;
revoke execute on function private.youtube_tags_length(text[]) from public, anon, authenticated, service_role;

-- ── 1) 발행 준비 한도 검사(20261112260200 본문 그대로 + 한도 검사) ─────────
create or replace function private.prepare_publication(
  p_project_id uuid, p_mode text, p_scheduled_at timestamptz, p_title text, p_body text,
  p_hashtags text[], p_purchase_guide boolean, p_pin_comment boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status jsonb;
  v_account uuid;
  v_policy jsonb;
  v_tags text[] := private.publish_clean_hashtags(p_hashtags);
  v_title text := btrim(coalesce(p_title, ''));
  v_existing text;
  v_description text;
  v_row public.publications;
begin
  perform private.publish_owned(p_project_id, true);
  select step_status, account_id into v_status, v_account from public.projects where id = p_project_id;
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

  select status into v_existing from public.publications where project_id = p_project_id;
  if v_existing is not null and v_existing not in ('pending', 'invalidated') then
    raise exception '이미 예약·업로드가 시작된 발행입니다' using errcode = '55000';
  end if;

  v_policy := private.publish_evaluate(p_project_id, v_title, p_body, v_tags);
  if (v_policy ->> 'passed')::int <> 6 then
    raise exception '정책 점검 6개 항목을 모두 통과해야 발행할 수 있습니다' using errcode = 'PC001';
  end if;

  v_description := private.publish_description(
    v_policy ->> 'disclosure',
    case when coalesce(p_purchase_guide, true) then v_policy ->> 'purchase' else '' end,
    p_body, v_policy ->> 'credits', v_tags);
  -- YouTube 한도(task-024a 보완): 설명란 5000바이트(UTF-8)·태그 합 500자. 제목 100자는 위에서 검사
  if octet_length(v_description) > 5000 then
    raise exception '설명란이 YouTube 한도(5000바이트)를 넘습니다. 본문을 줄여 다시 발행 준비해 주세요' using errcode = 'PC002';
  end if;
  if private.youtube_tags_length(v_tags) > 500 then
    raise exception '해시태그가 YouTube 태그 한도(500자)를 넘습니다' using errcode = 'PC003';
  end if;

  insert into public.publications (project_id, account_id, mode, scheduled_at, title, body, description, hashtags,
                                   pin_comment, prepared_at, status)
  values (p_project_id, v_account, p_mode, case when p_mode = 'scheduled' then p_scheduled_at end, v_title,
          nullif(btrim(coalesce(p_body, '')), ''), v_description, v_tags, coalesce(p_pin_comment, false), now(), 'pending')
  on conflict (project_id) do update
    set mode = excluded.mode, scheduled_at = excluded.scheduled_at, title = excluded.title, body = excluded.body,
        description = excluded.description, hashtags = excluded.hashtags, pin_comment = excluded.pin_comment,
        prepared_at = excluded.prepared_at, status = 'pending'
  returning * into v_row;

  update public.projects set status = 'awaiting_publish' where id = p_project_id;

  return jsonb_build_object('id', v_row.id, 'mode', v_row.mode, 'scheduled_at', v_row.scheduled_at,
                            'title', v_row.title, 'description', v_row.description,
                            'prepared_at', v_row.prepared_at, 'status', v_row.status);
end;
$$;

-- ── 2) 업로더: 문구가 한도를 넘으면 자동 재시도 없이 발행 준비 해제 ──────────
create function private.publication_reject_copy(p_publication_id uuid, p_attempt_token uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pub public.publications := private.publication_attempt(p_publication_id, p_attempt_token);
begin
  if p_code is null or p_code not in ('title_too_long', 'description_too_long', 'tags_too_long') then
    raise exception '한도 코드가 올바르지 않습니다' using errcode = '22023';
  end if;
  -- 세션이 생긴 뒤에는 문구가 이미 YouTube 에 갔다 → 이 경로가 아니다
  if exists (select 1 from public.publication_upload_sessions where publication_id = v_pub.id) then
    raise exception '업로드 세션이 있는 발행입니다' using errcode = '55000';
  end if;
  perform private.publication_block(v_pub, false, 'confirm:' || p_code);
  return jsonb_build_object('status', 'invalidated');
end;
$$;
revoke execute on function private.publication_reject_copy(uuid, uuid, text) from public, anon, authenticated;
grant execute on function private.publication_reject_copy(uuid, uuid, text) to service_role;

-- ── 3) needs_check 출구 ───────────────────────────────────────
alter table public.project_events drop constraint project_events_event_check;
alter table public.project_events add constraint project_events_event_check
  check (event in ('step_started', 'step_approved', 'step_change_requested', 'render_succeeded',
                   'upload_absent_confirmed'));

create function private.publication_confirm_absent(p_project_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pub public.publications;
begin
  perform private.publish_owned(p_project_id, true);
  select * into v_pub from public.publications where project_id = p_project_id for update;
  if v_pub.id is null or v_pub.status <> 'needs_check' or v_pub.platform_video_id is not null then
    raise exception '지금은 새로 업로드할 수 없습니다' using errcode = '55000';
  end if;
  if exists (select 1 from public.publication_upload_sessions
             where publication_id = v_pub.id and completed_at is not null) then
    raise exception '이미 업로드가 끝난 발행입니다' using errcode = '55000';
  end if;
  delete from public.publication_upload_sessions where publication_id = v_pub.id;
  update public.publications
  set status = 'retry_wait', retry_count = 0, error = null, attempt_token = null, next_attempt_at = now()
  where id = v_pub.id;
  insert into public.project_events (project_id, step, event) values (p_project_id, 6, 'upload_absent_confirmed');
  return jsonb_build_object('status', 'retry_wait');
end;
$$;
revoke execute on function private.publication_confirm_absent(uuid) from public, anon, service_role;
grant execute on function private.publication_confirm_absent(uuid) to authenticated;

-- ── 4) public 래퍼 ───────────────────────────────────────────
create function public.publication_reject_copy(p_publication_id uuid, p_attempt_token uuid, p_code text)
returns jsonb language sql security invoker set search_path = ''
as $$ select private.publication_reject_copy(p_publication_id, p_attempt_token, p_code); $$;
create function public.publication_confirm_absent(p_project_id uuid)
returns jsonb language sql security invoker set search_path = ''
as $$ select private.publication_confirm_absent(p_project_id); $$;
comment on function public.publication_confirm_absent(uuid) is
  '결과 불명(needs_check)에서 사용자가 Studio 에 영상이 없음을 확인 → 세션 폐기·새 업로드. 사용자 세션으로 호출';

revoke execute on function public.publication_reject_copy(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.publication_confirm_absent(uuid) from public, anon, service_role;
grant execute on function public.publication_reject_copy(uuid, uuid, text) to service_role;
grant execute on function public.publication_confirm_absent(uuid) to authenticated;

-- ── 5) 보관 정리 경합(024b RT001): 발행 상태 전환이 RT001 로 취소되면 deferred(횟수 미차감, 5분 뒤) ──
--    세션은 남아 있으므로 다음 시도는 상태 조회로 완료를 확인해 기록한다(재업로드 없음). 무한 대기는 예약 TTL(30분)이 막는다.
create or replace function private.publication_attempt_fail(p_publication_id uuid, p_attempt_token uuid, p_kind text, p_code text)
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
  update public.publications
  set status = v_status, next_attempt_at = v_next, attempt_token = null, error = p_kind || ':' || v_code
  where id = v_pub.id;
  return jsonb_build_object('status', v_status, 'next_attempt_at', v_next);
end;
$$;
revoke execute on function private.publication_attempt_fail(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function private.publication_attempt_fail(uuid, uuid, text, text) to service_role;
