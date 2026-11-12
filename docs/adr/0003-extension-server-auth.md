# ADR-0003 확장 ↔ 서버 인증·통신
- 상태: 제안 · 날짜: 2026-11-12 · 근거: `docs/planning.md#17-2`(D2) · `#17-5` · `#17-8`

## 맥락
MVP 수집은 사용자 브라우저 확장(Chrome MV3)에서 돈다. 확장은 Supabase 세션을 직접 갖지 않고, 플랫폼 쿠키·비밀번호를 서버로 보내면 안 된다(17-8).

## 결정
- 연결: 로그인한 웹의 **연결 페이지 1곳**이 서버에서 확장 전용 자격을 받아 `externally_connectable`(서비스 도메인만)로 확장에 전달. Supabase 액세스·리프레시 토큰은 넘기지 않는다.
- 통신: 확장 → Next.js Route Handler(`Authorization: Bearer`)만. 하트비트 30초, 작업 수령(claim)·결과 업로드는 작업별 서명 업로드 URL. 서버가 매 요청마다 토큰·사용자·`job` 소유권을 다시 검사한다.
- `waiting_extension` 전이(수집 작업만): `queued`→`waiting_extension` = 생성 시 최근 60초 하트비트 없음 · `waiting_extension`→`running` = 확장이 claim 성공 · `running`→`waiting_extension` = 하트비트 2분 끊김(진행분 보존) · →`failed` = 수집 상한 15분 초과 또는 대기 24시간(가설) · →`canceled` = 사용자 취소·앞 단계 변경. 시간 감시는 ADR-0001의 스위퍼.

## 보안·운영 조건
- 자격은 사실상 bearer: **액세스 토큰 15분 + 갱신 토큰 30일**(갱신 시 회전, 재사용 감지되면 전체 폐기). DB엔 해시만.
- claim은 원자적: `update jobs set status='running', extension_id=$2 where id=$1 and status='waiting_extension'` 1행일 때만 성공(확장 2대 경쟁 방지).
- `onMessageExternal`에서 `sender.origin`과 `sender.url` 경로를 연결 페이지로 고정, 그 외 메시지 무시.
- 확장 팝업에 연결된 계정(이메일 일부)과 연결 해제 버튼 표시. 웹 설정에도 연결된 확장 목록·폐기.
- CORS: 확장 API는 Bearer 전용, 쿠키 폴백 없음(`credentials` 미허용) → CSRF 면 제거.
- 업로드 크기: 서명 업로드 URL은 URL별 크기 상한을 걸 수 없으므로 수집 버킷 `file_size_limit`(가설 200MB)와 `allowed_mime_types`(video/mp4·quicktime·webm)로 막는다. `succeeded` 전에 서버가 ADR-0002 샌드박스에서 ffprobe로 다시 검사.

## 위협 메모
| 위협 | 대응 |
|---|---|
| 다른 사이트·다른 페이지가 확장에 메시지 위장 | 도메인 고정 + `sender.url` 경로 고정 |
| 확장 토큰 탈취·재사용 | 짧은 TTL·갱신 회전·폐기, 해시 저장, 요청 속도 제한 |
| 남의 `job_id`로 업로드(IDOR) | 서버에서 소유권·상태 검사, RLS, 원자적 claim |
| 악성·초대형 파일 업로드 | 버킷 크기·MIME 상한, 샌드박스 ffprobe 재검사 |
| 플랫폼 쿠키·비밀번호 유출 | 확장은 메타데이터·영상 파일만 전송, 권한은 틱톡·샤오홍슈·서비스 도메인만 |

## 대안
쿠키 공유(확장이 웹 세션 쿠키 사용): 권한 과다·CSRF 위험으로 거부. 페어링 코드 수동 입력: 연결 UX가 나빠 차선.

## 버전·라이선스
Chrome Manifest V3 · 새 의존성 없음.

## 보강(2026-11-12)
근거: challenger 검토, 사용자 결정 D13(`docs/planning.md#17-2`). 작업: `tasks/task-015.md`(015a~d).
- ① **D8 3단계**: `collect`(확장, 목록·썸네일) → `select_sources`(워커, 썸네일 기준 점수·상위 20편) → 사용자 체크 10편 `collect_download`(확장, 파일) → 워커 ffprobe 재검사 후 `succeeded`. 두 확장 작업 모두 아래 전이를 따른다.
- ② **수집 방식(D13)**: 사용자가 연 틱톡·샤오홍슈 탭에서만, 사람 속도, 백그라운드 자동 수집 없음. 캡차·위험 제어 감지 시 즉시 중단하고 사유를 배너에 표시. 영상은 플랫폼이 주는 워터마크 포함 사본만(워터마크 없는 재생 사본 금지, AGENTS 4장). 배포 방식은 task-028, 개발·베타는 수동 설치.
- ③ **전이 정본**: 하트비트 2분 끊김은 `running`→`waiting_extension`(진행분 보존, 결정 본문대로). 24시간은 `jobs.waiting_since`(대기 진입 시각) 기준. 기존 `sweep_jobs`의 `failed` 처리·`created_at` 기준은 새 마이그레이션으로 교체한다.
- ③ **claim·전달**: claim 조건에 `확장.user_id = 프로젝트 소유자`·`revoked_at is null` 추가. 대기 job은 하트비트 응답으로 전달(별도 폴링 없음).
- ③ **수집 데이터 위조 방지**: platform은 서버가 정규화 URL의 호스트로 결정, URL 정규화(쿼리·조각·userinfo 제거·거부), `collected_at`은 서버 시각, 틱톡은 URL `@handle` = author, 필드 허용 목록, 검사는 직접 추가와 같은 DB 함수(`private.has_unsafe_chars` 등) 재사용.
- ④ **host_permissions**: 틱톡·샤오홍슈 웹 호스트와 영상·이미지 CDN 호스트만. CDN 목록은 구현 시 실측 후 확정해 task-015d에 근거와 함께 기록. Storage 업로드는 서비스 도메인 경유 서명 URL이라 Supabase 호스트 권한을 따로 두지 않는다. `<all_urls>`·`cookies`·`webRequest` 금지.
- ⑤ **MV3 운영**: 하트비트는 `chrome.alarms` 30초. 토큰 보관 위치·회전 유예 시간은 팀장 결정 필요. 파일은 파일 단위 스트림 업로드, 끊기면 그 파일만 재시도.
- ⑤ **업로드 상한 통일**: 위 "업로드 크기"의 200MB(가설)와 `sources` 버킷 500MiB 중 하나로 통일(팀장 결정 필요). 썸네일은 이미지 MIME 전용 버킷.

| 추가 위협 | 대응 |
|---|---|
| 확장이 platform·URL·시각·작성자 위조 | ③ 서버 결정·정규화·DB 함수 검사 |
| 다른 사용자 job claim | ③ 소유자 조건 |
| 워터마크 없는 사본으로 권리 우회 · 대량 수집으로 계정 제재 | ② 사용자 탭·사람 속도·워터마크 사본만 |
