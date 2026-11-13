# task-035 작업 큐 병목 대응: 종류별 처리 슬롯·사용자별 동시 실행·대기 상한·적체 조회

| 항목 | 내용 |
|---|---|
| 웨이브 | W4 |
| 선행 | task-012(큐·작업 함수), task-019·020(음성·렌더 워커) |
| 위험도 | 보통(작업 생성·시작 함수 변경, 크레딧 예약 순서 유지) |
| 담당 | builder → codex-reviewer(code) |
| 근거 | `docs/planning.md#17-5-1`, `docs/planning.md#17-5`, `docs/adr/0001-job-queue-supabase-queues.md`, `supabase/migrations/20261112180400_create_job_step_guard.sql`(create_job 최신), `20261112180300_worker_credit_hardening.sql`(job_start 최신), `apps/worker/worker/__main__.py`·`jobs.py`(poll_once: 큐마다 1건씩 직렬 처리) |
| 쓰기 허용 | `supabase/migrations/<새 번호>_job_backpressure.sql`, `supabase/tests/job_backpressure.sql`, `apps/worker/worker/**`, `apps/worker/tests/**`, `docker/docker-compose.override.yml`(워커 환경 변수 이름만), 웹의 create_job 오류 문구 매핑 1곳 |

## 할 것
- 워커: 큐별 스레드(각자 DB 연결 + 하트비트 연결), 큐별 동시 처리 수 환경 변수 `WORKER_CONCURRENCY_RENDER`(기본 1)·`_TTS`(2)·`_ANALYZE`(2). SIGTERM 시 진행 중 작업을 끝내거나 vt 만료로 넘김(기존 동작 유지)
- DB `create_job`: 같은 사용자·같은 큐의 queued·running 수가 상한(render 3·tts 5·analyze 5, 설정 함수 1곳)을 넘으면 크레딧 예약 전에 새 오류 코드 `JQ001`로 거부. 멱등 키가 같은 기존 작업 반환은 상한보다 먼저
- DB `job_start`: 같은 사용자의 같은 큐 running 수가 1 이상이면 시작하지 않고 vt를 짧게(가설 20초) 미뤄 `deferred` 반환 → 워커는 메시지를 놓고 다음 메시지를 읽음. 시도 횟수(attempts)·read_ct 기반 실패 판정에 미룸이 섞이지 않게 함
- 서버 전용 조회 함수 `public.queue_health()`(service_role만): 큐별 대기 수·가장 오래 기다린 초(pgmq.metrics)

## 후속 035b (사용자 승인 2026-11-13, 035 병합 뒤)
- 본인 작업 대기 순번·예상 대기 시간 함수(authenticated, 본인 job만) + 상태 배너 표시(S-06~S-10), 03_SCREENS_UX·design·프로토타입·spec 반영. 계산 규칙은 `docs/planning.md#17-5-1` 화면 행
- GNB 작업 현황 패널(탭: 제작 중 · 포스팅 대기, `docs/planning.md#17-5-1` 작업 현황 패널 행). 포스팅 대기 순번은 publication_claim 정렬(next_attempt_at·prepared_at)과 같은 기준. GNB 구조 변경은 사용자 승인 완료(2026-11-13) → docs/design.md·prototype·03_SCREENS_UX 반영

## 하지 않을 것
- 화면(대기 순번·예상 대기 배너) — 035b에서
- 운영 알림 발송 연결(17-10 감시 작업에서)
- 우선순위 요금제(유료 사용자 먼저) — P1
- 적용된 마이그레이션 수정

## 완료 조건
- [ ] reset 후 `supabase/tests/job_backpressure.sql`: 상한 초과 create_job → JQ001·크레딧 변화 0, 같은 멱등 키는 상한이어도 기존 작업 반환, 같은 사용자 두 번째 render job_start → deferred·attempts 불변, 다른 사용자 render는 시작, queue_health는 authenticated 실행 불가
- [ ] 기존 작업·크레딧 SQL 테스트 회귀 통과
- [ ] 워커 pytest: 렌더 처리 중에도 tts 메시지가 처리됨(가짜 Repo), deferred 메시지는 처리하지 않고 넘김
- [ ] web `pnpm typecheck`·`pnpm test`
