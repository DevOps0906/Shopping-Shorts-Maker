import { type BannedHit, findBannedTerms } from "./banned";
import { type ScriptPromptInput, type TopicPromptInput, buildScriptRequest, buildTopicRequest } from "./prompt";
import { type TopicCandidate, parseScriptOutput, parseTopicOutput } from "./schema";
import { LLM_ERROR_MESSAGE, LlmError, type LlmProvider, type LlmUsage } from "./types";

/*
 * search_topics · draft_script 의 모델 호출 부분(docs/planning.md 17-7). 공급자는 주입받는다.
 * 결과는 검사한 값만 돌려주고, 저장·단계 상태 변경은 호출한 서버 코드가 소유권을 다시 검사한 뒤 한다.
 */

export type GenerateFailure = { ok: false; error: string };
export type TopicGenerateResult = { ok: true; candidates: TopicCandidate[]; usage: LlmUsage; model: string } | GenerateFailure;
export type ScriptGenerateResult =
  | { ok: true; lines: string[]; banned: BannedHit[]; usage: LlmUsage; model: string }
  | GenerateFailure;

function failure(error: unknown): GenerateFailure {
  if (error instanceof LlmError) return { ok: false, error: error.message };
  return { ok: false, error: LLM_ERROR_MESSAGE.provider_error };
}

export async function generateTopicCandidates(provider: LlmProvider, input: TopicPromptInput): Promise<TopicGenerateResult> {
  try {
    const res = await provider.generateJson(buildTopicRequest(input));
    const candidates = parseTopicOutput(res.text);
    if (!candidates) return { ok: false, error: LLM_ERROR_MESSAGE.bad_output };
    // 같은 이름 중복 제거
    const unique = candidates.filter((c, i) => candidates.findIndex((d) => d.name === c.name) === i);
    return { ok: true, candidates: unique, usage: res.usage, model: res.model };
  } catch (error) {
    return failure(error);
  }
}

export async function generateScriptDraft(provider: LlmProvider, input: ScriptPromptInput): Promise<ScriptGenerateResult> {
  try {
    const res = await provider.generateJson(buildScriptRequest(input));
    const lines = parseScriptOutput(res.text);
    if (!lines) return { ok: false, error: LLM_ERROR_MESSAGE.bad_output };
    return { ok: true, lines, banned: findBannedTerms(lines, input.bannedTerms), usage: res.usage, model: res.model };
  } catch (error) {
    return failure(error);
  }
}
