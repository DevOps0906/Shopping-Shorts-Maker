-- task-016 팀장 결정: 원본 선정(일치도·점수·상위 20편)은 02 단계 일이므로 새 작업 종류 select_sources(02)를 둔다.
-- - analyze 는 그대로 03 대본용 원본 영상 분석(워커는 아직 스텁).
-- - 큐는 새로 만들지 않고 analyze 큐를 같이 쓴다(권한·RLS 정책 재사용). 워커는 job_start 가 돌려준 type 으로 처리기를 고른다.
-- - 예상 크레딧·시간 상한은 analyze 와 같다(5 · 5분).
-- - 20261112200000 의 워커 함수는 select_sources 실행 중 작업만 받도록 바꾼다(create or replace).

alter table public.jobs drop constraint jobs_type_check;
alter table public.jobs add constraint jobs_type_check
  check (type in ('render', 'tts', 'analyze', 'collect', 'select_sources'));

create or replace function private.job_cost(p_type text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'render' then 30
    when 'tts' then 10
    when 'analyze' then 5
    when 'select_sources' then 5
    else 0
  end;
$$;

create or replace function private.job_time_limit(p_type text)
returns interval
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'tts' then interval '2 minutes'
    when 'render' then interval '10 minutes'
    when 'analyze' then interval '5 minutes'
    when 'select_sources' then interval '5 minutes'
    when 'collect' then interval '15 minutes'
  end;
$$;

create or replace function private.job_step(p_type text)
returns smallint
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'collect' then 2
    when 'select_sources' then 2
    when 'analyze' then 3
    when 'tts' then 4
    when 'render' then 5
  end::smallint;
$$;

-- 종류 → 큐. collect 는 큐 없음(null)
create function private.job_queue(p_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'render' then 'render'
    when 'tts' then 'tts'
    when 'analyze' then 'analyze'
    when 'select_sources' then 'analyze'
  end;
$$;
revoke execute on function private.job_queue(text) from public, anon, authenticated;

create or replace function private.create_job(
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

  if private.job_queue(p_type) is not null then
    perform pgmq.send(private.job_queue(p_type), jsonb_build_object('job_id', v_job.id));
  end if;

  return to_jsonb(v_job) - 'payload' - 'idempotency_key' || jsonb_build_object('created', true);
end;
$$;

revoke execute on function private.create_job(uuid, text, text, jsonb) from public, anon, authenticated;
grant execute on function private.create_job(uuid, text, text, jsonb) to authenticated;

create or replace function private.analyze_job_project(p_job_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid;
begin
  select project_id into v_project
  from public.jobs
  where id = p_job_id and type = 'select_sources' and status = 'running';
  if v_project is null then
    raise exception '실행 중인 원본 선정 작업이 아닙니다' using errcode = '55000';
  end if;
  return v_project;
end;
$$;
