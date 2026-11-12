-- task-024b 통합 보안 리뷰 반영: 삭제 직전 재확인과 "삭제 중" 창(20261112290300 보강)
-- - 서버는 객체마다 Storage 삭제 직전에 retention_confirm(종류, 행, 토큰)을 부른다. 행을 FOR UPDATE 잠그고
--   토큰 일치 · 예약 30분 이내 · 지금도 기준일 지남(발행·활동 규칙 포함)을 다시 판정해, 통과한 행에만 삭제 중 시각을 남긴다.
--   → 정리 프로세스가 멈췄다가 TTL 만료·발행 연장 뒤 재개하면 확인에서 빠져 삭제 0건.
-- - 잠금을 Storage 호출 동안 쥘 수 없으므로, 발행 트리거는 삭제 중 시각 뒤 5분 동안 RT001 로 발행 전환을 거부한다.
--   서버는 Storage 호출에 60초 제한을 두고, 재시도마다 다시 확인한다(창 5분 안에서 끝난다).
-- - 표시(mark)는 같은 토큰이고 삭제 중 시각이 있는 행만 기록한다.

alter table public.sources
  add column retention_deleting_at timestamptz,
  add column thumbnail_retention_deleting_at timestamptz;
alter table public.voice_takes add column retention_deleting_at timestamptz;
alter table public.renders add column retention_deleting_at timestamptz;
comment on column public.sources.retention_deleting_at is '원본 파일 Storage 삭제 직전 확인 시각(5분간 발행 전환 거부). 서버 전용';
comment on column public.sources.thumbnail_retention_deleting_at is '썸네일 Storage 삭제 직전 확인 시각(5분간 발행 전환 거부). 서버 전용';
comment on column public.voice_takes.retention_deleting_at is '음성 Storage 삭제 직전 확인 시각(5분간 발행 전환 거부). 서버 전용';
comment on column public.renders.retention_deleting_at is 'MP4 Storage 삭제 직전 확인 시각(5분간 발행 전환 거부). 서버 전용';

-- ── 발행 트리거: 유효 예약(30분) 또는 삭제 중(5분)이면 RT001 ──
create or replace function private.publications_set_purge()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_purge date;
  v_live timestamptz := now() - interval '30 minutes';
  v_deleting timestamptz := now() - interval '5 minutes';
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
    if exists (select 1 from public.sources
               where project_id = new.project_id
                 and ((file_deleted_at is null and retention_token is not null and retention_reserved_at > v_live)
                      or (thumbnail_deleted_at is null and thumbnail_retention_token is not null
                          and thumbnail_retention_reserved_at > v_live)
                      or retention_deleting_at > v_deleting
                      or thumbnail_retention_deleting_at > v_deleting))
       or exists (select 1 from public.voice_takes
                  where project_id = new.project_id
                    and ((file_deleted_at is null and retention_token is not null and retention_reserved_at > v_live)
                         or retention_deleting_at > v_deleting))
       or exists (select 1 from public.renders
                  where project_id = new.project_id
                    and ((file_deleted_at is null and retention_token is not null and retention_reserved_at > v_live)
                         or retention_deleting_at > v_deleting)) then
      raise exception '보관 정리 중인 파일이 있어 잠시 후 다시 시도해 주세요' using errcode = 'RT001';
    end if;
    update public.sources
    set purge_after = v_purge,
        retention_token = null, retention_reserved_at = null, retention_deleting_at = null,
        thumbnail_retention_token = null, thumbnail_retention_reserved_at = null, thumbnail_retention_deleting_at = null
    where project_id = new.project_id and file_deleted_at is null;
    update public.voice_takes
    set purge_after = v_purge, retention_token = null, retention_reserved_at = null, retention_deleting_at = null
    where project_id = new.project_id and file_deleted_at is null;
    update public.renders
    set purge_after = v_purge, retention_token = null, retention_reserved_at = null, retention_deleting_at = null
    where project_id = new.project_id and file_deleted_at is null;
  end if;
  return null;
end;
$$;

-- ── 삭제 직전 확인 ──────────────────────────────────────────
create function private.retention_confirm(p_kind text, p_ids uuid[], p_token uuid)
returns setof uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_live timestamptz := now() - interval '30 minutes';
  v_ok uuid[];
begin
  if p_kind not in ('source', 'thumbnail', 'voice', 'render') then
    raise exception '알 수 없는 종류입니다' using errcode = '22023';
  end if;
  if p_token is null then
    raise exception '예약 토큰이 없습니다' using errcode = '22023';
  end if;
  if p_ids is null or cardinality(p_ids) = 0 then
    return;
  end if;
  if cardinality(p_ids) > 1000 then
    raise exception '한 번에 확인할 수 있는 개수를 넘었습니다' using errcode = '22023';
  end if;
  -- 발행 트리거와 같은 순서(id)로 잠근 뒤, 토큰·예약 시각·기준일을 최신 커밋으로 다시 판정한다
  if p_kind = 'source' then
    perform 1 from public.sources s where s.id = any (p_ids) order by s.id for update;
    select coalesce(array_agg(s.id), '{}') into v_ok from public.sources s
    where s.id = any (p_ids) and s.retention_token = p_token and s.retention_reserved_at > v_live;
  elsif p_kind = 'thumbnail' then
    perform 1 from public.sources s where s.id = any (p_ids) order by s.id for update;
    select coalesce(array_agg(s.id), '{}') into v_ok from public.sources s
    where s.id = any (p_ids) and s.thumbnail_retention_token = p_token and s.thumbnail_retention_reserved_at > v_live;
  elsif p_kind = 'voice' then
    perform 1 from public.voice_takes t where t.id = any (p_ids) order by t.id for update;
    select coalesce(array_agg(t.id), '{}') into v_ok from public.voice_takes t
    where t.id = any (p_ids) and t.retention_token = p_token and t.retention_reserved_at > v_live;
  else
    perform 1 from public.renders r where r.id = any (p_ids) order by r.id for update;
    select coalesce(array_agg(r.id), '{}') into v_ok from public.renders r
    where r.id = any (p_ids) and r.retention_token = p_token and r.retention_reserved_at > v_live;
  end if;

  select coalesce(array_agg(c.id), '{}') into v_ok
  from private.retention_candidates() c
  where c.kind = p_kind and c.id = any (v_ok) and c.due_on <= current_date;

  if p_kind = 'source' then
    update public.sources s set retention_deleting_at = now() where s.id = any (v_ok);
  elsif p_kind = 'thumbnail' then
    update public.sources s set thumbnail_retention_deleting_at = now() where s.id = any (v_ok);
  elsif p_kind = 'voice' then
    update public.voice_takes t set retention_deleting_at = now() where t.id = any (v_ok);
  else
    update public.renders r set retention_deleting_at = now() where r.id = any (v_ok);
  end if;
  return query select unnest(v_ok);
end;
$$;
revoke execute on function private.retention_confirm(text, uuid[], uuid) from public, anon, authenticated;
grant execute on function private.retention_confirm(text, uuid[], uuid) to service_role;

create function public.retention_confirm(p_kind text, p_ids uuid[], p_token uuid)
returns setof uuid
language sql
security invoker
set search_path = ''
as $$
  select private.retention_confirm(p_kind, p_ids, p_token);
$$;
comment on function public.retention_confirm(text, uuid[], uuid) is
  'Storage 삭제 직전 재판정(토큰·예약 30분·기준일)과 삭제 중 시각 기록(task-024b). 서버 retention(service_role) 전용';
revoke execute on function public.retention_confirm(text, uuid[], uuid) from public, anon, authenticated;
grant execute on function public.retention_confirm(text, uuid[], uuid) to service_role;

-- ── 표시: 같은 토큰 + 삭제 중 시각이 있는 행만 ─────────────────
create or replace function private.retention_mark_deleted(p_kind text, p_ids uuid[], p_token uuid)
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
      update public.sources
      set file_deleted_at = now(), retention_token = null, retention_reserved_at = null, retention_deleting_at = null
      where id = any (p_ids) and retention_token = p_token and retention_deleting_at is not null
        and file_path is not null and file_deleted_at is null;
    when 'thumbnail' then
      update public.sources
      set thumbnail_deleted_at = now(), thumbnail_retention_token = null, thumbnail_retention_reserved_at = null,
          thumbnail_retention_deleting_at = null
      where id = any (p_ids) and thumbnail_retention_token = p_token and thumbnail_retention_deleting_at is not null
        and thumbnail_path is not null and thumbnail_deleted_at is null;
    when 'voice' then
      update public.voice_takes
      set file_deleted_at = now(), retention_token = null, retention_reserved_at = null, retention_deleting_at = null
      where id = any (p_ids) and retention_token = p_token and retention_deleting_at is not null
        and audio_path is not null and file_deleted_at is null;
    when 'render' then
      update public.renders
      set file_deleted_at = now(), retention_token = null, retention_reserved_at = null, retention_deleting_at = null
      where id = any (p_ids) and retention_token = p_token and retention_deleting_at is not null
        and mp4_path is not null and file_deleted_at is null;
    else
      raise exception '알 수 없는 종류입니다' using errcode = '22023';
  end case;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
