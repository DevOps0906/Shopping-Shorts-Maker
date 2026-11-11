# task-004 문서 정합(권리 동의 문구·W0 실측 반영)

| 항목 | 내용 |
|---|---|
| 웨이브 | W1 |
| 선행 | task-002 |
| 위험도 | 낮음 |
| 보안 영향 | 없음 |
| 담당 | planner |
| 근거 | `docs/planning.md#02-소스-모으기`, `docs/planning.md#17-2`, `docs/00_LEAN.md` |
| 쓰기 허용 | `docs/planning.md`, `docs/03_SCREENS_UX.md`, `docs/diagrams/user-flow.mmd` |

## 할 것
- task-002 전문가 검토 결과로 권리 확인 동의 문구 확정
- task-002 실측(제품별 권리 확인 편수)으로 3편 예외 승인 하한을 확정하거나 수정
- 승인 규칙은 3장 02 한 곳에만 두고 다른 문서는 링크로 유지

## 하지 않을 것
- 화면 구조·토큰 변경(`docs/design.md`, `design/prototype/`)
- 새 기능·수치 추가

## 완료 조건 (실행 가능한 확인)
- [ ] `grep -nE "3회 탐색 후|3회 후 예외|3회 실패 시 예외|기본은 모두 체크" docs/` 결과 0건
- [ ] `mmd-check docs/diagrams/user-flow.mmd` 통과
- [ ] reviewer(mode=doc) 🔴 0
