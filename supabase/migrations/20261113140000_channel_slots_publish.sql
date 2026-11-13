-- task-034b: 초과 채널의 새 발행(INSERT) 거부 · 한도 초과 사용자의 is_default 변경 거부
-- 근거: tasks/task-034.md(034b), 20261113110000_channel_slots.sql(channel_is_excess)
--
-- - CS005: publications BEFORE INSERT 에서 검사한다. 그 프로젝트의 발행 행이 이미 있으면 통과시킨다: BEFORE INSERT 는
--   ON CONFLICT DO UPDATE(prepare_publication 재준비)에서도 충돌 검사 전에 발화하므로, 첫 발행 준비만 막고 재준비·기존 예약
--   (pending·retry_wait)은 유지하기 위함이다. prepare_publication 이 publish_owned(..., true)로 프로젝트를 잠가 같은 프로젝트의
--   동시 INSERT 경쟁은 없다. 프로젝트당 발행 1건·영상 ID 1회라 우회 이득이 없다. claim·retry·confirm_absent 도 막지 않는다.
--   prepare_publication 은 SECURITY DEFINER(소유자 postgres)이므로 역할 예외를 두지 않는다.
-- - '024 scheduled 전이'는 범위 밖: scheduled 는 업로드 완료 뒤 상태라 새 예약이 아니다.
-- - CS006: 한도를 넘는 슬롯을 가진 사용자는 is_default 를 바꿀 수 없다(기본 채널을 돌려 초과 순위를 바꾸는 우회 차단).
--   슬롯 ≤ 한도면 순위가 초과 여부에 영향이 없으므로 허용. 슬롯 > 한도는 한도 하향으로만 생기므로 advisory lock 은 두지 않는다.
--   SECURITY DEFINER 함수 안에서는 current_user 가 소유자라 역할 예외 검사가 항상 통과하므로, 트리거 함수는 INVOKER 로 두어
--   current_user 로 판별하고, 개수 계산은 auth.uid() = p_user_id 일 때만 답하는 definer 헬퍼를 부른다.

-- ── 1) 초과 채널로 새 발행 거부(CS005) ─────────────────────────
create function private.publications_channel_slot_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
begin
  select p.user_id into v_user from public.projects p where p.id = new.project_id;
  if exists (select 1 from public.publications x where x.project_id = new.project_id) then
    return new;
  end if;
  if v_user is not null and private.channel_is_excess(v_user, new.account_id) then
    raise exception '이 채널은 요금제 채널 수를 넘어 새로 발행할 수 없습니다' using errcode = 'CS005';
  end if;
  return new;
end;
$$;
revoke execute on function private.publications_channel_slot_guard() from public, anon, authenticated, service_role;

create trigger publications_channel_slot_guard
  before insert on public.publications
  for each row execute function private.publications_channel_slot_guard();

-- ── 2) 한도 초과 중 is_default 변경 거부(CS006) ────────────────
-- 호출자 본인(auth.uid())에 대해서만 답한다. 다른 사용자·서버 호출은 false.
create function private.channel_over_limit_self(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user_id is not null and p_user_id = (select auth.uid())
         and private.channel_slot_count(p_user_id) > private.channel_limit_of(p_user_id);
$$;
revoke execute on function private.channel_over_limit_self(uuid) from public, anon, service_role;
grant execute on function private.channel_over_limit_self(uuid) to authenticated;

-- INVOKER: current_user 가 호출 역할이어야 서버·마이그레이션 주체를 구분할 수 있다
create function private.accounts_default_slot_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.is_default is distinct from old.is_default
     and old.external_channel_id is not null and old.disconnected_at is null
     and current_user not in ('postgres', 'service_role', 'supabase_admin')
     and private.channel_over_limit_self(old.user_id) then
    raise exception '요금제 채널 수를 넘은 동안에는 기본 채널을 바꿀 수 없습니다' using errcode = 'CS006';
  end if;
  return new;
end;
$$;
revoke execute on function private.accounts_default_slot_guard() from public, anon, authenticated, service_role;

create trigger accounts_default_slot_guard
  before update of is_default on public.accounts
  for each row execute function private.accounts_default_slot_guard();
