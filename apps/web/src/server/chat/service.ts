import "server-only";
import type { Json } from "@/types/db";
import { type ChatContextView, type ChatLoadResponse, type ChatMessageView, type ChatSendResponse, toMessageView } from "@/lib/agent-tools/messages";
import { type ChatContext, type HistoryItem, MAX_MESSAGE, buildChatRequest } from "@/lib/agent-tools/prompt";
import { type ParsedCall, TOOL_LABEL } from "@/lib/agent-tools/tools";
import {
  NOT_OWNED,
  PROPOSAL_INVALID,
  type ToolOutcome,
  type ToolProject,
  type TurnDeps,
  type TurnResult,
  runChatTurn,
  runProposal,
} from "@/lib/agent-tools/turn";
import { RATE_LIMIT_MESSAGE } from "@/lib/llm/rate-limit";
import { cleanText } from "@/lib/llm/prompt";
import { LLM_ERROR_MESSAGE, LlmError } from "@/lib/llm/types";
import { STUDIO_STEPS, findStudioStep } from "@/lib/routes";
import { isProjectId } from "@/lib/steps/project-id";
import { createClient } from "@/lib/supabase/server";
import { llmLimiter } from "@/server/llm/provider";
import { createAdminClient } from "@/server/supabase-admin";
import { createChatModel } from "./model";
import { executeTool, loadToolProject } from "./tools";

/*
 * 제작 파트너 대화(S-16) — docs/planning.md 5장 · 17-7.
 * - 사용자 메시지는 사용자 세션으로 chat_messages 에 role=user 로 쓴다(RLS: 본인 프로젝트·role=user만).
 * - AI 메시지는 소유권을 확인한 뒤 서버(service_role)가 role=ai 로 쓴다(테이블 주석의 서버 경로).
 * - 모델 호출은 llmLimiter(프로젝트 동시 1개 · 사용자 분당 상한)를 거치고, 도구 실행 전에 슬롯을 놓는다
 *   (소재 검색·대본 초안은 각자 슬롯을 다시 잡는다).
 * - 사용량은 토큰 수만 로그에 남긴다(본문·키 없음).
 */

const HISTORY_LIMIT = 12;
const PROPOSAL_STALE = "확인을 요청한 뒤 단계 상태가 바뀌었습니다. 화면을 확인하고 다시 요청해 주세요.";
const LOAD_LIMIT = 60;
const MESSAGE_COLUMNS = "id, project_id, role, kind, text, payload, created_at";

type Session = Awaited<ReturnType<typeof createClient>>;

const embedded = (value: unknown, key: string): string | null => {
  const row = Array.isArray(value) ? value[0] : value;
  if (typeof row !== "object" || row === null) return null;
  const v = (row as Record<string, unknown>)[key];
  return typeof v === "string" ? v : null;
};

function stepOf(slug: unknown, current: number) {
  const found = typeof slug === "string" ? findStudioStep(slug) : null;
  if (found) return { num: found.num, label: `${String(found.num).padStart(2, "0")} ${found.label}` };
  const n = Math.min(Math.max(current, 1), STUDIO_STEPS.length);
  return { num: n, label: `${String(n).padStart(2, "0")} ${STUDIO_STEPS[n - 1].label}` };
}

async function loadContext(supabase: Session, projectId: string, slug: unknown) {
  const { data: p, error } = await supabase
    .from("projects")
    .select("id, name, current_step, step_status, accounts(channel_name), categories(name)")
    .eq("id", projectId)
    .maybeSingle();
  if (error) throw new Error("chat_context_failed");
  if (!p) return null;
  const step = stepOf(slug, Number(p.current_step) || 1);
  const view: ChatContextView = {
    projectId: p.id,
    projectName: p.name,
    stepNumber: step.num,
    stepLabel: step.label,
    channelName: embedded(p.accounts, "channel_name"),
    categoryName: embedded(p.categories, "name"),
  };
  return { view, stepStatus: (p.step_status ?? {}) as Record<string, string> };
}

export async function loadChat(projectId: unknown, slug: unknown): Promise<ChatLoadResponse> {
  if (typeof projectId !== "string" || !isProjectId(projectId)) return { ok: false, error: "잘못된 요청입니다." };
  const supabase = await createClient();
  const ctx = await loadContext(supabase, projectId, slug);
  if (!ctx) return { ok: false, error: "프로젝트를 찾을 수 없거나 권한이 없습니다." };
  const { data, error } = await supabase
    .from("chat_messages")
    .select(MESSAGE_COLUMNS)
    .eq("project_id", projectId)
    .order("created_at", { ascending: false })
    .limit(LOAD_LIMIT);
  if (error) return { ok: false, error: "대화를 불러오지 못했습니다. 잠시 뒤 다시 시도해 주세요." };
  return { ok: true, context: ctx.view, messages: (data ?? []).reverse().map(toMessageView) };
}

async function modelContext(supabase: Session, projectId: string, slug: unknown): Promise<{ context: ChatContext; history: HistoryItem[] } | null> {
  const ctx = await loadContext(supabase, projectId, slug);
  if (!ctx) return null;
  const [topic, checked, script, history] = await Promise.all([
    supabase.from("topics").select("name").eq("project_id", projectId).eq("picked", true).limit(1).maybeSingle(),
    supabase.from("sources").select("id", { count: "exact", head: true }).eq("project_id", projectId).eq("checked", true),
    supabase
      .from("scripts")
      .select("lines")
      .eq("project_id", projectId)
      .not("approved_at", "is", null)
      .order("version", { ascending: false })
      .limit(1)
      .maybeSingle(),
    supabase.from("chat_messages").select("role, text").eq("project_id", projectId).order("created_at", { ascending: false }).limit(HISTORY_LIMIT),
  ]);
  const lines = Array.isArray(script.data?.lines) ? script.data.lines.filter((l): l is string => typeof l === "string") : [];
  return {
    context: {
      stepLabel: ctx.view.stepLabel,
      stepStatus: ctx.stepStatus,
      productName: typeof topic.data?.name === "string" ? topic.data.name : null,
      channelName: ctx.view.channelName,
      categoryName: ctx.view.categoryName,
      checkedSources: checked.count ?? 0,
      approvedScript: lines,
    },
    history: (history.data ?? [])
      .reverse()
      .map((h) => ({ role: h.role === "ai" ? ("ai" as const) : ("user" as const), text: h.text ?? "" })),
  };
}

/** 결과를 AI 메시지로 저장(service_role, 소유권 확인 뒤). 확인이 필요하면 제안(chat_proposals)을 먼저 저장하고 id만 싣는다 */
async function saveAi(projectId: string, userId: string, result: Exclude<TurnResult, { kind: "error" }>) {
  const admin = createAdminClient();
  let payload: Record<string, unknown> | null = null;
  if (result.kind === "tool") payload = { tool: result.tool, ok: result.outcome.ok, draft: result.outcome.ok ? (result.outcome.draft ?? null) : null };
  if (result.kind === "confirm") {
    const { data: proposalId, error } = await admin.rpc("chat_create_proposal", {
      p_user_id: userId,
      p_project_id: projectId,
      p_tool: result.tool,
      p_args: result.args as Json,
    });
    if (error || typeof proposalId !== "string") throw new Error("chat_proposal_failed");
    payload = { tool: result.tool, confirm: { proposalId, tool: result.tool, options: result.confirm } };
  }
  const { data, error } = await admin
    .from("chat_messages")
    .insert({ project_id: projectId, role: "ai", kind: "ai", text: result.text, payload: payload as Json })
    .select(MESSAGE_COLUMNS)
    .single();
  if (error || !data) throw new Error("chat_save_failed");
  const message = toMessageView(data);
  return { message, confirm: message.confirm };
}

async function saveUser(supabase: Session, projectId: string, kind: "text" | "screen", text: string) {
  const { data, error } = await supabase
    .from("chat_messages")
    .insert({ project_id: projectId, role: "user", kind, text })
    .select(MESSAGE_COLUMNS)
    .single();
  if (error || !data) return null;
  return toMessageView(data);
}

async function finish(projectId: string, userId: string, userMsg: ChatMessageView, result: TurnResult): Promise<ChatSendResponse> {
  if (result.kind === "error") return { ok: false, error: result.error };
  try {
    const { message, confirm } = await saveAi(projectId, userId, result);
    const changed = result.kind === "tool" && result.outcome.ok && result.tool !== "draft_script" ? result.tool : null;
    return { ok: true, messages: [userMsg, message], confirm, changed };
  } catch {
    return { ok: false, error: "응답을 저장하지 못했습니다. 잠시 뒤 다시 시도해 주세요." };
  }
}

const deps = (key: string | null): TurnDeps => ({
  loadProject: loadToolProject,
  execute: (call, project) => executeTool(call, project, key),
});

export async function sendMessage(projectId: unknown, slug: unknown, rawText: unknown): Promise<ChatSendResponse> {
  if (typeof projectId !== "string" || !isProjectId(projectId) || typeof rawText !== "string") return { ok: false, error: "잘못된 요청입니다." };
  const text = cleanText(rawText, MAX_MESSAGE + 1);
  if (!text) return { ok: false, error: "메시지를 적어 주세요." };
  if (text.length > MAX_MESSAGE) return { ok: false, error: `메시지는 ${MAX_MESSAGE}자까지 보낼 수 있습니다.` };

  const supabase = await createClient();
  const saved: { user: ChatMessageView | null; userId: string; error: string | null } = { user: null, userId: "", error: null };
  const result = await runChatTurn(
    projectId,
    async (project) => {
      saved.userId = project.userId;
      const slot = llmLimiter.acquire(project.id, project.userId);
      if (!slot.ok) throw new LlmError("rate_limited", RATE_LIMIT_MESSAGE[slot.reason]);
      try {
        saved.user = await saveUser(supabase, project.id, "text", text);
        if (!saved.user) throw new Error("chat_user_save_failed");
        const input = await modelContext(supabase, project.id, slug);
        if (!input) throw new Error("chat_context_failed");
        // 이번 요청은 history 에서 빼고 <data> 밖에 둔다
        const history = input.history.filter((h, i, all) => !(i === all.length - 1 && h.role === "user" && h.text === text));
        const model = createChatModel();
        const res = await model.chat(buildChatRequest({ context: input.context, history, message: text }));
        console.info(
          `[llm] chat provider=${model.id} model=${res.model} input=${res.usage.inputTokens} output=${res.usage.outputTokens} thinking=${res.usage.thinkingTokens} tool=${res.call?.name ?? "-"}`,
        );
        return res;
      } finally {
        slot.release();
      }
    },
    deps(null),
  ).catch((error: unknown) => {
    saved.error = error instanceof LlmError ? error.message : LLM_ERROR_MESSAGE.provider_error;
    return null;
  });
  if (!result) return { ok: false, error: saved.error ?? LLM_ERROR_MESSAGE.provider_error };
  if (result.kind === "error") return { ok: false, error: result.error };
  if (!saved.user) return { ok: false, error: "메시지를 저장하지 못했습니다." };
  return finish(projectId, saved.userId, saved.user, result);
}

/** LLM 을 부르지 않는 도구는 확인 경로에서도 호출 제한(프로젝트 동시 1개 · 분당 상한)을 건다. 소재 검색·대본 초안은 내부에서 건다 */
async function limited(call: ParsedCall, project: ToolProject, key: string): Promise<ToolOutcome> {
  if (call.name === "search_topics" || call.name === "draft_script") return executeTool(call, project, key);
  const slot = llmLimiter.acquire(project.id, project.userId);
  if (!slot.ok) return { ok: false, error: RATE_LIMIT_MESSAGE[slot.reason] };
  try {
    return await executeTool(call, project, key);
  } finally {
    slot.release();
  }
}

/** 사용자가 확인 대화상자에서 실행을 눌렀다. 제안을 DB에서 1회 소비하고 저장된 tool·args로만 실행. 멱등 키는 proposal id로 파생 */
export async function confirmProposal(proposalId: string): Promise<ChatSendResponse> {
  const supabase = await createClient();
  const key = `proposal:${proposalId}`;
  const result = await runProposal(proposalId, {
    loadProject: loadToolProject,
    execute: (call, project) => limited(call, project, key),
    consume: async (id) => {
      const { data, error } = await supabase.rpc("chat_consume_proposal", { p_proposal_id: id });
      const row = (data ?? {}) as Record<string, unknown>;
      if (error || typeof row.project_id !== "string") {
        return { ok: false, error: row.error === "stale" ? PROPOSAL_STALE : PROPOSAL_INVALID };
      }
      return { ok: true, projectId: row.project_id, tool: row.tool, args: row.args };
    },
  });
  if (result.kind === "error" || !result.projectId) return { ok: false, error: result.kind === "error" ? result.error : PROPOSAL_INVALID };
  const project = await loadToolProject(result.projectId);
  if (!project) return { ok: false, error: NOT_OWNED };
  const label = result.kind === "tool" ? TOOL_LABEL[result.tool] : "도구";
  const userMsg = await saveUser(supabase, project.id, "screen", `확인 · ${label} 실행`);
  if (!userMsg) return { ok: false, error: "메시지를 저장하지 못했습니다." };
  return finish(project.id, project.userId, userMsg, result);
}
