# task-015b 확장 수집 웹 서버: API·연결 페이지·확장 관리·S-07 배너

| 항목 | 내용 |
|---|---|
| 웨이브 | W3 |
| 선행 | task-015a, 화면 행 추가·사용자 승인(연결 페이지·설정 확장 탭) |
| 위험도 | 높음 |
| 보안 영향 | 노출 면(확장 API), 키·권한(확장 토큰 발급·회전·폐기) |
| 담당 | builder → codex-reviewer(code) + reviewer(security) |
| 근거 | `docs/adr/0003-extension-server-auth.md`(결정·보안·운영 조건·보강 ③⑤), `docs/planning.md#17-8`, spec S-07(상태 배너), 승인될 연결·설정 화면 행 |
| 쓰기 허용 | `apps/web/src/app/api/extension/**`, `apps/web/src/server/extension/**`, 연결 페이지 경로(화면 행 승인 후 확정), `apps/web/src/app/(dashboard)/settings/[tab]/**`(확장 탭만), `apps/web/src/components/studio/status-banner.tsx`, `apps/web/src/lib/jobs/create-job.ts`(collect_download 생성만) |

## 할 것
- 연결 페이지: 로그인 사용자에게 확장 자격 발급 → `externally_connectable`로 전달(Supabase 토큰 미전달)
- 토큰: 액세스 15분·갱신 30일, 갱신 시 회전, 재사용 감지 시 family 전체 폐기. 동시 갱신 유예 시간 `팀장 결정 필요`
- API(Bearer 전용, 쿠키·credentials 미허용): 하트비트(응답에 대기 job) · claim · 목록 업로드 · 썸네일/파일 서명 업로드 URL · 완료 보고 · 갱신 · 해제. 매 요청 토큰·사용자·job 소유권 재검사, 속도 제한(값 `팀장 결정 필요`)
- 수집 입력은 서버가 JSON 스키마 검사(허용 필드만) 후 015a DB 함수로만 저장 — 서버에서 platform·collected_at을 받지 않음(🔴5)
- 서명 업로드 URL은 서비스 도메인 경유로만 발급(확장이 Supabase 호스트를 직접 알 필요 없음), 경로 `<user_id>/<project_id>/<파일>`
- 사용자 체크 10편 확정 시 `collect_download` job 생성(멱등 키)
- 설정: 연결된 확장 목록(마지막 하트비트·생성일)·폐기 버튼
- S-07 배너: 확장 미연결 · 플랫폼 탭 필요 · 캡차·위험 제어로 중단(사유) · 로그인 만료 · 대기 만료 문구(문구는 `docs/design.md#5-6` 기준, 없으면 `팀장 결정 필요`)

## 하지 않을 것
- 플랫폼 쿠키·비밀번호 수신·저장, 서버 측 플랫폼 크롤링·다운로드, 로그에 토큰 원문

## 완료 조건 (실행 가능한 확인)
- [ ] `pnpm typecheck` · `pnpm lint` · `pnpm test` 통과
- [ ] 보안 테스트: 만료·폐기·회전 전 토큰 거부 · 갱신 토큰 재사용 → family 폐기 · 남의 job_id claim/업로드 403 · 쿠키만 있는 요청 401 · CORS 응답에 `Access-Control-Allow-Credentials` 없음 · 허용 외 필드·platform 입력 무시/거부 · 응답·로그에 토큰 원문 없음
- [ ] 끊김 → waiting_extension → 재연결 claim → running 통합 테스트(015a 함수 사용)
