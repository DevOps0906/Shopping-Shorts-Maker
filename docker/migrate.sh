#!/bin/sh
# 셀프 호스팅 Compose DB에 supabase/migrations 를 순서대로 적용한다 (task-010).
# `supabase db reset` 은 CLI 로컬 스택 전용이라 이 스크립트로 대체한다.
#
#   sh docker/migrate.sh up      # 아직 적용하지 않은 마이그레이션만 적용
#   MIGRATE_ALLOW_RESET=1 sh docker/migrate.sh reset   # (로컬 컨텍스트만) 앱 객체(public 스키마 객체·private·api)만 지우고 전부 재적용 + seed.sql
#
# - db 컨테이너 안의 psql(postgres 역할)로 실행하므로 비밀번호를 쓰지 않는다.
# - auth·storage·vault 등 Supabase 스키마와 auth.users 데이터는 건드리지 않는다.
# - 적용 기록은 Supabase CLI와 같은 supabase_migrations.schema_migrations 에 남긴다.
set -eu

cd "$(dirname "$0")/.."

psql_db() {
  docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q "$@"
}

ensure_history() {
  psql_db <<'SQL'
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
  version text primary key,
  statements text[],
  name text
);
SQL
}

reset_app() {
  psql_db <<'SQL'
drop schema if exists private cascade;
drop schema if exists api cascade;
do $$
declare r record;
begin
  -- public 스키마의 앱 객체만(확장 소유 객체 제외) 지운다.
  for r in
    select c.oid::regclass as obj, c.relkind
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm')
      and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e')
  loop
    if r.relkind in ('v', 'm') then
      execute format('drop %s view if exists %s cascade',
                     case r.relkind when 'm' then 'materialized' else '' end, r.obj);
    else
      execute format('drop table if exists %s cascade', r.obj);
    end if;
  end loop;
  for r in
    select p.oid::regprocedure as fn
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('drop routine if exists %s cascade', r.fn);
  end loop;
  for r in
    select t.oid::regtype as typ
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typtype in ('e', 'd', 'c')
      and (t.typrelid = 0 or (select relkind from pg_class where oid = t.typrelid) = 'c')
      and not exists (select 1 from pg_depend d where d.objid = t.oid and d.deptype = 'e')
  loop
    execute format('drop type if exists %s cascade', r.typ);
  end loop;
end
$$;
truncate supabase_migrations.schema_migrations;
SQL
}

apply_pending() {
  for f in supabase/migrations/*.sql; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .sql)
    version=${base%%_*}
    name=${base#*_}
    applied=$(psql_db -tA -c "select 1 from supabase_migrations.schema_migrations where version = '$version'")
    if [ "$applied" = "1" ]; then
      continue
    fi
    echo "적용: $base"
    { cat "$f"; printf "\ninsert into supabase_migrations.schema_migrations (version, name) values ('%s', '%s');\n" "$version" "$name"; } \
      | psql_db -1
  done
}

case "${1:-up}" in
  up)
    ensure_history
    apply_pending
    ;;
  reset)
    # 파괴적 작업: 로컬 Docker(기본·desktop-linux 컨텍스트)에서만, 명시적 동의가 있을 때만 실행한다.
    ctx=$(docker context show 2>/dev/null || echo unknown)
    case "$ctx" in default|desktop-linux) ;; *) echo "reset 거부: Docker 컨텍스트 '$ctx'는 로컬이 아닙니다" >&2; exit 3 ;; esac
    if [ "${MIGRATE_ALLOW_RESET:-}" != "1" ]; then
      echo "reset 거부: 앱 테이블을 지웁니다. 개발 DB가 맞으면 MIGRATE_ALLOW_RESET=1 을 붙여 실행하세요" >&2
      exit 3
    fi
    ensure_history
    reset_app
    apply_pending
    if [ -f supabase/seed.sql ]; then
      echo "시드: supabase/seed.sql"
      psql_db -1 < supabase/seed.sql
    fi
    ;;
  *)
    echo "사용법: sh docker/migrate.sh [up|reset]" >&2
    exit 2
    ;;
esac
echo "완료"
