/*
 * LLM 공급자 어댑터 계약. 구현(키를 쓰는 코드)은 src/server/llm/** 에만 둔다.
 * 요청에 도구(function calling)를 넣지 않는다 — 모델은 정해진 JSON만 돌려주고, 데이터 변경은 서버 코드가 한다(17-7).
 */

export type LlmUsage = { inputTokens: number; outputTokens: number; thinkingTokens: number };

export type LlmRequest = {
  /** 역할·규칙(시스템 지시). 외부 글을 넣지 않는다 */
  system: string;
  /** 작업 지시 + 데이터 구분자 안의 외부 글 */
  user: string;
  /** 응답 JSON 스키마(OpenAPI 부분집합, Gemini responseSchema 형식) */
  schema: Record<string, unknown>;
  maxOutputTokens: number;
};

export type LlmResponse = { text: string; usage: LlmUsage; model: string };

export interface LlmProvider {
  readonly id: "gemini" | "claude";
  readonly model: string;
  generateJson(request: LlmRequest): Promise<LlmResponse>;
}

export type LlmErrorCode = "not_configured" | "rate_limited" | "unknown_result" | "provider_error" | "bad_output";

/** 공급자 오류. message는 화면에 그대로 내보낼 수 있는 문구만 담는다(키·응답 원문 금지) */
export class LlmError extends Error {
  constructor(
    readonly code: LlmErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "LlmError";
  }
}

export const LLM_ERROR_MESSAGE: Record<LlmErrorCode, string> = {
  not_configured: "AI 모델 키가 설정되지 않았습니다. 관리자에게 문의해 주세요.",
  rate_limited: "AI 호출 한도에 걸렸습니다. 잠시 뒤 다시 시도해 주세요.",
  unknown_result: "AI 응답을 받지 못했습니다. 중복 과금을 막으려고 자동으로 다시 보내지 않았습니다. 잠시 뒤 다시 시도해 주세요.",
  provider_error: "AI 호출에 실패했습니다. 잠시 뒤 다시 시도해 주세요.",
  bad_output: "AI 응답 형식이 올바르지 않아 버렸습니다. 다시 시도해 주세요.",
};
