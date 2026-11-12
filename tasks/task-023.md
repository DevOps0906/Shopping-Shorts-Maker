# task-023 06 발행 화면: 제휴·링크인바이오·정책 점검 6항목

| 항목 | 내용 |
|---|---|
| 웨이브 | W4 |
| 선행 | task-013, task-017 |
| 위험도 | 보통 |
| 보안 영향 | 없음(링크 이동·업로드는 task-024·025) |
| 담당 | builder |
| 근거 | spec S-11, `docs/planning.md#3`(06 발행), `docs/planning.md#15-1`, `docs/planning.md#15-4`, `docs/planning.md#16-3`, `docs/planning.md#16-4`, `docs/design.md#5-7` |
| 쓰기 허용 | `apps/web/src/app/(dashboard)/studio/[projectId]/[step]/publish/**`, `apps/web/src/components/publish/**` |

## 할 것
- AffiliatePicker·LinkPlacement·LinkInBioCard: 제휴 링크 입력, 링크인바이오 번호 운영 규칙(16-4)
- 설명란 순서: 고지 → 구매 안내 → 본문 → 해시태그
- PolicyChecklist 6항목, 모두 통과 전 PublishPanel 발행 버튼 비활성

## 하지 않을 것
- 실제 업로드(task-024), 인포크링크·리틀리 API 연동(16-5 확장)
- 정책 항목 추가·삭제

## 완료 조건 (실행 가능한 확인)
- [x] 테스트: 6항목 중 1개라도 미통과면 발행 버튼 비활성
- [x] 테스트: 설명란 생성 순서 고정
- [x] `spec S-11` 렌더 테스트, 3구간 `shot` 확인
