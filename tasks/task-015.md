# task-015 확장: 연결·로그인 수집·출처 기록·waiting_extension

| 항목 | 내용 |
|---|---|
| 웨이브 | W3 |
| 선행 | task-012 |
| 위험도 | 높음 (위험 상위 3: 플랫폼 약관·화면 변경) |
| 보안 영향 | 노출 면(확장↔서버), 키·권한(확장 권한), 의존성 |
| 담당 | builder (착수 전 challenger) |
| 근거 | `docs/adr/0003-*.md`, `docs/planning.md#4`, `docs/planning.md#17-2`(D2), `docs/planning.md#17-8`, spec S-07(상태 배너) |
| 쓰기 허용 | `apps/extension/**`, `apps/web/src/app/api/extension/**` |

## 할 것
- 확장 연결(ADR 0003 인증 방식), 사용자 로그인 세션으로 틱톡·샤오홍슈 검색 결과 수집
- 원본마다 URL·작성자·수집 시각 기록, 결과는 "참고용·권리 미확인"
- 미연결·로그인 만료 시 job `waiting_extension` + 배너 "확장 프로그램 연결 필요"
- 위협 메모 표(security-baseline threat-model) 첨부

## 하지 않을 것
- 플랫폼 비밀번호·쿠키를 서버로 전송, 권한을 두 플랫폼·서비스 도메인 밖으로 확대
- 서버 측 무인 크롤링

## 완료 조건 (실행 가능한 확인)
- [ ] manifest 권한 도메인 목록이 17-8 범위와 일치(테스트로 검사)
- [ ] 미연결 상태 job이 waiting_extension → 연결 후 running 전이 테스트
- [ ] 수집 레코드 3필드 누락 0건 테스트, `secscan license` 통과
