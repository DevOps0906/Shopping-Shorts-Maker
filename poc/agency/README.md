# 대행 파이프라인 PoC (task-003)

- 실행: `python poc/agency/run.py --demo` — 합성 클립(testsrc2) 5개로 15·20초 MP4 2편 생성, ffprobe 검증, `out/costs.csv` 원가 표
- 실제 원본: `python poc/agency/run.py <cut_map.json>` — 형식은 `samples/demo_15s.json`(대사·원본 경로·구간, 경로는 JSON 기준 상대). task-002에서 권리 확인된 원본만 넣는다
- 흐름: 컷 자르기 → 9:16(1080x1920) 확대·중앙 크롭 → 이어 붙이기 → 음성(tts·tone·silent) → 컷별 한 줄 자막 → MP4
- TTS(Fish Audio)·LLM(Claude)은 `adapters.py` 인터페이스만, 기본 dry-run(호출 없음·청구 0원). 기본 테스트는 테스트용 Google API 키로 한다: `--live`만 붙이면 `--llm gemini`가 기본(원본 분석+대본 초안, 실측 토큰을 costs.csv에 dry_run=false 행으로 기록). 키는 루트 `.env.local`의 `GEMINI_API_KEY`(또는 `GOOGLE_API_KEY`), 모델은 `config.json` `gemini.model`. Claude live는 미구현
- 이미지 이해(vision): 대본 초안 전 컷별 대표 프레임(`vision.frames_per_cut`, 기본 1)을 `out/<project>/frames/`에 뽑고 토큰을 ceil(w×h/750)(긴 변 1568px 초과 시 축소)로 추정해 `costs.csv`에 vision 행으로 기록(호출 없음, claude input 단가 사용)
- 단가는 `config.json`에 사용자가 채운다(빈 값이면 예상 원가 비움). 원화는 올림한 정수 원
- 키는 `.env.example`의 이름으로 환경 변수에만 둔다. 요구 사항: Python 3.11, ffmpeg 8.1(PATH)
- 출처 표기: cut_map 컷에 선택 필드 `author`·`platform`(tiktok·xiaohongshu)·`url`을 두면 컷마다 우하단에 `@author`를 작은 글씨로 계속 표기하고(없으면 생략), `out/<project>/credits.txt`에 설명란용 `영상 출처: @a(TikTok), @b(小红书)`(중복 제거)를 저장한다
- 원본 편수 시나리오: `--sources N`(기본 10)은 원본 N편 × 데모 컷 평균 길이로 Claude 프레임(초당 1장) 토큰과 Gemini 영상(ceil(초)×(70+오디오32)) 토큰을 `sources_N` 행으로 나란히 비교한다(dry-run, 호출 없음).
- `config.json`의 `gemini.free_tier`가 true면 Gemini는 0원이고 비고에 "무료 구간: 학습 활용·사람 검토 대상"을 남긴다. `pricing.gemini` 단가는 사용자가 채운다.
