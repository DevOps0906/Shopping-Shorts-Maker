#!/bin/sh
# task-025 동시성 테스트: 같은 코드·같은 IP 클릭 2건이 동시에 들어와도 counted = true 는 1건(advisory lock).
# 실행: sh supabase/tests/analytics_click_concurrency.sh
# - 세션은 커밋된 데이터만 서로 보므로 픽스처를 커밋하고, 끝나면(실패해도) 테스트 사용자를 지운다(cascade).
# - 세션 1이 기록 뒤 커밋하지 않고 잠든 동안 세션 2가 같은 클릭을 보낸다 → 잠금에서 기다린 뒤 counted = false.
set -eu
cd "$(dirname "$0")/../.."

U=00000000-0000-4000-f025-c0000000000a
A=00000000-0000-4000-f025-c0000000010a
P=00000000-0000-4000-f025-c0000000020a
L=00000000-0000-4000-f025-c0000000030a
CODE=Cc7Rk2Te
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

psql_db -c "delete from auth.users where id = '$U'" >/dev/null || true
psql_db <<SQL
insert into auth.users (id, aud, role, email) values ('$U', 'authenticated', 'authenticated', 'rls-test-click-conc@example.com');
insert into public.accounts (id, user_id, platform, channel_name) values ('$A', '$U', 'youtube', 'click-conc');
insert into public.projects (id, user_id, account_id, name) values ('$P', '$U', '$A', 'click-conc');
insert into public.affiliate_links (id, project_id, program, url, short_url)
values ('$L', '$P', 'coupang_partners', 'https://link.coupang.com/a/conc', '$CODE');
SQL

psql_db -c "set role service_role" -c "begin" \
  -c "select count(*) from public.record_link_click('$CODE', '192.0.2.77', null, 'youtube')" \
  -c "select pg_sleep(3.03)" -c "commit" > "$TMP/s1" &
wait_for 3.03
psql_db -c "set role service_role" -c "select count(*) from public.record_link_click('$CODE', '192.0.2.77', null, 'youtube')" > "$TMP/s2"
wait
[ "$(sed -n 1p "$TMP/s1")" = "1" ] || fail "세션 1 반환 행"
[ "$(sed -n 1p "$TMP/s2")" = "1" ] || fail "세션 2 반환 행"
r=$(psql_db -c "select count(*) || ' ' || count(*) filter (where counted) from public.link_clicks where affiliate_link_id = '$L'")
[ "$r" = "2 1" ] || fail "기록/집계 $r (기대 2 1)"
echo "PASS K1 동시 클릭 2건 → 기록 2, counted 1(두 번째는 잠금 대기 후 중복 판정)"
