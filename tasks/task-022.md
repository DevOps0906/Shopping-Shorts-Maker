# task-022 다중 계정·YouTube OAuth·Vault·API 키 탭·내 채널

| 항목 | 내용 |
|---|---|
| 웨이브 | W4 |
| 선행 | task-007, task-011 |
| 위험도 | 높음 |
| 보안 영향 | 키·권한(OAuth 토큰·사용자 API 키 Vault), 노출 면(OAuth 콜백) |
| 담당 | builder |
| 근거 | spec S-05, S-13~S-15, `docs/planning.md#12`, `docs/planning.md#13`, `docs/planning.md#17-8`, `docs/04_API.md`(YouTube 절) |
| 쓰기 허용 | `apps/web/src/app/(dashboard)/{channels,settings}/**`, `apps/web/src/app/api/oauth/**`, `apps/web/src/components/{channels,settings}/**`, `apps/web/src/lib/vault/**`, `supabase/migrations/**`(새 번호만) |

## 할 것
- 다중 계정: accounts별 YouTube 공식 OAuth 연결·재연결, 토큰은 Vault 저장
- 설정 API 키 탭: 키 저장·교체·삭제, 화면에는 마스킹 표시만
- 내 채널(채널별 화면): 말투·타깃(accounts.target)
- OAuth state 검증, task-007에서 정한 최소 범위만 요청

## 하지 않을 것
- 비밀번호 저장, 토큰·키 원문을 브라우저로 반환
- YouTube 외 플랫폼 연결

## 완료 조건 (실행 가능한 확인)
- [ ] 테스트: 키 조회 API 응답에 원문 0건, state 불일치 콜백 거부
- [ ] 테스트: 타인 계정 토큰 접근 거부(RLS)
- [ ] 위협 메모 표 첨부, `spec S-05`·`S-13~S-15` 렌더 테스트
