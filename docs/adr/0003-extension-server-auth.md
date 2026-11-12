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
