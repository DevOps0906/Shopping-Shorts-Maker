import { LLM_ERROR_MESSAGE, LlmError, type LlmProvider, type LlmRequest, type LlmResponse } from "./types";

/*
 * Gemini generateContent 호출 본체(키는 인자로만 받는다 — 키를 읽는 곳은 src/server/llm/gemini.ts).
 * 재시도 규칙(poc/agency/adapters.py gemini_request와 같음):
 * - 생성 POST는 429(미처리 확실)만 1회 재시도.
 * - 5xx·타임아웃·네트워크 오류는 처리 여부 불명 → 중복 과금을 막으려고 재시도하지 않는다.
 * 오류 메시지에 키·응답 원문을 넣지 않는다.
 */

export const GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta";
export const RETRY_DELAY_MS = 5000;
const TIMEOUT_MS = 60_000;

type GeminiDeps = {
  apiKey: string;
  model: string;
  fetchImpl?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
};

const defaultSleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
const fail = (code: ConstructorParameters<typeof LlmError>[0]) => new LlmError(code, LLM_ERROR_MESSAGE[code]);
const toInt = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? Math.trunc(value) : 0);

export function geminiBody(request: LlmRequest) {
  return {
    systemInstruction: { parts: [{ text: request.system }] },
    contents: [{ role: "user", parts: [{ text: request.user }] }],
    generationConfig: {
      responseMimeType: "application/json",
      responseSchema: request.schema,
      maxOutputTokens: request.maxOutputTokens,
      temperature: 0.7,
    },
  };
}

/** 응답에서 본문 텍스트(생각 파트 제외)와 사용량을 꺼낸다 */
export function readGeminiResponse(data: unknown, model: string): LlmResponse {
  const root = (data ?? {}) as {
    candidates?: { content?: { parts?: { text?: unknown; thought?: unknown }[] } }[];
    usageMetadata?: Record<string, unknown>;
  };
  const parts = root.candidates?.[0]?.content?.parts;
  if (!Array.isArray(parts)) throw fail("bad_output");
  const text = parts
    .filter((p) => p.thought !== true && typeof p.text === "string")
    .map((p) => p.text as string)
    .join("");
  const um = root.usageMetadata ?? {};
  return {
    text,
    model,
    usage: {
      inputTokens: toInt(um.promptTokenCount),
      outputTokens: toInt(um.candidatesTokenCount),
      thinkingTokens: toInt(um.thoughtsTokenCount),
    },
  };
}

export function createGeminiCore({ apiKey, model, fetchImpl = fetch, sleep = defaultSleep }: GeminiDeps): LlmProvider {
  return {
    id: "gemini",
    model,
    async generateJson(request) {
      const body = JSON.stringify(geminiBody(request));
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
        return readGeminiResponse(data, model);
      }
      throw fail("rate_limited");
    },
  };
}
