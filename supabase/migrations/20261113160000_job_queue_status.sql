-- task-035b 본인 작업의 대기 순번·예상 대기 시간(docs/planning.md 17-5-1 화면 행·작업 현황 패널 행)
-- - public.job_queue_status(): authenticated 전용 래퍼 → private.job_queue_status(SECURITY DEFINER, auth.uid() 본인 행만).
--   앞선 작업은 수만 센다(남의 job·publication 내용·소유자는 돌려주지 않는다).
-- - 제작: queued(대기)·deferred(같은 사용자 같은 종류가 실행 중이라 미뤄짐)·running + 순번 + 예상 대기 초.
--   순번 = 같은 큐에서 내 작업보다 먼저 만들어진 대기(queued) 작업 수(미룸 상태인 다른 사용자 작업 제외) + 1,
--   예상: effective = 내 앞 대기 수 + 같은 큐 실행 중 수, 슬롯 수 미만이면 0, 아니면 (effective - 슬롯 수 + 1) × 최근 성공 소요 중앙값(종류별 최근 20건, 표본 3 미만이면 시간 제한의 절반) ÷ 슬롯 수(올림).
-- - 포스팅: 업로드 대기(pending)·재시도 대기(retry_wait)·업로드 중·예약됨·실패(needs_check 포함)·재연결 필요.
--   순번은 publication_claim 정렬(coalesce(next_attempt_at, prepared_at, created_at), id)과 같은 기준.

-- ── 설정 한 곳(가설, 워커·업로더 기본값과 같게) ─────────────────
-- 큐별 동시 처리 수 = docker-compose WORKER_CONCURRENCY_RENDER/TTS/ANALYZE 기본값
create function private.job_queue_slots(p_queue text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case p_queue when 'render' then 1 when 'tts' then 2 when 'analyze' then 2 end;
$$;
revoke execute on function private.job_queue_slots(text) from public, anon, authenticated, service_role;

-- 업로드 1건 예상 소요(초, 가설). 업로더는 한 번에 1건씩 처리한다
create function private.upload_est_seconds()
returns integer
language sql
immutable
set search_path = ''
as $$
  select 180;
$$;
revoke execute on function private.upload_est_seconds() from public, anon, authenticated, service_role;

-- 성공 이력 조회용(종류별 최근 성공 20건): job_eta_basis 의 중앙값 쿼리
create index jobs_succeeded_type_finished_idx on public.jobs (type, finished_at desc) where status = 'succeeded';

-- 종류별 기준 소요 초: 최근 성공 20건 중앙값, 표본 3 미만이면 시간 제한의 절반
create function private.job_eta_basis(p_type text)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select percentile_cont(0.5) within group (order by s.secs)
     from (select extract(epoch from j.finished_at - j.started_at) as secs
           from public.jobs j
           where j.type = p_type and j.status = 'succeeded' and j.started_at is not null and j.finished_at is not null
           order by j.finished_at desc
           limit 20) s
     having count(*) >= 3),
    extract(epoch from private.job_time_limit(p_type)) / 2);
$$;
revoke execute on function private.job_eta_basis(text) from public, anon, authenticated, service_role;

-- ── 본체 ────────────────────────────────────────────────────
create function private.job_queue_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_prod jsonb;
  v_post jsonb;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'job_id', t.job_id, 'project_id', t.project_id, 'project_name', t.project_name,
      'step', t.step, 'type', t.type, 'queue', t.queue, 'state', t.state,
      'started_at', t.started_at,
      'position', case when t.state = 'queued' then t.ahead + 1 end,
      'eta_seconds', case when t.state = 'queued'
        then ceil(greatest(t.ahead + t.running - private.job_queue_slots(t.queue) + 1, 0) * private.job_eta_basis(t.type) / private.job_queue_slots(t.queue))::integer end)
    order by t.created_at, t.job_id), '[]'::jsonb)
  into v_prod
  from (
    select j.id as job_id, j.project_id, p.name as project_name, j.step, j.type, j.created_at, j.started_at,
           private.job_queue(j.type) as queue,
           case
             when j.status = 'running' then 'running'
             when exists (select 1 from public.jobs j2 join public.projects p2 on p2.id = j2.project_id
                          where p2.user_id = v_uid and j2.status = 'running' and j2.id <> j.id
                            and private.job_queue(j2.type) = private.job_queue(j.type)) then 'deferred'
             else 'queued'
           end as state,
           (select count(*) from public.jobs q
            where q.status = 'queued' and private.job_queue(q.type) = private.job_queue(j.type)
              and (q.created_at, q.id) < (j.created_at, j.id)
              -- 미룸 상태(그 소유자가 같은 큐에 실행 중인 작업이 있음)인 다른 사용자 작업은 나보다 먼저 시작하지 못한다
              and not exists (select 1 from public.jobs r2
                              join public.projects pr2 on pr2.id = r2.project_id
                              join public.projects pq on pq.id = q.project_id
                              where r2.status = 'running' and pr2.user_id = pq.user_id
                                and private.job_queue(r2.type) = private.job_queue(j.type))) as ahead,
           (select count(*) from public.jobs r
            where r.status = 'running' and private.job_queue(r.type) = private.job_queue(j.type)) as running
    from public.jobs j
    join public.projects p on p.id = j.project_id
    where p.user_id = v_uid and j.status in ('queued', 'running') and private.job_queue(j.type) is not null
  ) t;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'publication_id', t.publication_id, 'project_id', t.project_id, 'project_name', t.project_name,
      'state', t.state, 'raw_status', t.raw_status, 'scheduled_at', t.scheduled_at, 'started_at', t.attempt_started_at,
      'retry_count', t.retry_count, 'error', t.error,
      'position', case when t.state in ('pending', 'retry_wait') and t.due then t.ahead + 1 end,
      'est_start_at', case
        when t.state in ('pending', 'retry_wait') and t.due
          then now() + make_interval(secs => greatest(t.ahead + t.uploading, 0) * private.upload_est_seconds())
        when t.state = 'retry_wait' then t.next_attempt_at end)
    order by t.sort_at, t.publication_id), '[]'::jsonb)
  into v_post
  from (
    select pb.id as publication_id, pb.project_id, p.name as project_name, pb.scheduled_at, pb.attempt_started_at,
           pb.retry_count, pb.next_attempt_at,
           pb.error,
           pb.state, pb.raw_status, pb.sort_at, pb.due,
           (select count(*) from public.publications q
            where q.status in ('pending', 'retry_wait') and (q.next_attempt_at is null or q.next_attempt_at <= now())
              and (coalesce(q.next_attempt_at, q.prepared_at, q.created_at), q.id)
                  < (coalesce(pb.next_attempt_at, pb.prepared_at, pb.created_at), pb.id)) as ahead,
           (select count(*) from public.publications u where u.status = 'uploading') as uploading
    from (
      select x.*,
             case x.status when 'needs_check' then 'failed' else x.status end as state, x.status as raw_status,
             coalesce(x.next_attempt_at, x.prepared_at, x.created_at) as sort_at,
             (x.next_attempt_at is null or x.next_attempt_at <= now()) as due
      from public.publications x
      where x.status in ('pending', 'retry_wait', 'uploading', 'scheduled', 'failed', 'needs_check', 'reconnect_wait')
    ) pb
    join public.projects p on p.id = pb.project_id
    where p.user_id = v_uid
  ) t;

  return jsonb_build_object('production', v_prod, 'posting', v_post, 'generated_at', now());
end;
$$;
revoke execute on function private.job_queue_status() from public, anon, service_role;
grant execute on function private.job_queue_status() to authenticated;

create function public.job_queue_status()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select private.job_queue_status();
$$;
revoke execute on function public.job_queue_status() from public, anon, service_role;
grant execute on function public.job_queue_status() to authenticated;
comment on function public.job_queue_status() is
  '본인 제작 작업(대기·미룸·실행: 순번·예상 대기 초)과 포스팅 대기(순번·예상 시작·예약 시각) 조회(17-5-1). 사용자 세션으로 호출, 남의 작업은 수로만 반영';
