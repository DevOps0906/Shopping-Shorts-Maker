import { GEMINI_BASE, RETRY_DELAY_MS, readGeminiResponse } from "@/lib/llm/gemini-core";
import { LLM_ERROR_MESSAGE, LlmError, type LlmUsage } from "@/lib/llm/types";
import type { ChatRequest } from "./prompt";

/*
 * Gemini 함수 호출(function calling) 대화 1회 — 키는 인자로만 받는다(키를 읽는 곳은 src/server/chat/model.ts).
 * 재시도 규칙은 lib/llm/gemini-core.ts와 같다: 429만 1회 재시도, 5xx·타임아웃은 결과 불명이라 재시도하지 않는다.
 * 도구 호출은 구조화된 functionCall 파트에서만 읽는다(본문 글 속 "도구 호출" 문자열은 무시).
 */

export type ModelToolCall = { name: string; args: unknown };
export type ChatModelResult = { text: string; call: ModelToolCall | null; usage: LlmUsage; model: string };

export interface ChatModel {
  readonly id: "gemini";
  readonly model: string;
  chat(request: ChatRequest): Promise<ChatModelResult>;
}

const TIMEOUT_MS = 60_000;
const fail = (code: ConstructorParameters<typeof LlmError>[0]) => new LlmError(code, LLM_ERROR_MESSAGE[code]);
const defaultSleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

export function chatBody(request: ChatRequest) {
  return {
    systemInstruction: { parts: [{ text: request.system }] },
    contents: [{ role: "user", parts: [{ text: request.user }] }],
    tools: [{ functionDeclarations: request.tools }],
    toolConfig: { functionCallingConfig: { mode: "AUTO" } },
    generationConfig: { maxOutputTokens: request.maxOutputTokens, temperature: 0.4 },
  };
}

/** 응답에서 본문 텍스트·첫 functionCall·사용량을 꺼낸다 */
export function readChatResponse(data: unknown, model: string): ChatModelResult {
  const base = readGeminiResponse(data, model);
  const parts = (data as { candidates?: { content?: { parts?: { functionCall?: { name?: unknown; args?: unknown } }[] } }[] })
    .candidates?.[0]?.content?.parts ?? [];
  const fc = parts.find((p) => p.functionCall && typeof p.functionCall.name === "string")?.functionCall;
  return { ...base, call: fc ? { name: fc.name as string, args: fc.args ?? {} } : null };
}

type Deps = { apiKey: string; model: string; fetchImpl?: typeof fetch; sleep?: (ms: number) => Promise<void> };

export function createGeminiChat({ apiKey, model, fetchImpl = fetch, sleep = defaultSleep }: Deps): ChatModel {
  return {
    id: "gemini",
    model,
    async chat(request) {
      const body = JSON.stringify(chatBody(request));
      for (let attempt = 1; attempt <= 2; attempt++) {
        let res: Response;
        try {
          res = await fetchImpl(`${GEMINI_BASE}/models/${encodeURIComponent(model)}:generateContent`, {
            method: "POST",
            headers: { "x-goog-api-key": apiKey, "Content-Type": "application/json" },
            body,
            signal: AbortSignal.timeout(TIMEOUT_MS),
            cache: "no-store",
          });
        } catch {
          throw fail("unknown_result");
        }
        if (res.status === 429 && attempt === 1) {
          await sleep(RETRY_DELAY_MS);
          continue;
        }
        if (res.status === 429) throw fail("rate_limited");
        if (!res.ok) throw fail("provider_error");
        let data: unknown;
        try {
          data = await res.json();
        } catch {
          throw fail("bad_output");
        }
        return readChatResponse(data, model);
      }
      throw fail("rate_limited");
    },
  };
}
