# 대행 파이프라인 PoC (task-003)

- 실행: `python poc/agency/run.py --demo` — 합성 클립(testsrc2) 5개로 15·20초 MP4 2편 생성, ffprobe 검증, `out/costs.csv` 원가 표
- 실제 원본: `python poc/agency/run.py <cut_map.json>` — 형식은 `samples/demo_15s.json`(대사·원본 경로·구간, 경로는 JSON 기준 상대). 컷마다 `rights_basis` 필수: `own`(자체 촬영)·`seller`(판매자 제공)·`licensed`(허락받음)·`attribution`(D7: 판매자 회신 없이 출처 표기로 사용, 법적 허락 아님). `attribution` 컷은 `author`·`platform`·`url`이 있어야 하고 cut_map에 `"notice_ack": true`(화면의 노란 고지 확인 체크)가 있어야 렌더하며, `remove_watermark`는 거부한다. 예: `samples/demo_15s.json`(attribution)·`demo_20s.json`(own)
- 흐름: 컷 자르기 → 9:16(1080x1920) 확대·중앙 크롭 → 이어 붙이기 → 음성(tts·tone·silent) → 컷별 한 줄 자막 → MP4
- TTS(Fish Audio)·LLM(Claude)은 `adapters.py` 인터페이스만, 기본 dry-run(호출 없음·청구 0원). 기본 테스트는 테스트용 Google API 키로 한다: `--live`만 붙이면 `--llm gemini`가 기본(원본 분석+대본 초안, 실측 토큰을 costs.csv에 dry_run=false 행으로 기록). 키는 루트 `.env.local`의 `GEMINI_API_KEY`(또는 `GOOGLE_API_KEY`), 모델은 `config.json` `gemini.model`. Claude live는 미구현
- 이미지 이해(vision): 대본 초안 전 컷별 대표 프레임(`vision.frames_per_cut`, 기본 1)을 `out/<project>/frames/`에 뽑고 토큰을 ceil(w×h/750)(긴 변 1568px 초과 시 축소)로 추정해 `costs.csv`에 vision 행으로 기록(호출 없음, claude input 단가 사용)
- 단가는 `config.json`에 사용자가 채운다(빈 값이면 예상 원가 비움). 원화는 올림한 정수 원
- 키는 `.env.example`의 이름으로 환경 변수에만 둔다. 요구 사항: Python 3.11, ffmpeg 8.1(PATH)
- 출처 표기: cut_map 컷에 선택 필드 `author`·`platform`(tiktok·xiaohongshu)·`url`을 두면 컷마다 우하단에 `@author`를 작은 글씨로 계속 표기하고(없으면 생략), `out/<project>/credits.txt`에 설명란용 `영상 출처: @a(TikTok), @b(小红书)`(중복 제거)를 저장한다
- 원본 편수 시나리오: `--sources N`(기본 10)은 원본 N편 × 데모 컷 평균 길이로 Claude 프레임(초당 1장) 토큰과 Gemini 영상(ceil(초)×(70+오디오32)) 토큰을 `sources_N` 행으로 나란히 비교한다(dry-run, 호출 없음).
- `config.json`의 `gemini.free_tier`가 true면 Gemini는 0원이고 비고에 "무료 구간: 학습 활용·사람 검토 대상"을 남긴다. `pricing.gemini` 단가는 사용자가 채운다.
- 음성(테스트): `--tts gemini`(`--live`일 때 기본, dry-run 기본은 fish). `config.json` `gemini.tts_model`(`gemini-3.8-flash-lite-tts`)·`gemini.tts_voice`(`Kore`)로 PCM을 받아 wav로 저장해 렌더 음성으로 쓰고 usageMetadata 토큰을 costs.csv에 `gemini_tts` 행(dry_run=false)으로 기록한다. live 호출 최소화로 첫 cut_map만 실제 음성, 나머지는 톤 대체. Fish Audio 경로는 그대로(live 미구현). 단가는 `pricing.gemini_tts`, 비면 "단가 입력 전", `free_tier`면 0원
- 예상 비용 가정: `config.json` `estimate`(대본·소재·채팅 입력 2만·출력 3천 토큰, 원본 1편 15초, 프레임 720x1280)가 있으면 렌더 전 예상 비용 표(`out/estimate.csv`)를 이 값으로 계산한다. 화면 S-02·S-04 예시 금액(최저 약 27원 / 추천 약 102원 / Claude만 약 653원)과 같은 값이며, W0 실측 후 여기만 고치고 화면·문서 금액을 표 결과로 갱신한다. 비우면 cut_map 데모 값으로 계산
- 원본이 컷 길이보다 짧으면(예: 음성이 짧아 남는 시간이 마지막 컷에 몰릴 때) 마지막 프레임을 정지 화면으로 늘려 영상·음성 길이를 같게 맞춘다
