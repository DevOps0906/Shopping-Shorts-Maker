import "server-only";
import { type Candidate, type RenderJobView, type RenderView, type SentenceSpan, parseCutMap, planCuts } from "@/lib/edit/plan";
import { createJob } from "@/lib/jobs/create-job";
import { isProjectId } from "@/lib/steps/project-id";
import type { StepStatusMap } from "@/lib/steps/state";
import { parseSentences } from "@/lib/voice/voices";
import { type OwnedProject, loadOwnedProject } from "@/server/llm/project-access";
import { markStep } from "@/server/llm/step-mark";
import { createAdminClient } from "@/server/supabase-admin";

/*
 * 05 편집(S-10) — docs/planning.md 3장 05 · 17-5 · 17-6 · D7.
 * - 매칭 후보: 사용자 세션으로 DB 함수 edit_input_sources(권리 근거 있음 · 격리 아님 · 고지 확인)만 읽는다. 미확인 원본은 후보에 없다.
 * - MP4 만들기: 사용자 세션으로 render 작업을 만든다(create_job: 단계·멱등·잔액·예약). 워커는 Storage 키가 없으므로
 *   이 서버가 원본·음성 서명 다운로드 URL과 renders 서명 업로드 URL(기한 30분)을 payload 에 넣는다(팀장 결정). URL은 로그에 남기지 않는다.
 *   워커는 payload 를 믿지 않고 DB 함수(private.render_job_context · save_render)로 원본 조건을 다시 검사한다.
 * - 미리보기·다운로드: 소유권을 확인한 뒤 10분짜리 서명 다운로드 URL만 준다(공개 URL 없음).
 * - 승인 조건(검토본 1개 이상): 렌더가 성공한 뒤에만 5단계를 ready 로 바꾼다. 승인은 StepActions 버튼만.
 * - 스케일업·자막/워터마크 제거는 3단계 유료 후보라 구현하지 않는다(버튼 비활성 표시만).
 */

const LINK_TTL_SEC = 30 * 60;
const PLAY_TTL_SEC = 10 * 60;
const MAX_VERSIONS = 10;

export type EditTake = { id: string; source: "tts" | "recording"; durationSec: number; sentences: SentenceSpan[] };
export type EditStepData = {
  targetSec: number;
  lines: string[];
  take: EditTake | null;
  candidates: Candidate[];
  renders: RenderView[];
  job: RenderJobView | null;
  lastError: string | null;
};

export type StartRenderResult = { ok: true; jobId: string } | { ok: false; error: string };
export type PollRenderResult =
  | { ok: true; job: RenderJobView; render: RenderView | null; status: StepStatusMap | null }
  | { ok: false; error: string };

const NOT_FOUND = { ok: false, error: "프로젝트를 찾을 수 없거나 권한이 없습니다." } as const;
const RENDER_COLUMNS = "id, version, created_at, duration_sec, cut_map, mp4_path";

type Client = NonNullable<Awaited<ReturnType<typeof loadOwnedProject>>["supabase"]>;
type RenderRow = {
  id: string;
  version: number;
  created_at: string;
  duration_sec: number | null;
  cut_map: unknown;
  mp4_path: string | null;
};
type SourceRow = { id: string; author: string; platform: string; duration_sec: number | null; score: number | null; rights_basis: string | null; file_path: string | null };

function precondition(project: OwnedProject): string | null {
  if (project.status[4] !== "approved") return "04 목소리를 먼저 승인해 주세요.";
  if (project.status[5] === "approved") return "승인된 편집입니다. 바꾸려면 아래 변경 필요를 눌러 주세요.";
  return null;
}

async function toRenderViews(rows: RenderRow[]): Promise<RenderView[]> {
  const paths = rows.flatMap((r) => (r.mp4_path ? [r.mp4_path] : []));
  const urls = new Map<string, string>();
  if (paths.length) {
    const { data } = await createAdminClient().storage.from("renders").createSignedUrls(paths, PLAY_TTL_SEC);
    for (const item of data ?? []) if (item.path && item.signedUrl) urls.set(item.path, item.signedUrl);
  }
  return rows.map((r) => {
    const map = parseCutMap(r.cut_map);
    return {
      id: r.id,
      version: r.version,
      createdAt: r.created_at,
      durationSec: r.duration_sec === null ? null : Number(r.duration_sec),
      videoUrl: r.mp4_path ? (urls.get(r.mp4_path) ?? null) : null,
      cuts: map?.cuts ?? [],
      credits: map?.credits ?? "",
    };
  });
}

/** 편집 입력 원본(점수 순) — 사용자 세션. file_path 는 서버 안에서만 쓴다 */
async function loadSources(supabase: Client, projectId: string): Promise<SourceRow[]> {
  const { data, error } = await supabase.rpc("edit_input_sources", { p_project_id: projectId });
  if (error) throw new Error("edit_sources_load_failed");
  return (data ?? []) as SourceRow[];
}

function toCandidates(rows: SourceRow[]): Candidate[] {
  return rows.map((s, i) => ({
    id: s.id,
    rank: i + 1,
    author: s.author,
    platform: s.platform,
    durationSec: s.duration_sec === null ? null : Number(s.duration_sec),
    score: s.score === null ? null : Number(s.score),
    rightsBasis: s.rights_basis ?? "",
  }));
}

async function loadInputs(supabase: Client, projectId: string) {
  const [scriptRes, takeRes] = await Promise.all([
    supabase
      .from("scripts")
      .select("lines")
      .eq("project_id", projectId)
      .not("approved_at", "is", null)
      .order("version", { ascending: false })
      .limit(1)
      .maybeSingle(),
    supabase
      .from("voice_takes")
      .select("id, source, duration_sec, sentences, audio_path")
      .eq("project_id", projectId)
      .not("audio_path", "is", null)
      .order("created_at", { ascending: false })
      .order("id", { ascending: false })
      .limit(1)
      .maybeSingle(),
  ]);
  if (scriptRes.error || takeRes.error) throw new Error("edit_load_failed");
  const lines = Array.isArray(scriptRes.data?.lines)
    ? scriptRes.data.lines.filter((l): l is string => typeof l === "string" && l.trim() !== "").map((l) => l.trim())
    : [];
  const t = takeRes.data;
  const take: (EditTake & { audioPath: string }) | null =
    t && t.audio_path && t.duration_sec !== null
      ? {
          id: String(t.id),
          source: t.source === "recording" ? "recording" : "tts",
          durationSec: Number(t.duration_sec),
          sentences: parseSentences(t.sentences),
          audioPath: t.audio_path,
        }
      : null;
  return { lines, take };
}

/** 본문 로더: 승인 대본 · 음성 · 매칭 후보 · 버전 목록 · 진행 중/최근 실패 render 작업 */
export async function loadEditStep(projectId: string): Promise<EditStepData | null> {
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return null;
  const [inputs, sources, rendersRes, jobRes] = await Promise.all([
    loadInputs(supabase, project.id),
    loadSources(supabase, project.id),
    supabase.from("renders").select(RENDER_COLUMNS).eq("project_id", project.id).order("version", { ascending: false }).limit(MAX_VERSIONS),
    supabase
      .from("jobs")
      .select("id, status, error, started_at")
      .eq("project_id", project.id)
      .eq("type", "render")
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle(),
  ]);
  if (rendersRes.error || jobRes.error) throw new Error("edit_load_failed");
  const latestJob = jobRes.data;
  const active = latestJob && (latestJob.status === "queued" || latestJob.status === "running");
  return {
    targetSec: project.targetSec,
    lines: inputs.lines,
    take: inputs.take ? { id: inputs.take.id, source: inputs.take.source, durationSec: inputs.take.durationSec, sentences: inputs.take.sentences } : null,
    candidates: toCandidates(sources),
    renders: await toRenderViews((rendersRes.data ?? []) as RenderRow[]),
    job: active ? { id: String(latestJob.id), status: String(latestJob.status), error: latestJob.error, startedAt: latestJob.started_at } : null,
    lastError: latestJob?.status === "failed" ? (latestJob.error ?? "렌더에 실패했습니다.") : null,
  };
}

export async function startRender(projectId: string, assignment: unknown, idempotencyKey: unknown): Promise<StartRenderResult> {
  if (typeof idempotencyKey !== "string" || !Array.isArray(assignment) || !assignment.every((x) => typeof x === "string" && isProjectId(x))) {
    return { ok: false, error: "잘못된 요청입니다." };
  }
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return NOT_FOUND;
  const blocked = precondition(project);
  if (blocked) return { ok: false, error: blocked };

  const [{ lines, take }, sources] = await Promise.all([loadInputs(supabase, project.id), loadSources(supabase, project.id)]);
  if (!take) return { ok: false, error: "04 목소리의 음성이 없습니다. 음성을 만든 뒤 다시 시도해 주세요." };
  const ids = assignment as string[];
  if (ids.length !== lines.length) return { ok: false, error: "컷 구성이 대본과 맞지 않습니다. 화면을 새로 고친 뒤 다시 시도해 주세요." };
  // 미확인·격리 원본은 후보(편집 입력)에 없으므로 여기서 걸린다
  const plan = planCuts(lines, take.sentences, take.durationSec, project.targetSec, ids, toCandidates(sources));
  if (!plan.ok) return plan;

  const admin = createAdminClient();
  const byId = new Map(sources.map((s) => [s.id, s]));
  const sourceUrls: Record<string, string> = {};
  for (const id of new Set(ids)) {
    const path = byId.get(id)?.file_path;
    const { data } = path ? await admin.storage.from("sources").createSignedUrl(path, LINK_TTL_SEC) : { data: null };
    if (!data?.signedUrl) return { ok: false, error: "원본 파일을 준비하지 못했습니다. 잠시 뒤 다시 시도해 주세요." };
    sourceUrls[id] = data.signedUrl;
  }
  const { data: voice } = await admin.storage.from("voices").createSignedUrl(take.audioPath, LINK_TTL_SEC);
  const objectPath = `${project.userId}/${project.id}/render-${crypto.randomUUID()}.mp4`;
  const { data: upload } = await admin.storage.from("renders").createSignedUploadUrl(objectPath, { upsert: true });
  if (!voice?.signedUrl || !upload) return { ok: false, error: "영상 저장 공간을 준비하지 못했습니다. 잠시 뒤 다시 시도해 주세요." };

  const result = await createJob(supabase, {
    projectId: project.id,
    type: "render",
    idempotencyKey,
    payload: {
      cuts: ids,
      take_id: take.id,
      voice_url: voice.signedUrl,
      source_urls: sourceUrls,
      upload_url: upload.signedUrl,
      upload_expires_at: new Date(Date.now() + LINK_TTL_SEC * 1000).toISOString(),
    },
  });
  if (result.ok) return { ok: true, jobId: result.job.id };
  switch (result.code) {
    case "insufficient_credits":
      return { ok: false, error: `크레딧이 부족합니다(필요 ${result.required} · 잔액 ${result.balance}).` };
    case "step_not_ready":
      return { ok: false, error: "04 목소리를 먼저 승인해 주세요. 이미 승인된 편집은 변경 필요 후 다시 만들 수 있습니다." };
    case "forbidden":
      return { ok: false, error: "이 프로젝트를 바꿀 권한이 없습니다." };
    case "invalid":
    case "conflict":
      return { ok: false, error: "잘못된 요청입니다. 화면을 새로 고친 뒤 다시 시도해 주세요." };
    default:
      return { ok: false, error: "MP4 만들기를 시작하지 못했습니다. 잠시 뒤 다시 시도해 주세요." };
  }
}

/** 작업 상태 확인(화면이 2초마다). 성공하면 새 버전을 돌려주고 5단계를 ready 로 */
export async function pollRender(projectId: string, jobId: unknown): Promise<PollRenderResult> {
  if (typeof jobId !== "string" || !isProjectId(jobId)) return { ok: false, error: "잘못된 요청입니다." };
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return NOT_FOUND;
  const { data: job, error } = await supabase
    .from("jobs")
    .select("id, status, error, started_at")
    .eq("id", jobId)
    .eq("project_id", project.id)
    .eq("type", "render")
    .maybeSingle();
  if (error) return { ok: false, error: "작업 상태를 읽지 못했습니다. 잠시 뒤 다시 확인합니다." };
  if (!job) return NOT_FOUND;
  const view: RenderJobView = { id: String(job.id), status: String(job.status), error: job.error, startedAt: job.started_at };
  if (view.status !== "succeeded") return { ok: true, job: view, render: null, status: null };

  const { data: row } = await supabase.from("renders").select(RENDER_COLUMNS).eq("job_id", view.id).maybeSingle();
  const [render] = row ? await toRenderViews([row as RenderRow]) : [null];
  const status = render && project.status[5] !== "approved" ? await markStep(project.id, 5, "ready") : null;
  return { ok: true, job: view, render, status };
}
