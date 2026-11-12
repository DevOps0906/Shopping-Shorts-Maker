#!/bin/sh
# task-024a 동시성 테스트: 전역 일일 업로드 카운터(youtube_upload_quota, 하루 100회)는 동시 session_begin 에도 100을 넘지 않는다.
# 실행: sh supabase/tests/upload_quota_concurrency.sh
# - 오늘(태평양 날짜) 카운터를 98로 두고, 선점한 발행 5건의 session_begin 을 동시에 보낸다 → 통과 2건·쿼터 대기 3건·카운터 100.
# - 세션 1이 카운터 행 잠금을 쥔 채 잠든 동안 나머지 4개를 보낸다. 끝나면(실패해도) 카운터 원래 값과 테스트 사용자를 되돌린다.
# - 선점은 전역 큐다. 다른 대기 발행이 있으면 건드리지 않도록 실행을 거부한다.
set -eu
cd "$(dirname "$0")/../.."

U=00000000-0000-4000-c242-c0000000000a
A=00000000-0000-4000-c242-c0000000010a
TMP=$(mktemp -d)
DAY="(now() at time zone 'America/Los_Angeles')::date"

psql_db() {
  docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qtAX "$@"
}
fail() { echo "FAIL: $*" >&2; exit 1; }

others=$(psql_db -c "select count(*) from public.publications where status in ('pending', 'retry_wait', 'uploading')")
[ "$others" = "0" ] || fail "다른 대기·업로드 중 발행 ${others}건이 있어 실행하지 않습니다(개발 DB 데이터 보호)"
psql_db -c "delete from auth.users where id = '$U'" >/dev/null
BEFORE=$(psql_db -c "select coalesce((select used from public.youtube_upload_quota where day = $DAY), -1)")
cleanup() {
  psql_db -c "delete from auth.users where id = '$U'" >/dev/null || true
  if [ "$BEFORE" = "-1" ]; then
    psql_db -c "delete from public.youtube_upload_quota where day = $DAY" >/dev/null || true
  else
    psql_db -c "update public.youtube_upload_quota set used = $BEFORE where day = $DAY" >/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

psql_db <<SQL
insert into auth.users (id, aud, role, email) values ('$U', 'authenticated', 'authenticated', 'up-quota-a@example.com');
insert into public.accounts (id, user_id, platform, channel_name, status, external_channel_id)
values ('$A', '$U', 'youtube', 'up-quota', 'connected', 'UCupquota000000000000000');
do \$\$
declare i integer; p uuid;
begin
  for i in 1..5 loop
    p := ('00000000-0000-4000-c242-c0000000020' || i)::uuid;
    insert into public.projects (id, user_id, account_id, name, step_status, sources_notice_ack_at, sources_notice_ack_by)
    values (p, '$U', '$A', 'up-quota', '{"1":"approved","2":"approved","3":"ready","4":"idle","5":"idle","6":"idle"}', now(), '$U');
    insert into public.scripts (project_id, version, lines, approved_at) values (p, 1, '["좁은 틈에도 쏙 들어가요."]', now());
    insert into public.renders (project_id, version, mp4_path, duration_sec, cut_map)
    values (p, 1, '$U/' || p || '/v1.mp4', 15, jsonb_build_object('cuts', jsonb_build_array(jsonb_build_object(
      'no', 1, 'source_id', '00000000-0000-4000-c242-c00000000301', 'author', 'maker_a', 'platform', 'tiktok',
      'source_url', 'https://www.tiktok.com/@maker_a/video/1', 'collected_at', '2026-11-12T01:00:00Z'))));
    update public.projects set step_status = '{"1":"approved","2":"approved","3":"approved","4":"approved","5":"approved","6":"idle"}'
    where id = p;
    insert into public.policy_checks (project_id, item, result, checked_by, checked_at)
    values (p, 'attribution_notice', 'pass', '$U', now());
    insert into public.publications (project_id, account_id, mode, title, body, description, hashtags, prepared_at, status)
    values (p, '$A', 'now', '압축팩 정리 꿀팁', '본문', '본문 설명', array['수납'], now(), 'pending');
  end loop;
end \$\$;
insert into public.youtube_upload_quota (day, used) values ($DAY, 98)
on conflict (day) do update set used = 98;
SQL

# 5건 선점(순서대로) → id|token
for n in 1 2 3 4 5; do
  printf "set role service_role;\nselect (c ->> 'publication_id') || '|' || (c ->> 'attempt_token') from public.publication_claim() c;\n" \
    | psql_db > "$TMP/c$n"
  grep -q '|' "$TMP/c$n" || fail "선점 $n 실패: $(cat "$TMP/c$n")"
done

begin_sql() {
  id=$(cut -d'|' -f1 "$TMP/c$1"); tok=$(cut -d'|' -f2 "$TMP/c$1")
  echo "select (public.publication_session_begin('$id', '$tok') ->> 'ok');"
}

# 세션 1: 카운터 행 잠금을 쥔 채 3초 대기 후 커밋
printf 'set role service_role;\nbegin;\n%s\nselect pg_sleep(3.07);\ncommit;\n' "$(begin_sql 1)" | psql_db > "$TMP/s1" 2>&1 &
i=0
until [ "$(psql_db -c "select count(*) from pg_stat_activity where query like '%pg_sleep(3.07)%' and pid <> pg_backend_pid()")" = "1" ]; do
  i=$((i + 1)); [ $i -gt 60 ] && fail "세션 1 대기 시간 초과"
  sleep 0.5
done
for n in 2 3 4 5; do
  printf 'set role service_role;\n%s\n' "$(begin_sql $n)" | psql_db > "$TMP/s$n" 2>&1 &
done
wait

ok=$(cat "$TMP"/s* | grep -c "^true$" || true)
full=$(cat "$TMP"/s* | grep -c "^false$" || true)
used=$(psql_db -c "select used from public.youtube_upload_quota where day = $DAY")
waiting=$(psql_db -c "select count(*) from public.publications p join public.projects j on j.id = p.project_id
                      where j.user_id = '$U' and p.status = 'retry_wait' and p.error = 'quota:daily_limit' and p.retry_count = 0")
[ "$ok" = "2" ] || { cat "$TMP"/s*; fail "통과 ${ok}건(2건이어야 함)"; }
[ "$full" = "3" ] || { cat "$TMP"/s*; fail "쿼터 대기 ${full}건(3건이어야 함)"; }
[ "$used" = "100" ] || fail "카운터 $used(100이어야 함)"
[ "$waiting" = "3" ] || fail "쿼터 대기 상태 ${waiting}건"
echo "PASS Q1 카운터 98에서 동시 session_begin 5회 → 통과 2·대기 3(횟수 미차감), 카운터 100(초과 0)"
