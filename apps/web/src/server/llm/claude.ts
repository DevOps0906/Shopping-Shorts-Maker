import "server-only";
import { LLM_ERROR_MESSAGE, LlmError, type LlmProvider } from "@/lib/llm/types";

/*
 * Claude 어댑터 자리 — 실무 모델 결정(docs/planning.md 17-2 D10)과 S-15 키(Vault) 연결 뒤 구현한다.
 * 지금은 호출하면 not_configured 오류를 낸다(유료 호출 없음).
 */

export function createClaudeProvider(): LlmProvider {
  return {
    id: "claude",
    model: "",
    async generateJson() {
      throw new LlmError("not_configured", LLM_ERROR_MESSAGE.not_configured);
    },
  };
}
