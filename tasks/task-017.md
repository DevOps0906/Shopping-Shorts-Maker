# task-017 02 소스: SourceGrid·기본 체크 해제·권리 근거·직접 추가·승인 규칙

| 항목 | 내용 |
|---|---|
| 웨이브 | W3 |
| 선행 | task-013, task-016 |
| 위험도 | 높음 (위험 상위 3: 권리 게이트) |
| 보안 영향 | 민감 데이터(권리 근거·확인자), 노출 면(원본 직접 업로드) |
| 담당 | builder (착수 전 challenger) |
| 근거 | spec S-07, `docs/planning.md#3`(02 소스), `docs/planning.md#4`, `docs/planning.md#15-4`, `docs/planning.md#17-6` |
| 쓰기 허용 | `apps/web/src/app/(dashboard)/studio/[projectId]/[step]/sources/**`, `apps/web/src/components/sources/**`, `apps/web/src/lib/sources/**` |

## 할 것
- SourceGrid: 자동 수집 결과 기본 체크 해제, 체크 시 권리 근거 선택 + 확인자·시각 저장
- 직접 추가(판매자 제공·자체 촬영 파일) 업로드 → 비공개 버킷
- 승인 규칙: `docs/planning.md#02-소스-모으기`의 승인 조건을 그대로 구현(7편 승인 / 3~6편 사유 기록 예외 승인 / 0~2편 불가)
- 권리 확인 체크·승인은 사용자 클릭만(서버에서 재검사)

## 하지 않을 것
- AI 도구로 체크·승인 제공, 미확인 원본을 05 편집에 전달
- 업로드 파일 형식·크기 한도 임의 결정(팀장 결정 필요)

## 완료 조건 (실행 가능한 확인)
- [x] 테스트: 2편 승인 거부, 3편+사유 없음 거부, 3편+사유 허용, 7편 허용
- [x] 테스트: 미확인 원본이 편집 입력에서 제외
- [x] `spec S-07` 블록 렌더 테스트, 3구간 `shot` 확인
