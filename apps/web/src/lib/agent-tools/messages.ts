import type { ConfirmOptions } from "@/lib/feedback/types";
import { type AgentToolName, isAgentToolName } from "./tools";

/*
 * 화면 ↔ /api/chat 주고받는 모양. chat_messages.payload(jsonb)는 서버가 쓴 AI 메시지에서만 읽는다
 * (사용자는 role=user 행만 쓸 수 있어 확인 버튼·적용 버튼을 위조할 수 없다 — 그래도 실행 때 서버가 다시 검사한다).
 */

/** 서버가 저장한 제안(chat_proposals)의 id. 화면은 tool·args를 보내지 않고 proposalId만 보낸다 */
export type PendingConfirm = { proposalId: string; projectId: string; tool: AgentToolName; options: ConfirmOptions };

export type ChatMessageView = {
  id: string;
  projectId: string;
  role: "user" | "ai";
  kind: "screen" | "text" | "ai";
  text: string;
  createdAt: string;
  tool: AgentToolName | null;
  draft: string[] | null;
  confirm: PendingConfirm | null;
};

export type ChatContextView = {
  projectId: string;
  projectName: string;
  stepNumber: number;
  stepLabel: string;
  channelName: string | null;
  categoryName: string | null;
};

export type ChatLoadResponse = { ok: true; context: ChatContextView; messages: ChatMessageView[] } | { ok: false; error: string };
export type ChatSendResponse =
  | { ok: true; messages: ChatMessageView[]; confirm: PendingConfirm | null; changed: AgentToolName | null }
  | { ok: false; error: string };

const strings = (v: unknown) => (Array.isArray(v) && v.every((x) => typeof x === "string") ? (v as string[]) : null);

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** POST /api/chat/confirm 본문: proposalId 하나만. 다른 키(tool·args 등)가 있으면 거부 */
export function parseConfirmBody(body: Record<string, unknown>): string | null {
  const keys = Object.keys(body);
  if (keys.length !== 1 || typeof body.proposalId !== "string" || !UUID.test(body.proposalId)) return null;
  return body.proposalId;
}

function readConfirm(v: unknown, projectId: string): PendingConfirm | null {
  if (typeof v !== "object" || v === null) return null;
  const r = v as Record<string, unknown>;
  const o = r.options as Record<string, unknown> | undefined;
  if (!isAgentToolName(r.tool) || typeof r.proposalId !== "string" || !UUID.test(r.proposalId) || !o || typeof o.title !== "string" || typeof o.description !== "string" || typeof o.confirmLabel !== "string") {
    return null;
  }
  return {
    proposalId: r.proposalId,
    projectId,
    tool: r.tool,
    options: { title: o.title, description: o.description, confirmLabel: o.confirmLabel, danger: o.danger === true },
  };
}

export function toMessageView(row: {
  id: string;
  project_id: string;
  role: string;
  kind: string;
  text: string | null;
  payload: unknown;
  created_at: string;
}): ChatMessageView {
  const ai = row.role === "ai";
  const p = ai && typeof row.payload === "object" && row.payload !== null ? (row.payload as Record<string, unknown>) : {};
  return {
    id: row.id,
    projectId: row.project_id,
    role: ai ? "ai" : "user",
    kind: row.kind === "screen" ? "screen" : ai ? "ai" : "text",
    text: row.text ?? "",
    createdAt: row.created_at,
    tool: isAgentToolName(p.tool) ? p.tool : null,
    draft: strings(p.draft),
    confirm: readConfirm(p.confirm, row.project_id),
  };
}

/** 단계별 빠른 요청 칩 3개(planning 5장) */
export const QUICK_REQUESTS: Record<number, readonly string[]> = {
  1: ["다른 소재 추천해줘", "더 저렴한 제품으로", "후킹 포인트 설명해줘"],
  2: ["샤오홍슈 영상 더 찾아줘", "틱톡 영상 더 찾아줘", "왜 이 영상은 뺐어?"],
  3: ["대본 초안 만들어줘", "대본을 더 짧게", "첫 3초 후킹 강화"],
  4: ["더 차분한 남자 목소리로", "밝은 여자 목소리로", "지금 목소리 설명해줘"],
  5: ["2번 컷을 다른 장면으로", "MP4 다시 만들어줘", "컷 구성 설명해줘"],
  6: ["발행 전에 확인할 것 알려줘", "제목 아이디어 줘", "설명란 문구 점검해줘"],
};
