-- task-024b 보안 리뷰 반영(20261112290000 보강)
-- 🔴1 삭제 직전 재판정: 서버는 Storage 삭제 전에 private.retention_reserve 로 대상 행을 FOR UPDATE 잠그고
--     기준일·발행 상태를 다시 판정해 통과한 행에만 예약 토큰(retention_token)을 남긴다. 발행 트리거도 같은 행을 먼저 잠그고,
--     기준일을 늘리면서 예약 토큰을 지운다. 삭제 표시(retention_mark_deleted)는 같은 토큰을 가진 행만 기록한다.
--     → 목록 조회 뒤 발행되면 예약 단계에서 빠진다(삭제 0건).
--     남는 창: 예약 커밋 → Storage 삭제 사이(밀리초)에 발행되면 객체는 지워지고 토큰이 지워져 표시가 남지 않는다.
--     이 경우 서버가 "표시 실패"로 기록하고, 다음 회차는 기준일이 늘어난 행을 대상으로 보지 않는다(운영 로그로 확인).
-- 🔴2 기존 행 기준일 보정: 발행(scheduled·uploaded)된 프로젝트는 max(지금, 예약·업로드 시각) + 30일,
--     미발행은 max(저장된 기준일, 프로젝트 마지막 수정 + 30일).
-- 🟡 retention_due 키셋 페이지(due_on · kind · id 커서).

-- ── 1) 예약 토큰 열(서버 전용) ───────────────────────────────
alter table public.sources
  add column retention_token uuid,
  add column thumbnail_retention_token uuid;
alter table public.voice_takes add column retention_token uuid;
alter table public.renders add column retention_token uuid;
comment on column public.sources.retention_token is '원본 파일 삭제 예약 토큰(retention_reserve). 서버 전용';
comment on column public.sources.thumbnail_retention_token is '썸네일 삭제 예약 토큰(retention_reserve). 서버 전용';
comment on column public.voice_takes.retention_token is '음성 파일 삭제 예약 토큰(retention_reserve). 서버 전용';
comment on column public.renders.retention_token is 'MP4 삭제 예약 토큰(retention_reserve). 서버 전용';

-- ── 2) 기존 행 기준일 보정 ───────────────────────────────────
with pub as (
  select project_id,
         (greatest(now(), coalesce(max(scheduled_at), now()), coalesce(max(published_at), now()))
          + interval '30 days')::date as purge
  from public.publications
  where status in ('scheduled', 'uploaded')
  group by project_id
)
update public.sources s set purge_after = greatest(s.purge_after, pub.purge)
from pub where s.project_id = pub.project_id and s.file_deleted_at is null;
with pub as (
  select project_id,
         (greatest(now(), coalesce(max(scheduled_at), now()), coalesce(max(published_at), now()))
          + interval '30 days')::date as purge
  from public.publications
  where status in ('scheduled', 'uploaded')
  group by project_id
)
update public.voice_takes t set purge_after = greatest(t.purge_after, pub.purge)
from pub where t.project_id = pub.project_id and t.file_deleted_at is null;
with pub as (
  select project_id,
         (greatest(now(), coalesce(max(scheduled_at), now()), coalesce(max(published_at), now()))
          + interval '30 days')::date as purge
  from public.publications
  where status in ('scheduled', 'uploaded')
  group by project_id
)
update public.renders r set purge_after = greatest(r.purge_after, pub.purge)
from pub where r.project_id = pub.project_id and r.file_deleted_at is null;

update public.sources s set purge_after = greatest(s.purge_after, (p.updated_at + interval '30 days')::date)
from public.projects p
where p.id = s.project_id and s.file_deleted_at is null
  and not exists (select 1 from public.publications pub where pub.project_id = p.id and pub.status in ('scheduled', 'uploaded'));
update public.voice_takes t set purge_after = greatest(t.purge_after, (p.updated_at + interval '30 days')::date)
from public.projects p
where p.id = t.project_id and t.file_deleted_at is null
  and not exists (select 1 from public.publications pub where pub.project_id = p.id and pub.status in ('scheduled', 'uploaded'));
update public.renders r set purge_after = greatest(r.purge_after, (p.updated_at + interval '30 days')::date)
from public.projects p
where p.id = r.project_id and r.file_deleted_at is null
  and not exists (select 1 from public.publications pub where pub.project_id = p.id and pub.status in ('scheduled', 'uploaded'));

-- ── 3) 발행 트리거: 같은 행을 id 순으로 먼저 잠그고, 기준일을 늘리며 예약 토큰을 지운다 ──
create or replace function private.publications_set_purge()
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
    perform 1 from public.sources where project_id = new.project_id order by id for update;
    perform 1 from public.voice_takes where project_id = new.project_id order by id for update;
    perform 1 from public.renders where project_id = new.project_id order by id for update;
    update public.sources set purge_after = v_purge, retention_token = null, thumbnail_retention_token = null
    where project_id = new.project_id and file_deleted_at is null;
    update public.voice_takes set purge_after = v_purge, retention_token = null
    where project_id = new.project_id and file_deleted_at is null;
    update public.renders set purge_after = v_purge, retention_token = null
    where project_id = new.project_id and file_deleted_at is null;
  end if;
  return null;
end;
$$;

-- ── 4) 판정(기준일 포함, 거르지 않음) — 목록·예약이 같은 규칙을 쓴다 ──
create function private.retention_candidates()
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
  )
  select 'source'::text, s.id, 'sources'::text, s.file_path, pr.user_id, pr.id,
         case when pr.published then s.purge_after else greatest(s.purge_after, pr.active_until) end
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
  where r.mp4_path is not null and r.file_deleted_at is null;
$$;
revoke execute on function private.retention_candidates() from public, anon, authenticated;

-- ── 5) 목록: 키셋 페이지 ─────────────────────────────────────
drop function public.retention_due(integer);
drop function private.retention_due(integer);

create function private.retention_due(p_limit integer, p_after_due date default null,
                                      p_after_kind text default null, p_after_id uuid default null)
returns table (kind text, id uuid, bucket text, path text, user_id uuid, project_id uuid, due_on date)
language sql
stable
security definer
set search_path = ''
as $$
  select c.kind, c.id, c.bucket, c.path, c.user_id, c.project_id, c.due_on
  from private.retention_candidates() c
  where c.due_on <= current_date
    and (p_after_due is null
         or (c.due_on, c.kind, c.id) > (p_after_due, coalesce(p_after_kind, ''), coalesce(p_after_id, '00000000-0000-0000-0000-000000000000'::uuid)))
  order by c.due_on, c.kind, c.id
  limit greatest(1, least(coalesce(p_limit, 500), 1000));
$$;
revoke execute on function private.retention_due(integer, date, text, uuid) from public, anon, authenticated;
grant execute on function private.retention_due(integer, date, text, uuid) to service_role;

create function public.retention_due(p_limit integer, p_after_due date default null,
                                     p_after_kind text default null, p_after_id uuid default null)
returns table (kind text, id uuid, bucket text, path text, user_id uuid, project_id uuid, due_on date)
language sql
security invoker
set search_path = ''
as $$
  select * from private.retention_due(p_limit, p_after_due, p_after_kind, p_after_id);
$$;
comment on function public.retention_due(integer, date, text, uuid) is
  '보관 기간이 지난 파일 목록, (due_on, kind, id) 커서 페이지(task-024b). 서버 retention(service_role) 전용';
revoke execute on function public.retention_due(integer, date, text, uuid) from public, anon, authenticated;
grant execute on function public.retention_due(integer, date, text, uuid) to service_role;

-- ── 6) 삭제 예약: 행 잠금 → 재판정 → 통과한 행에 토큰 ──────────
create function private.retention_reserve(p_kind text, p_ids uuid[])
returns table (id uuid, path text, user_id uuid, project_id uuid, token uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token uuid := gen_random_uuid();
  v_ok uuid[];
begin
  if p_kind not in ('source', 'thumbnail', 'voice', 'render') then
    raise exception '알 수 없는 종류입니다' using errcode = '22023';
  end if;
  if p_ids is null or cardinality(p_ids) = 0 then
    return;
  end if;
  if cardinality(p_ids) > 1000 then
    raise exception '한 번에 예약할 수 있는 개수를 넘었습니다' using errcode = '22023';
  end if;
  -- 발행 트리거와 같은 순서(id)로 잠근다. 잠금을 얻은 뒤의 문장은 최신 커밋(발행 상태·기준일)을 본다.
  if p_kind in ('source', 'thumbnail') then
    perform 1 from public.sources s where s.id = any (p_ids) order by s.id for update;
  elsif p_kind = 'voice' then
    perform 1 from public.voice_takes t where t.id = any (p_ids) order by t.id for update;
  else
    perform 1 from public.renders r where r.id = any (p_ids) order by r.id for update;
  end if;

  select coalesce(array_agg(c.id), '{}') into v_ok
  from private.retention_candidates() c
  where c.kind = p_kind and c.id = any (p_ids) and c.due_on <= current_date;

  if p_kind = 'source' then
    update public.sources s set retention_token = v_token where s.id = any (v_ok);
  elsif p_kind = 'thumbnail' then
    update public.sources s set thumbnail_retention_token = v_token where s.id = any (v_ok);
  elsif p_kind = 'voice' then
    update public.voice_takes t set retention_token = v_token where t.id = any (v_ok);
  else
    update public.renders r set retention_token = v_token where r.id = any (v_ok);
  end if;

  return query
  select c.id, c.path, c.user_id, c.project_id, v_token
  from private.retention_candidates() c
  where c.kind = p_kind and c.id = any (v_ok)
  order by c.id;
end;
$$;
revoke execute on function private.retention_reserve(text, uuid[]) from public, anon, authenticated;
grant execute on function private.retention_reserve(text, uuid[]) to service_role;

create function public.retention_reserve(p_kind text, p_ids uuid[])
returns table (id uuid, path text, user_id uuid, project_id uuid, token uuid)
language sql
security invoker
set search_path = ''
as $$
  select * from private.retention_reserve(p_kind, p_ids);
$$;
comment on function public.retention_reserve(text, uuid[]) is
  'Storage 삭제 직전 행 잠금·재판정·예약 토큰(task-024b). 서버 retention(service_role) 전용';
revoke execute on function public.retention_reserve(text, uuid[]) from public, anon, authenticated;
grant execute on function public.retention_reserve(text, uuid[]) to service_role;

-- ── 7) 삭제 표시: 같은 토큰을 가진 행만(발행으로 연장되면 토큰이 지워져 표시되지 않음) ──
drop function public.retention_mark_deleted(text, uuid[]);
drop function private.retention_mark_deleted(text, uuid[]);

create function private.retention_mark_deleted(p_kind text, p_ids uuid[], p_token uuid)
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
  if p_token is null then
    raise exception '예약 토큰이 없습니다' using errcode = '22023';
  end if;
  case p_kind
    when 'source' then
      update public.sources set file_deleted_at = now(), retention_token = null
      where id = any (p_ids) and retention_token = p_token and file_path is not null and file_deleted_at is null;
    when 'thumbnail' then
      update public.sources set thumbnail_deleted_at = now(), thumbnail_retention_token = null
      where id = any (p_ids) and thumbnail_retention_token = p_token and thumbnail_path is not null
        and thumbnail_deleted_at is null;
    when 'voice' then
      update public.voice_takes set file_deleted_at = now(), retention_token = null
      where id = any (p_ids) and retention_token = p_token and audio_path is not null and file_deleted_at is null;
    when 'render' then
      update public.renders set file_deleted_at = now(), retention_token = null
      where id = any (p_ids) and retention_token = p_token and mp4_path is not null and file_deleted_at is null;
    else
      raise exception '알 수 없는 종류입니다' using errcode = '22023';
  end case;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke execute on function private.retention_mark_deleted(text, uuid[], uuid) from public, anon, authenticated;
grant execute on function private.retention_mark_deleted(text, uuid[], uuid) to service_role;

create function public.retention_mark_deleted(p_kind text, p_ids uuid[], p_token uuid)
returns integer
language sql
security invoker
set search_path = ''
as $$
  select private.retention_mark_deleted(p_kind, p_ids, p_token);
$$;
comment on function public.retention_mark_deleted(text, uuid[], uuid) is
  'Storage 삭제 성공 뒤 같은 예약 토큰 행만 *_deleted_at 기록(task-024b). 서버 retention(service_role) 전용';
revoke execute on function public.retention_mark_deleted(text, uuid[], uuid) from public, anon, authenticated;
grant execute on function public.retention_mark_deleted(text, uuid[], uuid) to service_role;
