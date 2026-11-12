-- task-024b 보안 리뷰 반영 2: 예약 직후 발행 경합을 닫는다(20261112290200 보강)
-- - 발행 트리거(publications 가 scheduled·uploaded 로 전환)가 같은 행을 잠갔을 때 유효한 삭제 예약 토큰이 있으면
--   기준일을 늘리지 않고 SQLSTATE RT001 로 발행 상태 전환을 거부한다(그 트랜잭션 전체가 취소된다).
--   웹 prepare_publication 경로는 RT001 을 사용자 문구로 바꾸고, 업로더(024a)도 같은 SQLSTATE 를 일시 실패로 다룬다.
-- - 예약 토큰은 30분 TTL(retention_reserved_at). 정리 프로세스가 죽어도 30분 뒤에는 발행이 막히지 않는다.
--   만료된 토큰은 발행 트리거가 지운다. 표시(mark)는 토큰이 남아 있으면 기록한다(삭제는 이미 일어났으므로).

alter table public.sources
  add column retention_reserved_at timestamptz,
  add column thumbnail_retention_reserved_at timestamptz;
alter table public.voice_takes add column retention_reserved_at timestamptz;
alter table public.renders add column retention_reserved_at timestamptz;
comment on column public.sources.retention_reserved_at is '원본 파일 삭제 예약 시각(30분 TTL). 서버 전용';
comment on column public.sources.thumbnail_retention_reserved_at is '썸네일 삭제 예약 시각(30분 TTL). 서버 전용';
comment on column public.voice_takes.retention_reserved_at is '음성 파일 삭제 예약 시각(30분 TTL). 서버 전용';
comment on column public.renders.retention_reserved_at is 'MP4 삭제 예약 시각(30분 TTL). 서버 전용';

-- 290200 에서 남았을 수 있는 시각 없는 토큰은 무효로 정리
update public.sources set retention_token = null where retention_token is not null;
update public.sources set thumbnail_retention_token = null where thumbnail_retention_token is not null;
update public.voice_takes set retention_token = null where retention_token is not null;
update public.renders set retention_token = null where retention_token is not null;

-- ── 발행 트리거: 잠금 → 유효 예약 있으면 RT001, 없으면 기준일 연장·만료 토큰 정리 ──
create or replace function private.publications_set_purge()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_purge date;
  v_live timestamptz := now() - interval '30 minutes';
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
               where project_id = new.project_id and file_deleted_at is null
                 and ((retention_token is not null and retention_reserved_at > v_live)
                      or (thumbnail_retention_token is not null and thumbnail_retention_reserved_at > v_live)))
       or exists (select 1 from public.voice_takes
                  where project_id = new.project_id and file_deleted_at is null
                    and retention_token is not null and retention_reserved_at > v_live)
       or exists (select 1 from public.renders
                  where project_id = new.project_id and file_deleted_at is null
                    and retention_token is not null and retention_reserved_at > v_live) then
      raise exception '보관 정리 중인 파일이 있어 잠시 후 다시 시도해 주세요' using errcode = 'RT001';
    end if;
    update public.sources
    set purge_after = v_purge,
        retention_token = null, retention_reserved_at = null,
        thumbnail_retention_token = null, thumbnail_retention_reserved_at = null
    where project_id = new.project_id and file_deleted_at is null;
    update public.voice_takes set purge_after = v_purge, retention_token = null, retention_reserved_at = null
    where project_id = new.project_id and file_deleted_at is null;
    update public.renders set purge_after = v_purge, retention_token = null, retention_reserved_at = null
    where project_id = new.project_id and file_deleted_at is null;
  end if;
  return null;
end;
$$;

-- ── 예약: 토큰과 예약 시각을 함께 남긴다 ─────────────────────
create or replace function private.retention_reserve(p_kind text, p_ids uuid[])
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
    update public.sources s set retention_token = v_token, retention_reserved_at = now() where s.id = any (v_ok);
  elsif p_kind = 'thumbnail' then
    update public.sources s set thumbnail_retention_token = v_token, thumbnail_retention_reserved_at = now()
    where s.id = any (v_ok);
  elsif p_kind = 'voice' then
    update public.voice_takes t set retention_token = v_token, retention_reserved_at = now() where t.id = any (v_ok);
  else
    update public.renders r set retention_token = v_token, retention_reserved_at = now() where r.id = any (v_ok);
  end if;

  return query
  select c.id, c.path, c.user_id, c.project_id, v_token
  from private.retention_candidates() c
  where c.kind = p_kind and c.id = any (v_ok)
  order by c.id;
end;
$$;

-- ── 표시: 같은 토큰 행만, 예약 시각도 지운다 ──────────────────
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
      update public.sources set file_deleted_at = now(), retention_token = null, retention_reserved_at = null
      where id = any (p_ids) and retention_token = p_token and file_path is not null and file_deleted_at is null;
    when 'thumbnail' then
      update public.sources
      set thumbnail_deleted_at = now(), thumbnail_retention_token = null, thumbnail_retention_reserved_at = null
      where id = any (p_ids) and thumbnail_retention_token = p_token and thumbnail_path is not null
        and thumbnail_deleted_at is null;
    when 'voice' then
      update public.voice_takes set file_deleted_at = now(), retention_token = null, retention_reserved_at = null
      where id = any (p_ids) and retention_token = p_token and audio_path is not null and file_deleted_at is null;
    when 'render' then
      update public.renders set file_deleted_at = now(), retention_token = null, retention_reserved_at = null
      where id = any (p_ids) and retention_token = p_token and mp4_path is not null and file_deleted_at is null;
    else
      raise exception '알 수 없는 종류입니다' using errcode = '22023';
  end case;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
