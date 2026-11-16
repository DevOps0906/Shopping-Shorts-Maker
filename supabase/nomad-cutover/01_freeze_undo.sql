-- 01_freeze_undo.sql — 01_freeze.sql 을 정확히 되돌린다(쓰기 재개 전까지만 의미 있음).
-- 실행: psql "<DB 주소>" -v ON_ERROR_STOP=1 -f supabase/nomad-cutover/01_freeze_undo.sql   (postgres 역할)
-- nomad_cutover.freeze_state 의 기록으로 권한·cron·가입 트리거 함수를 복원하고, 기록과 같아졌는지 확인한 뒤 스키마를 지운다.
-- 02 를 apply 한 뒤 되돌린다면 먼저 docs/ops/NOMAD_DB_CUTOVER.md "되돌리기" 의 새 표 비우기를 한다(이 파일은 새 표를 건드리지 않는다).
begin;

do $$
begin
  if to_regclass('nomad_cutover.freeze_state') is null then
    raise exception 'freeze 기록이 없습니다(nomad_cutover.freeze_state). 되돌릴 것이 없습니다';
  end if;
end $$;

do $$
declare
  r record; n int;
  touched oid[] := array[0::oid, 'anon'::regrole::oid, 'authenticated'::regrole::oid, 'service_role'::regrole::oid];
begin
  -- 표·열 권한: freeze 가 회수한 종류만 기록대로 다시 준다
  for r in
    select t.ident, a.privilege_type, a.grantee, a.is_grantable
    from nomad_cutover.freeze_state t, aclexplode(t.acl) a
    where t.kind = 'table' and a.grantee = any (touched)
      and a.privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
  loop
    execute format('grant %s on table %s to %s%s', r.privilege_type, r.ident,
      case when r.grantee = 0 then 'public' else quote_ident(r.grantee::regrole::text) end,
      case when r.is_grantable then ' with grant option' else '' end);
  end loop;

  for r in
    select split_part(t.ident, '|', 1) as tbl, split_part(t.ident, '|', 2) as col, a.privilege_type, a.grantee, a.is_grantable
    from nomad_cutover.freeze_state t, aclexplode(t.acl) a
    where t.kind = 'column' and a.grantee = any (touched)
      and a.privilege_type in ('INSERT', 'UPDATE')
  loop
    execute format('grant %s (%I) on table %s to %s%s', r.privilege_type, r.col, r.tbl,
      case when r.grantee = 0 then 'public' else quote_ident(r.grantee::regrole::text) end,
      case when r.is_grantable then ' with grant option' else '' end);
  end loop;

  -- RPC 실행 권한(기록이 null 이면 기본값 = PUBLIC 실행)
  for r in
    select t.ident, a.grantee, a.is_grantable
    from nomad_cutover.freeze_state t,
         aclexplode(coalesce(t.acl, acldefault('f', (t.detail ->> 'owner')::regrole::oid))) a
    where t.kind = 'function' and a.grantee = any (touched) and a.privilege_type = 'EXECUTE'
  loop
    execute format('grant execute on function %s to %s%s', r.ident,
      case when r.grantee = 0 then 'public' else quote_ident(r.grantee::regrole::text) end,
      case when r.is_grantable then ' with grant option' else '' end);
  end loop;

  -- cron
  for r in select ident, detail from nomad_cutover.freeze_state where kind = 'cron' loop
    perform cron.schedule(r.ident, r.detail ->> 'schedule', r.detail ->> 'command');
    if not (r.detail ->> 'active')::boolean then
      perform cron.alter_job((select jobid from cron.job where jobname = r.ident), active := false);
    end if;
  end loop;

  -- 가입 트리거 함수 원래 정의
  for r in select detail from nomad_cutover.freeze_state where kind = 'trigger_function' loop
    execute r.detail ->> 'def';
  end loop;

  -- ── 확인: 기록과 같아야 한다(aclitem 순서는 무시) ──────────
  select count(*) into n
  from nomad_cutover.freeze_state t join pg_class c on c.oid = t.ident::regclass
  where t.kind = 'table'
    and array(select x::text from unnest(coalesce(t.acl, acldefault('r', c.relowner))) x order by 1)
     <> array(select x::text from unnest(coalesce(c.relacl, acldefault('r', c.relowner))) x order by 1);
  if n > 0 then raise exception 'undo 확인 실패: 표 권한이 기록과 다른 표 %개', n; end if;

  select count(*) into n
  from (
    select t.ident, array(select x::text from unnest(t.acl) x order by 1) as acl
    from nomad_cutover.freeze_state t where t.kind = 'column'
  ) w
  full join (
    select a.attrelid::regclass::text || '|' || a.attname as ident,
           array(select x::text from unnest(a.attacl) x order by 1) as acl
    from pg_attribute a
    join nomad_cutover.freeze_state t on t.kind = 'table' and t.ident = a.attrelid::regclass::text
    where a.attnum > 0 and not a.attisdropped and coalesce(cardinality(a.attacl), 0) > 0
  ) h using (ident)
  where w.acl is distinct from h.acl;
  if n > 0 then raise exception 'undo 확인 실패: 열 권한이 기록과 다른 열 %개', n; end if;

  select count(*) into n
  from nomad_cutover.freeze_state t join pg_proc p on p.oid = t.ident::regprocedure
  where t.kind = 'function'
    and array(select x::text from unnest(coalesce(t.acl, acldefault('f', p.proowner))) x order by 1)
     <> array(select x::text from unnest(coalesce(p.proacl, acldefault('f', p.proowner))) x order by 1);
  if n > 0 then raise exception 'undo 확인 실패: RPC 권한이 기록과 다른 함수 %개', n; end if;

  select count(*) into n
  from nomad_cutover.freeze_state t
  left join cron.job j on j.jobname = t.ident
  where t.kind = 'cron'
    and (j.jobname is null or j.schedule <> t.detail ->> 'schedule' or j.command <> t.detail ->> 'command'
         or j.active <> (t.detail ->> 'active')::boolean);
  if n > 0 then raise exception 'undo 확인 실패: cron 작업 %개가 기록과 다름', n; end if;

  select count(*) into n
  from nomad_cutover.freeze_state t
  where t.kind = 'trigger_function'
    and pg_get_functiondef('private.handle_new_user()'::regprocedure) <> t.detail ->> 'def';
  if n > 0 then raise exception 'undo 확인 실패: private.handle_new_user() 정의가 기록과 다름'; end if;
end $$;

drop schema nomad_cutover cascade;

commit;
