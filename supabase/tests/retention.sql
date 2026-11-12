-- task-024b 보관 기간 지난 파일 삭제(20261112290000) 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/retention.sql
-- 한 트랜잭션으로 돌리고 ROLLBACK 한다. 서버 경로 그대로 service_role 로 public 래퍼를 부른다.
-- A1 = A 의 미발행·오래 손대지 않은 프로젝트, A2 = A 의 미발행·진행 중(최근 수정), B = B 의 프로젝트(발행 흐름)
begin;

insert into auth.users (id, aud, role, email) values
  ('00000000-0000-4000-f024-00000000000a', 'authenticated', 'authenticated', 'ret-test-a@example.com'),
  ('00000000-0000-4000-f024-00000000000b', 'authenticated', 'authenticated', 'ret-test-b@example.com');
insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-f024-00000000010a', '00000000-0000-4000-f024-00000000000a', 'youtube', 'ret-a'),
  ('00000000-0000-4000-f024-00000000010b', '00000000-0000-4000-f024-00000000000b', 'youtube', 'ret-b');
insert into public.projects (id, user_id, account_id, name, created_at, updated_at) values
  ('00000000-0000-4000-f024-0000000002a1', '00000000-0000-4000-f024-00000000000a', '00000000-0000-4000-f024-00000000010a',
   'A1', now() - interval '60 days', now() - interval '45 days'),
  ('00000000-0000-4000-f024-0000000002a2', '00000000-0000-4000-f024-00000000000a', '00000000-0000-4000-f024-00000000010a',
   'A2', now() - interval '60 days', now() - interval '1 day'),
  ('00000000-0000-4000-f024-0000000002b1', '00000000-0000-4000-f024-00000000000b', '00000000-0000-4000-f024-00000000010b',
   'B', now() - interval '60 days', now() - interval '45 days');

-- 원본: 모두 40일 전 수집(purge_after = 수집 + 30일 = 10일 전). 썸네일 미선정 8일 전·선정 40일 전
insert into public.sources (id, project_id, platform, url, author, collected_at, file_path, thumbnail_path, checked, used,
                            rights_basis, rights_confirmed_at, score) values
  -- A1: 파일 있음(대상) · 목록만(파일 없음) · 미선정 썸네일
  ('00000000-0000-4000-f024-0000000003a1', '00000000-0000-4000-f024-0000000002a1', 'tiktok', 'https://www.tiktok.com/@a/video/1', 'a1',
   now() - interval '40 days', '00000000-0000-4000-f024-00000000000a/00000000-0000-4000-f024-0000000002a1/s1.mp4',
   '00000000-0000-4000-f024-00000000000a/00000000-0000-4000-f024-0000000002a1/s1.jpg', true, true,
   'own', now() - interval '40 days', 90),
  ('00000000-0000-4000-f024-0000000003a2', '00000000-0000-4000-f024-0000000002a1', 'tiktok', 'https://www.tiktok.com/@a/video/2', 'a2',
   now() - interval '40 days', null, null, false, false, null, null, null),
  -- A2(진행 중): 선정 원본은 연장, 미선정 썸네일은 8일 전 수집이라 7일 규칙으로 대상, 3일 전 수집 썸네일은 아님
  ('00000000-0000-4000-f024-0000000003a3', '00000000-0000-4000-f024-0000000002a2', 'tiktok', 'https://www.tiktok.com/@a/video/3', 'a3',
   now() - interval '40 days', '00000000-0000-4000-f024-00000000000a/00000000-0000-4000-f024-0000000002a2/s3.mp4',
   '00000000-0000-4000-f024-00000000000a/00000000-0000-4000-f024-0000000002a2/s3.jpg', true, false, null, null, 80),
  ('00000000-0000-4000-f024-0000000003a4', '00000000-0000-4000-f024-0000000002a2', 'xiaohongshu', 'https://www.xiaohongshu.com/explore/4', 'a4',
   now() - interval '8 days', null,
   '00000000-0000-4000-f024-00000000000a/00000000-0000-4000-f024-0000000002a2/s4.jpg', false, false, null, null, null),
  ('00000000-0000-4000-f024-0000000003a5', '00000000-0000-4000-f024-0000000002a2', 'xiaohongshu', 'https://www.xiaohongshu.com/explore/5', 'a5',
   now() - interval '3 days', null,
   '00000000-0000-4000-f024-00000000000a/00000000-0000-4000-f024-0000000002a2/s5.jpg', false, false, null, null, null),
  -- B: 40일 전 수집, 아직 미발행(대상) → 발행 후 기준일 재계산으로 빠짐
  ('00000000-0000-4000-f024-0000000003b1', '00000000-0000-4000-f024-0000000002b1', 'tiktok', 'https://www.tiktok.com/@b/video/1', 'b1',
   now() - interval '40 days', '00000000-0000-4000-f024-00000000000b/00000000-0000-4000-f024-0000000002b1/s1.mp4',
   null, true, true, 'own', now() - interval '40 days', 70);

insert into public.voice_takes (id, project_id, voice_id, source, audio_path, duration_sec, created_at, purge_after) values
  ('00000000-0000-4000-f024-0000000004a1', '00000000-0000-4000-f024-0000000002a1', 'Leda', 'tts',
   '00000000-0000-4000-f024-00000000000a/00000000-0000-4000-f024-0000000002a1/v1.wav', 15,
   now() - interval '40 days', (now() - interval '10 days')::date),
  ('00000000-0000-4000-f024-0000000004a2', '00000000-0000-4000-f024-0000000002a2', 'Leda', 'tts',
   '00000000-0000-4000-f024-00000000000a/00000000-0000-4000-f024-0000000002a2/v1.wav', 15,
   now() - interval '40 days', (now() - interval '10 days')::date),
  ('00000000-0000-4000-f024-0000000004b1', '00000000-0000-4000-f024-0000000002b1', 'Leda', 'tts',
   '00000000-0000-4000-f024-00000000000b/00000000-0000-4000-f024-0000000002b1/v1.wav', 15,
   now() - interval '40 days', (now() - interval '10 days')::date);
insert into public.renders (id, project_id, version, mp4_path, created_at, purge_after) values
  ('00000000-0000-4000-f024-0000000005a1', '00000000-0000-4000-f024-0000000002a1', 1,
   '00000000-0000-4000-f024-00000000000a/00000000-0000-4000-f024-0000000002a1/r1.mp4',
   now() - interval '40 days', (now() - interval '10 days')::date),
  ('00000000-0000-4000-f024-0000000005b1', '00000000-0000-4000-f024-0000000002b1', 1,
   '00000000-0000-4000-f024-00000000000b/00000000-0000-4000-f024-0000000002b1/r1.mp4',
   now() - interval '40 days', (now() - interval '10 days')::date);

create temp table t_due (kind text, id uuid, bucket text, path text, user_id uuid, project_id uuid, due_on date);
grant select, insert, delete on t_due to service_role;

create function pg_temp.expect_fail(p_sql text, p_state text, p_label text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate <> p_state then
      raise exception 'FAIL: % → % (%)', p_label, sqlstate, sqlerrm;
    end if;
    return;
  end;
  raise exception 'FAIL: % 가 거부되지 않음', p_label;
end;
$$;

-- ── 1) 권한: anon·authenticated·worker_role 실행 불가, service_role 만 ──
do $$
declare f text;
begin
  foreach f in array array['public.retention_due(integer,date,text,uuid)', 'public.retention_reserve(text,uuid[])',
                           'public.retention_mark_deleted(text,uuid[],uuid)', 'public.retention_confirm(text,uuid[],uuid)',
                           'private.retention_confirm(text,uuid[],uuid)',
                           'private.retention_due(integer,date,text,uuid)', 'private.retention_reserve(text,uuid[])',
                           'private.retention_mark_deleted(text,uuid[],uuid)'] loop
    if has_function_privilege('anon', f, 'execute') or has_function_privilege('authenticated', f, 'execute')
       or has_function_privilege('worker_role', f, 'execute') then
      raise exception 'FAIL: % 를 anon·authenticated·worker_role 이 실행 가능', f;
    end if;
    if not has_function_privilege('service_role', f, 'execute') then
      raise exception 'FAIL: service_role % 불가', f;
    end if;
  end loop;
  if has_function_privilege('service_role', 'private.publications_set_purge()', 'execute')
     or has_function_privilege('authenticated', 'private.publications_set_purge()', 'execute')
     or has_function_privilege('service_role', 'private.retention_candidates()', 'execute') then
    raise exception 'FAIL: 트리거 함수를 직접 실행 가능';
  end if;
  if has_column_privilege('authenticated', 'public.sources', 'thumbnail_deleted_at', 'update')
     or has_column_privilege('authenticated', 'public.voice_takes', 'file_deleted_at', 'update')
     or has_column_privilege('authenticated', 'public.renders', 'purge_after', 'update')
     or has_column_privilege('authenticated', 'public.renders', 'retention_token', 'update')
     or has_column_privilege('authenticated', 'public.sources', 'thumbnail_retention_token', 'update') then
    raise exception 'FAIL: 사용자가 보관 열을 바꿀 수 있음';
  end if;
  raise notice 'PASS 1 보관 함수 service_role 전용, 보관 열 사용자 쓰기 불가';
end $$;

-- ── 2) 대상 목록: 미발행 오래된 것·미선정 썸네일 7일만, 진행 중 연장 ──
set local role service_role;
insert into t_due select * from public.retention_due(100) where project_id::text like '00000000-0000-4000-f024-%';
reset role;

do $$
declare v text[];
begin
  select array_agg(kind || ' ' || right(id::text, 3) order by kind, id) into v from t_due;
  -- A1: source a1 · thumbnail a1 · voice a1 · render a1 / A2: thumbnail a4 / B(미발행, 손대지 않음): source b1 · voice b1 · render b1
  if v is distinct from array['render 5a1', 'render 5b1', 'source 3a1', 'source 3b1', 'thumbnail 3a1', 'thumbnail 3a4',
                              'voice 4a1', 'voice 4b1'] then
    raise exception 'FAIL: 대상 목록이 다름: %', v;
  end if;
  if exists (select 1 from t_due where bucket <> case kind when 'source' then 'sources' when 'thumbnail' then 'thumbnails'
                                                           when 'voice' then 'voices' else 'renders' end
                                    or not starts_with(path, user_id::text || '/' || project_id::text || '/')) then
    raise exception 'FAIL: 버킷·경로·소유자 매핑이 다름';
  end if;
  raise notice 'PASS 2 기준일 지난 것만: 진행 중 프로젝트 원본·음성 연장, 미선정 썸네일 7일, 3일 썸네일·목록만 원본 제외';
end $$;

-- ── 3) 발행 시 기준일 재계산: B 를 예약(10일 뒤) → B 파일 purge_after = 예약 + 30일, A 는 그대로 ──
insert into public.publications (project_id, account_id, mode, status)
values ('00000000-0000-4000-f024-0000000002b1', '00000000-0000-4000-f024-00000000010b', 'scheduled', 'pending');
do $$
begin
  if (select purge_after from public.sources where id = '00000000-0000-4000-f024-0000000003b1')
     <> (now() - interval '10 days')::date then
    raise exception 'FAIL: pending 에서 기준일이 바뀜';
  end if;
end $$;
update public.publications set scheduled_at = now() + interval '10 days', status = 'scheduled'
where project_id = '00000000-0000-4000-f024-0000000002b1';
do $$
declare v_exp date := (now() + interval '40 days')::date;
begin
  if (select purge_after from public.sources where id = '00000000-0000-4000-f024-0000000003b1') <> v_exp
     or (select purge_after from public.voice_takes where id = '00000000-0000-4000-f024-0000000004b1') <> v_exp
     or (select purge_after from public.renders where id = '00000000-0000-4000-f024-0000000005b1') <> v_exp then
    raise exception 'FAIL: 예약 발행 기준일 재계산 안 됨';
  end if;
  if (select purge_after from public.sources where id = '00000000-0000-4000-f024-0000000003a1') <> (now() - interval '10 days')::date
     or (select purge_after from public.renders where id = '00000000-0000-4000-f024-0000000005a1') <> (now() - interval '10 days')::date then
    raise exception 'FAIL: 남의 프로젝트 기준일이 바뀜';
  end if;
end $$;
-- 업로드 완료(지금 시각) → 예약 시각이 더 늦으므로 그대로 예약 + 30일
update public.publications set status = 'uploaded', published_at = now()
where project_id = '00000000-0000-4000-f024-0000000002b1';
do $$
begin
  if (select purge_after from public.renders where id = '00000000-0000-4000-f024-0000000005b1') <> (now() + interval '40 days')::date then
    raise exception 'FAIL: 업로드 후 기준일이 예약 + 30일이 아님';
  end if;
end $$;

set local role service_role;
delete from t_due;
insert into t_due select * from public.retention_due(100) where project_id::text like '00000000-0000-4000-f024-%';
reset role;
do $$
begin
  if exists (select 1 from t_due where project_id = '00000000-0000-4000-f024-0000000002b1') then
    raise exception 'FAIL: 발행 직후 B 파일이 대상에 남음';
  end if;
  raise notice 'PASS 3 발행(scheduled·uploaded) 시 기준일 = 늦은 시각 + 30일, pending 은 그대로, 남의 프로젝트 영향 없음';
end $$;

-- 🔴1 목록 조회(2번, B 포함) 뒤 발행 → 삭제 직전 예약에서 빠진다(삭제 0건)
set local role service_role;
do $$
begin
  if (select count(*) from public.retention_reserve('source', array['00000000-0000-4000-f024-0000000003b1'::uuid])) <> 0
     or (select count(*) from public.retention_reserve('voice', array['00000000-0000-4000-f024-0000000004b1'::uuid])) <> 0
     or (select count(*) from public.retention_reserve('render', array['00000000-0000-4000-f024-0000000005b1'::uuid])) <> 0 then
    raise exception 'FAIL: 목록 조회 뒤 발행된 파일이 삭제 예약됨';
  end if;
  raise notice 'PASS 3-2 목록 조회 뒤 발행 → 예약(삭제) 0건';
end $$;
reset role;

-- 발행된 프로젝트는 최근 수정이 있어도 저장된 기준일만 본다(기준일을 지난 날로 조작)
update public.renders set purge_after = current_date where id = '00000000-0000-4000-f024-0000000005b1';
set local role service_role;
delete from t_due;
insert into t_due select * from public.retention_due(100) where project_id::text like '00000000-0000-4000-f024-%';
reset role;
do $$
begin
  if not exists (select 1 from t_due where kind = 'render' and id = '00000000-0000-4000-f024-0000000005b1') then
    raise exception 'FAIL: 발행 프로젝트의 기준일 당일 MP4 가 대상이 아님';
  end if;
  raise notice 'PASS 4 발행 프로젝트는 저장된 기준일(당일 포함)로 판정';
end $$;

-- 예약 중(30분 TTL 안) 발행 상태 전환은 RT001 로 거부, TTL 이 지나면 발행되고 만료 토큰은 지워져 표시되지 않는다
create temp table t_tok (token uuid);
grant select, insert on t_tok to service_role;
set local role service_role;
insert into t_tok select token from public.retention_reserve('render', array['00000000-0000-4000-f024-0000000005b1'::uuid]);
reset role;
select pg_temp.expect_fail($$update public.publications set published_at = now() + interval '1 minute'
                             where project_id = '00000000-0000-4000-f024-0000000002b1'$$, 'RT001', '예약 중 발행 전환');
do $$
begin
  if (select count(*) from t_tok) <> 1 then raise exception 'FAIL: 기준일 당일 MP4 예약 안 됨'; end if;
  if (select published_at > now() from public.publications where project_id = '00000000-0000-4000-f024-0000000002b1')
     or (select retention_token from public.renders where id = '00000000-0000-4000-f024-0000000005b1')
        is distinct from (select token from t_tok) then
    raise exception 'FAIL: 거부된 발행 전환이 일부 반영됨';
  end if;
  raise notice 'PASS 4-2 삭제 예약 중 발행 상태 전환 → RT001 거부(변경 없음)';
end $$;
-- 정지·재개: 예약 뒤 정리 프로세스가 멈춰 TTL(30분)이 지남 → 만료 토큰으로는 삭제 직전 확인 0건(발행 전에도)
update public.renders set retention_reserved_at = now() - interval '31 minutes'
where id = '00000000-0000-4000-f024-0000000005b1';
set local role service_role;
do $$
begin
  if exists (select 1 from public.retention_confirm('render', array['00000000-0000-4000-f024-0000000005b1'::uuid],
                                                    (select token from t_tok))) then
    raise exception 'FAIL: 만료 토큰이 삭제 직전 확인을 통과';
  end if;
end $$;
reset role;
-- TTL 이 지났으니 발행 가능 → 기준일 연장·토큰 정리 → 재개해도 확인·표시 0건(삭제 0)
update public.publications set published_at = now() + interval '1 minute'
where project_id = '00000000-0000-4000-f024-0000000002b1';
set local role service_role;
do $$
begin
  if exists (select 1 from public.retention_confirm('render', array['00000000-0000-4000-f024-0000000005b1'::uuid],
                                                    (select token from t_tok)))
     or public.retention_mark_deleted('render', array['00000000-0000-4000-f024-0000000005b1'::uuid], (select token from t_tok)) <> 0 then
    raise exception 'FAIL: 발행 연장 뒤 재개한 정리가 삭제 대상으로 확인됨';
  end if;
  raise notice 'PASS 4-3 정지 뒤 TTL 만료·발행 연장 → 재개해도 삭제 직전 확인 0건, 표시 0건';
end $$;
reset role;

-- 삭제 직전 확인 뒤 5분(삭제 중)은 발행 전환 RT001, 5분이 지나면 가능
update public.renders set purge_after = current_date where id = '00000000-0000-4000-f024-0000000005b1';
delete from t_tok;
set local role service_role;
insert into t_tok select token from public.retention_reserve('render', array['00000000-0000-4000-f024-0000000005b1'::uuid]);
do $$
begin
  if not exists (select 1 from public.retention_confirm('render', array['00000000-0000-4000-f024-0000000005b1'::uuid],
                                                        (select token from t_tok))) then
    raise exception 'FAIL: 유효한 예약이 삭제 직전 확인을 통과하지 못함';
  end if;
end $$;
reset role;
update public.renders set retention_reserved_at = now() - interval '31 minutes'
where id = '00000000-0000-4000-f024-0000000005b1';
select pg_temp.expect_fail($$update public.publications set published_at = now() + interval '2 minutes'
                             where project_id = '00000000-0000-4000-f024-0000000002b1'$$, 'RT001', '삭제 중 발행 전환');
update public.renders set retention_deleting_at = now() - interval '6 minutes'
where id = '00000000-0000-4000-f024-0000000005b1';
update public.publications set published_at = now() + interval '2 minutes'
where project_id = '00000000-0000-4000-f024-0000000002b1';
do $$
begin
  if (select retention_deleting_at from public.renders where id = '00000000-0000-4000-f024-0000000005b1') is not null then
    raise exception 'FAIL: 발행 뒤 삭제 중 시각이 남음';
  end if;
  raise notice 'PASS 4-4 삭제 직전 확인 뒤 5분은 발행 전환 RT001, 지나면 가능';
end $$;

-- ── 5) 예약 → 삭제 표시: 토큰 일치 행만, 행·출처 기록 유지, 다시 대상 아님, 재렌더 입력에서 빠짐 ──
set local role service_role;
do $$
declare v_tok uuid; v_n integer;
begin
  select max(token::text)::uuid, count(*) into v_tok, v_n
  from public.retention_reserve('source', array['00000000-0000-4000-f024-0000000003a1'::uuid,
                                                '00000000-0000-4000-f024-0000000003a2'::uuid,
                                                '00000000-0000-4000-f024-0000000003a3'::uuid]);
  if v_n <> 1 then raise exception 'FAIL: 파일 없는·연장된 원본까지 예약됨 (%건)', v_n; end if;
  if public.retention_mark_deleted('source', array['00000000-0000-4000-f024-0000000003a1'::uuid], v_tok) <> 0 then
    raise exception 'FAIL: 삭제 직전 확인 없이 표시됨';
  end if;
  if exists (select 1 from public.retention_confirm('source', array['00000000-0000-4000-f024-0000000003a1'::uuid], gen_random_uuid())) then
    raise exception 'FAIL: 다른 토큰으로 확인됨';
  end if;
  perform public.retention_confirm('source', array['00000000-0000-4000-f024-0000000003a1'::uuid,
                                                   '00000000-0000-4000-f024-0000000003a3'::uuid], v_tok);
  if public.retention_mark_deleted('source', array['00000000-0000-4000-f024-0000000003a1'::uuid], gen_random_uuid()) <> 0 then
    raise exception 'FAIL: 다른 토큰으로 표시됨';
  end if;
  if public.retention_mark_deleted('source', array['00000000-0000-4000-f024-0000000003a1'::uuid,
                                                   '00000000-0000-4000-f024-0000000003a3'::uuid], v_tok) <> 1 then
    raise exception 'FAIL: 예약한 원본만 표시되지 않음';
  end if;
  if public.retention_mark_deleted('source', array['00000000-0000-4000-f024-0000000003a1'::uuid], v_tok) <> 0 then
    raise exception 'FAIL: 두 번 표시됨';
  end if;
  select max(token::text)::uuid into v_tok from public.retention_reserve('thumbnail', array['00000000-0000-4000-f024-0000000003a4'::uuid]);
  perform public.retention_confirm('thumbnail', array['00000000-0000-4000-f024-0000000003a4'::uuid], v_tok);
  if public.retention_mark_deleted('thumbnail', array['00000000-0000-4000-f024-0000000003a4'::uuid], v_tok) <> 1 then
    raise exception 'FAIL: 썸네일 표시';
  end if;
  select max(token::text)::uuid into v_tok from public.retention_reserve('voice', array['00000000-0000-4000-f024-0000000004a1'::uuid]);
  perform public.retention_confirm('voice', array['00000000-0000-4000-f024-0000000004a1'::uuid], v_tok);
  if public.retention_mark_deleted('voice', array['00000000-0000-4000-f024-0000000004a1'::uuid], v_tok) <> 1 then
    raise exception 'FAIL: 음성 표시';
  end if;
  select max(token::text)::uuid into v_tok from public.retention_reserve('render', array['00000000-0000-4000-f024-0000000005a1'::uuid]);
  perform public.retention_confirm('render', array['00000000-0000-4000-f024-0000000005a1'::uuid], v_tok);
  if public.retention_mark_deleted('render', array['00000000-0000-4000-f024-0000000005a1'::uuid], v_tok) <> 1
     or public.retention_mark_deleted('voice', '{}', v_tok) <> 0 then
    raise exception 'FAIL: MP4 표시';
  end if;
end $$;
select pg_temp.expect_fail($$select * from public.retention_reserve('project', array[gen_random_uuid()])$$, '22023', '알 수 없는 종류(예약)');
select pg_temp.expect_fail($$select * from public.retention_confirm('project', array[gen_random_uuid()], gen_random_uuid())$$, '22023', '알 수 없는 종류(확인)');
select pg_temp.expect_fail($$select public.retention_mark_deleted('project', array[gen_random_uuid()], gen_random_uuid())$$, '22023', '알 수 없는 종류');
select pg_temp.expect_fail($$select public.retention_mark_deleted('source', array[gen_random_uuid()], null)$$, '22023', '토큰 없음');
delete from t_due;
insert into t_due select * from public.retention_due(100) where project_id::text like '00000000-0000-4000-f024-%';
reset role;
do $$
begin
  if exists (select 1 from t_due where id in ('00000000-0000-4000-f024-0000000004a1', '00000000-0000-4000-f024-0000000005a1')
                                    or (kind = 'source' and id = '00000000-0000-4000-f024-0000000003a1')
                                    or (kind = 'thumbnail' and id = '00000000-0000-4000-f024-0000000003a4')) then
    raise exception 'FAIL: 표시된 파일이 다시 대상';
  end if;
  if not exists (select 1 from t_due where kind = 'thumbnail' and id = '00000000-0000-4000-f024-0000000003a1') then
    raise exception 'FAIL: 원본 파일 표시가 썸네일까지 지움';
  end if;
  if not exists (select 1 from public.sources
                 where id = '00000000-0000-4000-f024-0000000003a1' and file_deleted_at is not null
                   and url = 'https://www.tiktok.com/@a/video/1' and author = 'a1' and platform = 'tiktok'
                   and collected_at is not null and rights_basis = 'own' and file_path is not null)
     or (select count(*) from public.voice_takes where id = '00000000-0000-4000-f024-0000000004a1') <> 1
     or (select count(*) from public.renders where id = '00000000-0000-4000-f024-0000000005a1') <> 1 then
    raise exception 'FAIL: 출처 행·기록이 사라짐';
  end if;
  if exists (select 1 from private.render_input_sources('00000000-0000-4000-f024-0000000002a1')) then
    raise exception 'FAIL: 삭제된 원본이 재렌더 입력에 남음';
  end if;
  if (select count(*) from public.sources where project_id = '00000000-0000-4000-f024-0000000002b1' and file_deleted_at is not null) <> 0 then
    raise exception 'FAIL: 남의 프로젝트 원본이 표시됨';
  end if;
  raise notice 'PASS 5 삭제 표시: 파일 있는 행만 1회, 출처 행 유지, 다시 대상 아님, 재렌더 입력 제외, 남의 프로젝트 영향 없음';
end $$;

-- ── 5-2) 파일이 지워진 프로젝트(A1: 원본·음성 삭제 표시됨)를 다시 렌더하면 RD001 ──
insert into public.jobs (id, project_id, step, type, status, idempotency_key) values
  ('00000000-0000-4000-f024-0000000006a1', '00000000-0000-4000-f024-0000000002a1', 5, 'render', 'running', 'ret-render-1');
do $$
begin
  perform private.render_job_context('00000000-0000-4000-f024-0000000006a1');
  raise exception 'FAIL: 지워진 파일로 재렌더 입력이 만들어짐';
exception when sqlstate 'RD001' then
  raise notice 'PASS 5-2 삭제된 원본·음성으로 재렌더 시 RD001';
end $$;

-- ── 6) 사용자는 목록·표시 불가 ──
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-f024-00000000000a","role":"authenticated"}', true);
select pg_temp.expect_fail($$select * from public.retention_due(10)$$, '42501', '사용자 목록');
select pg_temp.expect_fail($$select public.retention_mark_deleted('source', array['00000000-0000-4000-f024-0000000003b1'::uuid], gen_random_uuid())$$,
                           '42501', '사용자 표시');
select pg_temp.expect_fail($$select * from public.retention_reserve('source', array['00000000-0000-4000-f024-0000000003b1'::uuid])$$,
                           '42501', '사용자 예약');
select pg_temp.expect_fail($$select * from public.retention_confirm('source', array['00000000-0000-4000-f024-0000000003b1'::uuid], gen_random_uuid())$$,
                           '42501', '사용자 확인');
select pg_temp.expect_fail($$update public.sources set file_deleted_at = now() where id = '00000000-0000-4000-f024-0000000003a3'$$,
                           '42501', '사용자 직접 수정');
reset role;
do $$ begin raise notice 'PASS 6 사용자 세션은 목록·표시·직접 수정 거부'; end $$;

-- ── 7) 키셋 페이지: 1건씩 커서로 넘겨도 전체 목록과 같다 ──
set local role service_role;
do $$
declare v_all text[]; v_paged text[] := '{}'; r record; v_due date; v_kind text; v_id uuid; v_n integer := 0;
begin
  select coalesce(array_agg(d.kind || ':' || d.id order by d.due_on, d.kind, d.id), '{}') into v_all from public.retention_due(1000) d;
  loop
    select * into r from public.retention_due(1, v_due, v_kind, v_id);
    exit when r.id is null;
    v_paged := v_paged || (r.kind || ':' || r.id);
    v_due := r.due_on; v_kind := r.kind; v_id := r.id;
    v_n := v_n + 1;
    if v_n > 2000 then raise exception 'FAIL: 커서가 끝나지 않음'; end if;
  end loop;
  if v_paged is distinct from v_all or cardinality(v_all) = 0 then
    raise exception 'FAIL: 키셋 페이지 결과가 다름 % / %', v_paged, v_all;
  end if;
  raise notice 'PASS 7 키셋 페이지(due_on·kind·id) 전체 순회 = 전체 목록';
end $$;
reset role;

-- ── 8) 기존 행 보정 결과: 발행된 프로젝트의 남은 파일은 발행 기준 + 30일 이상 ──
do $$
begin
  if exists (
    select 1 from public.publications pub
    join (select project_id, purge_after from public.sources where file_deleted_at is null
          union all select project_id, purge_after from public.voice_takes where file_deleted_at is null
          union all select project_id, purge_after from public.renders where file_deleted_at is null) f
      on f.project_id = pub.project_id
    where pub.status in ('scheduled', 'uploaded')
      and pub.project_id <> '00000000-0000-4000-f024-0000000002b1'
      and f.purge_after < (greatest(coalesce(pub.scheduled_at, pub.created_at), coalesce(pub.published_at, pub.created_at))
                           + interval '30 days')::date) then
    raise exception 'FAIL: 발행 기준보다 이른 기준일이 남음';
  end if;
  raise notice 'PASS 8 발행된 프로젝트의 파일 기준일 >= 발행 기준 + 30일(보정)';
end $$;

rollback;
