# ADR-0001 작업 큐: Supabase Queues(pgmq)
- 상태: 제안 · 날짜: 2026-11-12 · 근거: `docs/planning.md#17-2`(D4) · `#17-5` · `#7`

## 맥락
검색·수집·음성·렌더링은 오래 걸리고 재시도가 필요하다. D6으로 전부 셀프 호스팅이라 외부 큐 서비스를 쓰지 않는다. 상태 정본은 `jobs` 테이블(17-5)이다.

## 결정
- Supabase Queues(Postgres 확장 `pgmq`)를 쓴다. `jobs` 행 삽입과 `pgmq.send`를 **한 트랜잭션**에서 해 유실·중복을 막고, 메시지에는 `job_id`만 넣는다.
- 워커는 `pgmq.read(vt)`로 가져가고, 일시 오류는 vt 만료로 재노출(`read_ct` ≤ 3). 입력·권한 오류는 즉시 `failed`.
- 큐는 종류별로 나눈다(`render`·`tts`·`analyze`). 수집은 확장이 처리하므로 큐에 넣지 않는다(ADR-0003).
- 셀프 호스팅 이미지 동작 확인: ADR-0004 참고(pgmq 1.5.1 사용 가능, send/read 실측 통과).

## 보안·운영 조건
- vt는 종류별 시간 상한보다 길게(렌더 상한 10분 → vt 12분). 진행 중에는 1분마다 `pgmq.set_vt`로 연장해 다른 워커가 같은 작업을 집지 않게 한다.
- 상태 전이는 조건부 갱신만: `update jobs set status=… where id=$1 and status='running'`(영향 0행이면 중단·메시지 archive).
- 정산 중복 방지: `credit_ledger`에 `unique(job_id, kind)`(kind = reserve·settle·release). 결과 기록·`settle`·`pgmq.archive`는 **한 트랜잭션**.
- `read_ct` > 3: 워커가 같은 트랜잭션에서 `failed` 전환 + `release` + archive.
- 실행 중 취소(17-5): 웹 서버가 `status='canceled'`로 바꾸고 `release`. 워커는 vt 연장 때마다 상태를 확인해 `canceled`면 FFmpeg를 종료하고 archive(결과 버림).
- 시간 초과 감시(하트비트 2분·수집 15분·대기 24시간·렌더 10분)는 **pg_cron 1분 주기 스위퍼 함수 한 곳**이 맡는다(조건부 갱신 + release). pg_cron 1.6.4는 `supabase/postgres:17.6.1.136`에 사용 가능(미설치, 2026-11-12 확인 — `create extension pg_cron` 필요).
- 권한: 워커 전용 DB 역할에 `pgmq` 함수 실행과 `jobs`·`credit_ledger` 필요한 열만 GRANT, 테이블 RLS는 유지하고 이 역할만 BYPASSRLS 없이 정책으로 허용. service_role 미사용.
- Storage 서명 URL은 **웹 서버만** 발급하고, 워커는 내부망 Storage API를 전용 키로 쓴다(키 범위는 ADR-0004 비밀 목록에서 관리).
- `pgmq` 스키마는 PostgREST `exposed schemas`에 넣지 않는다(브라우저에서 큐 직접 접근 금지).

## 대안
| 대안 | 판단 |
|---|---|
| pg-boss · Graphile Worker (MIT, Node 전용) | 워커가 Python이면 못 씀(ADR-0002). Node 워커일 때 차선 |
| Trigger.dev v4 (Apache-2.0) | 셀프 호스팅 시 별도 서버·Redis·스토리지가 늘어 D6과 맞지 않음. 비교만 |
| Redis + BullMQ/RQ | Redis 8은 AGPLv3/SSPL/RSAL 중 택1 → 거부. Valkey(BSD)도 구성 요소가 늘어 보류 |

## 결과
+ 컨테이너 추가 없음, 백업 1곳, 트랜잭션 일관성. − 큐 처리량이 Postgres에 묶임(MVP 규모에선 문제없음). 적체는 `pgmq.metrics`로 감시(17-10).

## 버전·라이선스
pgmq 1.5.1(이미지 내장, 상류 최신 1.13.1) · PostgreSQL License · supabase/postgres 17.6.1.136.
