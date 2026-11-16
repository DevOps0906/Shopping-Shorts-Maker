-- 작업 큐·예약 작업 확장을 먼저 만든다.
-- 20261112170100(jobs_credit_ledger)이 pgmq 함수 권한을 다루는데 확장 생성(20261112180000)이 그보다 뒤에 있어
-- 새 DB에 처음부터 적용하면 실패했다. 이미 적용된 DB에서는 if not exists 라 아무 일도 하지 않는다.
create extension if not exists pgmq;
create extension if not exists pg_cron;
