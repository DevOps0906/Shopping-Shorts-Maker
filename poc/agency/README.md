# 대행 파이프라인 PoC (task-003)

- 실행: `python poc/agency/run.py --demo` — 합성 클립(testsrc2) 5개로 15·20초 MP4 2편 생성, ffprobe 검증, `out/costs.csv` 원가 표
- 실제 원본: `python poc/agency/run.py <cut_map.json>` — 형식은 `samples/demo_15s.json`(대사·원본 경로·구간, 경로는 JSON 기준 상대). task-002에서 권리 확인된 원본만 넣는다
- 흐름: 컷 자르기 → 9:16(1080x1920) 확대·중앙 크롭 → 이어 붙이기 → 음성(tts·tone·silent) → 컷별 한 줄 자막 → MP4
- TTS(Fish Audio)·LLM(Claude)은 `adapters.py` 인터페이스만, 기본 dry-run(호출 없음·청구 0원). `--live`는 아직 미구현
- 단가는 `config.json`에 사용자가 채운다(빈 값이면 예상 원가 비움). 원화는 올림한 정수 원
- 키는 `.env.example`의 이름으로 환경 변수에만 둔다. 요구 사항: Python 3.11, ffmpeg 8.1(PATH)
