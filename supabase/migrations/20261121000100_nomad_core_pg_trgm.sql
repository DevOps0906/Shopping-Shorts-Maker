-- pg_trgm 확장(2026-11-16 결정 5): knowflow·news 이식본의 부분 일치 검색 GIN(extensions.gin_trgm_ops)이 쓴다.
-- 확장은 core가 한 번만 만들고, 제품 이식본은 만들지 않고 extensions 스키마에 있는지만 검사한다.
-- 다른 스키마(public 등)에 이미 있으면 조용히 넘어가지 않고 분명한 메시지로 중단한다(이식본의 extensions.gin_trgm_ops가 깨지므로).
-- 되돌림: drop extension pg_trgm; (사용하는 제품 인덱스가 없을 때만)
begin;

do $$
declare v_schema text;
begin
  select n.nspname into v_schema
    from pg_catalog.pg_extension e join pg_catalog.pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'pg_trgm';
  if v_schema is not null and v_schema <> 'extensions' then
    raise exception 'pg_trgm 확장이 이미 % 스키마에 있다 — extensions 스키마가 필요하다', v_schema
      using errcode = '55000',
            hint = '사용처를 확인한 뒤 "alter extension pg_trgm set schema extensions;"로 옮기고 다시 적용한다';
  end if;
end $$;

create extension if not exists pg_trgm with schema extensions;

commit;
