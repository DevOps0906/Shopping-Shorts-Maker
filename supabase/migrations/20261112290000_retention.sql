-- task-024b: 보관 기간 지난 파일 삭제(출처 행은 남김). 근거 docs/planning.md 17-2 D5, docs/05_DATA_MODEL.md 1절 보관(잠정)
-- - 삭제 주체: 서버 retention 프로세스(service_role)가 Storage API로 객체를 지운 뒤, 성공한 것만 *_deleted_at 을 채운다.
--   워커(worker_role)는 Storage 삭제 권한이 없고 이 함수들도 실행할 수 없다.
-- - 행(URL·작성자·플랫폼·수집 시각·권리 근거·경로)은 지우지 않는다. 경로도 기록으로 남긴다.
-- - 기준일
--   · 발행(publications.status 가 scheduled·uploaded 가 된 시각과 scheduled_at·published_at 중 늦은 쪽) + 30일:
--     원본(sources 파일)·음성(voice_takes)·MP4(renders). 상태 전환 때 트리거가 purge_after 를 다시 계산한다.
--   · 미발행: 저장된 purge_after(원본 collected_at + 30일, 음성·MP4 created_at + 30일)와
--     프로젝트 마지막 수정(projects.updated_at) + 30일 중 늦은 쪽(진행 중 프로젝트 연장).
--   · 썸네일: 미선정(체크·사용 안 함)은 collected_at + 7일, 선정된 원본의 썸네일은 원본 파일과 같은 기준.
--   · 예정일 당일(<= current_date)부터 삭제 대상.

-- ── 1) 열 ──────────────────────────────────────────────────
alter table public.voice_takes
  add column purge_after date,
  add column file_deleted_at timestamptz;
update public.voice_takes set purge_after = (created_at + interval '30 days')::date;
alter table public.voice_takes
  alter column purge_after set default ((now() + interval '30 days')::date),
  alter column purge_after set not null;
comment on column public.voice_takes.purge_after is '파일 삭제 예정일. 미발행 created_at + 30일, 발행 시 발행일 + 30일(트리거). 서버 전용';
comment on column public.voice_takes.file_deleted_at is '보관 기간이 지나 Storage 객체를 지운 시각. 행은 남긴다. 서버 전용';

alter table public.renders
  add column purge_after date,
  add column file_deleted_at timestamptz;
update public.renders set purge_after = (created_at + interval '30 days')::date;
alter table public.renders
  alter column purge_after set default ((now() + interval '30 days')::date),
  alter column purge_after set not null;
comment on column public.renders.purge_after is '파일 삭제 예정일. 미발행 created_at + 30일, 발행 시 발행일 + 30일(트리거). 서버 전용';
comment on column public.renders.file_deleted_at is '보관 기간이 지나 Storage 객체를 지운 시각. 행은 남긴다. 서버 전용';

alter table public.sources add column thumbnail_deleted_at timestamptz;
comment on column public.sources.thumbnail_deleted_at is '썸네일 객체를 지운 시각(미선정 7일, 선정 원본은 파일과 같은 기준). 서버 전용';

create index voice_takes_purge_idx on public.voice_takes (purge_after) where file_deleted_at is null;
create index renders_purge_idx on public.renders (purge_after) where file_deleted_at is null;

-- ── 2) 발행 시 기준일 재계산 ────────────────────────────────
create function private.publications_set_purge()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_purge date;
begin
  if new.status in ('scheduled', 'uploaded')
     and (tg_op = 'INSERT'
          or (old.status, old.scheduled_at, old.published_at)
             is distinct from (new.status, new.scheduled_at, new.published_at)) then
    v_purge := (greatest(now(), coalesce(new.scheduled_at, now()), coalesce(new.published_at, now()))
                + interval '30 days')::date;
    update public.sources set purge_after = v_purge
    where project_id = new.project_id and file_deleted_at is null;
    update public.voice_takes set purge_after = v_purge
    where project_id = new.project_id and file_deleted_at is null;
    update public.renders set purge_after = v_purge
    where project_id = new.project_id and file_deleted_at is null;
  end if;
  return null;
end;
$$;
revoke execute on function private.publications_set_purge() from public, anon, authenticated;

create trigger publications_set_purge
  after insert or update on public.publications
  for each row execute function private.publications_set_purge();

-- ── 3) 삭제 대상 목록(서버 전용) ─────────────────────────────
-- kind: source · thumbnail · voice · render. 경로가 <user_id>/<project_id>/ 로 시작하는지는 서버가 다시 확인한다.
create function private.retention_due(p_limit integer)
returns table (kind text, id uuid, bucket text, path text, user_id uuid, project_id uuid, due_on date)
language sql
stable
security definer
set search_path = ''
as $$
  with proj as (
    select p.id, p.user_id,
           exists (select 1 from public.publications pub
                   where pub.project_id = p.id and pub.status in ('scheduled', 'uploaded')) as published,
           (p.updated_at + interval '30 days')::date as active_until
    from public.projects p
  ),
  due as (
    select 'source'::text as kind, s.id, 'sources'::text as bucket, s.file_path as path, pr.user_id, pr.id as project_id,
           case when pr.published then s.purge_after else greatest(s.purge_after, pr.active_until) end as due_on
    from public.sources s join proj pr on pr.id = s.project_id
    where s.file_path is not null and s.file_deleted_at is null
    union all
    select 'thumbnail', s.id, 'thumbnails', s.thumbnail_path, pr.user_id, pr.id,
           case when not s.checked and not s.used then (s.collected_at + interval '7 days')::date
                when pr.published then s.purge_after
                else greatest(s.purge_after, pr.active_until) end
    from public.sources s join proj pr on pr.id = s.project_id
    where s.thumbnail_path is not null and s.thumbnail_deleted_at is null
    union all
    select 'voice', t.id, 'voices', t.audio_path, pr.user_id, pr.id,
           case when pr.published then t.purge_after else greatest(t.purge_after, pr.active_until) end
    from public.voice_takes t join proj pr on pr.id = t.project_id
    where t.audio_path is not null and t.file_deleted_at is null
    union all
    select 'render', r.id, 'renders', r.mp4_path, pr.user_id, pr.id,
           case when pr.published then r.purge_after else greatest(r.purge_after, pr.active_until) end
    from public.renders r join proj pr on pr.id = r.project_id
    where r.mp4_path is not null and r.file_deleted_at is null
  )
  select d.kind, d.id, d.bucket, d.path, d.user_id, d.project_id, d.due_on
  from due d
  where d.due_on <= current_date
  order by d.due_on, d.kind, d.id
  limit greatest(1, least(coalesce(p_limit, 500), 1000));
$$;
revoke execute on function private.retention_due(integer) from public, anon, authenticated;
grant execute on function private.retention_due(integer) to service_role;

-- ── 4) 삭제 완료 표시(Storage 삭제 성공 뒤에만 서버가 부른다) ──
create function private.retention_mark_deleted(p_kind text, p_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if p_ids is null or cardinality(p_ids) = 0 then
    return 0;
  end if;
  if cardinality(p_ids) > 1000 then
    raise exception '한 번에 표시할 수 있는 개수를 넘었습니다' using errcode = '22023';
  end if;
  case p_kind
    when 'source' then
      update public.sources set file_deleted_at = now()
      where id = any (p_ids) and file_path is not null and file_deleted_at is null;
    when 'thumbnail' then
      update public.sources set thumbnail_deleted_at = now()
      where id = any (p_ids) and thumbnail_path is not null and thumbnail_deleted_at is null;
    when 'voice' then
      update public.voice_takes set file_deleted_at = now()
      where id = any (p_ids) and audio_path is not null and file_deleted_at is null;
    when 'render' then
      update public.renders set file_deleted_at = now()
      where id = any (p_ids) and mp4_path is not null and file_deleted_at is null;
    else
      raise exception '알 수 없는 종류입니다' using errcode = '22023';
  end case;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke execute on function private.retention_mark_deleted(text, uuid[]) from public, anon, authenticated;
grant execute on function private.retention_mark_deleted(text, uuid[]) to service_role;

-- ── 5) public 래퍼(service_role 전용) ────────────────────────
create function public.retention_due(p_limit integer)
returns table (kind text, id uuid, bucket text, path text, user_id uuid, project_id uuid, due_on date)
language sql
security invoker
set search_path = ''
as $$
  select * from private.retention_due(p_limit);
$$;
comment on function public.retention_due(integer) is '보관 기간이 지난 파일 목록(task-024b). 서버 retention(service_role) 전용';
revoke execute on function public.retention_due(integer) from public, anon, authenticated;
grant execute on function public.retention_due(integer) to service_role;

create function public.retention_mark_deleted(p_kind text, p_ids uuid[])
returns integer
language sql
security invoker
set search_path = ''
as $$
  select private.retention_mark_deleted(p_kind, p_ids);
$$;
comment on function public.retention_mark_deleted(text, uuid[]) is 'Storage 삭제 성공 뒤 *_deleted_at 기록(task-024b). 서버 retention(service_role) 전용';
revoke execute on function public.retention_mark_deleted(text, uuid[]) from public, anon, authenticated;
grant execute on function public.retention_mark_deleted(text, uuid[]) to service_role;
