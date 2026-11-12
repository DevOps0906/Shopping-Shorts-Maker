# 04 API 명세

YouTube 절만 작성됨(task-007), 나머지는 W1 이후.

## YouTube

근거: [planning.md 12장](./planning.md#12-다중-계정과-채널-전략) · [13장](./planning.md#13-환경설정) · [15-2](./planning.md#15-2-업로드예약-발행) · [15-3](./planning.md#15-3-성과-분석) · [17-8](./planning.md#17-8-보안과-개인정보). 모든 항목은 공식 문서를 2026-11-12에 확인했다. 문서에서 찾지 못한 값은 `미확인`으로 적었다.

### 1. 쓰는 API 호출

| 기능 (기획 근거) | 메서드 | 쿼터 비용 | 공식 문서 | 확인일 |
|---|---|---|---|---|
| 업로드·예약 공개 (15-2) | `videos.insert` (`status.privacyStatus=private` + `status.publishAt`) | 업로드 전용 버킷에서 1회 1단위, 기본 하루 100회 | [videos.insert](https://developers.google.com/youtube/v3/docs/videos/insert) | 2026-11-12 |
| 예약 시각 변경·재설정 | `videos.update` | 일반 버킷 50단위 | [videos.update](https://developers.google.com/youtube/v3/docs/videos/update) | 2026-11-12 |
| 업로드 결과·처리 상태 조회 | `videos.list` | 일반 버킷 1단위 | [쿼터 계산표](https://developers.google.com/youtube/v3/determine_quota_cost) | 2026-11-12 |
| 연결한 채널 정보 (12장 계정 목록) | `channels.list` (`mine=true`) | 일반 버킷 1단위 | [channels.list](https://developers.google.com/youtube/v3/docs/channels/list) | 2026-11-12 |
| 업로드 직후 안내 댓글 (15-2) | `commentThreads.insert` | 일반 버킷 50단위 | [commentThreads.insert](https://developers.google.com/youtube/v3/docs/commentThreads/insert) | 2026-11-12 |
| 영상별 지표 (15-3: 조회수·평균 시청 비율) | YouTube Analytics `reports.query` (`views`, `averageViewPercentage`) | 미확인(문서에 쿼터 표기 없음) | [reports.query](https://developers.google.com/youtube/analytics/reference/reports/query) | 2026-11-12 |

- 예약 공개 조건: `publishAt`은 공개 상태가 `private`이고 한 번도 공개된 적 없는 영상에만 넣을 수 있다. `videos.update`로 바꿀 때도 `privacyStatus=private`를 함께 보내야 한다([videos 리소스](https://developers.google.com/youtube/v3/docs/videos)). 공개 상태를 빼먹으면 기본값이 `public`이므로 서버에서 항상 명시한다.
- **고정 댓글**: Data API에 댓글 고정 기능이 없다(미지원 확인: [comments](https://developers.google.com/youtube/v3/docs/comments)·[commentThreads](https://developers.google.com/youtube/v3/docs/commentThreads)에 pin 메서드·속성 없음, 2026-11-12). API로는 일반 댓글 작성까지만 가능하고, 고정은 사용자가 YouTube Studio에서 하도록 안내하는 안을 사용자 판단으로 넘긴다.

### 2. 최소 OAuth 범위

| 범위 | 쓰는 곳 | 필요 여부 | 공식 문서 | 확인일 |
|---|---|---|---|---|
| `youtube.upload` | `videos.insert`(예약 공개 포함) | **필수** | [videos.insert 인증](https://developers.google.com/youtube/v3/docs/videos/insert) · [범위 목록](https://developers.google.com/identity/protocols/oauth2/scopes) | 2026-11-12 |
| `youtube.readonly` | `channels.list mine=true`, Analytics `reports.query`(문서: "now require access to the youtube.readonly scope") | **필수** | [reports.query](https://developers.google.com/youtube/analytics/reference/reports/query) | 2026-11-12 |
| `yt-analytics.readonly` | Analytics 지표 조회(수익 지표 제외) | **필수** | [Analytics 인증](https://developers.google.com/youtube/reporting/guides/authorization) | 2026-11-12 |
| `youtube.force-ssl` | `commentThreads.insert`, `videos.update`(upload 범위로는 불가, `youtube`·`youtubepartner`·`youtube.force-ssl` 중 하나 필요) | 선택(권장: MVP 제외) | [commentThreads.insert](https://developers.google.com/youtube/v3/docs/commentThreads/insert) · [videos.update](https://developers.google.com/youtube/v3/docs/videos/update) | 2026-11-12 |
| `youtube` (전체 관리) | — | 요청하지 않음 | [범위 목록](https://developers.google.com/identity/protocols/oauth2/scopes) | 2026-11-12 |
| `yt-analytics-monetary.readonly` | 광고 수익 지표 | 요청하지 않음(제휴 수익은 자체 단축 링크로 셈) | [Analytics 인증](https://developers.google.com/youtube/reporting/guides/authorization) | 2026-11-12 |

- `youtube.force-ssl`은 "영상·댓글·자막을 보고 수정하고 영구 삭제"까지 포함하는 넓은 범위다. 이것을 빼면 예약 시각 변경(`videos.update`)과 자동 댓글이 안 되므로, MVP는 **예약 시각을 업로드 전에 확정**하고 변경 시에는 "YouTube Studio에서 변경" 안내로 처리하는 안을 제안한다(17-8 "최소 범위" 원칙).
- 17-8대로 state + PKCE를 쓰고, 연결 해제 시 토큰 폐기 후 Vault에서 삭제한다.

### 3. 앱 검증·API 감사 요건

| 항목 | 현행 내용 | 공식 문서 | 확인일 |
|---|---|---|---|
| OAuth 앱 검증 | 운영(Production) 앱은 민감·제한 범위를 요청하기 전에 검증을 받아야 한다. 민감 범위 검증은 브랜드 검증 + 데모 영상(동의 화면·앱 이름·클라이언트 ID·범위별 기능, YouTube에 일부 공개로 올림) + 범위별 사유서 | [OAuth 앱 검증](https://support.google.com/cloud/answer/13464321) · [민감 범위 검증](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification) | 2026-11-12 |
| YouTube 범위의 등급(민감/제한) | 공식 문서에 범위별 등급 표가 없다. 민감 범위 예시에 "YouTube 영상 삭제"가 나온다. 정확한 등급은 Cloud Console 데이터 액세스 화면에서 확인 필요 → **미확인** | [민감 범위 검증](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification) | 2026-11-12 |
| 검증 소요 기간 | 민감 범위 검증은 "최대 10일", 브랜드 자동 검토는 보통 몇 분. 제한 범위면 연 1회 보안 평가 추가(YouTube 범위 해당 여부 미확인) | 같은 문서 · [OAuth 앱 검증](https://support.google.com/cloud/answer/13464321) | 2026-11-12 |
| 검증 전(테스트 모드) | 테스트 사용자 최대 100명, 테스트 사용자 동의는 7일 뒤 만료(refresh token 포함). 미검증 앱 화면을 띄운 앱은 신규 사용자 누적 100명 상한 | [테스트·게시 상태](https://support.google.com/cloud/answer/15549945) | 2026-11-12 |
| YouTube API 감사 | 기본 쿼터를 넘는 증설을 요청할 때만 감사가 필요하다("you must first complete an audit"). 감사는 개발자 정책 준수를 확인. 처리 기간은 문서에 없음(**미확인**) | [쿼터·준수 감사](https://developers.google.com/youtube/v3/guides/quota_and_compliance_audits) · [감사·증설 신청서](https://support.google.com/youtube/contact/yt_api_form) · [개발자 정책](https://developers.google.com/youtube/terms/developer-policies) | 2026-11-12 |
| **감사 전 업로드 비공개 제한** | **해제됨.** 2026-11-02 개정: 미검증 프로젝트에서 `videos.insert`로 올린 영상은 더 이상 비공개로 제한되지 않는다(2020-07-28 정책 철회). videos.insert 문서에도 같은 문장 | [개정 이력 2026-11-02](https://developers.google.com/youtube/v3/revision_history) · [videos.insert](https://developers.google.com/youtube/v3/docs/videos/insert) | 2026-11-12 |

### 4. 쿼터

| 항목 | 값 | 공식 문서 | 확인일 |
|---|---|---|---|
| 일반 버킷 기본 할당 | 프로젝트당 하루 10,000단위 (`videos.insert`·`search.list` 제외 전체) | [쿼터 계산표](https://developers.google.com/youtube/v3/determine_quota_cost) | 2026-11-12 |
| 업로드 버킷 | `videos.insert` 전용, 기본 하루 100회(1회 1단위). 2026-06-01부터 별도 버킷 | [쿼터 계산표](https://developers.google.com/youtube/v3/determine_quota_cost) · [개정 이력 2026-06-01](https://developers.google.com/youtube/v3/revision_history) | 2026-11-12 |
| 초기화 시각 | 매일 태평양 시간 자정(한국 시간 오후 4시 또는 5시) | [쿼터 계산표](https://developers.google.com/youtube/v3/determine_quota_cost) | 2026-11-12 |
| Analytics API 쿼터 | **미확인**(reports.query 문서에 표기 없음) | [reports.query](https://developers.google.com/youtube/analytics/reference/reports/query) | 2026-11-12 |

- 참고: 개정 이력의 2025-12-04 항목은 업로드 1건을 "약 1600단위 → 약 100단위"로 낮췄다고 적었고, 현행 videos.insert 문서는 "업로드 버킷 1단위"로 적는다. 현행 문서 기준으로 계산한다.
- 쿼터는 **사용자별이 아니라 우리 Google Cloud 프로젝트 하나에 합산**된다. 모든 베타 사용자의 업로드가 하루 100회를 나눠 쓴다.

**업로드 1건 비용(MVP 최소 범위 기준)**: 업로드 버킷 1회 + 일반 버킷 약 3단위(`videos.list` 상태 확인 3회 가정). 자동 댓글을 켜면 일반 버킷 +50, 예약 변경 1회마다 +50.

**베타 판정**: 20명×30편 = 600편을 30일에 나누면 하루 평균 20회 → 업로드 버킷 100회의 20%, 일반 버킷은 댓글까지 켜도 20×53 ≈ 1,060단위(10,000의 약 11%)로 **충분**. 단, 하루 100편을 넘게 몰아 올리면 초과하므로 서버가 프로젝트 전체 일일 업로드 수를 세고 초과분은 다음 날(PT 자정 이후)로 미룬다.

### 5. 일정 판정

**감사 일정이 W4 착수 전에 끝나는지: 해당 없음(통과).** 비공개 제한이 2026-11-02에 풀렸고 베타 규모는 기본 쿼터 안이라 YouTube API 감사가 필요 없다. 남는 일정 위험은 OAuth 민감 범위 검증(최대 10일, 반려 시 재제출)뿐이므로 **W4 착수 최소 2주 전**에 데모 영상과 함께 신청해야 한다(W4 착수일은 00_LEAN 통과 전이라 미정).

### 6. 팀장 확인 필요

1. 고정 댓글은 API 미지원(확인)이므로 15-2 "고정 댓글" 스위치를 "댓글 자동 작성(+`youtube.force-ssl`)" 또는 "Studio에서 직접 고정 안내" 중 하나로 바꿔야 한다.
2. MVP에서 `youtube.force-ssl`을 빼면 예약 시각 변경을 앱에서 못 한다. 범위를 넓힐지 결정 필요.
3. YouTube 범위의 민감/제한 등급과 Analytics 쿼터는 Cloud Console에서 프로젝트를 만든 뒤 직접 확인한다(task-022 착수 시).
