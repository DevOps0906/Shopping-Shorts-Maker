import "server-only";
import { generateTopicCandidates } from "@/lib/llm/generate";
import { MAX_PRODUCT_NAME, toProductUrl } from "@/lib/llm/prefill";
import { cleanText } from "@/lib/llm/prompt";
import { LlmError } from "@/lib/llm/types";
import type { StepStatusMap } from "@/lib/steps/state";
import { createAdminClient } from "@/server/supabase-admin";
import { loadOwnedProject } from "./project-access";
import { RATE_LIMIT_MESSAGE } from "@/lib/llm/rate-limit";
import { getLlmProvider, llmLimiter, logUsage } from "./provider";
import { markStep } from "./step-mark";

/*
 * 01 소재 — search_topics(docs/planning.md 3장 01 · 17-7). topics 생성은 서버(service_role), 사용자는 picked만 바꾼다.
 * 비슷한 영상 링크(evidence_urls)는 실제 검색 결과로만 채운다. 모델에게 URL을 만들게 하지 않는다.
 */

export type TopicView = {
  id: string;
  name: string;
  reason: string | null;
  evidenceUrls: string[];
  picked: boolean;
  productUrl: string | null;
};
export type TopicActionResult =
  | { ok: true; topics: TopicView[]; status: StepStatusMap | null }
  | { ok: false; error: string };

const NOT_FOUND = { ok: false, error: "프로젝트를 찾을 수 없거나 권한이 없습니다." } as const;
const LOCKED = { ok: false, error: "승인된 소재는 바꿀 수 없습니다. 변경 필요를 눌러 승인을 푼 뒤 다시 시도해 주세요." } as const;
const FAILED = { ok: false, error: "소재를 저장하지 못했습니다. 잠시 뒤 다시 시도해 주세요." } as const;


function toView(row: Record<string, unknown>): TopicView {
  return {
    id: String(row.id),
    name: String(row.name),
    reason: typeof row.reason === "string" ? row.reason : null,
    evidenceUrls: Array.isArray(row.evidence_urls) ? row.evidence_urls.filter((u): u is string => typeof u === "string") : [],
    picked: row.picked === true,
    productUrl: typeof row.product_url === "string" ? row.product_url : null,
  };
}

export async function suggestTopics(projectId: string, hint: string): Promise<TopicActionResult> {
  const { project } = await loadOwnedProject(projectId);
  if (!project) return NOT_FOUND;
  const state = project.status[1];
  if (state === "approved") return LOCKED;
  if (state === "running") return { ok: false, error: "이미 진행 중인 작업이 있습니다." };

  const slot = llmLimiter.acquire(project.id, project.userId);
  if (!slot.ok) return { ok: false, error: RATE_LIMIT_MESSAGE[slot.reason] };
  let result;
  try {
    const provider = getLlmProvider();
    result = await generateTopicCandidates(provider, {
      hint: cleanText(hint, 60) || project.name,
      categoryName: project.categoryName,
      keywords: project.keywords,
    });
    if (result.ok) logUsage("topics", provider, result.usage);
  } catch (error) {
    return { ok: false, error: error instanceof LlmError ? error.message : FAILED.error };
  } finally {
    slot.release();
  }
  if (!result.ok) return result;
  if (result.candidates.length === 0) return { ok: true, topics: [], status: null };

  const admin = createAdminClient();
  const { data: last } = await admin
    .from("topics")
    .select("round")
    .eq("project_id", project.id)
    .order("round", { ascending: false })
    .limit(1)
    .maybeSingle();
  const round = (Number(last?.round) || 0) + 1;
  const { data: rows, error } = await admin
    .from("topics")
    .insert(result.candidates.map((c) => ({ project_id: project.id, round, name: c.name, reason: c.reason })))
    .select("id, name, reason, evidence_urls, picked, product_url");
  if (error || !rows) return FAILED;

  const status = await markStep(project.id, 1, "suggested");
  return { ok: true, topics: rows.map(toView), status };
}

/** 이번 영상에서 다룰 제품 저장: 같은 이름 후보가 있으면 그 후보를, 없으면 직접 입력 행을 picked로 둔다 */
export async function saveTopic(projectId: string, rawName: string, rawUrl = ""): Promise<TopicActionResult> {
  const name = cleanText(rawName, MAX_PRODUCT_NAME + 1);
  if (name.length === 0) return { ok: false, error: "제품명을 적어 주세요." };
  if (name.length > MAX_PRODUCT_NAME) return { ok: false, error: `제품명은 ${MAX_PRODUCT_NAME}자까지 적을 수 있습니다.` };

  // 상품 링크: 서버에서 http(s) 다시 검사, 비면 null
  const productUrl = rawUrl.trim() ? toProductUrl(rawUrl) : null;
  if (rawUrl.trim() && !productUrl) return { ok: false, error: "상품 링크는 http:// 또는 https://로 시작하는 주소만 넣을 수 있습니다." };

  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return NOT_FOUND;
  if (project.status[1] === "approved") return LOCKED;

  const { data: latest } = await supabase
    .from("topics")
    .select("id, name, round")
    .eq("project_id", project.id)
    .order("round", { ascending: false })
    .order("created_at", { ascending: true });
  const rows = latest ?? [];
  const latestRound = rows.length > 0 ? Number(rows[0].round) : 1;
  const match = rows.find((r) => Number(r.round) === latestRound && r.name === name);

  // 사용자 세션으로 선택 해제·선택(열 권한 picked, RLS 본인)
  const { error: unpickError } = await supabase.from("topics").update({ picked: false }).eq("project_id", project.id).eq("picked", true);
  if (unpickError) return FAILED;
  if (match) {
    const { error } = await supabase.from("topics").update({ picked: true, product_url: productUrl }).eq("id", match.id);
    if (error) return FAILED;
  } else {
    const { error } = await createAdminClient()
      .from("topics")
      .insert({ project_id: project.id, round: latestRound, name, reason: null, picked: true, product_url: productUrl });
    if (error) return FAILED;
  }

  const status = await markStep(project.id, 1, "ready");
  return { ok: true, topics: await selectTopics(supabase, project.id), status };
}

type SessionClient = NonNullable<Awaited<ReturnType<typeof loadOwnedProject>>["supabase"]>;

/** 가장 최근 회차 후보 + 선택된 소재(사용자 세션, RLS 본인) */
export async function selectTopics(supabase: SessionClient, projectId: string): Promise<TopicView[]> {
  const { data } = await supabase
    .from("topics")
    .select("id, name, reason, evidence_urls, picked, product_url, round")
    .eq("project_id", projectId)
    .order("round", { ascending: false })
    .order("created_at", { ascending: true });
  const rows = data ?? [];
  if (rows.length === 0) return [];
  const round = Number(rows[0].round);
  return rows.filter((r) => Number(r.round) === round || r.picked === true).map(toView);
}
