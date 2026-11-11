# NOW — 재진입 스냅샷 (30줄 이내, 매 작업 끝에 덮어쓴다)

- 갱신: 2026-11-12
- 현재 작업: W0 task-001·002·003 — 상태: 002 결정 확정, 사용자 실측·발송 대기
- 마지막으로 한 일: task-002 확정(P1 생활·수납 압축팩 / P2 주방 밀폐용기 / P3 생활가전 보풀제거기, 회신 10일·구입비 제품당 5만·합계 15만·클립 2초↑·의뢰서 전체 발송). D7(사용자 결정): 원작자 허락 대신 출처 표기 + 노란 고지 확인 체크(체크해야 승인) + 경고 메일 대처 팁(접이식 7단계), 제작 파트너가 상위 7편 미리 체크, 영상 우하단·설명란 출처 자동 표기, 워터마크 제거는 출처 표기 원본에 금지, 정책 점검 2번 "출처 표기·고지 확인"으로 변경. 반영: planning 3장 02, design.md, 03_SCREENS_UX, spec.json·S-07 와이어(plan2spec 재생성), 프로토타입, 의뢰서 A2-1을 D7 위험 질문으로 교체. PoC 영상 우하단 @작성자 표기·credits.txt 저장 완료(데모 재실행 통과). task-003 원가 표에 이미지 이해(vision) 항목 추가 완료(dry-run 추정, 컷당 프레임 1장, 데모 편당 약 6,268 토큰)
- 추가(2026-11-12 오후): D8 "20편 검색(목록) → 체크 10편만 다운로드 → 5편 사용, 승인 5편·예외 3~4편" 반영(planning 1·3·4·7장·오류표, design, 03, 프로토타입 dlLabel, spec). D9 "제작 전 모델별 AI 예상 비용" 반영(S-02 표·S-04 선택 바, 예시 단가 최저 약 30원/추천 약 160원/Claude만 약 1,020원). PoC: Gemini 영상 dry-run·--sources N·렌더 전 estimate 표(out/estimate.csv) 추가, 10편 기준 토큰 Claude 프레임 50,144 vs Gemini 4,080
- Gemini 실호출: 사용자 무료 키가 루트 .env.local(GEMINI_API_KEY 또는 GOOGLE_API_KEY, 내용 열람 금지·권한 차단됨). `run.py --demo --live --llm gemini` 성공(gemini-2.5-flash, 실측 입력 4,771·출력 311·thinking 1,851 토큰, 0원). 합성 클립만 전송. 키 유출 검사 0건. 독립 보안 리뷰(Codex) 지적 5건 반영 완료: 생성 POST는 결과 불명 시 재시도 안 함(429만 1회), 본문 20MB 검사, 어댑터 dry_run 차단, 단가 미상은 빈칸, 렌더 시간에서 API 대기 제외. tests/test_gemini.py 5건 통과. .env.example 변경은 사용자가 이름만 추가됐는지 확인 필요
- 다음 한 걸음: 사용자가 A 판매자 연락·B 제품 구입/촬영·법률 의뢰 발송 → 실측 표 기록 → 00_LEAN
- 열린 결정(사용자 확인 필요):
  - task-001: 폼 서비스·방문 집계 도구 계정(config.js FORM_URL·ANALYTICS_SNIPPET), 정책 문구 확인
  - task-003: API 방식(OpenRouter / Anthropic 직접)과 키, 단가, Fish Audio 목소리 6종 reference_id
  - 법률 검토: 수신처·회신 기한·비용
  - 00_LEAN 기준 ②(원본 7편)를 D7·D8(사용 5편)에 맞출지
  - 화면 예시 금액(대본 2만/3천 토큰 가정)과 PoC dry-run(대본 158토큰)이 달라 실측 후 한쪽으로 통일
- 주의: D7은 법적 허락이 아님 — 법률 검토 회신으로 재판단. 00_LEAN 기준 ②(권리 확인 원본 7편)는 D7과 의미가 어긋나 사용자 판단 필요. W1~W6은 00_LEAN 통과 전 보류. C 경로를 뺐으므로 기준 ②(2개 카테고리 7편)는 A+B만으로 채워야 함. plan2spec은 docs/diagrams에 flow·sitemap도 쓰므로 필요 없으면 되돌릴 것. 경고 색은 주의 토큰(#FFF4D6/#7A4E00) — 순수 노랑 글자는 대비 부족. 프로토타입 변경은 JS 문법 검사만, 화면 확인은 미실시. 실제 API 연결 시 task-003 독립 코드 리뷰 필요
- SDLC 단계: 01 검증(W0) 진행 중
- 담당 모델/역할: 팀장 · Opus 5.5 / builder
- 수정 파일(미커밋): design/prototype/Main.dc.html, design/spec.json, design/wireframes/S-07.html, docs/03_SCREENS_UX.md, docs/design.md, docs/planning.md, docs/w0/*.md, poc/agency/(README·adapters·config·run·samples), tasks/NOW.md
- 테스트 상태: 프로토타입 스크립트 node --check 통과, S-07 와이어 캡처 확인, poc --demo 재실행 통과(vision 행 포함)
- 남은 작업: 위 열린 결정, /token-audit, /secure setup(task-008에 포함)
