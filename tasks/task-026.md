# task-026 RLS·Vault·권리 게이트·AI 금지 도구 보안 테스트

| 항목 | 내용 |
|---|---|
| 웨이브 | W5 |
| 선행 | task-021, task-024 |
| 위험도 | 높음 |
| 보안 영향 | 키·권한, 민감 데이터, 노출 면(검증 대상) |
| 담당 | tester (+ reviewer mode=security) |
| 근거 | `docs/planning.md#17-7`, `docs/planning.md#17-8`, `docs/planning.md#15-4`, `docs/05_DATA_MODEL.md`, `AGENTS.md#4` |
| 쓰기 허용 | `tests/security/**`, `supabase/tests/**` |

## 할 것
- 모든 테이블·버킷: 사용자 2명 교차 읽기·쓰기 거부
- Vault: 키·토큰 원문이 응답·로그·클라이언트 번들에 없음
- 권리 게이트: 7편 규칙, 미확인 원본 편집·발행 차단, 정책 6항목 미통과 발행 차단
- 제작 파트너: 승인·발행·권리 도구 부재, 프롬프트 주입 시 상태 변경 0

## 하지 않을 것
- 제품 코드 수정(발견 사항은 `tasks/README.md` 발견한 문제에 기록)

## 완료 조건 (실행 가능한 확인)
- [ ] `pnpm test tests/security` 전부 통과
- [ ] `secscan` 비밀 0건, 실패 항목 0 또는 후속 작업 등록
