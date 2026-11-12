-- task-015a 확장 수집 DB(20261112240000) 테스트. 실행:
--   docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/tests/extension_collect.sql
-- 한 트랜잭션으로 돌리고 ROLLBACK 한다(테스트 사용자 ext-test-* 는 남지 않는다).
-- 확장 함수는 서버(service_role)가 public 래퍼로 부르는 경로 그대로 실행한다.
-- 사용자 A(확장 EA · 폐기된 EA2) · 사용자 B(확장 EB). 작업: J1 collect(PA) · J2 collect_download(PA) · JB collect(PB)
begin;

insert into auth.users (id, aud, role, email) values
  ('00000000-0000-4000-f015-00000000000a', 'authenticated', 'authenticated', 'ext-test-a@example.com'),
  ('00000000-0000-4000-f015-00000000000b', 'authenticated', 'authenticated', 'ext-test-b@example.com');
insert into public.accounts (id, user_id, platform, channel_name) values
  ('00000000-0000-4000-f015-00000000010a', '00000000-0000-4000-f015-00000000000a', 'youtube', 'ext-a'),
  ('00000000-0000-4000-f015-00000000010b', '00000000-0000-4000-f015-00000000000b', 'youtube', 'ext-b');
insert into public.projects (id, user_id, account_id, name, step_status) values
  ('00000000-0000-4000-f015-00000000020a', '00000000-0000-4000-f015-00000000000a',
   '00000000-0000-4000-f015-00000000010a', 'PA',
   '{"1":"approved","2":"idle","3":"idle","4":"idle","5":"idle","6":"idle"}'),
  ('00000000-0000-4000-f015-00000000020b', '00000000-0000-4000-f015-00000000000b',
   '00000000-0000-4000-f015-00000000010b', 'PB',
   '{"1":"approved","2":"idle","3":"idle","4":"idle","5":"idle","6":"idle"}');

insert into public.extension_connections
  (id, user_id, access_token_hash, access_expires_at, refresh_token_hash, refresh_expires_at, family_id, revoked_at)
values
  ('00000000-0000-4000-f015-0000000003a1', '00000000-0000-4000-f015-00000000000a', 'ext-test-a1', now() + interval '15 minutes',
   'ext-test-r-a1', now() + interval '30 days', gen_random_uuid(), null),
  ('00000000-0000-4000-f015-0000000003a2', '00000000-0000-4000-f015-00000000000a', 'ext-test-a2', now() + interval '15 minutes',
   'ext-test-r-a2', now() + interval '30 days', gen_random_uuid(), now()),
  ('00000000-0000-4000-f015-0000000003b1', '00000000-0000-4000-f015-00000000000b', 'ext-test-b1', now() + interval '15 minutes',
   'ext-test-r-b1', now() + interval '30 days', gen_random_uuid(), null);

insert into public.jobs (id, project_id, step, type, status, idempotency_key, created_at) values
  ('00000000-0000-4000-f015-0000000004a1', '00000000-0000-4000-f015-00000000020a', 2, 'collect',
   'waiting_extension', 'ext-test-j1', now() - interval '2 hours'),
  ('00000000-0000-4000-f015-0000000004b1', '00000000-0000-4000-f015-00000000020b', 2, 'collect',
   'waiting_extension', 'ext-test-jb', now() - interval '1 hour');

-- 기존 원본 1편(중복 검사용) + 체크 원본 1편 + 미체크 원본 1편
insert into public.sources (id, project_id, platform, url, author, checked) values
  ('00000000-0000-4000-f015-0000000005a1', '00000000-0000-4000-f015-00000000020a', 'tiktok',
   'https://www.tiktok.com/@dup/video/1', 'dup', true),
  ('00000000-0000-4000-f015-0000000005a2', '00000000-0000-4000-f015-00000000020a', 'tiktok',
   'https://www.tiktok.com/@dup/video/2', 'dup', false);

-- 실패해야 하는 SQL: 기대 SQLSTATE 로 실패하지 않으면 FAIL
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

create function pg_temp.items(p_json text) returns text language sql as $$
  select format('select public.extension_collect_list(%L, %L, %L::jsonb)',
                '00000000-0000-4000-f015-0000000003a1', '00000000-0000-4000-f015-0000000004a1', p_json);
$$;

-- ── 1) 권한 ─────────────────────────────────────────────────
do $$
declare f text; r text;
begin
  foreach f in array array[
    'public.extension_heartbeat(uuid)', 'public.extension_claim_job(uuid,uuid)',
    'public.extension_collect_list(uuid,uuid,jsonb)', 'public.extension_collect_download(uuid,uuid,jsonb)',
    'private.ext_heartbeat(uuid)', 'private.ext_claim_job(uuid,uuid)',
    'private.ext_collect_list(uuid,uuid,jsonb)', 'private.ext_collect_download(uuid,uuid,jsonb)',
    'private.ext_job_project(uuid,uuid,text)', 'private.normalize_collect_url(text)',
    'private.jobs_waiting_since()'] loop
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then raise exception 'FAIL: % 가 % 실행 가능', r, f; end if;
    end loop;
  end loop;
  foreach f in array array[
    'public.extension_heartbeat(uuid)', 'public.extension_claim_job(uuid,uuid)',
    'public.extension_collect_list(uuid,uuid,jsonb)', 'public.extension_collect_download(uuid,uuid,jsonb)'] loop
    if not has_function_privilege('service_role', f, 'execute') then raise exception 'FAIL: service_role % 불가', f; end if;
  end loop;
  if has_function_privilege('service_role', 'private.ext_job_project(uuid,uuid,text)', 'execute')
     or has_function_privilege('service_role', 'private.add_direct_source(uuid,text,text,text)', 'execute') then
    raise exception 'FAIL: service_role 이 래퍼 밖 private 함수 실행 가능';
  end if;
  if has_column_privilege('authenticated', 'public.sources', 'thumbnail_path', 'UPDATE')
     or has_column_privilege('authenticated', 'public.sources', 'thumbnail_path', 'INSERT')
     or has_column_privilege('authenticated', 'public.jobs', 'waiting_since', 'UPDATE')
     or has_column_privilege('worker_role', 'public.jobs', 'waiting_since', 'UPDATE') then
    raise exception 'FAIL: 새 열 쓰기 권한 노출';
  end if;
  if not (select bool_and(relrowsecurity) from pg_class
          where oid in ('public.sources'::regclass, 'public.jobs'::regclass)) then
    raise exception 'FAIL: RLS 꺼짐';
  end if;
  if (select file_size_limit from storage.buckets where id = 'sources') <> 209715200
     or (select (public, file_size_limit, allowed_mime_types) from storage.buckets where id = 'thumbnails')
        is distinct from (false, 524288::bigint, array['image/jpeg', 'image/webp']) then
    raise exception 'FAIL: 버킷 상한';
  end if;
  raise notice 'PASS 1 새 함수 anon·authenticated 실행 불가, 래퍼만 service_role, 새 열 쓰기 권한 없음, 버킷 200MiB·썸네일 512KiB';
end $$;

-- ── 2) collect_download 작업 생성(사용자) ────────────────────
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-f015-00000000000a","role":"authenticated"}', true);
do $$
declare r jsonb;
begin
  r := public.create_job('00000000-0000-4000-f015-00000000020a', 'collect_download', 'ext-test-download-1');
  if r ->> 'status' <> 'waiting_extension' or r ->> 'type' <> 'collect_download' or r ->> 'step' <> '2' then
    raise exception 'FAIL: collect_download 생성 %', r;
  end if;
  raise notice 'PASS 2 collect_download 작업은 02 단계 waiting_extension 으로 생성';
end $$;
reset role;

-- J2 = 방금 만든 collect_download. 하트비트 순서를 정하려고 생성 시각을 J1 뒤로
create temp table t_ids as
select id from public.jobs where idempotency_key = '00000000-0000-4000-f015-00000000000a:ext-test-download-1';
grant select on t_ids to service_role;
do $$
begin
  if exists (select 1 from pgmq.q_analyze where message ->> 'job_id' = (select id::text from t_ids)) then
    raise exception 'FAIL: collect_download 가 큐에 들어감';
  end if;
end $$;

-- ── 3) 하트비트·claim (서버 = service_role) ─────────────────
set local role service_role;
do $$
declare n int; r record; v_j2 uuid := (select id from t_ids);
begin
  -- 하트비트: A 의 대기 작업 중 가장 오래된 J1
  select * into r from public.extension_heartbeat('00000000-0000-4000-f015-0000000003a1');
  if r.id is distinct from '00000000-0000-4000-f015-0000000004a1'::uuid or r.type <> 'collect' then
    raise exception 'FAIL: 하트비트 대기 작업 %', r;
  end if;
  perform pg_temp.expect_fail($q$select * from public.extension_heartbeat('00000000-0000-4000-f015-0000000003a2')$q$,
                              '42501', '폐기된 확장 하트비트');

  -- claim 실패: 남의 job · 폐기된 확장 · 다른 사용자 확장
  select count(*) into n from public.extension_claim_job('00000000-0000-4000-f015-0000000003a1', '00000000-0000-4000-f015-0000000004b1');
  if n <> 0 then raise exception 'FAIL: 남의 job claim'; end if;
  select count(*) into n from public.extension_claim_job('00000000-0000-4000-f015-0000000003a2', '00000000-0000-4000-f015-0000000004a1');
  if n <> 0 then raise exception 'FAIL: 폐기된 확장 claim'; end if;
  select count(*) into n from public.extension_claim_job('00000000-0000-4000-f015-0000000003b1', '00000000-0000-4000-f015-0000000004a1');
  if n <> 0 then raise exception 'FAIL: 다른 사용자 확장 claim'; end if;

  -- 성공 1행, 이미 running 이면 0행
  select count(*) into n from public.extension_claim_job('00000000-0000-4000-f015-0000000003a1', '00000000-0000-4000-f015-0000000004a1');
  if n <> 1 then raise exception 'FAIL: claim 성공 %', n; end if;
  select count(*) into n from public.extension_claim_job('00000000-0000-4000-f015-0000000003a1', '00000000-0000-4000-f015-0000000004a1');
  if n <> 0 then raise exception 'FAIL: running job 재claim'; end if;
  select count(*) into n from public.extension_claim_job('00000000-0000-4000-f015-0000000003a1', v_j2);
  if n <> 1 then raise exception 'FAIL: collect_download claim'; end if;
  raise notice 'PASS 3 하트비트는 대기 작업 1건 반환·폐기 확장 거부, claim 은 남의 job·폐기 확장·running → 0행';
end $$;
reset role;

do $$
begin
  if (select (status, extension_id, started_at) from public.jobs where id = '00000000-0000-4000-f015-0000000004a1')
     is distinct from ('running'::text, '00000000-0000-4000-f015-0000000003a1'::uuid, now()) then
    raise exception 'FAIL: claim 후 상태';
  end if;
end $$;

-- ── 4) 목록 입력(J1, EA) ────────────────────────────────────
set local role service_role;
do $$
declare r jsonb; n int; big text;
begin
  r := public.extension_collect_list('00000000-0000-4000-f015-0000000003a1', '00000000-0000-4000-f015-0000000004a1',
    jsonb_build_array(
      jsonb_build_object('url', 'HTTPS://WWW.TikTok.COM/@Maker.Kr/video/7301?is_from_webapp=1#c', 'author', '@maker.kr',
                         'title', '접이식 선반', 'platform', 'tiktok',
                         'thumbnail_path', '00000000-0000-4000-f015-00000000000a/00000000-0000-4000-f015-00000000020a/t1.jpg'),
      jsonb_build_object('url', 'https://xiaohongshu.com/discovery/item/64AB0123456789ABCDEF0123/', 'author', '小红薯')));
  if (r ->> 'inserted')::int <> 2 then raise exception 'FAIL: 목록 입력 %', r; end if;

  -- 거부: 호스트 위장 platform · 플랫폼 불일치 · userinfo · 다른 호스트(direct 불가) · handle 불일치 ·
  --       제어/양방향 문자 · 허용 외 키 · 과다 행 · 중복 · 다른 프로젝트 썸네일 경로 · 형식 아닌 경로
  perform pg_temp.expect_fail(pg_temp.items('[{"url":"https://evil.example/@a/video/1","author":"a","platform":"tiktok"}]'), '22023', '호스트 위장');
  perform pg_temp.expect_fail(pg_temp.items('[{"url":"https://www.tiktok.com/@a/video/9","author":"a","platform":"xiaohongshu"}]'), '22023', 'platform 불일치');
  perform pg_temp.expect_fail(pg_temp.items('[{"url":"https://www.tiktok.com@evil.example/@a/video/9","author":"a"}]'), '22023', 'userinfo');
  perform pg_temp.expect_fail(pg_temp.items('[{"url":"https://user@www.tiktok.com/@a/video/9","author":"a"}]'), '22023', 'userinfo 2');
  perform pg_temp.expect_fail(pg_temp.items('[{"url":"https://www.tiktok.com.evil.example/@a/video/9","author":"a"}]'), '22023', '접미 위장 호스트');
  perform pg_temp.expect_fail(pg_temp.items('[{"url":"https://www.tiktok.com:8443/@a/video/9","author":"a"}]'), '22023', '포트');
  perform pg_temp.expect_fail(pg_temp.items('[{"url":"https://www.tiktok.com/@a/video/9","author":"b"}]'), '22023', 'handle 불일치');
  perform pg_temp.expect_fail(pg_temp.items(jsonb_build_array(jsonb_build_object(
    'url', 'https://www.xiaohongshu.com/explore/64ab0123456789abcdef0999', 'author', 'a' || chr(7)))::text), '22023', '제어 문자');
  perform pg_temp.expect_fail(pg_temp.items(jsonb_build_array(jsonb_build_object(
    'url', 'https://www.xiaohongshu.com/explore/64ab0123456789abcdef0999', 'author', 'a',
    'title', 'abc' || chr(8238) || 'gpj.exe'))::text), '22023', '양방향 문자');
  perform pg_temp.expect_fail(pg_temp.items('[{"url":"https://www.tiktok.com/@a/video/9","author":"a","collected_at":"2020-01-01T00:00:00Z"}]'), '22023', '허용 외 키');
  perform pg_temp.expect_fail(pg_temp.items('[{"url":"https://www.tiktok.com/@a/video/9","author":"a","score":100}]'), '22023', '허용 외 키 2');
  perform pg_temp.expect_fail(pg_temp.items('[{"url":"https://www.tiktok.com/@a/video/9"}]'), '22023', '작성자 누락');
  perform pg_temp.expect_fail(pg_temp.items('[{"author":"a"}]'), '22023', 'URL 누락');
  select jsonb_agg(jsonb_build_object('url', 'https://www.tiktok.com/@a/video/' || g, 'author', 'a'))::text
    into big from generate_series(100, 160) g;
  perform pg_temp.expect_fail(pg_temp.items(big), '22023', '61행');
  perform pg_temp.expect_fail(pg_temp.items('[{"url":"https://m.tiktok.com/@DUP/video/1/","author":"dup"}]'), '23505', '기존 URL 중복');
  perform pg_temp.expect_fail(pg_temp.items('[{"url":"https://www.tiktok.com/@a/video/9","author":"a"},{"url":"https://www.tiktok.com/@A/video/9?x=1","author":"a"}]'), '23505', '같은 호출 안 중복');
  perform pg_temp.expect_fail(pg_temp.items('[{"url":"https://www.tiktok.com/@a/video/9","author":"a","thumbnail_path":"00000000-0000-4000-f015-00000000000b/00000000-0000-4000-f015-00000000020b/t.jpg"}]'), '22023', '남의 썸네일 경로');
  perform pg_temp.expect_fail(pg_temp.items('[{"url":"https://www.tiktok.com/@a/video/9","author":"a","thumbnail_path":"00000000-0000-4000-f015-00000000000a/00000000-0000-4000-f015-00000000020a/../x.jpg"}]'), '22023', '상위 경로 썸네일');
  -- 남의 확장·종류 다른 작업
  perform pg_temp.expect_fail(format('select public.extension_collect_list(%L, %L, %L::jsonb)',
    '00000000-0000-4000-f015-0000000003b1', '00000000-0000-4000-f015-0000000004a1',
    '[{"url":"https://www.tiktok.com/@a/video/9","author":"a"}]'), '42501', '남의 확장 목록 입력');
  perform pg_temp.expect_fail(format('select public.extension_collect_download(%L, %L, %L::jsonb)',
    '00000000-0000-4000-f015-0000000003a1', '00000000-0000-4000-f015-0000000004a1',
    '[{"id":"00000000-0000-4000-f015-0000000005a1","file_path":"x"}]'), '42501', 'collect 작업에 다운로드 입력');
  raise notice 'PASS 4 목록 입력: 정규화 저장, 위장 호스트·userinfo·포트·handle 불일치·제어/양방향·허용 외 키·누락·61행·중복·경로 → 거부';
end $$;
reset role;

do $$
begin
  if (select array_agg((platform, url, author, title, collected_at, thumbnail_path)::text order by url)
      from public.sources
      where project_id = '00000000-0000-4000-f015-00000000020a' and url not like '%@dup/%')
     is distinct from array[
       ('tiktok', 'https://www.tiktok.com/@maker.kr/video/7301', '@maker.kr', '접이식 선반', now(),
        '00000000-0000-4000-f015-00000000000a/00000000-0000-4000-f015-00000000020a/t1.jpg')::text,
       ('xiaohongshu', 'https://www.xiaohongshu.com/explore/64ab0123456789abcdef0123', '小红薯', null, now(), null)::text] then
    raise exception 'FAIL: 저장 값 %', (select array_agg(url) from public.sources
                                        where project_id = '00000000-0000-4000-f015-00000000020a');
  end if;
  if exists (select 1 from public.sources
             where url is null or btrim(url) = '' or author is null or btrim(author) = '' or collected_at is null) then
    raise exception 'FAIL: 3필드 누락 행 존재';
  end if;
  raise notice 'PASS 5 저장: platform 은 호스트로, collected_at 은 서버 시각, URL·작성자·수집 시각 누락 0건';
end $$;

-- ── 5) 다운로드 입력(J2, EA): 체크된 원본에만 ────────────────
set local role service_role;
do $$
declare v_j2 text := (select id::text from t_ids); n int;
  v_ok text := '00000000-0000-4000-f015-00000000000a/00000000-0000-4000-f015-00000000020a/s1.mp4';
begin
  perform pg_temp.expect_fail(format('select public.extension_collect_download(%L, %L, %L::jsonb)',
    '00000000-0000-4000-f015-0000000003a1', v_j2,
    jsonb_build_array(jsonb_build_object('id', '00000000-0000-4000-f015-0000000005a2', 'file_path', v_ok))), '22023', '미체크 원본');
  perform pg_temp.expect_fail(format('select public.extension_collect_download(%L, %L, %L::jsonb)',
    '00000000-0000-4000-f015-0000000003a1', v_j2,
    jsonb_build_array(jsonb_build_object('id', '00000000-0000-4000-f015-0000000005a1',
      'file_path', '00000000-0000-4000-f015-00000000000b/00000000-0000-4000-f015-00000000020b/s1.mp4'))), '22023', '남의 경로');
  perform pg_temp.expect_fail(format('select public.extension_collect_download(%L, %L, %L::jsonb)',
    '00000000-0000-4000-f015-0000000003a1', v_j2,
    jsonb_build_array(jsonb_build_object('id', '00000000-0000-4000-f015-0000000005a1', 'file_path', v_ok, 'url', 'x'))), '22023', '다운로드 허용 외 키');
  perform pg_temp.expect_fail(format('select public.extension_collect_download(%L, %L, %L::jsonb)',
    '00000000-0000-4000-f015-0000000003b1', v_j2,
    jsonb_build_array(jsonb_build_object('id', '00000000-0000-4000-f015-0000000005a1', 'file_path', v_ok))), '42501', '남의 확장 다운로드');
  n := public.extension_collect_download('00000000-0000-4000-f015-0000000003a1', v_j2::uuid,
    jsonb_build_array(jsonb_build_object('id', '00000000-0000-4000-f015-0000000005a1', 'file_path', v_ok)));
  if n <> 1 then raise exception 'FAIL: 다운로드 기록 %', n; end if;
  raise notice 'PASS 6 다운로드 입력: 체크된 원본·이 프로젝트 경로만, 허용 외 키·남의 확장 거부';
end $$;
reset role;

-- ── 6) 스위퍼: 끊김 → 대기(진행분 유지) · 재claim · 대기 24시간 → failed · claim 마다 15분 ──
do $$
declare r jsonb; n int; v_j2 uuid := (select id from t_ids); v_old uuid;
begin
  -- EA 하트비트 3분 끊김
  update public.extension_connections set last_heartbeat_at = now() - interval '3 minutes'
  where id = '00000000-0000-4000-f015-0000000003a1';
  update public.jobs set started_at = now() - interval '3 minutes'
  where id in ('00000000-0000-4000-f015-0000000004a1', v_j2);
  -- 생성 30시간 전이지만 대기 재진입 1시간 전인 작업은 실패시키지 않는다
  insert into public.jobs (project_id, step, type, status, idempotency_key, created_at, waiting_since)
  values ('00000000-0000-4000-f015-00000000020b', 2, 'collect', 'waiting_extension', 'ext-test-jx',
          now() - interval '30 hours', now() - interval '1 hour')
  returning id into v_old;

  r := private.sweep_jobs();
  if (select (status, extension_id, waiting_since) from public.jobs where id = '00000000-0000-4000-f015-0000000004a1')
     is distinct from ('waiting_extension'::text, null::uuid, now()) then
    raise exception 'FAIL: 끊김 → waiting_extension %', r;
  end if;
  if (select status from public.jobs where id = v_j2) <> 'waiting_extension' then
    raise exception 'FAIL: 다운로드 작업 끊김 전이';
  end if;
  if (select count(*) from public.sources where project_id = '00000000-0000-4000-f015-00000000020a') <> 4
     or (select file_path from public.sources where id = '00000000-0000-4000-f015-0000000005a1') is null then
    raise exception 'FAIL: 진행분(수집 행·파일 경로) 유실';
  end if;
  if (select status from public.jobs where id = v_old) <> 'waiting_extension' then
    raise exception 'FAIL: 대기 재진입 기준이 아니라 생성 시각 기준으로 실패 처리됨';
  end if;
  raise notice 'PASS 7 하트비트 2분 끊김 → waiting_extension(extension_id null, waiting_since 갱신, 진행분 유지)';
end $$;

set local role service_role;
do $$
declare n int;
begin
  select count(*) into n from public.extension_claim_job('00000000-0000-4000-f015-0000000003a1', '00000000-0000-4000-f015-0000000004a1');
  if n <> 1 then raise exception 'FAIL: 끊긴 뒤 재claim'; end if;
end $$;
reset role;

do $$
declare r jsonb; v_j2 uuid := (select id from t_ids);
begin
  if (select status from public.jobs where id = '00000000-0000-4000-f015-0000000004a1') <> 'running' then
    raise exception 'FAIL: 재claim → running';
  end if;
  -- 재claim 직후 스위퍼가 끊김으로 보지 않는다(claim 이 하트비트 갱신)
  r := private.sweep_jobs();
  if (select status from public.jobs where id = '00000000-0000-4000-f015-0000000004a1') <> 'running' then
    raise exception 'FAIL: 재claim 직후 끊김 처리 %', r;
  end if;
  -- 대기 진입 24시간 → failed (생성 시각은 최근이어도)
  update public.jobs set waiting_since = now() - interval '25 hours', created_at = now() where id = v_j2;
  r := private.sweep_jobs();
  if (select status || ':' || error from public.jobs where id = v_j2) <> 'failed:확장 대기 시간 초과' then
    raise exception 'FAIL: waiting_since 24시간 → failed %', r;
  end if;
  -- 15분 상한은 claim 시각(started_at)부터. 하트비트가 살아 있어도 넘으면 failed
  update public.jobs set started_at = now() - interval '16 minutes' where id = '00000000-0000-4000-f015-0000000004a1';
  r := private.sweep_jobs();
  if (select status || ':' || error from public.jobs where id = '00000000-0000-4000-f015-0000000004a1') <> 'failed:시간 초과' then
    raise exception 'FAIL: 수집 15분 상한 %', r;
  end if;
  raise notice 'PASS 8 재claim → running, waiting_since 24시간 → failed, claim 후 15분 → failed';
end $$;

-- ── 7) 실패 작업 release 1건·금액 = reserve, 대기 작업은 반환하지 않음 ──
do $$
declare v_j2 uuid := (select id from t_ids); r jsonb;
begin
  r := private.sweep_jobs();
  if (select count(*) from public.credit_ledger where job_id = v_j2 and kind = 'release') <> 1
     or (select delta from public.credit_ledger where job_id = v_j2 and kind = 'release')
        <> -(select delta from public.credit_ledger where job_id = v_j2 and kind = 'reserve') then
    raise exception 'FAIL: 실패 작업 release';
  end if;
  if exists (select 1 from public.credit_ledger l join public.jobs j on j.id = l.job_id
             where j.status = 'waiting_extension' and l.kind in ('release', 'settle')) then
    raise exception 'FAIL: 대기 작업이 반환됨';
  end if;
  raise notice 'PASS 9 실패 작업 release 1건(금액 = reserve), 반복 스위프에도 중복 없음, 대기 작업은 반환 안 함';
end $$;

-- ── 8) 끊김 뒤 다른 확장이 재claim 하면 이전 확장의 다운로드 기록은 거부 ──
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-f015-00000000000a","role":"authenticated"}', true);
create temp table t_j3 as
select (public.create_job('00000000-0000-4000-f015-00000000020a', 'collect_download', 'ext-test-download-3') ->> 'id')::uuid as id;
reset role;
grant select on t_j3 to service_role;
insert into public.extension_connections
  (id, user_id, access_token_hash, access_expires_at, refresh_token_hash, refresh_expires_at, family_id)
values ('00000000-0000-4000-f015-0000000003a3', '00000000-0000-4000-f015-00000000000a', 'ext-test-a3',
        now() + interval '15 minutes', 'ext-test-r-a3', now() + interval '30 days', gen_random_uuid());

set local role service_role;
do $$
declare n int;
begin
  select count(*) into n from public.extension_claim_job('00000000-0000-4000-f015-0000000003a1', (select id from t_j3));
  if n <> 1 then raise exception 'FAIL: J3 claim'; end if;
end $$;
reset role;
update public.extension_connections set last_heartbeat_at = now() - interval '3 minutes'
where id = '00000000-0000-4000-f015-0000000003a1';
update public.jobs set started_at = now() - interval '3 minutes' where id = (select id from t_j3);
select private.sweep_jobs();

set local role service_role;
do $$
declare n int; v_j3 text := (select id::text from t_j3);
  v_files jsonb := jsonb_build_array(jsonb_build_object('id', '00000000-0000-4000-f015-0000000005a1',
    'file_path', '00000000-0000-4000-f015-00000000000a/00000000-0000-4000-f015-00000000020a/s3.mp4'));
begin
  select count(*) into n from public.extension_claim_job('00000000-0000-4000-f015-0000000003a3', v_j3::uuid);
  if n <> 1 then raise exception 'FAIL: 다른 확장 재claim'; end if;
  perform pg_temp.expect_fail(format('select public.extension_collect_download(%L, %L, %L::jsonb)',
    '00000000-0000-4000-f015-0000000003a1', v_j3, v_files), '42501', '이전 확장의 다운로드 기록');
  if public.extension_collect_download('00000000-0000-4000-f015-0000000003a3', v_j3::uuid, v_files) <> 1 then
    raise exception 'FAIL: 새 확장 다운로드 기록';
  end if;
  raise notice 'PASS 10 끊김 뒤 다른 확장이 재claim 하면 이전 확장 기록 거부, 새 확장만 기록';
end $$;
reset role;

-- ── 9) URL 정규화: 대문자 호스트·IDN·퓨니코드·끝 점·포트·빈 포트 ──
do $$
declare r record; u text;
begin
  r := private.normalize_collect_url('https://WWW.TIKTOK.COM/@AbC/video/12/');
  if (r.url, r.platform) is distinct from ('https://www.tiktok.com/@abc/video/12', 'tiktok') then
    raise exception 'FAIL: 대문자 호스트 정규화 %', r;
  end if;
  foreach u in array array[
    'https://www.t' || chr(1110) || 'ktok.com/@a/video/1',          -- 키릴 і
    'https://www.xn--tktok-4ye.com/@a/video/1',                     -- 퓨니코드
    'https://www.tiktok.com./@a/video/1',                           -- 끝 점
    'https://www.tiktok.com:443/@a/video/1',                        -- 포트
    'https://www.tiktok.com:/@a/video/1',                           -- 빈 포트
    'https://tiktok.com.evil.example/@a/video/1',
    'https://evil-tiktok.com/@a/video/1',
    'https://www.xiaohongshu.com./explore/64ab0123456789abcdef0123',
    'https://xhslink.com/abc',
    'javascript://www.tiktok.com/@a/video/1'] loop
    begin
      perform private.normalize_collect_url(u);
      raise exception 'FAIL: 정규화가 거부하지 않음 %', u;
    exception when sqlstate '22023' then null;
    end;
  end loop;
  raise notice 'PASS 11 URL 정규화: 대문자 호스트 소문자화, IDN·퓨니코드·끝 점·포트·위장 호스트·단축 주소 거부';
end $$;

-- ── 10) private 함수 실행 권한 전수: PUBLIC·anon·authenticated·service_role ──
do $$
declare v_found text[]; v_expected text[] := array[
  -- 사용자 세션 Route Handler → public 래퍼 → private 본체(auth.uid() 검사)
  'authenticated private.add_direct_source(uuid,text,text,text)',
  'authenticated private.approve_step(uuid,integer)',
  'authenticated private.assign_bio_number(uuid,text)',
  'authenticated private.chat_consume_proposal(uuid)',
  'authenticated private.chat_start_collect(uuid,text,text,text)',
  'authenticated private.confirm_policy_check(uuid,text,boolean)',
  'authenticated private.create_job(uuid,text,text,jsonb)',
  'authenticated private.mark_step_ready(uuid,integer,text)',
  'authenticated private.prepare_publication(uuid,text,timestamp with time zone,text,text,text[],boolean,boolean)',
  'authenticated private.publish_policy(uuid,text,text,text[])',
  'authenticated private.request_step_change(uuid,integer)',
  'authenticated private.save_source_use(uuid,jsonb,boolean,text)',
  'authenticated private.set_source_checks(uuid,uuid[])',
  -- 제작 파트너 Route Handler(서버, service_role) → 제안 저장
  'service_role private.chat_create_proposal(uuid,uuid,text,jsonb)',
  -- 확장 Route Handler(서버, service_role) → public.extension_* 래퍼
  'service_role private.ext_claim_job(uuid,uuid)',
  'service_role private.ext_collect_download(uuid,uuid,jsonb)',
  'service_role private.ext_collect_list(uuid,uuid,jsonb)',
  'service_role private.ext_heartbeat(uuid)',
  -- 06 발행 업로드 직전 재판정(서버, service_role, task-024) → public.publish_recheck
  'service_role private.publish_recheck(uuid)'];
begin
  select coalesce(array_agg(x order by x), '{}') into v_found
  from (
    select r.rolname || ' ' || p.oid::regprocedure::text as x
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join (values ('anon'), ('authenticated'), ('service_role')) r(rolname)
    where n.nspname = 'private' and has_function_privilege(r.rolname, p.oid, 'execute')
    union all
    select 'PUBLIC ' || p.oid::regprocedure::text
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace,
    aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where n.nspname = 'private' and a.grantee = 0 and a.privilege_type = 'EXECUTE'
  ) t;
  if v_found is distinct from (select array_agg(e order by e) from unnest(v_expected) e) then
    raise exception 'FAIL: private 실행 권한이 목록과 다름: %', v_found;
  end if;
  raise notice 'PASS 12 private 함수 실행 권한 = 의도된 예외 목록만(PUBLIC·anon 0건)';
end $$;

rollback;
