#!/bin/sh
# task-015a 동시성 테스트(두 psql 세션). 실행: sh supabase/tests/extension_collect_concurrency.sh
# - 세션은 커밋된 데이터만 서로 보므로 픽스처를 커밋하고, 끝나면(실패해도) 테스트 사용자를 지운다(cascade).
# 1) 같은 작업을 두 확장이 동시에 claim → 1건만 성공(두 번째는 첫 번째 커밋까지 기다린 뒤 0행)
# 2) 다운로드 입력이 확장 행을 잡고 있는 동안 폐기 UPDATE 는 커밋까지 기다린다(폐기와 직렬화)
set -eu
cd "$(dirname "$0")/../.."

U=00000000-0000-4000-f015-c0000000000a
P=00000000-0000-4000-f015-c0000000020a
E1=00000000-0000-4000-f015-c000000003a1
E2=00000000-0000-4000-f015-c000000003a2
J=00000000-0000-4000-f015-c000000004a1
S=00000000-0000-4000-f015-c000000005a1
TMP=$(mktemp -d)

psql_db() {
  docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qtAX "$@"
}
cleanup() {
  psql_db -c "delete from auth.users where id = '$U'" >/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
wait_for() {  # 다른 세션이 pg_sleep 에 들어갈 때까지
  i=0
  until [ "$(psql_db -c "select count(*) from pg_stat_activity where query like '%pg_sleep($1)%' and pid <> pg_backend_pid()")" = "1" ]; do
    i=$((i + 1)); [ $i -gt 60 ] && fail "세션 1 대기 시간 초과"
    sleep 0.5
  done
}

# 이전 실행이 남긴 테스트 사용자만 지운다(TMP는 남겨 둔다)
psql_db -c "delete from auth.users where id = '$U'" >/dev/null || true
psql_db <<SQL
insert into auth.users (id, aud, role, email) values ('$U', 'authenticated', 'authenticated', 'ext-conc-a@example.com');
insert into public.accounts (id, user_id, platform, channel_name)
values ('00000000-0000-4000-f015-c0000000010a', '$U', 'youtube', 'ext-conc');
insert into public.projects (id, user_id, account_id, name, step_status)
values ('$P', '$U', '00000000-0000-4000-f015-c0000000010a', 'ext-conc',
        '{"1":"approved","2":"idle","3":"idle","4":"idle","5":"idle","6":"idle"}');
insert into public.extension_connections
  (id, user_id, access_token_hash, access_expires_at, refresh_token_hash, refresh_expires_at, family_id)
values ('$E1', '$U', 'ext-conc-1', now() + interval '15 minutes', 'ext-conc-r1', now() + interval '30 days', gen_random_uuid()),
       ('$E2', '$U', 'ext-conc-2', now() + interval '15 minutes', 'ext-conc-r2', now() + interval '30 days', gen_random_uuid());
insert into public.jobs (id, project_id, step, type, status, idempotency_key)
values ('$J', '$P', 2, 'collect_download', 'waiting_extension', 'ext-conc-j');
insert into public.sources (id, project_id, platform, url, author, checked)
values ('$S', '$P', 'tiktok', 'https://www.tiktok.com/@c/video/1', 'c', true);
SQL

# ── 1) 동시 claim ──
psql_db -c "set role service_role" -c "begin" \
  -c "select count(*) from public.extension_claim_job('$E1', '$J')" \
  -c "select pg_sleep(4.01)" -c "select clock_timestamp()" -c "commit" > "$TMP/s1" &
wait_for 4.01
r2=$(psql_db -c "set role service_role" \
  -c "select count(*) || ' ' || clock_timestamp() from public.extension_claim_job('$E2', '$J')")
wait
r1=$(sed -n 1p "$TMP/s1"); t1=$(grep -E '^[0-9]{4}-' "$TMP/s1" | head -1)
[ "$r1" = "1" ] || fail "세션 1 claim $r1"
[ "${r2%% *}" = "0" ] || fail "세션 2 claim 이 성공함: $r2"
[ "$(psql_db -c "select '${r2#* }'::timestamptz >= '$t1'::timestamptz")" = "t" ] || fail "세션 2가 세션 1 커밋을 기다리지 않음"
[ "$(psql_db -c "select extension_id from public.jobs where id = '$J'")" = "$E1" ] || fail "claim 확장"
echo "PASS C1 동시 claim 1건만 성공(두 번째는 첫 커밋까지 대기 후 0행)"

# ── 2) 다운로드 입력 중 폐기 ──
psql_db -c "set role service_role" -c "begin" \
  -c "select public.extension_collect_download('$E1', '$J', '[{\"id\":\"$S\",\"file_path\":\"$U/$P/c1.mp4\"}]'::jsonb)" \
  -c "select pg_sleep(4.02)" -c "select clock_timestamp()" -c "commit" > "$TMP/s2" &
wait_for 4.02
t2=$(psql_db -c "update public.extension_connections set revoked_at = now() where id = '$E1' returning clock_timestamp()")
wait
d1=$(sed -n 1p "$TMP/s2"); td=$(grep -E '^[0-9]{4}-' "$TMP/s2" | head -1)
[ "$d1" = "1" ] || fail "다운로드 기록 $d1"
[ "$(psql_db -c "select '$t2'::timestamptz >= '$td'::timestamptz")" = "t" ] || fail "폐기가 다운로드 커밋을 기다리지 않음"
# 폐기 뒤에는 같은 확장의 기록 거부
if psql_db -c "set role service_role" \
     -c "select public.extension_collect_download('$E1', '$J', '[{\"id\":\"$S\",\"file_path\":\"$U/$P/c2.mp4\"}]'::jsonb)" \
     >/dev/null 2>&1; then
  fail "폐기된 확장의 기록이 허용됨"
fi
echo "PASS C2 다운로드 입력 중 폐기는 커밋까지 대기, 폐기 뒤 기록 거부"
