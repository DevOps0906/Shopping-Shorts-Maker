# task-013 6단계 상태 머신·승인·초기화·Realtime·StepStepper·StatusBanner

| 항목 | 내용 |
|---|---|
| 웨이브 | W2 |
| 선행 | task-008, task-011 |
| 위험도 | 보통 |
| 보안 영향 | 없음(task-011 RLS 위에서 동작) |
| 담당 | builder |
| 근거 | spec S-06~S-11(제작단계 공통), `docs/planning.md#6`, `docs/planning.md#17-6`, `docs/design.md#5-6` |
| 쓰기 허용 | `apps/web/src/app/(dashboard)/studio/**`, `apps/web/src/components/studio/**`, `apps/web/src/lib/steps/**` |

## 할 것
- 단계 상태 6개와 전이(승인해야 다음 단계, 앞 단계 변경 시 뒤 단계 초기화·확인)
- `projects.step_status` 서버 보관, Realtime 구독으로 StatusBanner 갱신
- StepStepper(STEP 0N / 06), 승인 버튼은 사용자만
- step_started·step_approved·step_change_requested 이벤트 기록

## 하지 않을 것
- 단계별 내용 화면(task-017~020·023)
- 화면 구조·토큰 변경

## 완료 조건 (실행 가능한 확인)
- [x] 상태 전이 단위 테스트(초기화 연쇄 포함) 통과
- [x] 두 탭에서 승인 시 다른 탭 배너가 갱신되는지 수동 확인
- [x] `pnpm typecheck` · `pnpm lint` 통과
