import "server-only";
import { createJob } from "@/lib/jobs/create-job";
import { isProjectId } from "@/lib/steps/project-id";
import { type StepStatusMap, parseStepStatus } from "@/lib/steps/state";
import {
  MAX_DOWNLOAD_CHECKS,
  MAX_REASON,
  type SourceView,
  type UseEntry,
  directSourceError,
  isPlatform,
  isRightsBasis,
} from "@/lib/sources/rules";
import { createClient } from "@/lib/supabase/server";

/*
 * 02 소스 — 사용자 세션으로 DB 함수(public.set_source_checks · save_source_use · add_direct_source)를 부른다.
 * 소유자·단계 상태·승인 조건·권리 근거 확인자 기록은 함수가 맡는다(20261112210000). service_role 은 쓰지 않는다.
 * 사용자가 누른 버튼의 서버 액션에서만 부른다(제작 파트너 AI 도구 목록에는 없다, planning.md 17-7).
 */

type Client = Awaited<ReturnType<typeof createClient>>;

export type SourceState = {
  sources: SourceView[];
  noticeAck: boolean;
  reason: string | null;
  status: StepStatusMap;
};
export type SourceActionResult = ({ ok: true } & SourceState) | { ok: false; error: string };
export type SelectJobResult = { ok: true; created: boolean } | { ok: false; error: string; retryable: boolean };

const NOT_FOUND = { ok: false, error: "프로젝트를 찾을 수 없거나 권한이 없습니다." } as const;
const LOAD_FAILED = "원본 목록을 불러오지 못했습니다. 잠시 뒤 다시 시도해 주세요.";

/** DB 오류 코드를 화면 문구로. 원문 메시지는 화면·로그에 내보내지 않는다 */
function toMessage(code: string | undefined) {
  switch (code) {
    case "42501":
      return "이 프로젝트를 바꿀 권한이 없습니다. 다시 로그인해 주세요.";
    case "55000":
      return "지금 단계 상태에서는 원본을 바꿀 수 없습니다. 화면의 최신 상태를 확인해 주세요.";
    case "22023":
      return "저장할 수 없는 값이 있습니다. 내려받은 원본만 사용으로 체크할 수 있습니다.";
    case "23505":
      return "이미 추가한 URL입니다.";
    default:
      return "요청을 처리하지 못했습니다. 잠시 뒤 다시 시도해 주세요.";
  }
}

const num = (v: unknown) => (typeof v === "number" ? v : typeof v === "string" && v !== "" && !Number.isNaN(Number(v)) ? Number(v) : null);
const str = (v: unknown) => (typeof v === "string" ? v : null);

function toView(row: Record<string, unknown>): SourceView | null {
  if (!isPlatform(row.platform)) return null;
  return {
    id: String(row.id),
    platform: row.platform,
    url: String(row.url),
    author: String(row.author),
    title: str(row.title),
    collectedAt: String(row.collected_at),
    width: num(row.width),
    height: num(row.height),
    durationSec: num(row.duration_sec),
    score: num(row.score),
    downloaded: typeof row.file_path === "string" && row.file_deleted_at === null,
    checked: row.checked === true,
    used: row.used === true,
    excludeReason: str(row.exclude_reason),
    quarantined: row.quarantined === true,
    rightsBasis: isRightsBasis(row.rights_basis) ? row.rights_basis : null,
    rightsConfirmedAt: str(row.rights_confirmed_at),
  };
}

export async function loadSourceState(supabase: Client, projectId: string): Promise<SourceState | null> {
  const [{ data: project, error: projectError }, { data: rows, error: rowsError }] = await Promise.all([
    supabase
      .from("projects")
      .select("step_status, sources_notice_ack_at, sources_shortage_reason")
      .eq("id", projectId)
      .maybeSingle(),
    supabase
      .from("sources")
      .select(
        "id, platform, url, author, title, collected_at, width, height, duration_sec, score, file_path, file_deleted_at, checked, used, exclude_reason, quarantined, rights_basis, rights_confirmed_at",
      )
      .eq("project_id", projectId)
      .order("collected_at", { ascending: true }),
  ]);
  if (projectError || rowsError) throw new Error("sources_load_failed");
  const status = parseStepStatus(project?.step_status);
  if (!project || !status) return null;
  return {
    sources: (rows ?? []).map((r) => toView(r as Record<string, unknown>)).filter((s): s is SourceView => s !== null),
    noticeAck: project.sources_notice_ack_at !== null,
    reason: project.sources_shortage_reason,
    status,
  };
}

async function reload(supabase: Client, projectId: string): Promise<SourceActionResult> {
  try {
    const state = await loadSourceState(supabase, projectId);
    return state ? { ok: true, ...state } : NOT_FOUND;
  } catch {
    return { ok: false, error: LOAD_FAILED };
  }
}

const isUuid = (v: unknown): v is string => typeof v === "string" && isProjectId(v);
const isIdList = (v: unknown): v is string[] => Array.isArray(v) && v.length <= 100 && v.every(isUuid);

export async function setDownloadChecks(projectId: string, sourceIds: unknown): Promise<SourceActionResult> {
  if (!isProjectId(projectId) || !isIdList(sourceIds)) return { ok: false, error: "잘못된 요청입니다." };
  if (new Set(sourceIds).size > MAX_DOWNLOAD_CHECKS) return { ok: false, error: `다운로드는 ${MAX_DOWNLOAD_CHECKS}편까지 체크할 수 있습니다.` };
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_source_checks", { p_project_id: projectId, p_source_ids: [...new Set(sourceIds)] });
  if (error) return { ok: false, error: toMessage(error.code) };
  return reload(supabase, projectId);
}

function isUseList(v: unknown): v is UseEntry[] {
  return (
    Array.isArray(v) &&
    v.length <= 100 &&
    v.every((e) => typeof e === "object" && e !== null && isUuid((e as UseEntry).id) && isRightsBasis((e as UseEntry).rights_basis))
  );
}

export async function saveSourceUse(projectId: string, uses: unknown, noticeAck: unknown, reason: unknown): Promise<SourceActionResult> {
  if (!isProjectId(projectId) || !isUseList(uses) || typeof noticeAck !== "boolean" || (reason !== null && typeof reason !== "string")) {
    return { ok: false, error: "잘못된 요청입니다." };
  }
  const trimmed = (reason ?? "").trim();
  if (trimmed.length > MAX_REASON) return { ok: false, error: `부족 사유는 ${MAX_REASON}자까지 쓸 수 있습니다.` };
  const supabase = await createClient();
  const { error } = await supabase.rpc("save_source_use", {
    p_project_id: projectId,
    p_uses: uses.map((u) => ({ id: u.id, rights_basis: u.rights_basis })),
    p_notice_ack: noticeAck,
    p_reason: trimmed,
  });
  if (error) return { ok: false, error: toMessage(error.code) };
  return reload(supabase, projectId);
}

export async function addDirectSource(projectId: string, url: unknown, author: unknown, title: unknown): Promise<SourceActionResult> {
  if (!isProjectId(projectId) || typeof url !== "string" || typeof author !== "string" || typeof title !== "string") {
    return { ok: false, error: "잘못된 요청입니다." };
  }
  const invalid = directSourceError(url, author, title);
  if (invalid) return { ok: false, error: invalid };
  const supabase = await createClient();
  const { error } = await supabase.rpc("add_direct_source", {
    p_project_id: projectId,
    p_url: url.trim(),
    p_author: author.trim(),
    p_title: title.trim(),
  });
  if (error) return { ok: false, error: toMessage(error.code) };
  return reload(supabase, projectId);
}

/** 원본 선정(select_sources) 작업 시작. 멱등 키는 버튼을 누를 때 화면이 한 번 만들어 재시도에 그대로 쓴다 */
export async function startSourceSelection(projectId: string, idempotencyKey: unknown): Promise<SelectJobResult> {
  if (!isProjectId(projectId) || typeof idempotencyKey !== "string") return { ok: false, error: "잘못된 요청입니다.", retryable: false };
  const supabase = await createClient();
  const result = await createJob(supabase, { projectId, type: "select_sources", idempotencyKey });
  if (result.ok) return { ok: true, created: result.job.created };
  switch (result.code) {
    case "insufficient_credits":
      return { ok: false, error: `크레딧이 부족합니다(필요 ${result.required} · 잔액 ${result.balance}).`, retryable: false };
    case "step_not_ready":
      return { ok: false, error: "01 소재를 먼저 승인해 주세요. 이미 승인된 소스는 변경 필요 후 다시 시작할 수 있습니다.", retryable: false };
    case "forbidden":
      return { ok: false, error: "이 프로젝트를 바꿀 권한이 없습니다.", retryable: false };
    case "invalid":
    case "conflict":
      return { ok: false, error: "잘못된 요청입니다. 화면을 새로 고친 뒤 다시 시도해 주세요.", retryable: false };
    default:
      return { ok: false, error: "작업을 시작하지 못했습니다. 잠시 뒤 다시 시도해 주세요.", retryable: true };
  }
}
