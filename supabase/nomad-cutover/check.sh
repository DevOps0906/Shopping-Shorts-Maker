#!/usr/bin/env bash
# 이관 스크립트 검증 (일회용 DB). 사용: bash supabase/nomad-cutover/check.sh
# 컨테이너 $CUTOVER_CONTAINER(기본 supabase_db_nomad-supabase-module) 안에 cutover_shorts DB를 새로 만들고 끝나면 지운다.
# 운영 DB에는 접속하지 않는다. 합성 데이터만 쓴다.
#
# 일회용 DB 제약: pg_cron 은 클러스터당 한 DB(postgres)에만 만들 수 있어서, 이 DB에는 같은 이름의 최소 대역
# (cron.job · cron.schedule · cron.unschedule)을 두고 마이그레이션의 `create extension ... pg_cron` 줄만 빼고 적용한다.
# auth·storage 스키마는 같은 컨테이너 postgres DB의 구조를 복사한다(nomad 트리거 2개 제외).
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; R="$(cd "$D/../.." && pwd)"
C="${CUTOVER_CONTAINER:-supabase_db_nomad-supabase-module}"; DB=cutover_shorts
LOG="$(mktemp -d)"; trap 'rm -rf "$LOG"' EXIT
exec < /dev/null  # docker exec -i 가 터미널 stdin 을 기다리지 않게

adm() { docker exec -i -e PGOPTIONS=-cclient_min_messages=warning "$C" psql -U supabase_admin -d "$1" -v ON_ERROR_STOP=1 -q -X "${@:2}"; }
sqlf() { docker exec -i -e PGOPTIONS=-cclient_min_messages=warning "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q -X "$@"; }
val() { docker exec -i "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -X -At "$@"; }
ok() { echo "  ok  $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }
# 실패가 기대되는 실행: 출력에 $1 문구가 있어야 한다.
expect_fail() {
  local want="$1"; shift
  if "$@" > "$LOG/out" 2>&1; then cat "$LOG/out" >&2; die "실패해야 하는데 성공: $want"; fi
  grep -q -- "$want" "$LOG/out" || { cat "$LOG/out" >&2; die "다른 이유로 실패(기대: $want)"; }
}
mig() { sed -E 's/^[[:space:]]*create extension if not exists pg_cron[^;]*;/-- (check.sh) pg_cron 대역 사용/I' "$1"; }

# ── 0. 일회용 DB ──────────────────────────────────────────
ROLES_BEFORE="$(adm postgres -At -c "select string_agg(rolname, ',' order by rolname) from pg_roles where rolname in ('worker_role','worker_login')")"
cleanup_db() {
  adm postgres -c "drop database if exists $DB with (force)" || true
  # 이 검사가 만든 역할만 지운다(원래 있던 역할은 남긴다).
  for r in worker_login worker_role; do
    case ",$ROLES_BEFORE," in *",$r,"*) ;; *) adm postgres -c "drop role if exists $r" || true ;; esac
  done
}
[ "${KEEP_DB:-0}" = 1 ] || trap 'cleanup_db; rm -rf "$LOG"' EXIT
adm postgres -c "drop database if exists $DB with (force)"
adm postgres -c "create database $DB owner postgres"

docker exec "$C" pg_dump -U supabase_admin -d postgres --schema-only -n auth -n storage -n extensions \
  | grep -v '^CREATE TRIGGER nomad_' | adm "$DB" > /dev/null
adm "$DB" <<'SQL'
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists supabase_vault cascade;
create publication supabase_realtime;
-- pg_cron 대역(이름·시그니처만 같게)
create schema cron;
grant usage on schema cron to postgres;
create table cron.job (
  jobid bigserial primary key, jobname text unique, schedule text not null, command text not null,
  active boolean not null default true, username text not null default current_user, database text not null default current_database()
);
create function cron.schedule(job_name text, schedule text, command text) returns bigint language sql as $$
  insert into cron.job (jobname, schedule, command) values (job_name, schedule, command)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command
  returning jobid $$;
create function cron.unschedule(job_name text) returns boolean language plpgsql as $$
begin
  delete from cron.job where jobname = job_name;
  if not found then raise exception 'could not find valid entry for job ''%''', job_name; end if;
  return true;
end $$;
grant all on all tables in schema cron to postgres;
grant all on all sequences in schema cron to postgres;
SQL
ok "일회용 DB $DB"

# ── 1. 옛 스키마(legacy-migrations 59개) ───────────────────
for f in "$R"/supabase/legacy-migrations/*.sql; do
  mig "$f" | sqlf > /dev/null || die "legacy 적용 실패: $(basename "$f")"
done
ok "legacy-migrations $(ls "$R"/supabase/legacy-migrations/*.sql | wc -l)개"

# ── 2. 합성 데이터 ─────────────────────────────────────────
adm "$DB" < "$D/check_seed.sql" > /dev/null
ok "합성 데이터(사용자 2·익명 0)"

# 옛 권한·cron·가입 트리거 함수 상태(01 → undo 뒤 같아야 한다)
SNAP_SQL="
select 'T '||c.oid::regclass||' '||array(select x::text from unnest(coalesce(c.relacl, acldefault('r', c.relowner))) x order by 1)::text
  from pg_class c where c.relnamespace in ('public'::regnamespace,'private'::regnamespace) and c.relkind in ('r','p') and c.relname not like 'nomad\_%'
union all
select 'C '||a.attrelid::regclass||'.'||a.attname||' '||array(select x::text from unnest(a.attacl) x order by 1)::text
  from pg_attribute a join pg_class c on c.oid = a.attrelid
  where c.relnamespace in ('public'::regnamespace,'private'::regnamespace) and c.relkind in ('r','p') and coalesce(cardinality(a.attacl),0) > 0
union all
select 'F '||p.oid::regprocedure||' '||array(select x::text from unnest(coalesce(p.proacl, acldefault('f', p.proowner))) x order by 1)::text
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname not like 'nomad\_%'
union all
select 'J '||jobname||' '||schedule||' '||command||' '||active from cron.job where jobname in ('sweep-jobs','collect-metrics','cleanup-analytics')
union all
select 'H '||md5(pg_get_functiondef('private.handle_new_user()'::regprocedure))
order by 1"
echo "$SNAP_SQL" | val > "$LOG/snap_before"
[ "$(grep -c '^J ' "$LOG/snap_before")" = 3 ] || die "옛 cron 3개가 없음"

# ── 3. 01 freeze ──────────────────────────────────────────
sqlf < "$D/01_freeze.sql" > /dev/null
expect_fail "permission denied" sqlf -c "set role authenticated; select set_config('request.jwt.claims', '{\"sub\":\"a0000000-0000-4000-8000-000000000001\",\"role\":\"authenticated\"}', false); update public.topics set picked = false;"
expect_fail "permission denied" sqlf -c "set role authenticated; select public.approve_step('ab000000-0000-4000-8000-000000000001', 1);"
expect_fail "permission denied" sqlf -c "set role service_role; insert into public.youtube_upload_quota (day) values ('2026-01-01');"
[ "$(val -c "select count(*) from cron.job where jobname in ('sweep-jobs','collect-metrics','cleanup-analytics')")" = 0 ] || die "옛 cron 이 남음"
adm "$DB" -c "insert into auth.users (id, aud, role, email, is_anonymous) values ('d0000000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'during@example.test', false)"
[ "$(val -c "select count(*) from public.user_profiles where user_id = 'd0000000-0000-4000-8000-000000000004'")" = 0 ] || die "freeze 중 옛 가입 트리거가 동작함"
adm "$DB" -c "delete from auth.users where id = 'd0000000-0000-4000-8000-000000000004'"
expect_fail "이미 freeze" sqlf < "$D/01_freeze.sql"
ok "01 freeze: 표 쓰기·RPC 거부, 옛 cron 정지, 옛 가입 트리거 무력화, 재실행 거부"

# 큐 비움 확인(사용자 결정 3)
sqlf < "$D/01_queue_check.sql" > /dev/null
adm "$DB" -c "select pgmq.send('render', '{\"job_id\":\"synthetic\"}')" > /dev/null
expect_fail "옛 큐가 비어 있지 않습니다" sqlf < "$D/01_queue_check.sql"
ok "01_queue_check: 빈 큐 통과 · 메시지 있으면 중단"

# ── 4. 새 migrations(db push 와 같은 순서) ──────────────────
for f in "$R"/supabase/migrations/*.sql; do
  mig "$f" | sqlf > /dev/null || die "migrations 적용 실패: $(basename "$f")"
done
ok "migrations $(ls "$R"/supabase/migrations/*.sql | wc -l)개(개인 조직 백필 포함)"

# ── 5. 02 시작 검사: 남은 큐 메시지 · 익명 소유 · 개인 조직 없는 사용자 → 중단 ──
adm "$DB" <<'SQL' > /dev/null
begin;
insert into auth.users (id, aud, role, is_anonymous) values ('e0000000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', true);
set local session_replication_role = replica;  -- 가입 트리거 없이 만든 사용자 = 개인 조직 없음
insert into auth.users (id, aud, role, email, is_anonymous) values ('f0000000-0000-4000-8000-000000000006', 'authenticated', 'authenticated', 'noorg@example.test', false);
insert into public.accounts (id, user_id, platform, channel_name) values
  ('ee000000-0000-4000-8000-000000000005', 'e0000000-0000-4000-8000-000000000005', 'tiktok', '익명 채널'),
  ('ff000000-0000-4000-8000-000000000006', 'f0000000-0000-4000-8000-000000000006', 'tiktok', '조직 없음');
insert into public.projects (id, user_id, account_id, name) values
  ('ef000000-0000-4000-8000-000000000005', 'e0000000-0000-4000-8000-000000000005', 'ee000000-0000-4000-8000-000000000005', '익명 프로젝트');
commit;
SQL
expect_fail "익명 사용자 소유 행: public.projects 1건" sqlf < "$D/02_copy.sql"
grep -q "익명 사용자 소유 행: public.accounts 1건" "$LOG/out" || die "익명 accounts 건수 보고 없음"
grep -q "개인 조직 없는 사용자 소유 행: public.accounts 1건" "$LOG/out" || die "개인 조직 없음 보고 없음"
grep -q "옛 pgmq 큐 render 에 메시지 1건" "$LOG/out" || die "큐 메시지 중단 보고 없음"
adm "$DB" > /dev/null <<'SQL'
select pgmq.purge_queue('render');
set session_replication_role = replica;
delete from public.projects where id = 'ef000000-0000-4000-8000-000000000005';
delete from public.accounts where id in ('ee000000-0000-4000-8000-000000000005', 'ff000000-0000-4000-8000-000000000006');
delete from auth.users where id in ('e0000000-0000-4000-8000-000000000005', 'f0000000-0000-4000-8000-000000000006');
SQL
[ "$(val -c "select count(*) from nomad_shorts.projects")" = 0 ] || die "중단됐는데 복사됨"
ok "02 중단: 익명 소유(건수 보고) · 개인 조직 없음 · 큐 메시지"

# ── 6. 02 dry-run: 검사는 통과하고 아무것도 남기지 않는다 ─────
PROF_SQL="select string_agg(user_id||':'||coalesce(display_name,'-'), ',' order by user_id) from nomad_core.profiles"
P0="$(val -c "$PROF_SQL")"
sqlf < "$D/02_copy.sql" > "$LOG/dry" 2>&1 || { cat "$LOG/dry" >&2; die "02 dry-run 실패"; }
grep -q "dry-run" "$LOG/dry" || die "dry-run 표시 없음"
N="$(val -c "select (select count(*) from nomad_shorts.projects) + (select count(*) from nomad_shorts.user_settings) + (select count(*) from nomad_shorts_private.rate_counters)")"
[ "$N" = 0 ] || die "dry-run 뒤 대상 표에 행이 남음($N)"
[ "$(val -c "$PROF_SQL")" = "$P0" ] || die "dry-run 뒤 profiles 가 바뀜"
ok "02 dry-run: 검사 통과, 변경 없음"

# ── 7. 02 apply ───────────────────────────────────────────
sqlf -v apply=true < "$D/02_copy.sql" > "$LOG/apply" 2>&1 || { cat "$LOG/apply" >&2; die "02 apply 실패"; }
grep -q "APPLY" "$LOG/apply" || die "apply 표시 없음"

A=a0000000-0000-4000-8000-000000000001; B=b0000000-0000-4000-8000-000000000002
OA="$(val -c "select id from nomad_core.organizations where kind='personal' and created_by='$A'")"
OB="$(val -c "select id from nomad_core.organizations where kind='personal' and created_by='$B'")"
[ -n "$OA" ] && [ -n "$OB" ] || die "개인 조직 없음"
chk() { local got; got="$(val -c "$2")"; [ "$got" = "$3" ] || die "$1: 기대 [$3] 실제 [$got]"; }
chk "행 수(projects)" "select count(*) from nomad_shorts.projects" 3
chk "소유 조직(A)" "select count(*) from nomad_shorts.projects where organization_id = '$OA'" 2
chk "트리거 끔(단계·상태·updated_at 원본)" "select current_step||' '||status||' '||(updated_at at time zone 'Asia/Seoul') from nomad_shorts.projects where id='ab000000-0000-4000-8000-000000000001'" "6 uploaded 2026-10-12 11:22:33"
chk "accounts 서버 열 원본" "select status||' '||last_bio_no from nomad_shorts.accounts where id='aa000000-0000-4000-8000-000000000001'" "connected 2"
chk "경로 org 로" "select file_path from nomad_shorts.sources where file_path like '%src-1.mp4'" "$OA/ab000000-0000-4000-8000-000000000001/src-1.mp4"
chk "경로(render)" "select count(*) from nomad_shorts.renders where mp4_path like '$OA/%'" 2
chk "소프트 삭제 유지" "select count(*) from nomad_shorts.sources where file_deleted_at is not null" 1
chk "멱등 키" "select string_agg(idempotency_key, ',' order by idempotency_key) from nomad_shorts.jobs" "$A:dl-1,$A:render-1,$B:tts-1"
chk "공유 링크" "select short_url from nomad_shorts.affiliate_links where id='a3000000-0000-4000-8000-000000000001'" "https://s.example.test/aA1"
chk "크레딧 잔액(A 조직)" "select sum(delta) from nomad_shorts.credit_ledger where organization_id='$OA'" 70
chk "profiles 이름 덮음(A)" "select display_name from nomad_core.profiles where user_id='$A'" "합성 앨리스"
chk "profiles 이름 없으면 백필 유지(B)" "select display_name from nomad_core.profiles where user_id='$B'" "bob"
chk "user_settings" "select default_tone||' '||default_lang||' '||default_len||' '||notify_weekly from nomad_shorts.user_settings where user_id='$A'" "calm ko 20 true"
chk "시퀀스 이어짐" "select nextval('nomad_shorts_private.metrics_runs_id_seq')" 8
chk "구독 행 없음(옛 플랜 없음)" "select count(*) from nomad_core.subscriptions where product_code='shorts'" 0
ok "02 apply: 행 수·소유 조직·원본 값·경로·이름·설정·시퀀스"

# RLS 격리: 다른 사용자(조직) 행은 보이지 않는다
rls() { val -q -c "begin; set local role authenticated; select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\"}', true); $2; commit;" | tail -n 1; }
[ "$(rls "$A" "select string_agg(name, ',' order by name) from nomad_shorts.projects")" = "A 도마 쇼츠,A 두번째" ] || die "RLS: A 프로젝트"
[ "$(rls "$B" "select string_agg(name, ',' order by name) from nomad_shorts.projects")" = "B 틴트" ] || die "RLS: B 프로젝트"
[ "$(rls "$B" "select count(*) from nomad_shorts.sources")" = 1 ] || die "RLS: B sources"
[ "$(rls "$B" "select count(*) from nomad_shorts.user_settings")" = 1 ] || die "RLS: B user_settings"
[ "$(rls "$A" "select count(*) from nomad_shorts.credit_ledger where organization_id = '$OB'")" = 0 ] || die "RLS: A 가 B 원장 봄"
ok "RLS 격리(A·B 서로 못 봄)"

# 03 의 경로 규칙 = 02 가 바꾼 DB 경로(절차서의 대응표 \copy 와 같은 질의)
val -F , -c "select o.created_by, o.id from nomad_core.organizations o join nomad_core.memberships m on m.organization_id = o.id and m.user_id = o.created_by and m.role = 'owner' where o.kind = 'personal' order by 1" > "$LOG/user_org.csv"
val -F , -c "select s.file_path, n.file_path from public.sources s join nomad_shorts.sources n using (id) where s.file_path is not null
  union all select s.thumbnail_path, n.thumbnail_path from public.sources s join nomad_shorts.sources n using (id) where s.thumbnail_path is not null
  union all select s.audio_path, n.audio_path from public.voice_takes s join nomad_shorts.voice_takes n using (id) where s.audio_path is not null
  union all select s.mp4_path, n.mp4_path from public.renders s join nomad_shorts.renders n using (id) where s.mp4_path is not null" > "$LOG/paths.csv"
CUT_MOD="$D/03_storage.mjs" node --input-type=module -e "
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { parseMap, newPath } = await import(pathToFileURL(process.env.CUT_MOD).href);
const map = parseMap(readFileSync(process.argv[1], 'utf8'));
const rows = readFileSync(process.argv[2], 'utf8').trim().split(/\r?\n/);
const bad = rows.filter((l) => { const [o, n] = l.split(','); return newPath(o, map) !== n; });
if (rows.length !== 8 || bad.length) { console.error('경로 불일치', rows.length, bad); process.exit(1); }
" "$LOG/user_org.csv" "$LOG/paths.csv" || die "03 경로 규칙과 02 DB 경로가 다름"
ok "03 경로 규칙 = 02 DB 경로(8개)"

# ── 8. 재실행 거부 ─────────────────────────────────────────
expect_fail "대상 표가 비어 있지 않음" sqlf -v apply=true < "$D/02_copy.sql"
ok "02 재실행 거부"

# ── 9. 01 undo: 권한·cron·가입 트리거 함수가 freeze 전과 같다 ──
sqlf < "$D/01_freeze_undo.sql" > /dev/null
echo "$SNAP_SQL" | val > "$LOG/snap_after"
diff "$LOG/snap_before" "$LOG/snap_after" > "$LOG/snap_diff" || { cat "$LOG/snap_diff" >&2; die "undo 뒤 상태가 freeze 전과 다름"; }
[ -z "$(val -c "select to_regnamespace('nomad_cutover')")" ] || die "nomad_cutover 스키마가 남음"
ok "01 undo: 표·열·RPC 권한, cron 3개, 가입 트리거 함수가 freeze 전과 같음($(wc -l < "$LOG/snap_before")항목)"

# ── 10. 03 스토리지(단위 검증 + dry-run) ─────────────────────
node --test "$D/03_storage.test.mjs" > "$LOG/node" 2>&1 || { cat "$LOG/node" >&2; die "03_storage 단위 검증 실패"; }
ok "03_storage 단위 검증"

echo "check.sh: PASS"
