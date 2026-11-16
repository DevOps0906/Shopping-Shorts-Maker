-- task-012: 작업 큐(pgmq) 생성 · 워커 큐 권한 · 개발용 워커 로그인 역할
-- 근거: ADR-0001(종류별 큐 render·tts·analyze, 수집은 큐 없음, pgmq 스키마 PostgREST 비노출), docs/planning.md 17-5
-- - 큐 테이블(pgmq.q_*·a_*)은 RLS를 켜고 worker_role 정책만 둔다. 소유자(postgres)는 작업 생성 함수에서 send.
-- - worker_role 최소 권한: q_* 는 read(UPDATE … RETURNING)·set_vt·archive(DELETE)에 필요한 것만,
--   a_* 는 archive의 INSERT … RETURNING msg_id 에 필요한 INSERT·msg_id 읽기만. send 권한 없음.

create extension if not exists pgmq;

select pgmq.create(q) from unnest(array['render', 'tts', 'analyze']) as q
where not exists (select 1 from pgmq.meta m where m.queue_name = q);

do $$
declare q text;
begin
  foreach q in array array['render', 'tts', 'analyze'] loop
    execute format('alter table pgmq.%I enable row level security', 'q_' || q);
    execute format('alter table pgmq.%I enable row level security', 'a_' || q);
    execute format('revoke all on pgmq.%I from public, anon, authenticated, service_role', 'q_' || q);
    execute format('revoke all on pgmq.%I from public, anon, authenticated, service_role', 'a_' || q);

    execute format('grant select, delete on pgmq.%I to worker_role', 'q_' || q);
    execute format('grant update (vt, read_ct) on pgmq.%I to worker_role', 'q_' || q);
    execute format('grant insert on pgmq.%I to worker_role', 'a_' || q);
    execute format('grant select (msg_id) on pgmq.%I to worker_role', 'a_' || q);

    execute format('create policy worker_select on pgmq.%I for select to worker_role using (true)', 'q_' || q);
    execute format('create policy worker_update on pgmq.%I for update to worker_role using (true) with check (true)',
                   'q_' || q);
    execute format('create policy worker_delete on pgmq.%I for delete to worker_role using (true)', 'q_' || q);
    execute format('create policy worker_insert on pgmq.%I for insert to worker_role with check (true)', 'a_' || q);
    execute format('create policy worker_select on pgmq.%I for select to worker_role using (true)', 'a_' || q);
  end loop;
end
$$;

-- 개발·운영 공통 로그인 역할. 비밀번호는 마이그레이션에 두지 않는다(설정 전에는 비밀번호 인증으로 접속 불가).
-- 권한은 worker_role 상속으로만 받는다.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'worker_login') then
    create role worker_login login inherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
  end if;
end
$$;
grant worker_role to worker_login;
