# task-012 큐·워커 골격·멱등·재시도·취소·크레딧 기록

| 항목 | 내용 |
|---|---|
| 웨이브 | W2 |
| 선행 | task-005, task-011, task-030 |
| 위험도 | 높음 |
| 보안 영향 | 키·권한(워커 service_role), 의존성(워커 런타임) |
| 담당 | builder |
| 근거 | `docs/adr/0001-*.md`, `docs/adr/0002-*.md`, `docs/planning.md#17-5`, `docs/planning.md#17-6` |
| 쓰기 허용 | `apps/worker/**`, `supabase/migrations/**`(큐 생성만), `apps/web/src/lib/jobs/**` |

## 할 것
- 워커는 Docker 워커 컨테이너(task-030의 compose 서비스)로 실행, Railway 미사용
- 작업 생성 API: 같은 idempotency_key면 기존 job 반환
- 상태 `queued → waiting_extension(수집만) → running → succeeded/failed/canceled`
- 일시 오류만 재시도(가설 최대 3회·지수 백오프), 종류별 시간 제한, 앞 단계 초기화 시 취소
- credit_ledger reserve·settle·release 기록(결제 없음, D3)

## 하지 않을 것
- 실제 TTS·렌더 로직(task-019·020), 결제·충전
- 워커 로그에 키·서명 URL 출력

## 완료 조건 (실행 가능한 확인)
- [ ] 테스트: 중복 요청 1건만 생성, 실패 시 release 기록, 취소 시 canceled
- [ ] 테스트: 잔액 부족이면 시작 전 거부
- [ ] 워커 테스트·`pnpm typecheck` 통과
