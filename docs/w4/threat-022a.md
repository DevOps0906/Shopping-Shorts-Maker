# task-022a 위협 메모 — YouTube OAuth 연결·Vault 저장

근거: [04_API YouTube 2절](../04_API.md#2-최소-oauth-범위) · [planning 17-8](../planning.md) · [ADR-0005](../adr/0005-installable-app-shell.md)(앱 시스템 브라우저 흐름은 W7) · 마이그레이션 `20261112270000_youtube_oauth.sql`·`20261112270100_vault_cleanup_fix.sql` · 테스트 `supabase/tests/youtube_oauth.sql`, `apps/web/src/server/oauth/youtube.test.ts`

| # | 위협 | 대응 | 확인 |
|---|---|---|---|
| 1 | 남의 계정(account_id)으로 연결 시작 | 세션 사용자 id로 `oauth_state_create`가 accounts 소유·platform=youtube 확인(42501) | SQL PASS 3, 단위 "남의 account_id" |
| 2 | state 위조·재사용·만료·다른 사용자 콜백(로그인 CSRF·code 주입) | state 32바이트 무작위, DB에는 sha256만. verifier 원문은 `oauth_states`(정책 없음, 모든 역할 GRANT 회수)에만. 10분 만료, 콜백에서 1회 소모 후 세션 사용자 = state 사용자 확인(다른 사용자 제출 시에도 소모) | SQL PASS 3, 단위 "state 불일치…" |
| 3 | 인가 코드 가로채기 | PKCE S256(verifier 64자, 서버 보관), redirect_uri 고정(`OAUTH_REDIRECT_BASE_URL`, 운영 https만) | 단위 "verifier 사용" |
| 4 | 다른 채널로 재연결해 프로젝트 채널이 바뀜 | `accounts.external_channel_id`(서버 전용 열)와 channels.list mine=true 결과가 다르면 OA001 거부 | SQL PASS 5, 단위 "다른 채널" |
| 5 | 같은 채널을 여러 계정·사용자에 연결(1 프로젝트 = 1 채널 우회) | (platform, external_channel_id) 전역 unique(팀장 잠정 결정) | SQL PASS 5, 단위 "channel_taken" |
| 6 | 범위 축소 동의로 반쪽 연결 | 필수 3개(upload·readonly·yt-analytics.readonly) 모두 있어야 저장(앱 + DB OA002). force-ssl 요청 안 함 | SQL PASS 4, 단위 "범위 누락" |
| 7 | 토큰 원문 노출(브라우저·로그·응답) | 갱신 토큰만 Vault, access token은 요청마다 발급·미저장. 응답은 결과 코드만 쿼리로, 오류 메시지에 토큰 없음. authenticated는 oauth_token_ref·external_channel_id 열 권한 없음 | SQL PASS 1·2·9, 단위 "원문 없음" |
| 8 | Vault 직접 접근 | private SECURITY DEFINER 본체(EXECUTE 전부 회수) + public 래퍼(service_role만). anon·authenticated는 래퍼·vault.decrypted_secrets 모두 42501 | SQL PASS 1·2 |
| 9 | 빈 refresh_token으로 기존 토큰 덮어쓰기 | 빈 값·null은 기존 secret 유지 | SQL PASS 4, 단위 "빈 refresh_token" |
| 10 | 폐기된 권한(invalid_grant)으로 계속 시도 | Vault 삭제 + status=reconnect_required | 단위 "invalid_grant" |
| 11 | 해제 후 토큰 잔존 | Google revoke(200·400) 후 Vault 삭제, 5xx·네트워크 실패면 Vault 유지하고 재시도 안내. accounts·api_keys 행 삭제 시 트리거가 Vault secret 삭제 | SQL PASS 7·8, 단위 "해제" |
| 12 | 다른 사이트에서 시작·해제 폼 전송(CSRF) | Origin 같은 호스트 또는 Sec-Fetch-Site≠cross-site, 세션 필수, 콜백 응답 no-store·no-referrer | 코드 리뷰 |

## 남은 위험·확인 필요
- 거부된 연결(범위 누락·다른 채널·이미 연결된 채널)의 새 토큰은 저장하지 않지만 **폐기하지 않는다**. Google revoke는 같은 Google 계정의 앱 권한 전체를 끊을 수 있어 기존 연결을 깨뜨릴 수 있기 때문. 팀장 확인 필요.
- 해제해도 `external_channel_id`는 남는다(계정은 같은 채널로만 재연결 가능, 그 채널은 계정을 지워야 다른 계정에 연결 가능).
- 테스트 모드 동의는 7일 뒤 만료 → invalid_grant → 재연결 필요로 바뀐다(04_API 3절).
- 데스크톱·모바일 앱(시스템 브라우저 + 1회용 교환 토큰, ADR-0005)은 W7.
- 회원 탈퇴(auth.users 삭제 → accounts cascade)는 트리거가 Vault만 지우고 Google revoke는 하지 않는다 → 회원 탈퇴 기능(추후)에서 탈퇴 전 해제 경로(`/api/oauth/youtube/disconnect` 로직)를 계정마다 호출한다.
- 늦게 도착한 invalid_grant: 갱신에 쓴 토큰 버전(oauth_token_ref, 새 토큰마다 새 secret)이 현재 값과 같을 때만 재연결 필요·Vault 삭제(`20261112270200`, SQL PASS 10·11, 단위 "늦게 온 invalid_grant"). access token 조회는 `getAccessToken(userId, accountId)`로 소유자 확인.
