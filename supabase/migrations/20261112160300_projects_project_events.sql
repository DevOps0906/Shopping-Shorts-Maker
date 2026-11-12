-- task-010: projects · project_events
-- 근거: docs/05_DATA_MODEL.md 1·2절, 3절 projects·project_events, docs/planning.md 17-4
-- account_id 변경 금지(첫 publication 뒤) 트리거는 publications 테이블과 함께 task-011에서 추가한다.

create table public.projects (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  -- 1 프로젝트 = 1 채널. 복합 FK로 남의 채널을 참조할 수 없다.
  account_id uuid not null,
  category_id uuid references public.categories (id),
  name text not null,
  -- 함수 전용: authenticated INSERT·UPDATE 불가
  current_step smallint not null default 1 check (current_step between 1 and 6),
  step_status jsonb not null default
    '{"1":"idle","2":"idle","3":"idle","4":"idle","5":"idle","6":"idle"}'::jsonb
    check (
      jsonb_typeof(step_status) = 'object'
      and step_status ?& array['1', '2', '3', '4', '5', '6']
      and not jsonb_path_exists(
        step_status,
        '$.* ? (!(@ == "idle" || @ == "running" || @ == "suggested" || @ == "ready" || @ == "change" || @ == "approved"))'
      )
    ),
  -- 진행 중 · 발행 대기 · 예약됨 · 업로드됨. 발행 흐름이 바꾸므로 서버(SR) 전용
  status text not null default 'in_progress'
    check (status in ('in_progress', 'awaiting_publish', 'scheduled', 'uploaded')),
  target_sec smallint not null default 15 check (target_sec in (15, 20)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (account_id, user_id) references public.accounts (id, user_id)
);

comment on table public.projects is '숏폼 프로젝트. 1 프로젝트 = 1 채널, current_step·step_status는 함수 전용, status는 서버(SR) 전용';

create index projects_user_id_idx on public.projects (user_id);
create index projects_account_id_user_id_idx on public.projects (account_id, user_id);
create index projects_category_id_idx on public.projects (category_id);

alter table public.projects enable row level security;

revoke all on public.projects from anon, authenticated;
grant select, delete on public.projects to authenticated;
grant insert (user_id, account_id, category_id, name, target_sec) on public.projects to authenticated;
grant update (account_id, category_id, name, target_sec) on public.projects to authenticated;

create policy projects_select_own on public.projects
  for select to authenticated using (user_id = (select auth.uid()));
create policy projects_insert_own on public.projects
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy projects_update_own on public.projects
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
create policy projects_delete_own on public.projects
  for delete to authenticated using (user_id = (select auth.uid()));

-- 함수 전용·서버 전용 열 초기값 강제(열 GRANT 회수에 더한 2중 방어)
create function private.projects_force_initial_state()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- 서버(SR)·마이그레이션 주체가 아니면 강제. 트리거 안에서 private 함수를 부르지 않는다(authenticated에 USAGE 없음).
  if current_user not in ('postgres', 'service_role', 'supabase_admin') then
    new.current_step := 1;
    new.step_status := '{"1":"idle","2":"idle","3":"idle","4":"idle","5":"idle","6":"idle"}'::jsonb;
    new.status := 'in_progress';
  end if;
  return new;
end;
$$;
revoke execute on function private.projects_force_initial_state() from public, anon, authenticated;

create trigger projects_force_initial_state
  before insert on public.projects
  for each row execute function private.projects_force_initial_state();

create trigger projects_set_updated_at
  before update on public.projects
  for each row execute function private.set_updated_at();

create table public.project_events (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  step smallint not null check (step between 1 and 6),
  event text not null
    check (event in ('step_started', 'step_approved', 'step_change_requested', 'render_succeeded')),
  created_at timestamptz not null default now()
);

comment on table public.project_events is '단계 이벤트(17-9 지표). 본인 읽기, 쓰기는 서버(SR)만(추가 전용)';

create index project_events_project_id_idx on public.project_events (project_id);

alter table public.project_events enable row level security;

-- 쓰기는 서버(SR)만(추가 전용). authenticated는 본인 프로젝트 이벤트 읽기만.
revoke all on public.project_events from anon, authenticated;
grant select on public.project_events to authenticated;

create policy project_events_select_own on public.project_events
  for select to authenticated
  using (
    exists (
      select 1 from public.projects p
      where p.id = project_events.project_id
        and p.user_id = (select auth.uid())
    )
  );
