import "server-only";
import { type BannedHit, findBannedTerms } from "@/lib/llm/banned";
import { generateScriptDraft } from "@/lib/llm/generate";
import { totalTenths, validateLines } from "@/lib/llm/script-metrics";
import { LlmError } from "@/lib/llm/types";
import type { StepStatusMap } from "@/lib/steps/state";
import { type OwnedProject, loadOwnedProject } from "./project-access";
import { RATE_LIMIT_MESSAGE } from "@/lib/llm/rate-limit";
import { getLlmProvider, llmLimiter, logUsage } from "./provider";
import { markStep } from "./step-mark";

/*
 * 03 대본 — draft_script(docs/planning.md 3장 03 · 17-7). 초안은 제안만 돌려주고(적용·저장은 사용자),
 * 저장은 사용자 세션으로 scripts 에 쓴다(승인된 대본은 DB 트리거가 잠금). 승인은 StepActions 버튼만.
 */

export type DraftResult =
  | { ok: true; lines: string[]; banned: BannedHit[]; status: StepStatusMap | null }
  | { ok: false; error: string };
export type SaveScriptResult =
  | { ok: true; version: number; status: StepStatusMap | null }
  | { ok: false; error: string; banned?: BannedHit[] };

const NOT_FOUND = { ok: false, error: "프로젝트를 찾을 수 없거나 권한이 없습니다." } as const;
const LOCKED = { ok: false, error: "승인된 대본은 바꿀 수 없습니다. 변경 필요를 눌러 승인을 푼 뒤 수정해 주세요." } as const;

function precondition(project: OwnedProject): string | null {
  if (project.status[1] !== "approved" || project.status[2] !== "approved") return "01 소재와 02 소스를 먼저 승인해 주세요.";
  if (project.status[3] === "approved") return LOCKED.error;
  if (project.status[3] === "running") return "이미 진행 중인 작업이 있습니다.";
  return null;
}

export async function draftScript(projectId: string): Promise<DraftResult> {
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return NOT_FOUND;
  const blocked = precondition(project);
  if (blocked) return { ok: false, error: blocked };

  const [{ data: topic }, { data: sources, error: sourceError }] = await Promise.all([
    supabase.from("topics").select("name").eq("project_id", project.id).eq("picked", true).limit(1).maybeSingle(),
    supabase
      .from("sources")
      .select("platform, title, author, duration_sec")
      .eq("project_id", project.id)
      .eq("checked", true)
      .order("score", { ascending: false, nullsFirst: false })
      .limit(10),
  ]);
  if (sourceError) return { ok: false, error: "원본 목록을 읽지 못했습니다. 잠시 뒤 다시 시도해 주세요." };
  if (!sources || sources.length === 0) return { ok: false, error: "체크된 원본이 없습니다. 02 소스에서 원본을 체크해 주세요." };

  const slot = llmLimiter.acquire(project.id, project.userId);
  if (!slot.ok) return { ok: false, error: RATE_LIMIT_MESSAGE[slot.reason] };
  let result;
  try {
    const provider = getLlmProvider();
    result = await generateScriptDraft(provider, {
      productName: typeof topic?.name === "string" ? topic.name : project.name,
      targetSec: project.targetSec,
      bannedTerms: project.bannedTerms,
      sources: sources.map((s) => ({
        platform: String(s.platform),
        title: typeof s.title === "string" ? s.title : null,
        author: String(s.author),
        durationSec: typeof s.duration_sec === "number" ? s.duration_sec : null,
      })),
    });
    if (result.ok) logUsage("script", provider, result.usage);
  } catch (error) {
    return { ok: false, error: error instanceof LlmError ? error.message : "대본 초안을 만들지 못했습니다." };
  } finally {
    slot.release();
  }
  if (!result.ok) return result;

  const status = await markStep(project.id, 3, "suggested");
  return { ok: true, lines: result.lines, banned: result.banned, status };
}

export async function saveScript(projectId: string, input: unknown): Promise<SaveScriptResult> {
  if (!Array.isArray(input) || !input.every((l) => typeof l === "string")) return { ok: false, error: "잘못된 요청입니다." };
  const lines = input.map((l) => l.trim()).filter((l) => l.length > 0);
  const invalid = validateLines(lines);
  if (invalid) return { ok: false, error: invalid };

  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return NOT_FOUND;
  const blocked = precondition(project);
  if (blocked) return { ok: false, error: blocked };

  const banned = findBannedTerms(lines, project.bannedTerms);
  if (banned.length > 0) {
    return { ok: false, error: "금지 표현이 들어간 문장이 있습니다. 표시된 문장을 고친 뒤 저장해 주세요.", banned };
  }

  const estSec = totalTenths(lines) / 10;
  const { data: latest, error: readError } = await supabase
    .from("scripts")
    .select("id, version, approved_at")
    .eq("project_id", project.id)
    .order("version", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (readError) return { ok: false, error: "대본을 저장하지 못했습니다. 잠시 뒤 다시 시도해 주세요." };

  let version: number;
  if (latest && latest.approved_at === null) {
    version = Number(latest.version);
    const { error } = await supabase.from("scripts").update({ lines, est_sec: estSec }).eq("id", latest.id);
    if (error) return { ok: false, error: error.code === "55000" ? LOCKED.error : "대본을 저장하지 못했습니다." };
  } else {
    version = (Number(latest?.version) || 0) + 1;
    const { error } = await supabase.from("scripts").insert({ project_id: project.id, version, lines, est_sec: estSec });
    if (error) return { ok: false, error: error.code === "55000" ? LOCKED.error : "대본을 저장하지 못했습니다." };
  }

  const status = await markStep(project.id, 3, "ready");
  return { ok: true, version, status };
}
