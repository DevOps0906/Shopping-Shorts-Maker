import "server-only";
import { createLlmLimiter } from "@/lib/llm/rate-limit";
import type { LlmProvider } from "@/lib/llm/types";
import { createClaudeProvider } from "./claude";
import { createGeminiProvider } from "./gemini";

/** 공급자 선택. LLM_PROVIDER=claude 가 아니면 Gemini(테스트 기본값) */
export function getLlmProvider(): LlmProvider {
  return process.env.LLM_PROVIDER === "claude" ? createClaudeProvider() : createGeminiProvider();
}

/** 사용량 로그(토큰 수만, 키·본문 없음) */
export function logUsage(task: string, provider: LlmProvider, usage: { inputTokens: number; outputTokens: number; thinkingTokens: number }) {
  console.info(
    `[llm] ${task} provider=${provider.id} model=${provider.model} input=${usage.inputTokens} output=${usage.outputTokens} thinking=${usage.thinkingTokens}`,
  );
}

/** 서버 프로세스 하나에서 공유하는 생성 호출 제한(프로젝트 동시 1개 · 사용자 분당 상한). TODO: DB advisory lock으로 이전 */
export const llmLimiter = createLlmLimiter();
