-- task-024a 리뷰 반영: 업로드 세션이 있는 발행은 예약 시각·정책 판정보다 상태 조회를 먼저 한다(중복 업로드 방지)
-- - 문제: finish 가 RT001 로 미뤄지거나 멈춘 시도(30분)로 정리된 뒤, YouTube 에는 영상이 있는데 선점이 예약 시각(지금+5분)·
--   정책 판정으로 needs_check 를 만들면, 사용자가 "영상 없음 확인"을 눌러 같은 영상을 다시 올릴 수 있었다.
-- - 선점(publication_claim): 세션이 있는 행은 예약 시각·정책 판정 없이 선점해 세션을 넘긴다. 업로더는 상태 조회를 먼저 하고
--   완료면 바로 finish 로 기록한다(완료 기록에는 예약 시각 제한이 없다).
-- - 이어 올리기 직전(publication_resume_check): 아직 덜 올라갔을 때만 예약 시각·정책을 판정하고, 통과 못 하면 needs_check.
-- - 멈춘 시도: 세션이 있으면 바로 needs_check 로 두지 않고 retry_wait 로 돌려 상태 조회를 거치게 한다
--   (재시도 횟수 1 차감, 3회째면 needs_check).

create or replace function private.publication_claim()
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
  -- 멈춘 시도(30분 넘게 uploading): 일시 오류 1회. 세션이 있으면 다음 선점이 상태 조회로 결과를 확인한다
  for v_stale in
    select p.id, p.retry_count,
           exists (select 1 from public.publication_upload_sessions s where s.publication_id = p.id) as has_session
    from public.publications p
    where p.status = 'uploading' and p.attempt_started_at < now() - interval '30 minutes'
    for update of p skip locked
  loop
    update public.publications
    set status = case when v_stale.retry_count + 1 < 3 then 'retry_wait'
                      when v_stale.has_session then 'needs_check'
                      else 'failed' end,
        retry_count = least(retry_count + 1, 3),
        next_attempt_at = case when v_stale.retry_count + 1 < 3 then now() end,
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

  -- 연결이 끊긴 채널: 재시도 횟수를 쓰지 않고 재연결 대기(세션은 그대로, 재연결 뒤 상태 조회)
  if v_ctx.external_channel_id is null or v_ctx.account_status <> 'connected' then
    update public.publications
    set status = 'reconnect_wait', error = 'reconnect:reconnect_required', attempt_token = null, next_attempt_at = null
    where id = v_pub.id;
    return jsonb_build_object('claimed', false, 'reason', 'reconnect_wait', 'publication_id', v_pub.id);
  end if;

  -- 세션이 없을 때만 여기서 판정한다. 세션이 있으면 업로더가 상태 조회 → 완료면 기록, 덜 올라갔으면 publication_resume_check
  if not v_has_session then
    -- 예약 시각이 지금+5분보다 이르면 올리지 않는다(자동 즉시 공개 금지 → 사용자 확인)
    if v_pub.mode = 'scheduled' and (v_pub.scheduled_at is null or v_pub.scheduled_at < now() + interval '5 minutes') then
      perform private.publication_block(v_pub, false, 'confirm:schedule_passed');
      return jsonb_build_object('claimed', false, 'reason', 'schedule_passed', 'publication_id', v_pub.id);
    end if;

    -- 정책 6/6 재판정(publish_recheck 와 같은 판정, 저장된 문구)
    v_policy := private.publish_evaluate(v_pub.project_id, v_pub.title, v_pub.body, v_pub.hashtags);
    if (v_policy ->> 'passed')::int <> 6 then
      perform private.publication_block(v_pub, false, 'confirm:policy_failed');
      return jsonb_build_object('claimed', false, 'reason', 'policy_failed', 'publication_id', v_pub.id);
    end if;
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

-- 이어 올리기 직전 판정: 상태 조회가 "덜 올라감"일 때만 부른다. 예약 시각·정책을 통과 못 하면 needs_check(세션 유지)
create function private.publication_resume_check(p_publication_id uuid, p_attempt_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pub public.publications := private.publication_attempt(p_publication_id, p_attempt_token);
  v_policy jsonb;
begin
  if not exists (select 1 from public.publication_upload_sessions where publication_id = v_pub.id) then
    raise exception '업로드 세션이 없습니다' using errcode = '55000';
  end if;
  if v_pub.mode = 'scheduled' and (v_pub.scheduled_at is null or v_pub.scheduled_at < now() + interval '5 minutes') then
    perform private.publication_block(v_pub, true, 'confirm:schedule_passed');
    return jsonb_build_object('ok', false, 'status', 'needs_check', 'reason', 'schedule_passed');
  end if;
  v_policy := private.publish_evaluate(v_pub.project_id, v_pub.title, v_pub.body, v_pub.hashtags);
  if (v_policy ->> 'passed')::int <> 6 then
    perform private.publication_block(v_pub, true, 'confirm:policy_failed');
    return jsonb_build_object('ok', false, 'status', 'needs_check', 'reason', 'policy_failed');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function private.publication_resume_check(uuid, uuid) from public, anon, authenticated;
grant execute on function private.publication_resume_check(uuid, uuid) to service_role;

create function public.publication_resume_check(p_publication_id uuid, p_attempt_token uuid)
returns jsonb language sql security invoker set search_path = ''
as $$ select private.publication_resume_check(p_publication_id, p_attempt_token); $$;
comment on function public.publication_resume_check(uuid, uuid) is
  '이어 올리기 직전 예약 시각·정책 재판정(세션 있는 시도, 미통과면 needs_check). 업로더(service_role) 전용';
revoke execute on function public.publication_resume_check(uuid, uuid) from public, anon, authenticated;
grant execute on function public.publication_resume_check(uuid, uuid) to service_role;
