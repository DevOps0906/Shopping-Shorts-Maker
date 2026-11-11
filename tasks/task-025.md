# task-025 성과 수집·단축 링크·성과 화면

| 항목 | 내용 |
|---|---|
| 웨이브 | W4 |
| 선행 | task-011, task-022 |
| 위험도 | 높음 |
| 보안 영향 | 노출 면(익명 단축 링크·열린 리다이렉트), 민감 데이터(클릭 기록) |
| 담당 | builder |
| 근거 | spec S-12, `docs/planning.md#15-3`, `docs/planning.md#17-4`, `docs/planning.md#17-8`, `docs/04_API.md`(YouTube 절) |
| 쓰기 허용 | `apps/web/src/app/(dashboard)/analytics/**`, `apps/web/src/app/l/**`, `apps/web/src/components/analytics/**`, `apps/worker/src/analytics/**` |

## 할 것
- 단축 링크: 등록된 제휴 도메인으로만 이동, link_clicks는 서버만 기록(IP 원문 저장 안 함)
- YouTube 조회 수 주기 수집 job
- 성과 화면: 조회·링크 클릭(소유자는 bio_items 경유 읽기)

## 하지 않을 것
- 매출·전환 추적, 성과 기반 소재 추천(4단계 후보)
- 수집 주기 임의 결정(쿼터 근거 task-007, 없으면 팀장 결정 필요)

## 완료 조건 (실행 가능한 확인)
- [ ] 테스트: 미등록 도메인 리다이렉트 거부, 클릭 행에 IP 원문 없음
- [ ] 테스트: 타인 링크 클릭 집계 조회 0행
- [ ] 위협 메모 표 첨부, `spec S-12` 렌더 테스트
