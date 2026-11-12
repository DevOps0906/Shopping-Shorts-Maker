import "server-only";
import { createGeminiCore } from "@/lib/llm/gemini-core";
import { LLM_ERROR_MESSAGE, LlmError, type LlmProvider } from "@/lib/llm/types";

/*
 * Gemini 어댑터 — 키는 서버 환경 변수로만 읽는다(루트 .env.local, next.config.ts가 서버 프로세스에 로드).
 * 테스트·개발 모델은 무료 키 gemini-3.5-flash-lite(docs/planning.md 17-2 D10). 실무 키는 S-15·Vault(별도 작업).
 * 키 값은 로그·오류·응답에 넣지 않는다.
 */

export const GEMINI_TEST_MODEL = "gemini-3.5-flash-lite";

export function createGeminiProvider(): LlmProvider {
  const apiKey = process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY;
  if (!apiKey) throw new LlmError("not_configured", LLM_ERROR_MESSAGE.not_configured);
  return createGeminiCore({ apiKey, model: GEMINI_TEST_MODEL });
}
