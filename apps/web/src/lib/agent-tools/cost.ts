import { type CostLine, MODEL_PRICES, USD_KRW } from "@/lib/llm/pricing";

/*
 * 제작 파트너 요청 1회의 호출 전 모델별 예상 비용(docs/planning.md 17-2 D9). 단가·환율은 lib/llm/pricing.ts 정본.
 * 사용량은 가정값(맥락·이전 대화·도구 선언 포함 입력, 짧은 답 출력). 실측 후 CHAT_TOKENS만 고친다. 금액은 정수 원(올림).
 * 소재 검색·대본 초안 도구를 부르면 그 호출 비용(CostHint topics·script)이 따로 든다.
 */

export const CHAT_TOKENS = { input: 2000, output: 200 };

export function estimateChatCost(): CostLine[] {
  return MODEL_PRICES.map((m) => ({
    id: m.id,
    label: m.label,
    krw: Math.ceil(((CHAT_TOKENS.input * m.inputUsdPer1M + CHAT_TOKENS.output * m.outputUsdPer1M) / 1_000_000) * USD_KRW),
  }));
}

export function chatCostLine(): string {
  return `요청 1회 예상 비용 · ${estimateChatCost()
    .map((l) => `${l.label} 약 ${l.krw.toLocaleString("ko-KR")}원`)
    .join(" · ")}`;
}
