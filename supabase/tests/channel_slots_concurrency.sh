#!/bin/sh
# task-034a 동시성 테스트: 한도 1 사용자의 서로 다른 계정 2개가 동시에 연결을 저장해도 1개만 성공(사용자 단위 advisory lock).
# 실행: sh supabase/tests/channel_slots_concurrency.sh
# - 세션은 커밋된 데이터만 서로 보므로 픽스처를 커밋하고, 끝나면(실패해도) 테스트 사용자를 지운다(cascade, Vault 는 삭제 트리거).
# - 세션 1이 저장 뒤 커밋하지 않고 잠든 동안 세션 2가 다른 계정을 저장 → 잠금에서 기다린 뒤 CS001.
set -eu
cd "$(dirname "$0")/../.."

U=00000000-0000-4000-f034-c0000000000a
A1=00000000-0000-4000-f034-c0000000010a
A2=00000000-0000-4000-f034-c0000000020a
SCOPES="array['https://www.googleapis.com/auth/youtube.upload','https://www.googleapis.com/auth/youtube.readonly','https://www.googleapis.com/auth/yt-analytics.readonly']"
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
insert into auth.users (id, aud, role, email) values ('$U', 'authenticated', 'authenticated', 'slot-test-conc@example.com');
insert into public.accounts (id, user_id, platform, channel_name) values
  ('$A1', '$U', 'youtube', 'slot-conc-1'),
  ('$A2', '$U', 'youtube', 'slot-conc-2');
SQL

psql_db -c "set role service_role" -c "begin" \
  -c "select public.youtube_save_connection('$U', '$A1', 'UC-CONC-1', 'rt-conc-1', $SCOPES)" \
  -c "select pg_sleep(3.034)" -c "commit" > "$TMP/s1" &
wait_for 3.034
psql_db -c "set role service_role" \
  -c "select public.youtube_save_connection('$U', '$A2', 'UC-CONC-2', 'rt-conc-2', $SCOPES)" > "$TMP/s2"
wait
[ "$(sed -n 1p "$TMP/s1")" = "connected" ] || fail "세션 1 결과 $(sed -n 1p "$TMP/s1")"
[ "$(sed -n 1p "$TMP/s2")" = "CS001" ] || fail "세션 2 결과 $(sed -n 1p "$TMP/s2") (기대 CS001)"
r=$(psql_db -c "select count(*) filter (where status = 'connected') || ' ' || count(*) filter (where external_channel_id is not null) from public.accounts where user_id = '$U'")
[ "$r" = "1 1" ] || fail "연결 행 $r (기대 1 1)"
r=$(psql_db -c "select string_agg(kind, ',' order by created_at) from public.channel_slot_events where user_id = '$U'")
[ "$r" = "connect,reject_limit" ] || fail "이벤트 $r"
echo "PASS S1 한도 1 사용자의 동시 연결 2건 → 1건만 성공(두 번째는 잠금 대기 후 CS001)"
