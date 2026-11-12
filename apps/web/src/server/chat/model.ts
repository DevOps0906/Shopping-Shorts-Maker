import "server-only";
import { type ChatModel, createGeminiChat } from "@/lib/agent-tools/gemini-chat";
import { LLM_ERROR_MESSAGE, LlmError } from "@/lib/llm/types";
import { GEMINI_TEST_MODEL } from "@/server/llm/gemini";

/*
 * 제작 파트너 대화 모델 — 지금은 Gemini 무료 테스트 키만(docs/planning.md 17-2 D10). 키는 서버 환경 변수로만 읽고
 * 로그·오류·응답에 넣지 않는다. LLM_PROVIDER=claude 이면 Claude 도구 호출 어댑터가 아직 없어 not_configured.
 */
export function createChatModel(): ChatModel {
  if (process.env.LLM_PROVIDER === "claude") throw new LlmError("not_configured", LLM_ERROR_MESSAGE.not_configured);
  const apiKey = process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY;
  if (!apiKey) throw new LlmError("not_configured", LLM_ERROR_MESSAGE.not_configured);
  return createGeminiChat({ apiKey, model: GEMINI_TEST_MODEL });
}
