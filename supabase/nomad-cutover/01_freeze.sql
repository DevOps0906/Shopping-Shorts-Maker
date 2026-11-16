-- 01_freeze.sql — 옛 public 표 쓰기 중지(1회, 사람이 실행). 되돌림: 01_freeze_undo.sql
-- 실행: psql "<DB 주소>" -v ON_ERROR_STOP=1 -f supabase/nomad-cutover/01_freeze.sql   (postgres 역할)
-- 하는 일(표·함수·데이터는 지우지 않는다):
--   1) 옛 public·private 표의 insert·update·delete·truncate 를 PUBLIC·anon·authenticated·service_role 에서 회수
--      (표 단위 회수는 같은 종류의 열 단위 권한도 함께 회수한다)
--   2) 옛 public RPC(nomad_* 제외)의 execute 를 같은 대상에서 회수 — security definer RPC 로 쓰는 길까지 막는다
--   3) 옛 pg_cron 작업 sweep-jobs·collect-metrics·cleanup-analytics 를 unschedule(정의 기록)
--   4) 옛 가입 트리거 on_auth_user_created_user_profile 은 auth.users 소유자가 아니라 disable 할 수 없으므로
--      트리거 함수 private.handle_new_user() 본문을 아무것도 안 하는 본문으로 바꾼다(원래 정의 기록)
-- 워커(worker_role)는 막지 않는다: 쓰기 중지 후 옛 pgmq 큐(render·tts·analyze·sources)를 비우게 둔다.
-- 큐가 비었는지는 01_queue_check.sql 로 확인한다(비어 있지 않으면 02 가 중단한다).
-- 되돌리기 정보는 비노출 스키마 nomad_cutover.freeze_state 에 남는다(undo 가 읽고 스키마를 지운다).
begin;

do $$
begin
  if to_regnamespace('nomad_cutover') is not null then
    raise exception '이미 freeze 상태입니다(nomad_cutover 스키마 있음). 되돌리려면 01_freeze_undo.sql';
  end if;
end $$;

create schema nomad_cutover;
revoke all on schema nomad_cutover from public;
comment on schema nomad_cutover is 'Shorts nomad DB 전환용 1회 기록(01_freeze). API 비노출. undo 또는 전환 확정 후 삭제';

create table nomad_cutover.freeze_state (
  kind   text not null check (kind in ('table', 'column', 'function', 'cron', 'trigger_function')),
  ident  text not null,
  acl    aclitem[],
  detail jsonb,
  primary key (kind, ident)
);
comment on table nomad_cutover.freeze_state is 'freeze 직전 권한·cron·트리거 함수 정의. 01_freeze_undo.sql 이 이 값으로 정확히 되돌린다';
alter table nomad_cutover.freeze_state enable row level security;
revoke all on nomad_cutover.freeze_state from public, anon, authenticated, service_role;

-- ── 기록 ───────────────────────────────────────────────────
insert into nomad_cutover.freeze_state (kind, ident, acl, detail)
select 'table', c.oid::regclass::text, c.relacl, jsonb_build_object('owner', c.relowner::regrole::text)
from pg_class c
where c.relnamespace in ('public'::regnamespace, 'private'::regnamespace)
  and c.relkind in ('r', 'p')
  and c.relname not like 'nomad\_%'
  and not exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e');

insert into nomad_cutover.freeze_state (kind, ident, acl)
select 'column', a.attrelid::regclass::text || '|' || a.attname, a.attacl
from pg_attribute a
join nomad_cutover.freeze_state t on t.kind = 'table' and t.ident = a.attrelid::regclass::text
where a.attnum > 0 and not a.attisdropped and a.attacl is not null;

insert into nomad_cutover.freeze_state (kind, ident, acl, detail)
select 'function', p.oid::regprocedure::text, p.proacl, jsonb_build_object('owner', p.proowner::regrole::text)
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname not like 'nomad\_%'
  and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e');

insert into nomad_cutover.freeze_state (kind, ident, detail)
select 'cron', j.jobname, jsonb_build_object('schedule', j.schedule, 'command', j.command, 'active', j.active)
from cron.job j
where j.jobname in ('sweep-jobs', 'collect-metrics', 'cleanup-analytics');

insert into nomad_cutover.freeze_state (kind, ident, detail)
select 'trigger_function', 'private.handle_new_user()', jsonb_build_object('def', pg_get_functiondef('private.handle_new_user()'::regprocedure))
where to_regprocedure('private.handle_new_user()') is not null;

-- ── 중지 ───────────────────────────────────────────────────
do $$
declare r record; n int;
begin
  for r in select ident from nomad_cutover.freeze_state where kind = 'table' loop
    execute format('revoke insert, update, delete, truncate on table %s from public, anon, authenticated, service_role', r.ident);
  end loop;
  for r in select ident from nomad_cutover.freeze_state where kind = 'function' loop
    execute format('revoke execute on function %s from public, anon, authenticated, service_role', r.ident);
  end loop;
  for r in select ident from nomad_cutover.freeze_state where kind = 'cron' loop
    perform cron.unschedule(r.ident);
  end loop;

  if exists (select 1 from nomad_cutover.freeze_state where kind = 'trigger_function') then
    create or replace function private.handle_new_user()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
    as $f$
    begin
      -- 01_freeze: 전환 중 옛 user_profiles 자동 생성 중지(원래 정의는 nomad_cutover.freeze_state)
      return new;
    end;
    $f$;
  end if;

  -- 확인: 쓰기 권한·RPC 실행 권한이 남아 있으면 중단
  select count(*) into n
  from nomad_cutover.freeze_state t
  cross join (values ('anon'), ('authenticated'), ('service_role')) g(rolname)
  where t.kind = 'table'
    and (has_any_column_privilege(g.rolname, t.ident::regclass, 'INSERT')
      or has_any_column_privilege(g.rolname, t.ident::regclass, 'UPDATE')
      or has_table_privilege(g.rolname, t.ident::regclass, 'DELETE')
      or has_table_privilege(g.rolname, t.ident::regclass, 'TRUNCATE'));
  if n > 0 then raise exception 'freeze 실패: 쓰기 권한이 남은 (표, 역할) %건', n; end if;

  select count(*) into n
  from nomad_cutover.freeze_state t
  cross join (values ('anon'), ('authenticated'), ('service_role')) g(rolname)
  where t.kind = 'function' and has_function_privilege(g.rolname, t.ident::regprocedure, 'EXECUTE');
  if n > 0 then raise exception 'freeze 실패: 실행 권한이 남은 (RPC, 역할) %건', n; end if;

  if exists (select 1 from cron.job where jobname in ('sweep-jobs', 'collect-metrics', 'cleanup-analytics')) then
    raise exception 'freeze 실패: 옛 cron 작업이 남아 있음';
  end if;

  raise notice 'freeze 완료: 표 %개 · 열 권한 %개 · RPC %개 · cron %개 · 가입 트리거 함수 %개',
    (select count(*) from nomad_cutover.freeze_state where kind = 'table'),
    (select count(*) from nomad_cutover.freeze_state where kind = 'column'),
    (select count(*) from nomad_cutover.freeze_state where kind = 'function'),
    (select count(*) from nomad_cutover.freeze_state where kind = 'cron'),
    (select count(*) from nomad_cutover.freeze_state where kind = 'trigger_function');
end $$;

commit;
