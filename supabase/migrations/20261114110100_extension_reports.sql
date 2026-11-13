-- task-015b-1 확장 완료·중단 보고, 프로젝트당 활성 collect_download 1개, sources 워커 큐
-- 근거: tasks/task-015b.md "결정 보강"(정산·전이, collect_download 완료 = 워커 재검사)
-- - 보고 함수는 running 이고 이 확장이 claim 한 job 만 조건부 전이(아니면 EX409). 잠금 순서 projects → jobs → extension_connections.
--   스위퍼가 waiting 으로 돌린 job 의 늦은 보고는 거부(extension_id 가 null 로 지워짐).
-- - collect 완료: succeeded + 정산(settle_job, 같은 트랜잭션).
-- - collect_download 완료: running 유지 + files_reported_at 기록 + 큐 sources 에 재검사 메시지. succeeded/failed 는 워커(015c-2).
-- - 중단 보고: captcha·risk_control·login_expired → failed + 사유 코드(jobs.error) + 예약 반환(release_job).
-- - 활성(queued·running·waiting_extension) collect_download 는 프로젝트당 1개(부분 unique 인덱스).

alter table public.jobs add column files_reported_at timestamptz;
comment on column public.jobs.files_reported_at is
  'collect_download 파일 완료 보고 시각. 기록되면 확장 끊김으로 waiting 되지 않고 워커 재검사가 마무리한다';

-- 운영 배포 안전: 같은 프로젝트에 활성 collect_download 가 둘 이상이면 오래된 쪽을 failed('superseded')로 정리한다
-- (예약 크레딧은 스위퍼가 반환)
update public.jobs j
set status = 'failed', finished_at = now(), error = 'superseded'
where j.type = 'collect_download' and j.status in ('queued', 'running', 'waiting_extension')
  and exists (select 1 from public.jobs n
              where n.project_id = j.project_id and n.type = 'collect_download'
                and n.status in ('queued', 'running', 'waiting_extension')
                and (n.created_at, n.id) > (j.created_at, j.id));

create unique index jobs_one_active_collect_download_idx on public.jobs (project_id)
  where type = 'collect_download' and status in ('queued', 'running', 'waiting_extension');

-- ── 워커 큐 sources(재검사): job_queues(20261112180000)와 같은 권한 ──
select pgmq.create('sources')
where not exists (select 1 from pgmq.meta m where m.queue_name = 'sources');
do $$
declare q text := 'sources';
begin
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
end
$$;

-- ── 보고 대상 작업 잠금: 그 확장이 claim 한 running 수집 작업 ──
-- 남의 작업·폐기된 확장·수집 외 작업 42501, 상태·확장 불일치(늦은 보고 포함) EX409
create function private.ext_report_job(p_extension_id uuid, p_job_id uuid)
returns public.jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pid uuid;
  v_uid uuid;
  v_job public.jobs;
begin
  select j.project_id into v_pid from public.jobs j where j.id = p_job_id;
  select p.user_id into v_uid from public.projects p where p.id = v_pid for update;

  select j.* into v_job
  from public.jobs j
  where j.id = p_job_id and j.project_id = v_pid and j.type in ('collect', 'collect_download')
  for update;
  if not found then
    raise exception '수집 작업이 아니거나 권한이 없습니다' using errcode = '42501';
  end if;

  perform 1
  from public.extension_connections e
  where e.id = p_extension_id and e.revoked_at is null and e.user_id = v_uid
  for update;
  if not found then
    raise exception '수집 작업이 아니거나 권한이 없습니다' using errcode = '42501';
  end if;

  if v_job.status <> 'running' or v_job.extension_id is distinct from p_extension_id then
    raise exception '실행 중인 이 확장의 작업이 아닙니다' using errcode = 'EX409';
  end if;
  return v_job;
end;
$$;
revoke execute on function private.ext_report_job(uuid, uuid) from public, anon, authenticated;

-- ── 완료 보고 ────────────────────────────────────────────────
-- collect → 'succeeded' · collect_download → 'rechecking'(최초) / 'already_reported'(재전송, 메시지 중복 없음)
create function private.ext_report_complete(p_extension_id uuid, p_job_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.jobs := private.ext_report_job(p_extension_id, p_job_id);
begin
  if v_job.type = 'collect' then
    if not private.settle_job(p_job_id) then
      raise exception '실행 중인 이 확장의 작업이 아닙니다' using errcode = 'EX409';
    end if;
    return 'succeeded';
  end if;

  if v_job.files_reported_at is not null then
    return 'already_reported';
  end if;
  update public.jobs set files_reported_at = now() where id = p_job_id;
  perform pgmq.send('sources', jsonb_build_object('job_id', p_job_id));
  return 'rechecking';
end;
$$;
revoke execute on function private.ext_report_complete(uuid, uuid) from public, anon, authenticated;
grant execute on function private.ext_report_complete(uuid, uuid) to service_role;

-- ── 중단 보고: 사유 코드로 failed + 예약 반환 ────────────────
create function private.ext_report_abort(p_extension_id uuid, p_job_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.jobs;
begin
  if p_reason is null or p_reason not in ('captcha', 'risk_control', 'login_expired') then
    raise exception '알 수 없는 중단 사유입니다' using errcode = '22023';
  end if;
  v_job := private.ext_report_job(p_extension_id, p_job_id);
  if v_job.files_reported_at is not null then
    raise exception '이미 파일 완료가 보고된 작업입니다' using errcode = 'EX409';
  end if;
  update public.jobs set status = 'failed', finished_at = now(), error = p_reason where id = p_job_id;
  perform private.release_job(p_job_id);
end;
$$;
revoke execute on function private.ext_report_abort(uuid, uuid, text) from public, anon, authenticated;
grant execute on function private.ext_report_abort(uuid, uuid, text) to service_role;

create function public.extension_report_complete(p_extension_id uuid, p_job_id uuid)
returns text
language sql
security invoker
set search_path = ''
as $$
  select private.ext_report_complete(p_extension_id, p_job_id);
$$;
comment on function public.extension_report_complete(uuid, uuid) is
  '확장 완료 보고(서버 전용). collect 는 정산·succeeded, collect_download 는 running 유지 후 워커 재검사. 늦은 보고 EX409';

create function public.extension_report_abort(p_extension_id uuid, p_job_id uuid, p_reason text)
returns void
language sql
security invoker
set search_path = ''
as $$
  select private.ext_report_abort(p_extension_id, p_job_id, p_reason);
$$;
comment on function public.extension_report_abort(uuid, uuid, text) is
  '확장 중단 보고(서버 전용). 사유 captcha·risk_control·login_expired → failed + 예약 반환';

revoke execute on function public.extension_report_complete(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.extension_report_abort(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.extension_report_complete(uuid, uuid) to service_role;
grant execute on function public.extension_report_abort(uuid, uuid, text) to service_role;
