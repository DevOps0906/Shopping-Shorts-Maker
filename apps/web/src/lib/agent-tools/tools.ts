import { VOICES } from "@/lib/voice/voices";

/*
 * 제작 파트너 도구 계약 — docs/planning.md 17-7 표 그대로 6종.
 * 승인·발행·권리 확인 도구는 두지 않는다(사용자만 누른다). 프로젝트 ID는 도구 입력에 없다:
 * 서버가 요청한 사용자의 소유 프로젝트로 묶고, 각 실행 함수가 소유권·단계 상태를 다시 검사한다.
 * 이 파일은 브라우저 번들에도 들어갈 수 있으므로 키·서버 코드를 두지 않는다.
 */

export const AGENT_TOOL_NAMES = [
  "search_topics",
  "search_sources",
  "draft_script",
  "synthesize_voice",
  "replace_cut",
  "render_mp4",
] as const;
export type AgentToolName = (typeof AGENT_TOOL_NAMES)[number];

/** Gemini functionDeclarations 형식(OpenAPI 부분집합) */
export type ToolDeclaration = {
  name: AgentToolName;
  description: string;
  parameters?: Record<string, unknown>;
};

export const COLLECT_PLATFORMS = ["tiktok", "xiaohongshu"] as const;
export type CollectPlatform = (typeof COLLECT_PLATFORMS)[number];
export const MAX_HINT = 60;
export const MAX_CUT_NO = 12;

export const TOOL_LABEL: Record<AgentToolName, string> = {
  search_topics: "소재 검색",
  search_sources: "소스 검색",
  draft_script: "대본 초안",
  synthesize_voice: "음성 합성",
  replace_cut: "컷 교체",
  render_mp4: "MP4 출력",
};

export const AGENT_TOOLS: readonly ToolDeclaration[] = [
  {
    name: "search_topics",
    description: "01 소재 후보 3개를 다시 검색한다. 사용자가 다른 소재·제품 추천을 요청할 때만 쓴다.",
    parameters: {
      type: "OBJECT",
      properties: { hint: { type: "STRING", description: `제품 힌트(${MAX_HINT}자 이내, 없으면 빈 문자열)` } },
    },
  },
  {
    name: "search_sources",
    description: "02 소스에서 한 플랫폼의 원본 영상을 한 회차 더 수집한다. 사용자가 소스를 더 찾아 달라고 할 때만 쓴다.",
    parameters: {
      type: "OBJECT",
      properties: { platform: { type: "STRING", enum: [...COLLECT_PLATFORMS] } },
      required: ["platform"],
    },
  },
  {
    name: "draft_script",
    description: "03 대본 초안을 제안한다(저장하지 않음, 적용은 사용자가 버튼으로). 사용자가 대본 작성·수정을 요청할 때만 쓴다.",
  },
  {
    name: "synthesize_voice",
    description: "04 승인된 대본으로 음성을 다시 합성한다. 사용자가 목소리 변경·재합성을 요청할 때만 쓴다.",
    parameters: {
      type: "OBJECT",
      properties: {
        voice_id: {
          type: "STRING",
          enum: VOICES.map((v) => v.id),
          description: VOICES.map((v) => `${v.id}=${v.gender} ${v.tone}`).join(", "),
        },
      },
      required: ["voice_id"],
    },
  },
  {
    name: "replace_cut",
    description: "05 편집에서 지정한 컷 번호의 원본을 다음 순위 원본으로 바꿔 새 버전을 만든다.",
    parameters: {
      type: "OBJECT",
      properties: { cut_no: { type: "INTEGER", description: `컷 번호(1~${MAX_CUT_NO})` } },
      required: ["cut_no"],
    },
  },
  {
    name: "render_mp4",
    description: "05 편집의 현재 컷 구성·음성·자막으로 MP4를 새 버전으로 만든다.",
  },
];

export function isAgentToolName(value: unknown): value is AgentToolName {
  return typeof value === "string" && (AGENT_TOOL_NAMES as readonly string[]).includes(value);
}

export type ToolArgs = {
  search_topics: { hint: string };
  search_sources: { platform: CollectPlatform };
  draft_script: Record<string, never>;
  synthesize_voice: { voice_id: string };
  replace_cut: { cut_no: number };
  render_mp4: Record<string, never>;
};

export type ParsedCall = { [K in AgentToolName]: { name: K; args: ToolArgs[K] } }[AgentToolName];
export type ParseResult = { ok: true; call: ParsedCall } | { ok: false; error: string };

const BAD_ARGS = { ok: false, error: "도구 입력이 올바르지 않아 실행하지 않았습니다." } as const;

/** 모델·화면이 보낸 도구 호출을 검사한다. 모르는 이름·모르는 키(project_id 등)·형식 오류는 거부 */
export function parseToolCall(name: unknown, rawArgs: unknown): ParseResult {
  if (!isAgentToolName(name)) return { ok: false, error: "제작 파트너가 쓸 수 없는 동작이라 실행하지 않았습니다." };
  const args = rawArgs ?? {};
  if (typeof args !== "object" || Array.isArray(args)) return BAD_ARGS;
  const record = args as Record<string, unknown>;
  const keys = Object.keys(record);
  const only = (...allowed: string[]) => keys.every((k) => allowed.includes(k));

  switch (name) {
    case "search_topics": {
      const hint = record.hint ?? "";
      if (!only("hint") || typeof hint !== "string" || hint.length > MAX_HINT * 2) return BAD_ARGS;
      return { ok: true, call: { name, args: { hint: hint.trim().slice(0, MAX_HINT) } } };
    }
    case "search_sources": {
      const platform = record.platform;
      if (!only("platform") || !(COLLECT_PLATFORMS as readonly unknown[]).includes(platform)) return BAD_ARGS;
      return { ok: true, call: { name, args: { platform: platform as CollectPlatform } } };
    }
    case "synthesize_voice": {
      const voiceId = record.voice_id;
      if (!only("voice_id") || typeof voiceId !== "string" || !VOICES.some((v) => v.id === voiceId)) return BAD_ARGS;
      return { ok: true, call: { name, args: { voice_id: voiceId } } };
    }
    case "replace_cut": {
      const cutNo = record.cut_no;
      if (!only("cut_no") || typeof cutNo !== "number" || !Number.isInteger(cutNo) || cutNo < 1 || cutNo > MAX_CUT_NO) return BAD_ARGS;
      return { ok: true, call: { name, args: { cut_no: cutNo } } };
    }
    case "draft_script":
    case "render_mp4":
      if (keys.length > 0) return BAD_ARGS;
      return { ok: true, call: { name, args: {} } };
  }
}
