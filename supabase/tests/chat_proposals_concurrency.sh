#!/bin/sh
# task-021 동시성 테스트: 병렬 확인으로 소스 검색(chat_start_collect)을 6번 동시에 불러도 collect 작업은 3건(회차 상한)만.
# 실행: sh supabase/tests/chat_proposals_concurrency.sh
# - 세션은 커밋된 데이터만 서로 보므로 픽스처를 커밋하고, 끝나면(실패해도) 테스트 사용자를 지운다(cascade).
# - 세션 1이 프로젝트 행 잠금을 쥔 채 잠들어 있는 동안 나머지 5개를 동시에 보낸다 → 모두 잠금에서 기다린 뒤 차례로 검사.
set -eu
cd "$(dirname "$0")/../.."

U=00000000-0000-4000-c221-c0000000000a
A=00000000-0000-4000-c221-c0000000010a
P=00000000-0000-4000-c221-c0000000020a
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
as_user() {
  echo "set role authenticated; select set_config('request.jwt.claims', '{\"sub\":\"$U\",\"role\":\"authenticated\"}', false);"
}

psql_db -c "delete from auth.users where id = '$U'" >/dev/null || true
psql_db <<SQL
insert into auth.users (id, aud, role, email) values ('$U', 'authenticated', 'authenticated', 'chat-conc-a@example.com');
insert into public.accounts (id, user_id, platform, channel_name) values ('$A', '$U', 'youtube', 'chat-conc');
insert into public.projects (id, user_id, account_id, name, step_status)
values ('$P', '$U', '$A', 'chat-conc', '{"1":"approved","2":"idle","3":"idle","4":"idle","5":"idle","6":"idle"}');
SQL

# 세션 1: 잠금을 쥐고 4초 대기 후 커밋
printf '%s\nbegin;\nselect (public.chat_start_collect(%s, %s, %s, %s) ->> %s);\nselect pg_sleep(4.02);\ncommit;\n' \
  "$(as_user)" "'$P'" "'tiktok'" "'q'" "'chat-conc-key-1'" "'created'" | psql_db > "$TMP/s1" 2>&1 &
i=0
until [ "$(psql_db -c "select count(*) from pg_stat_activity where query like '%pg_sleep(4.02)%' and pid <> pg_backend_pid()")" = "1" ]; do
  i=$((i + 1)); [ $i -gt 60 ] && fail "세션 1 대기 시간 초과"
  sleep 0.5
done

# 세션 2~6: 동시에
for n in 2 3 4 5 6; do
  printf '%s\nselect (public.chat_start_collect(%s, %s, %s, %s) ->> %s);\n' \
    "$(as_user)" "'$P'" "'xiaohongshu'" "'q'" "'chat-conc-key-$n'" "'created'" | psql_db > "$TMP/s$n" 2>&1 &
done
wait

jobs=$(psql_db -c "select count(*) from public.jobs where project_id = '$P' and type = 'collect'")
denied=$(cat "$TMP"/s* | grep -c "CR003\|탐색 회차를 모두 썼습니다" || true)
[ "$jobs" = "3" ] || fail "collect 작업 ${jobs}건(3건이어야 함)"
[ "$denied" = "3" ] || fail "회차 초과 거부 ${denied}건(3건이어야 함)"
echo "PASS C1 병렬 6회 요청 → collect 작업 3건 · 회차 초과 거부 3건(3회 초과 작업 0)"
