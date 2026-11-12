# ADR-0005 설치형 앱 셸(Tauri·Capacitor)
- 상태: 제안 · 날짜: 2026-11-12 · 근거: `docs/planning.md#17-2`(D11) · `#17-8` · `AGENTS.md#2`

## 맥락
웹 대시보드 완성(task-028) 뒤 `apps/desktop`(Tauri)·`apps/mobile`(Capacitor)을 낸다. Next.js 서버 기능과 LLM 키는 서버에만 있다.

## 결정
- **원격 URL 방식**: 셸은 운영 웹 주소를 연다. 탐색은 우리 도메인으로 제한하고 외부 링크는 시스템 브라우저로 연다. 셸에 비밀·API 키를 넣지 않는다.
- 인증 세션: 웹뷰 안 Supabase 쿠키 세션 그대로. OAuth(YouTube 등)는 웹뷰가 아닌 시스템 브라우저로 열고 딥링크(`앱스킴://auth/callback` 또는 Universal/App Links)로 돌아온다.
- 파일 업로드: 웹의 `<input type=file>`을 그대로 쓴다(셸 플러그인 불필요). 큰 영상은 서명 업로드 URL로 직접 Storage에.
- 마이크(목소리 녹음 시): 웹 `getUserMedia` + 플랫폼 권한 문구(iOS `NSMicrophoneUsageDescription`, Android `RECORD_AUDIO`, macOS 엔타이틀먼트).
- 수집은 계속 브라우저 확장(앱 웹뷰는 사용자 브라우저 로그인 사용 불가).

## 보안·운영 조건
- 원격 출처에 네이티브 브리지 금지: Tauri는 원격 URL에 capability를 주지 않고(`remote` 항목 없음, IPC 명령 0개), Capacitor는 원격 서버 페이지에서 플러그인 브리지를 쓰지 않는다(필요한 플러그인은 딥링크 수신·시스템 브라우저 열기만, 로컬 셸 코드에서 처리).
- 시스템 브라우저 OAuth: `state`를 서버 측 로그인 사용자·기기에 묶어 저장, 콜백은 서버가 받아 코드 교환(PKCE). 딥링크에는 OAuth `code` 대신 **1회용·60초 교환 토큰**만 실어 앱이 서버에 제출 → 세션 확립. 딥링크 가로채기(같은 스킴 등록 앱) 대비로 Universal/App Links 우선.
- Google은 임베디드 웹뷰 로그인을 막으므로(`disallowed_useragent`) 앱 로그인은 이메일·OTP 또는 위 시스템 브라우저 흐름만 쓴다.

## 웹 구현에서 미리 지킬 제약
OAuth 콜백 URL을 환경별로 여러 개 등록 가능하게 · `window.open`·새 탭 의존 금지 · 파일 저장은 다운로드 링크(서명 URL) · 서비스 워커·푸시는 선택 기능으로 · 쿠키 `SameSite=Lax`·HTTPS 전용 · 반응형 3구간이 웹뷰에서도 동작 · 로그인 화면에 웹뷰 감지 시 Google 버튼 대신 시스템 브라우저 안내.

## 대안
정적 번들(`output: export`): 서버 액션·Route Handler를 별도 API 서버로 분리해야 하고 오프라인 이점이 작아 보류 · Electron: Chromium 포함으로 용량 큼 · PWA만: 앱스토어 배포·딥링크 제약.

## 결과
+ 웹 배포만으로 앱도 갱신, 키가 기기에 없음. − iOS 최소 기능 심사 거절 위험, 서명·공증 비용, 업데이트 서명 키 관리(D11).

## 버전·라이선스
Tauri 2.12.5(MIT/Apache-2.0, v3는 alpha라 제외) · Capacitor 8.6.0(MIT).
