-- task-012 보안 리뷰 반영 2
-- 1) create_job: 단계 인자를 받지 않고 작업 종류로 DB가 단계를 정한다(docs/03_SCREENS_UX.md 화면 표의 jobs 사용 화면):
--    collect = 02 소스(S-07) · analyze = 03 대본(S-08 "원본 영상 분석 중") · tts = 04 목소리(S-09) · render = 05 편집(S-10).
--    projects 행 FOR UPDATE 잠금 안에서 앞 단계 모두 approved, 그 단계는 아직 approved 아님을 확인(위반 55000).
-- 2) 멱등 키는 사용자 단위: jobs.idempotency_key 에 '<user_id>:<키>' 로 저장해 전역 unique 가 (user_id, 키) 유일이 된다.
--    같은 키 재요청인데 프로젝트·종류가 다르면 JK001 로 거부.
-- 3) pgmq 함수 EXECUTE 를 PUBLIC·anon·authenticated 에서 회수. send 는 create_job(SECURITY DEFINER, 소유자) 경로만,
--    worker_role 은 read·set_vt·archive·delete 와 그 내부 보조 함수(format_table_name)만.

-- ── 1·2) create_job 교체 ─────────────────────────────────────
drop function public.create_job(uuid, integer, text, text, jsonb);
drop function private.create_job(uuid, integer, text, text, jsonb);

create function private.job_step(p_type text)
returns smallint
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'collect' then 2
    when 'analyze' then 3
    when 'tts' then 4
    when 'render' then 5
  end::smallint;
$$;
revoke execute on function private.job_step(text) from public, anon, authenticated;

create function private.create_job(
  p_project_id uuid, p_type text, p_idempotency_key text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_key text;
  v_step smallint := private.job_step(p_type);
  v_status jsonb;
  v_job public.jobs;
  v_cost integer;
  v_balance bigint;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  if v_step is null then
    raise exception '알 수 없는 작업 종류입니다: %', p_type using errcode = '22023';
  end if;
  if p_idempotency_key is null or length(p_idempotency_key) not between 8 and 200 then
    raise exception '멱등 키가 올바르지 않습니다' using errcode = '22023';
  end if;
  v_key := v_uid::text || ':' || p_idempotency_key;

  select step_status into v_status
  from public.projects
  where id = p_project_id and user_id = v_uid
  for update;
  if not found then
    raise exception '프로젝트를 찾을 수 없거나 권한이 없습니다' using errcode = '42501';
  end if;

  -- 사용자 단위 잠금: 다른 프로젝트에서 같은 사용자의 잔액 경쟁도 직렬화
  perform pg_advisory_xact_lock(hashtextextended('credit:' || v_uid::text, 0));

  select j.* into v_job from public.jobs j where j.idempotency_key = v_key;
  if found then
    if v_job.project_id <> p_project_id or v_job.type <> p_type then
      raise exception '같은 멱등 키가 다른 작업에 이미 쓰였습니다' using errcode = 'JK001';
    end if;
    return to_jsonb(v_job) - 'payload' - 'idempotency_key' || jsonb_build_object('created', false);
  end if;

  if exists (select 1 from generate_series(1, v_step - 1) as g(n)
             where v_status ->> g.n::text is distinct from 'approved') then
    raise exception '앞 단계가 승인되지 않았습니다' using errcode = '55000';
  end if;
  if v_status ->> v_step::text = 'approved' then
    raise exception '이미 승인된 단계입니다. 변경 요청 후 다시 시도하세요' using errcode = '55000';
  end if;

  v_cost := private.job_cost(p_type);
  select coalesce(sum(delta), 0) into v_balance from public.credit_ledger where user_id = v_uid;
  if v_balance < v_cost then
    raise exception '크레딧이 부족합니다'
      using errcode = 'CR001',
            detail = jsonb_build_object('required', v_cost, 'balance', v_balance)::text;
  end if;

  insert into public.jobs (project_id, step, type, status, idempotency_key, payload)
  values (p_project_id, v_step, p_type,
          case when p_type = 'collect' then 'waiting_extension' else 'queued' end,
          v_key, coalesce(p_payload, '{}'::jsonb))
  returning * into v_job;

  insert into public.credit_ledger (user_id, project_id, job_id, kind, delta, reason, idempotency_key)
  values (v_uid, p_project_id, v_job.id, 'reserve', -v_cost, p_type, 'reserve:' || v_job.id);

  if p_type <> 'collect' then
    perform pgmq.send(p_type, jsonb_build_object('job_id', v_job.id));
  end if;

  return to_jsonb(v_job) - 'payload' - 'idempotency_key' || jsonb_build_object('created', true);
end;
$$;

revoke execute on function private.create_job(uuid, text, text, jsonb) from public, anon, authenticated;
grant execute on function private.create_job(uuid, text, text, jsonb) to authenticated;

create function public.create_job(
  p_project_id uuid, p_type text, p_idempotency_key text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.create_job(p_project_id, p_type, p_idempotency_key, p_payload);
$$;

comment on function public.create_job(uuid, text, text, jsonb) is
  '작업 생성(17-5). 단계는 종류로 결정, 단계 위반 55000, 같은 키 재요청은 기존 작업(다른 작업이면 JK001), 잔액 부족 CR001. Route Handler가 사용자 세션으로 호출';
revoke execute on function public.create_job(uuid, text, text, jsonb) from public, anon;
grant execute on function public.create_job(uuid, text, text, jsonb) to authenticated;

-- ── 3) pgmq 함수 실행 권한 ──────────────────────────────────
revoke execute on all functions in schema pgmq from public, anon, authenticated;
grant execute on function pgmq.format_table_name(text, text) to worker_role;
grant execute on function pgmq.read(text, integer, integer, jsonb) to worker_role;
grant execute on function pgmq.set_vt(text, bigint, integer) to worker_role;
grant execute on function pgmq.archive(text, bigint) to worker_role;
grant execute on function pgmq.delete(text, bigint) to worker_role;
