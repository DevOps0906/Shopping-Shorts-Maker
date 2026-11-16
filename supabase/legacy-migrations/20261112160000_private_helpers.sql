-- task-010: 앱 내부 함수용 private 스키마와 공용 트리거 함수.
-- private 은 PostgREST에 노출하지 않는다(docs/05_DATA_MODEL.md 1절 SECURITY DEFINER 조건).
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- 트리거 함수는 실행 시 권한 검사를 받지 않는다. RPC로 부를 수 없게 EXECUTE를 막아 둔다.
alter default privileges in schema private revoke execute on functions from public;

-- updated_at 자동 갱신
create function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke execute on function private.set_updated_at() from public, anon, authenticated;
