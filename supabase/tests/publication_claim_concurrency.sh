#!/bin/sh
# task-024a 동시성 테스트: 업로드 선점(publication_claim)을 6번 동시에 불러도 같은 발행은 1건만 선점된다.
# 실행: sh supabase/tests/publication_claim_concurrency.sh
# - 세션은 커밋된 데이터만 서로 보므로 픽스처를 커밋하고, 끝나면(실패해도) 테스트 사용자를 지운다(cascade).
# - 세션 1이 선점한 채(행 잠금) 잠들어 있는 동안 나머지 5개를 동시에 보낸다 → SKIP LOCKED 로 모두 빈손.
#   세션 1 커밋 뒤 한 번 더 불러도(uploading) 빈손.
# - 선점은 전역 큐다. 다른 대기 발행이 있으면 건드리지 않도록 실행을 거부한다.
set -eu
cd "$(dirname "$0")/../.."

U=00000000-0000-4000-c241-c0000000000a
A=00000000-0000-4000-c241-c0000000010a
P=00000000-0000-4000-c241-c0000000020a
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

psql_db -c "delete from auth.users where id = '$U'" >/dev/null || true
others=$(psql_db -c "select count(*) from public.publications where status in ('pending', 'retry_wait', 'uploading')")
[ "$others" = "0" ] || fail "다른 대기·업로드 중 발행 ${others}건이 있어 실행하지 않습니다(개발 DB 데이터 보호)"

psql_db <<SQL
insert into auth.users (id, aud, role, email) values ('$U', 'authenticated', 'authenticated', 'up-conc-a@example.com');
insert into public.accounts (id, user_id, platform, channel_name, status, external_channel_id)
values ('$A', '$U', 'youtube', 'up-conc', 'connected', 'UCupconc0000000000000000');
insert into public.projects (id, user_id, account_id, name, step_status, sources_notice_ack_at, sources_notice_ack_by)
values ('$P', '$U', '$A', 'up-conc', '{"1":"approved","2":"approved","3":"ready","4":"idle","5":"idle","6":"idle"}', now(), '$U');
insert into public.scripts (project_id, version, lines, approved_at) values ('$P', 1, '["좁은 틈에도 쏙 들어가요."]', now());
insert into public.renders (project_id, version, mp4_path, duration_sec, cut_map)
values ('$P', 1, '$U/$P/v1.mp4', 15, jsonb_build_object('cuts', jsonb_build_array(jsonb_build_object(
  'no', 1, 'source_id', '00000000-0000-4000-c241-c00000000301', 'author', 'maker_a', 'platform', 'tiktok',
  'source_url', 'https://www.tiktok.com/@maker_a/video/1', 'collected_at', '2026-11-12T01:00:00Z'))));
update public.projects set step_status = '{"1":"approved","2":"approved","3":"approved","4":"approved","5":"approved","6":"idle"}'
where id = '$P';
insert into public.policy_checks (project_id, item, result, checked_by, checked_at)
values ('$P', 'attribution_notice', 'pass', '$U', now());
insert into public.publications (project_id, account_id, mode, title, body, description, hashtags, prepared_at, status)
values ('$P', '$A', 'now', '압축팩 정리 꿀팁', '본문', '본문 설명', array['수납'], now(), 'pending');
SQL

# 세션 1: 선점하고 잠금을 쥔 채 4초 대기 후 커밋
printf 'set role service_role;\nbegin;\nselect (public.publication_claim() ->> %s);\nselect pg_sleep(4.03);\ncommit;\n' \
  "'claimed'" | psql_db > "$TMP/s1" 2>&1 &
i=0
until [ "$(psql_db -c "select count(*) from pg_stat_activity where query like '%pg_sleep(4.03)%' and pid <> pg_backend_pid()")" = "1" ]; do
  i=$((i + 1)); [ $i -gt 60 ] && fail "세션 1 대기 시간 초과"
  sleep 0.5
done

# 세션 2~6: 동시에
for n in 2 3 4 5 6; do
  printf 'set role service_role;\nselect (public.publication_claim() ->> %s);\n' "'claimed'" | psql_db > "$TMP/s$n" 2>&1 &
done
wait
printf 'set role service_role;\nselect (public.publication_claim() ->> %s);\n' "'claimed'" | psql_db > "$TMP/s7" 2>&1

claimed=$(cat "$TMP"/s* | grep -c "^true$" || true)
idle=$(cat "$TMP"/s* | grep -c "^false$" || true)
status=$(psql_db -c "select status || ':' || (attempt_token is not null) from public.publications where project_id = '$P'")
[ "$claimed" = "1" ] || { cat "$TMP"/s*; fail "선점 ${claimed}건(1건이어야 함)"; }
[ "$idle" = "6" ] || { cat "$TMP"/s*; fail "빈손 ${idle}건(6건이어야 함)"; }
[ "$status" = "uploading:true" ] || fail "발행 상태 $status"
echo "PASS C1 동시 선점 7회(잠금 중 5 + 커밋 뒤 1) → 선점 1건만, 나머지 6건 빈손"
