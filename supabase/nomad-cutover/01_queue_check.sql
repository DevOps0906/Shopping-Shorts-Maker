-- 01_queue_check.sql — freeze 뒤 옛 pgmq 큐가 비었는지 확인(읽기만). 비어 있지 않으면 오류로 끝난다.
-- 실행: psql "<DB 주소>" -v ON_ERROR_STOP=1 -f supabase/nomad-cutover/01_queue_check.sql
-- 사용자 결정(2026-11-17): 메시지는 옮기지 않는다. 워커가 다 처리할 때까지 기다렸다가 다시 실행한다.
do $$
declare q text; n bigint; total bigint := 0; msg text := ''; w bigint;
begin
  foreach q in array array['render', 'tts', 'analyze', 'sources'] loop
    if to_regclass(format('pgmq.%I', 'q_' || q)) is null then continue; end if;
    execute format('select count(*) from pgmq.%I', 'q_' || q) into n;
    total := total + n;
    msg := msg || format(' %s=%s', q, n);
  end loop;
  select count(*) into w from public.jobs where status in ('queued', 'running');
  raise notice '옛 큐 메시지:%  · 옛 jobs queued/running: %', msg, w;
  if total > 0 then
    raise exception '옛 큐가 비어 있지 않습니다(%건). 워커 처리 완료 후 다시 확인하세요', total;
  end if;
end $$;
