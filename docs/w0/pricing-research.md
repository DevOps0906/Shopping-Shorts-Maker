# W0 원가 실측용 공식 단가 조사

> 작성일 2026-11-12. 용도: `poc/agency/config.json` 단가 채우기. 모든 금액 USD, 토큰 단가는 100만 토큰당.
> 확인일은 모두 2026-11-12. 공식 페이지에서 확인하지 못한 값은 "미확인"으로 둔다.

## 1. Gemini API (유료 등급 기준)
출처: https://ai.google.dev/gemini-api/docs/pricing (→ https://aistudio.google.com/docs/pricing 로 이동됨)

| 모델 | 입력(텍스트·이미지·영상) | 입력(오디오) | 출력(thinking 포함) | 비고 |
|---|---|---|---|---|
| gemini-2.5-flash | 0.30 | 1.00 | 2.50 | 지원 종료 예정. 2026-12-01부터 요청이 gemini-3.5-flash-lite로 넘어가고 그 단가로 과금 |
| gemini-2.5-flash-lite | 0.10 | 0.30 | 0.40 | |
| gemini-3.8-flash (최신 Flash) | 0.75 (2027-01-01부터 1.50) | 별도 표기 없음 | 3.75 (2027-01-01부터 7.50) | |
| gemini-3.5-flash-lite (최신 Flash-Lite) | 0.30 | 0.30 | 2.50 | |

- thinking 토큰: 네 모델 모두 출력 단가에 포함된다. 즉 thinking 토큰도 출력 단가로 과금한다.
- 무료 등급: 네 모델 모두 입력·출력 무료. 다만 무료 등급에서는 데이터가 "Used to improve our products: Yes"(제품 개선에 사용), 유료 등급은 "No".
- 무료 등급 호출 한도(RPM·TPM·RPD): 미확인. 공식 한도 페이지(https://aistudio.google.com/docs/rate-limits)는 모델별 수치를 AI Studio(https://aistudio.google.com/rate-limit)에서만 보여 준다.

## 2. Claude API
출처: https://platform.claude.com/docs/en/about-claude/pricing

| 모델 | 입력 | 출력 |
|---|---|---|
| Claude Sonnet 5.5 (최신 Sonnet) | 2 | 10 |
| Claude Haiku 5.5 (최신 Haiku, 프롬프트 10만 토큰 이하) | 0.10 | 0.50 |
| Claude Haiku 5.5 (프롬프트 10만 토큰 초과) | 0.50 | 2.50 |
| Claude Haiku 4.5 (참고) | 1 | 5 |

## 3. Fish Audio TTS
출처: https://docs.fish.audio/developer-guide/models-pricing/pricing-and-rate-limits · https://docs.fish.audio/developer-guide/models-pricing/models-overview

- 과금 단위: 입력 텍스트의 UTF-8 바이트 수(100만 바이트 단위). 한글 1글자는 UTF-8로 3바이트라서, 같은 글자 수의 영어보다 약 3배 비싸다(UTF-8 인코딩 사실에 따른 계산이며 공식 문서에 적힌 내용은 아니다).
- 단가: s2.1-pro 15.00 · s2-pro 15.00 · s1(2026-12-31 종료) 15.00 · s2.1-pro-free 0.00 · drama-3 50.00(2026-11-30까지 10.00 할인).
- s2.1-pro-free는 s2.1-pro와 품질·언어 범위가 같다고 공식 문서에 적혀 있다. 사용 한도와 조건: 미확인.
- 한국어 지원: S1은 지원 언어 13개 목록에 한국어가 있다. S2.1-Pro(83개 언어)·S2-Pro(80개 이상)는 목록이 공개되지 않아 한국어 지원 여부는 미확인 → 실호출로 확인해야 한다.
- 한국어 목소리 찾기: 목소리 탐색 페이지(https://fish.audio/app/discovery)의 언어 필터로 Korean을 고른다. 목소리 페이지 URL `fish.audio/m/<ID>`의 `<ID>`를 `reference_id`로 쓴다. Fish Audio가 직접 만든 "공식" 목소리를 따로 구분하는 표시가 있는지는 미확인(웹 검색 결과로만 확인).

## 4. 원/달러 환율
- **1,336.9원/USD** (2026-11-11, ECB 기준 환율). 출처: https://api.frankfurter.dev/v1/latest?from=USD&to=KRW
- 참고: 서울 외환시장 2026-11-04 15:30 기준가 1,341.5원(연합뉴스, https://www.koreancenter.or.kr). 서울외국환중개 매매기준율: 미확인(사이트 접속 실패).

## 5. config.json 제안값
gemini는 현재 설정 모델 gemini-2.5-flash 기준이다. 2026-12-01 이후 넘어가는 3.5-flash-lite도 텍스트·영상 입력과 출력 단가가 같다. claude는 Sonnet 5.5 기준이고, Haiku 5.5를 쓰면 0.10 / 0.50이다.
```json
{
  "usd_krw": "1336.9",
  "pricing": {
    "claude": { "input_per_1m_tokens_usd": "2", "output_per_1m_tokens_usd": "10" },
    "gemini": { "input_per_1m_tokens_usd": "0.30", "output_per_1m_tokens_usd": "2.50" },
    "fish_audio": { "billing_unit": "utf8_bytes", "per_1m_units_usd": "15.00" }
  }
}
```

## 6. 영상 1편 예상 원가 (합성 데모 실측값, 유료 등급)
실측값: Gemini 입력 4,771 · 출력 311 · thinking 1,851토큰, 음성 179바이트. 이 데모에는 Claude 호출이 없어서 Claude 비용은 0이다.
- Gemini 입력 = 4,771 × 0.30 / 1,000,000 = $0.0014313
- Gemini 출력 = (311 + 1,851) × 2.50 / 1,000,000 = 2,162 × 2.50 / 1,000,000 = $0.0054050
- Fish Audio = 179 × 15.00 / 1,000,000 = $0.0026850
- 합계 = $0.0095213 × 1,336.9 = **약 12.7원**
- 비교 (gemini-3.8-flash, 2026년 단가): 4,771 × 0.75 / 1,000,000 + 2,162 × 3.75 / 1,000,000 + 0.002685 = $0.0143708 × 1,336.9 = 약 19.2원
- 무료 등급(Gemini 무료 + s2.1-pro-free)이면 API 비용은 0원이다. 다만 Gemini 무료 등급은 입력 데이터가 제품 개선에 쓰인다. 렌더링(render_local) 비용은 빠져 있다.
- thinking 토큰이 출력의 86%(1,851 / 2,162)를 차지한다. thinking 예산을 줄이는 것이 원가를 낮추는 가장 큰 방법이다.
- **2026-11-12 모델 전환 실측**(gemini-3.5-flash-lite, 같은 데모 영상): 입력 1,072 · 출력 223 · thinking 0토큰 → (1,072 × 0.30 + 223 × 2.50) / 1,000,000 × 1,336.9 = **약 1.2원**(2.5-flash 약 9.1원 대비 약 8분의 1, Fish Audio 제외). 테스트 키는 이 모델로 고정

## 실무 모델 후보 (2026-11-12 사용자 결정)
테스트는 Gemini 무료 키, 실무(서비스)는 아래 중에서 고른다. OpenAI 단가는 공식 페이지(https://developers.openai.com/api/docs/pricing)에서 **미확인**, 아래는 제3자 자료라 서로 다르다.

| 후보 | 100만 토큰당 입력/출력(USD) | 근거 |
|---|---|---|
| Claude Sonnet 5.5 | 2 / 10 | 위 2절(공식) |
| OpenAI Sol | 2 / 10 ~ 5 / 30 (세대·프로모션에 따라 다름) | https://aipricecompare.org/api/openai-api-pricing.html · https://techjacksolutions.com/ai-tools/chatgpt/gpt-5-6-pricing/ |
| OpenAI Terra | 1 / 5 ~ 2 / 12 | 같음 |
| OpenAI Luna | 0.10 / 0.50 ~ 0.20 / 1.20 | 같음 |

OpenAI 키를 받으면 공식 가격표로 확정해 config에 `pricing.openai`를 추가하고 예상 비용 표에 조합을 넣는다.
