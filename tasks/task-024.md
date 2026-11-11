# task-024 YouTube 예약 업로드·3회 재시도·발행 30일 후 원본 삭제

| 항목 | 내용 |
|---|---|
| 웨이브 | W4 |
| 선행 | task-012, task-022, task-023 |
| 위험도 | 높음 (위험 상위 3: API 감사 전 비공개 제한 가능성) |
| 보안 영향 | 키·권한(OAuth 토큰 사용), 민감 데이터(원본 삭제) |
| 담당 | builder (착수 전 challenger) |
| 근거 | `docs/planning.md#15-2`, `docs/planning.md#17-2`(D3·D5), `docs/planning.md#17-5`, `docs/planning.md#17-6`, `docs/04_API.md`(YouTube 절) |
| 쓰기 허용 | `apps/worker/src/publish/**`, `apps/worker/src/retention/**`, `apps/web/src/lib/publish/**` |

## 할 것
- 발행 버튼(사용자) → 업로드 job, 예약 공개 시각 지원, projects.status 갱신
- 일시 오류 3회 자동 재시도, OAuth 만료 시 다중 계정 재연결 안내
- 발행 30일(가설) 후 원본 파일 삭제 job, 출처 기록(URL·작성자·수집 시각·권리 근거)은 유지
- task-007 결론(감사 전 비공개 제한)에 따른 사용자 안내

## 하지 않을 것
- 같은 영상 다른 채널 재업로드, YouTube 외 플랫폼
- 정책 6항목 미통과 상태 업로드

## 완료 조건 (실행 가능한 확인)
- [ ] API 목 테스트: 일시 오류 3회 후 failed, 정책 미통과 거부
- [ ] 테스트: 삭제 예정일 지난 원본 객체 삭제·출처 행 유지
- [ ] 테스트 계정으로 비공개 업로드 1건 수동 확인
