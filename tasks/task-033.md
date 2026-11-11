# task-033 모바일 앱(Capacitor): Android APK·iOS TestFlight·딥링크·권한

| 항목 | 내용 |
|---|---|
| 웨이브 | W7 |
| 선행 | task-028(웹 대시보드 운영 배포), task-005 ADR ⑤ |
| 위험도 | 높음 |
| 보안 영향 | 새 의존성(Capacitor·플러그인), 노출 면(앱 배포·딥링크), 키·권한(앱 서명 키스토어·Apple 인증서) |
| 담당 | builder (착수 전 challenger) |
| 근거 | `docs/planning.md#9`(로드맵 4), `docs/planning.md#17-2`(D11), task-005 ADR ⑤, `AGENTS.md#2`·`#4` |
| 쓰기 허용 | `apps/mobile/**`, `landing/**`(다운로드 영역), `.github/**`(릴리스 빌드), `.env.example` |

## 할 것
- Capacitor 최신 stable(작업 시점 확인 후 버전 고정)로 `apps/mobile` 생성(Android·iOS), ADR ⑤ 방식대로 운영 웹을 열고 탐색은 우리 도메인만
- 모바일 구간(~767) 화면 점검: 승인·발행·성과 확인 중심, 편집 화면은 웹과 같은 동작 확인
- 권한: 마이크(직접 녹음)·파일 선택(원본 추가)·알림(작업 완료), 로그인 세션 유지와 OAuth 딥링크 복귀
- 배포: Android 서명 APK/AAB(다운로드 페이지·Play 내부 테스트), iOS TestFlight. 앱스토어 "웹 감싸기" 거절 위험 대응(네이티브 알림·녹음 등 앱 고유 기능)을 ADR ⑤ 결론대로
- 랜딩 다운로드 영역에 Android·iOS 링크

## 하지 않을 것
- 앱 안에 LLM·결제 키 넣기
- 앱 결제(인앱 결제)는 이 작업 범위 밖
- 웹 화면 구조·토큰 변경

## 완료 조건 (실행 가능한 확인)
- [ ] CI에서 Android 서명 빌드 성공, 실제 기기 설치 → 로그인 → 승인 1회 스모크 테스트
- [ ] iOS TestFlight 업로드 성공(Apple 개발자 계정은 사용자 준비)
- [ ] OAuth 로그인 후 앱으로 복귀(딥링크) 확인
- [ ] `secscan license`·`secscan` 비밀 0건
