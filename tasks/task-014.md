# task-014 홈·새 프로젝트·프로젝트 관리·트렌드(시드)

| 항목 | 내용 |
|---|---|
| 웨이브 | W3 |
| 선행 | task-013 |
| 위험도 | 보통 |
| 보안 영향 | 없음 |
| 담당 | builder |
| 근거 | spec S-01, S-02, S-03, S-04, `docs/planning.md#10`, `docs/planning.md#11`, `docs/planning.md#12` |
| 쓰기 허용 | `apps/web/src/app/(dashboard)/page.tsx`, `apps/web/src/app/(dashboard)/{new,projects,trends}/**`, `apps/web/src/components/{home,projects,trends}/**` |

## 할 것
- 홈, 새 프로젝트(1 프로젝트 = 1 채널 선택), 프로젝트 관리(status 필터), 트렌드(TrendTable·SelectionBar, 기간 오늘·7일·30일, task-010 시드)
- 화면별 빈·로딩·오류 상태(spec 정의대로)

## 하지 않을 것
- 트렌드 실데이터 수집, 일괄 생성(4단계 후보)
- 같은 영상을 다른 채널에 올리는 기능

## 완료 조건 (실행 가능한 확인)
- [x] `spec S-01`~`S-04` 구성 블록이 모두 렌더되는지 컴포넌트 테스트
- [x] 375·1024·1440 `shot` 비교, `pnpm typecheck` 통과
