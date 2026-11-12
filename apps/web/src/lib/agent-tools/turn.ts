import type { ConfirmOptions } from "@/lib/feedback/types";
import type { ChatModelResult } from "./gemini-chat";
import { type PolicyProject, gateFor } from "./policy";
import { type AgentToolName, type ParsedCall, TOOL_LABEL, parseToolCall } from "./tools";

/*
 * 대화 1턴의 판단(순수 함수, 서버 의존성은 주입). 순서가 보안 규칙이다:
 * 1) 프로젝트 소유권을 먼저 확인(타인·없는 프로젝트면 모델도 부르지 않는다)
 * 2) 모델 응답의 functionCall만 도구 호출로 본다 → 6종 목록·입력 형식 검사(모르는 이름·키는 거부)
 * 3) 사전 확인 정책(policy.ts) — 확인이 필요하면 실행하지 않고 confirm 결과만 돌려준다
 * 4) 실행 함수는 소유권·단계 상태를 다시 검사한다(server/chat/tools.ts → 기존 서버 함수)
 * 확인이 필요하면 서버가 제안(chat_proposals)을 저장하고 화면에는 proposal id만 준다. 사용자가 확인을 누르면
 * runProposal이 제안을 DB에서 원자적으로 1회 소비하고(본인·미소비·만료 전·입력 버전 같음) 저장된 tool·args로만 실행한다.
 */

export type ToolProject = PolicyProject & { id: string; userId: string };
export type ToolOutcome = { ok: true; text: string; draft?: string[] } | { ok: false; error: string };

export type ConsumedProposal = { ok: true; projectId: string; tool: unknown; args: unknown } | { ok: false; error: string };

export type TurnDeps = {
  loadProject: (projectId: string) => Promise<ToolProject | null>;
  execute: (call: ParsedCall, project: ToolProject) => Promise<ToolOutcome>;
  /** 제안 1회 소비(DB 원자 갱신). 없음·재사용·만료·남의 제안·입력 버전 변경이면 ok:false */
  consume?: (proposalId: string) => Promise<ConsumedProposal>;
};

export type TurnResult =
  | { kind: "reply"; text: string }
  | { kind: "tool"; tool: AgentToolName; text: string; outcome: ToolOutcome }
  | { kind: "confirm"; tool: AgentToolName; args: ParsedCall["args"]; confirm: ConfirmOptions; text: string }
  | { kind: "denied"; text: string }
  | { kind: "error"; error: string };

export const NOT_OWNED = "프로젝트를 찾을 수 없거나 권한이 없습니다.";
const EMPTY_REPLY = "요청을 이해하지 못했습니다. 바꾸고 싶은 단계와 내용을 조금 더 알려 주세요.";

async function gateAndRun(call: ParsedCall, project: ToolProject, deps: TurnDeps, confirmed: boolean, lead: string): Promise<TurnResult> {
  const gate = gateFor(call, project);
  if (gate.kind === "deny") return { kind: "denied", text: gate.error };
  if (gate.kind === "confirm" && !confirmed) {
    return { kind: "confirm", tool: call.name, args: call.args, confirm: gate.confirm, text: lead || `${TOOL_LABEL[call.name]} 전에 확인이 필요합니다.` };
  }
  const outcome = await deps.execute(call, project);
  const text = outcome.ok ? outcome.text : `${TOOL_LABEL[call.name]} 작업을 하지 못했습니다. ${outcome.error}`;
  return { kind: "tool", tool: call.name, text, outcome };
}

/** 사용자 메시지 1개 처리. ask는 모델 호출(호출 제한·비용 기록은 호출한 쪽이 맡는다) */
export async function runChatTurn(
  projectId: string,
  ask: (project: ToolProject) => Promise<ChatModelResult>,
  deps: TurnDeps,
): Promise<TurnResult> {
  const project = await deps.loadProject(projectId);
  if (!project) return { kind: "error", error: NOT_OWNED };
  const res = await ask(project);
  const lead = res.text.trim();
  if (!res.call) return { kind: "reply", text: lead || EMPTY_REPLY };
  const parsed = parseToolCall(res.call.name, res.call.args);
  if (!parsed.ok) return { kind: "denied", text: parsed.error };
  return gateAndRun(parsed.call, project, deps, false, lead);
}

export const PROPOSAL_INVALID = "확인 요청이 만료됐거나 이미 처리됐습니다. 다시 요청해 주세요.";

/** 사용자가 확인 대화상자에서 "실행"을 누른 제안. 모델·화면이 보낸 tool·args는 받지 않고 DB에 저장된 값만 쓴다 */
export async function runProposal(proposalId: string, deps: TurnDeps): Promise<TurnResult & { projectId?: string }> {
  if (!deps.consume) return { kind: "error", error: PROPOSAL_INVALID };
  const consumed = await deps.consume(proposalId);
  if (!consumed.ok) return { kind: "error", error: consumed.error };
  const parsed = parseToolCall(consumed.tool, consumed.args);
  if (!parsed.ok) return { kind: "denied", text: parsed.error };
  const project = await deps.loadProject(consumed.projectId);
  if (!project) return { kind: "error", error: NOT_OWNED };
  return { ...(await gateAndRun(parsed.call, project, deps, true, "")), projectId: project.id };
}
