-- task-024a 통합 보안 리뷰 반영: 결과 불명(needs_check)에서 새 업로드는 사용자 "영상 없음 확인"(publication_confirm_absent)만
-- - publication_retry 는 needs_check 를 거부한다(failed·reconnect_wait 만). 세션 재시작 허용(restart_allowed)을 더는 세우지 않는다.
-- - 세션 404·410 이면 업로더는 항상 needs_check 로 둔다. 세션 폐기는 confirm_absent(소유자·위험 확인·감사 이벤트)만 한다.
-- - 그래서 restart_allowed 로 세션을 지우던 publication_session_discard 를 없애고, 남아 있을 수 있는 표시도 지운다.

update public.publication_upload_sessions set restart_allowed = false where restart_allowed;
alter table public.publication_upload_sessions
  add constraint publication_upload_sessions_no_restart check (not restart_allowed);
comment on column public.publication_upload_sessions.restart_allowed is
  '사용 안 함(20261112280200). 새 업로드는 publication_confirm_absent 가 세션을 지운 뒤에만';

drop function public.publication_session_discard(uuid, uuid);
drop function private.publication_session_discard(uuid, uuid);

create or replace function private.publication_retry(p_project_id uuid)
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
  -- needs_check 는 여기서 다시 시도하지 않는다(중복 업로드 위험) → publication_confirm_absent
  if v_pub.id is null or v_pub.status not in ('failed', 'reconnect_wait')
     or v_pub.platform_video_id is not null then
    raise exception '지금은 다시 시도할 수 없습니다' using errcode = '55000';
  end if;
  select * into v_session from public.publication_upload_sessions where publication_id = v_pub.id for update;
  if v_session.completed_at is not null then
    raise exception '이미 업로드가 끝난 발행입니다' using errcode = '55000';
  end if;
  -- 세션이 있으면 업로더가 상태 조회로 이어 올린다(사라졌으면 needs_check)
  update public.publications
  set status = 'retry_wait', retry_count = 0, error = null, attempt_token = null, next_attempt_at = now()
  where id = v_pub.id;
  return jsonb_build_object('status', 'retry_wait');
end;
$$;
comment on function public.publication_retry(uuid) is
  '업로드 다시 시도(소유자, failed·reconnect_wait). needs_check 는 publication_confirm_absent 로만';
