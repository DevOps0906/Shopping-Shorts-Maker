# 작업 표

| 번호 | 제목 | 웨이브 | 선행 | 위험도 | 담당 | 상태 |
|---|---|---|---|---|---|---|
| [task-001](task-001.md) | 랜딩·사전예약 폼 | W0 | — | 보통 | builder | 대기 |
| [task-002](task-002.md) | 권리 확인 원본 7편 확보 실측(제품 3종)·전문가 검토 의뢰 | W0 | — | 보통 | planner | 대기 |
| [task-003](task-003.md) | 대행 파이프라인·TTS 6종·원가 측정(권리 확인 원본만) | W0 | 002 | 높음 | builder | 대기 |
| [task-004](task-004.md) | 문서 정합(D1~D5·7편 규칙·권리 동의 문구) | W1 | 002 | 낮음 | planner | 보류(00_LEAN 통과 후) |
| [task-005](task-005.md) | ADR: Supabase Queues·워커 언어·확장 통신·셀프 호스팅 구성 | W1 | 004 | 높음 | planner | 보류(00_LEAN 통과 후) |
| [task-006](task-006.md) | 스키마·RLS 표(권리 근거·확인자·삭제 예정일) | W1 | 004 | 높음 | planner | 보류(00_LEAN 통과 후) |
| [task-007](task-007.md) | YouTube OAuth·업로드·분석 API 요건·쿼터 조사 | W1 | 004 | 높음 | planner | 보류(00_LEAN 통과 후) |
| [task-008](task-008.md) | 프로젝트 생성·토큰·3구간·대시보드 셸·라우트(+ /secure setup) | W2 | 005 | 높음 | builder | 보류(00_LEAN 통과 후) |
| [task-009](task-009.md) | Supabase Auth·로그인·세션 | W2 | 008, 030 | 높음 | builder | 보류(00_LEAN 통과 후) |
| [task-010](task-010.md) | 마이그레이션1 사용자·채널·프로젝트·카테고리·trend_items·이벤트 | W2 | 006, 009, 030 | 높음 | builder | 보류(00_LEAN 통과 후) |
| [task-011](task-011.md) | 마이그레이션2 제작·jobs·credit_ledger·발행·성과·비공개 버킷 | W2 | 010 | 높음 | builder | 보류(00_LEAN 통과 후) |
| [task-012](task-012.md) | 큐·워커 골격·멱등·재시도·취소·크레딧 기록 | W2 | 005, 011, 030 | 높음 | builder | 보류(00_LEAN 통과 후) |
| [task-013](task-013.md) | 6단계 상태 머신·승인·초기화·Realtime·StepStepper·StatusBanner | W2 | 008, 011 | 보통 | builder | 보류(00_LEAN 통과 후) |
| [task-014](task-014.md) | 홈·새 프로젝트·프로젝트 관리·트렌드(시드) | W3 | 013 | 보통 | builder | 보류(00_LEAN 통과 후) |
| [task-015](task-015.md) | 확장: 연결·로그인 수집·출처 기록·waiting_extension | W3 | 012 | 높음 | builder | 보류(00_LEAN 통과 후) |
| [task-016](task-016.md) | 소스 서버: 프레임 일치·점수·20편 선정 | W3 | 012 | 높음 | builder | 보류(00_LEAN 통과 후) |
| [task-017](task-017.md) | 02 소스: SourceGrid·기본 체크 해제·권리 근거·직접 추가·승인 규칙 | W3 | 013, 016 | 높음 | builder | 보류(00_LEAN 통과 후) |
| [task-018](task-018.md) | 01 소재·03 대본: LLM·ScriptEditor·금지 표현 | W3 | 013 | 높음 | builder | 보류(00_LEAN 통과 후) |
| [task-019](task-019.md) | 04 목소리: Fish Audio·VoicePicker·녹음·단어 타이밍 | W3 | 012, 013 | 높음 | builder | 보류(00_LEAN 통과 후) |
| [task-020](task-020.md) | 05 편집: 컷 매칭·크롭 렌더·CutTimeline·버전(스케일업·제거 비활성) | W3 | 017, 019 | 높음 | builder | 보류(00_LEAN 통과 후) |
| [task-021](task-021.md) | 제작 파트너: ChatFab·도구 6종(승인·발행·권리 도구 없음) | W3 | 016, 018, 019, 020 | 높음 | builder | 보류(00_LEAN 통과 후) |
| [task-022](task-022.md) | 다중 계정·YouTube OAuth·Vault·API 키 탭·내 채널 | W4 | 007, 011 | 높음 | builder | 보류(00_LEAN 통과 후) |
| [task-023](task-023.md) | 06 발행 화면: 제휴·링크인바이오·정책 점검 6항목 | W4 | 013, 017 | 보통 | builder | 보류(00_LEAN 통과 후) |
| [task-024](task-024.md) | YouTube 예약 업로드·3회 재시도·발행 30일 후 원본 삭제 | W4 | 012, 022, 023 | 높음 | builder | 보류(00_LEAN 통과 후) |
| [task-025](task-025.md) | 성과 수집·단축 링크·성과 화면 | W4 | 011, 022 | 높음 | builder | 보류(00_LEAN 통과 후) |
| [task-026](task-026.md) | RLS·Vault·권리 게이트·AI 금지 도구 보안 테스트 | W5 | 021, 024 | 높음 | tester | 보류(00_LEAN 통과 후) |
| [task-027](task-027.md) | 6단계 E2E·실패 시나리오·3구간 UI 회귀 | W5 | 021, 024, 025 | 보통 | tester | 보류(00_LEAN 통과 후) |
| [task-028](task-028.md) | 운영 배포·보안 L2·전문가 검토 통과 게이트 | W6 | 026, 027, 031 | 높음 | builder | 보류(00_LEAN 통과 후) |
| [task-029](task-029.md) | 베타 20명·30편 측정 | W6 | 028 | 보통 | planner | 보류(00_LEAN 통과 후) |
| [task-030](task-030.md) | Docker Compose 개발 스택(Supabase 셀프 호스팅·웹·워커) | W2 | 005 | 높음 | builder | 보류(00_LEAN 통과 후) |
| [task-031](task-031.md) | 운영 서버 셀프 호스팅: 프록시 TLS·방화벽·키 회전·백업/복구·모니터링·업그레이드 | W6 | 026 | 높음 | builder | 보류(00_LEAN 통과 후) |

상태: 대기 / 진행 / 완료 / 보류

- 병렬 묶음: 001·002 / 005·006·007 / 008·030 / 012·013 / 014·015·016·018·019 / 022·023 / 026·027 / 027·031
- 위험 상위 3: 015 확장 수집(약관·화면 변경) · 017 권리 게이트 · 024 YouTube 업로드(API 감사 전 비공개 제한 가능성, 007에서 현행 확인)

## 발견한 문제 (범위 밖 — 나중 작업 후보)
| 날짜 | 위치 | 내용 | 제안 |
|---|---|---|---|

## 교훈 (다음 작업에 그대로 적용할 것만, 20줄 이내 유지)
- 
