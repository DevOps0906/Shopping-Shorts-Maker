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

## 결정 (2026-11-14)
- **화면(사용자 승인 2026-11-14)**: S-18 확장 연결 `/extension/connect`(로그인 필요, 연결하기 버튼·상태: 확장 미설치/연결됨, "플랫폼 비밀번호·쿠키는 받지 않음") · S-19 설정 탭 "브라우저 확장" `/settings/extensions`(연결된 확장: 이름·마지막 신호·연결일·해제, "+ 새 브라우저 연결"→S-18). 설정 tabs에 4번째 탭 추가
- **분할**: 015b-1 DB(토큰 발급·회전·폐기 함수, 완료·중단 보고 함수, 속도 제한, 버킷 상한) → 015b-2 웹(API·S-18·S-19·S-07 배너·collect_download 생성) → 015b-3 문서(03_SCREENS_UX·design·spec·prototype)
- 회전 유예: 직전 회전 후 **10초 이내** 같은 갱신 토큰 재사용은 family 폐기 대신 409(이미 갱신됨, 새 토큰 재발급 없음). 10초 뒤 재사용 = family 전체 폐기
- 속도 제한(확장 단위, 가설): 하트비트 분당 4 · 수집·업로드 URL·보고 분당 60 · 갱신 family당 분당 10 · 연결 발급 사용자당 10분에 5. 초과 429 + Retry-After
- 업로드 상한: 영상 200MB로 통일(서명 URL 발급 시 신고 크기 검사 + sources 버킷 상한을 새 마이그레이션으로 200MiB), 썸네일 512KiB 유지
- 완료 보고: collect → succeeded(이후 select_sources 생성은 기존 흐름 따름). collect_download → 지금은 succeeded, **015c-2에서 워커 재검사로 교체**(그 전엔 개발 환경만). 중단 보고: 캡차·위험 제어·로그인 만료 → failed + 사유 코드(배너 문구 매핑)
- 토큰 보관(015d 참고): 액세스 chrome.storage.session, 갱신 chrome.storage.local
