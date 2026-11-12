/*
 * 생성 버튼 옆 "호출 전 모델별 AI 예상 비용" — docs/planning.md 3장 첫머리 · 17-2 D9.
 * 단가·환율은 poc/agency/config.json pricing(docs/w0/pricing-research.md, 2026-11-12) 값과 같다.
 * 사용량은 호출 1회 가정값(토큰). 실측 후 CALL_TOKENS만 고친다. 금액은 정수 원(올림).
 * 이 파일에는 키·키 이름을 두지 않는다(브라우저 번들에 들어간다).
 */

export const USD_KRW = 1336.9;

export type LlmTask = "topics" | "script";

export const MODEL_PRICES = [
  { id: "gemini", label: "Gemini", inputUsdPer1M: 0.3, outputUsdPer1M: 2.5 },
  { id: "claude", label: "Claude", inputUsdPer1M: 2, outputUsdPer1M: 10 },
] as const;

/** 호출 1회 사용량 가정(입력·출력 토큰) */
export const CALL_TOKENS: Record<LlmTask, { input: number; output: number }> = {
  topics: { input: 700, output: 400 },
  script: { input: 1500, output: 600 },
};

export type CostLine = { id: string; label: string; krw: number };

export function estimateCallCost(task: LlmTask): CostLine[] {
  const { input, output } = CALL_TOKENS[task];
  return MODEL_PRICES.map((m) => ({
    id: m.id,
    label: m.label,
    krw: Math.ceil(((input * m.inputUsdPer1M + output * m.outputUsdPer1M) / 1_000_000) * USD_KRW),
  }));
}
