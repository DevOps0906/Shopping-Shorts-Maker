import "server-only";
import { createJob } from "@/lib/jobs/create-job";
import { isProjectId } from "@/lib/steps/project-id";
import type { StepStatusMap } from "@/lib/steps/state";
import { RECORDING_ERRORS, RECORDING_MAX_BYTES, checkRecording } from "@/lib/voice/recording";
import { type TakeView, type VoiceJobView, isVoiceId, parseSentences, parseWords } from "@/lib/voice/voices";
import { type OwnedProject, loadOwnedProject } from "@/server/llm/project-access";
import { markStep } from "@/server/llm/step-mark";
import { createAdminClient } from "@/server/supabase-admin";

/*
 * 04 목소리(S-09) — docs/planning.md 3장 04 · 17-5 · 17-6.
 * - 음성 생성: 사용자 세션으로 tts 작업을 만든다(create_job: 단계·멱등·잔액·예약). 워커는 Storage 키가 없으므로
 *   이 서버가 voices 버킷 서명 업로드 URL(기한 10분)을 만들어 payload 에 넣는다(팀장 결정). URL은 로그에 남기지 않는다.
 * - 직접 녹음: 소유권·단계 상태를 사용자 세션으로 확인한 뒤 서버 키로 비공개 voices 버킷에 올리고 voice_takes 에 기록한다.
 * - 재생: 소유권을 확인한 뒤 10분짜리 서명 다운로드 URL만 준다(공개 URL 없음).
 * - 승인 조건(음성 1개 이상): 테이크가 생긴 뒤에만 4단계를 ready 로 바꾼다. 승인은 StepActions 버튼만.
 */

const BUCKET = "voices";
const UPLOAD_TTL_MS = 10 * 60 * 1000;
const PLAY_TTL_SEC = 10 * 60;

export type VoiceStepData = { lines: string[]; take: TakeView | null; job: VoiceJobView | null };

export type StartTtsResult = { ok: true; jobId: string } | { ok: false; error: string };
export type PollResult =
  | { ok: true; job: VoiceJobView; take: TakeView | null; status: StepStatusMap | null }
  | { ok: false; error: string };
export type RecordingResult = { ok: true; take: TakeView; status: StepStatusMap | null } | { ok: false; error: string };

const NOT_FOUND = { ok: false, error: "프로젝트를 찾을 수 없거나 권한이 없습니다." } as const;
const TAKE_COLUMNS = "id, source, voice_id, audio_path, duration_sec, sentences, words, created_at";

type TakeRow = {
  id: string;
  source: string;
  voice_id: string | null;
  audio_path: string | null;
  duration_sec: number | null;
  sentences: unknown;
  words: unknown;
  created_at: string;
};

function precondition(project: OwnedProject): string | null {
  if (project.status[3] !== "approved") return "03 대본을 먼저 승인해 주세요.";
  if (project.status[4] === "approved") return "승인된 음성입니다. 바꾸려면 아래 변경 필요를 눌러 주세요.";
  return null;
}

async function toTakeView(row: TakeRow | null): Promise<TakeView | null> {
  if (!row) return null;
  let audioUrl: string | null = null;
  if (row.audio_path) {
    const { data } = await createAdminClient().storage.from(BUCKET).createSignedUrl(row.audio_path, PLAY_TTL_SEC);
    audioUrl = data?.signedUrl ?? null;
  }
  return {
    id: row.id,
    source: row.source === "recording" ? "recording" : "tts",
    voiceId: row.voice_id,
    durationSec: row.duration_sec === null ? null : Number(row.duration_sec),
    audioUrl,
    sentences: parseSentences(row.sentences),
    words: parseWords(row.words),
    createdAt: row.created_at,
  };
}

/** 본문 로더: 승인 대본 · 최신 테이크 · 진행 중 tts 작업 */
export async function loadVoiceStep(projectId: string): Promise<VoiceStepData | null> {
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return null;
  const [scriptRes, takeRes, jobRes] = await Promise.all([
    supabase
      .from("scripts")
      .select("lines")
      .eq("project_id", project.id)
      .not("approved_at", "is", null)
      .order("version", { ascending: false })
      .limit(1)
      .maybeSingle(),
    supabase.from("voice_takes").select(TAKE_COLUMNS).eq("project_id", project.id).order("created_at", { ascending: false }).limit(1).maybeSingle(),
    supabase
      .from("jobs")
      .select("id, status, error, started_at")
      .eq("project_id", project.id)
      .eq("type", "tts")
      .in("status", ["queued", "running"])
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle(),
  ]);
  if (scriptRes.error || takeRes.error || jobRes.error) throw new Error("voice_load_failed");
  const lines = Array.isArray(scriptRes.data?.lines) ? scriptRes.data.lines.filter((l): l is string => typeof l === "string") : [];
  const job = jobRes.data
    ? { id: String(jobRes.data.id), status: String(jobRes.data.status), error: jobRes.data.error, startedAt: jobRes.data.started_at }
    : null;
  return { lines, take: await toTakeView(takeRes.data as TakeRow | null), job };
}

export async function startTts(projectId: string, voiceId: unknown, idempotencyKey: unknown): Promise<StartTtsResult> {
  if (!isVoiceId(voiceId)) return { ok: false, error: "목소리를 다시 골라 주세요." };
  if (typeof idempotencyKey !== "string") return { ok: false, error: "잘못된 요청입니다." };
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return NOT_FOUND;
  const blocked = precondition(project);
  if (blocked) return { ok: false, error: blocked };

  const objectPath = `${project.userId}/${project.id}/tts-${crypto.randomUUID()}.wav`;
  const { data: signed, error: signError } = await createAdminClient().storage.from(BUCKET).createSignedUploadUrl(objectPath, { upsert: true });
  if (signError || !signed) return { ok: false, error: "음성 저장 공간을 준비하지 못했습니다. 잠시 뒤 다시 시도해 주세요." };

  const result = await createJob(supabase, {
    projectId: project.id,
    type: "tts",
    idempotencyKey,
    payload: { voice_id: voiceId, upload_url: signed.signedUrl, upload_expires_at: new Date(Date.now() + UPLOAD_TTL_MS).toISOString() },
  });
  if (result.ok) return { ok: true, jobId: result.job.id };
  switch (result.code) {
    case "insufficient_credits":
      return { ok: false, error: `크레딧이 부족합니다(필요 ${result.required} · 잔액 ${result.balance}).` };
    case "step_not_ready":
      return { ok: false, error: "03 대본을 먼저 승인해 주세요. 이미 승인된 음성은 변경 필요 후 다시 만들 수 있습니다." };
    case "forbidden":
      return { ok: false, error: "이 프로젝트를 바꿀 권한이 없습니다." };
    case "invalid":
    case "conflict":
      return { ok: false, error: "잘못된 요청입니다. 화면을 새로 고친 뒤 다시 시도해 주세요." };
    default:
      return { ok: false, error: "음성 생성을 시작하지 못했습니다. 잠시 뒤 다시 시도해 주세요." };
  }
}

/** 작업 상태 확인(화면이 2초마다). 성공하면 테이크를 돌려주고 4단계를 ready 로 */
export async function pollTts(projectId: string, jobId: unknown): Promise<PollResult> {
  if (typeof jobId !== "string" || !isProjectId(jobId)) return { ok: false, error: "잘못된 요청입니다." };
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return NOT_FOUND;
  const { data: job, error } = await supabase
    .from("jobs")
    .select("id, status, error, started_at")
    .eq("id", jobId)
    .eq("project_id", project.id)
    .eq("type", "tts")
    .maybeSingle();
  if (error) return { ok: false, error: "작업 상태를 읽지 못했습니다. 잠시 뒤 다시 확인합니다." };
  if (!job) return NOT_FOUND;
  const view: VoiceJobView = { id: String(job.id), status: String(job.status), error: job.error, startedAt: job.started_at };
  if (view.status !== "succeeded") return { ok: true, job: view, take: null, status: null };

  const { data: row } = await supabase.from("voice_takes").select(TAKE_COLUMNS).eq("job_id", view.id).maybeSingle();
  const take = await toTakeView(row as TakeRow | null);
  const status = take && project.status[4] !== "approved" ? await markStep(project.id, 4, "ready") : null;
  return { ok: true, job: view, take, status };
}

/** 녹음 업로드 전 인증·소유권·단계 확인(Route Handler 가 본문을 읽기 전에 부른다) */
export async function checkRecordingAccess(projectId: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return NOT_FOUND;
  const blocked = precondition(project);
  return blocked ? { ok: false, error: blocked } : { ok: true };
}

/** 녹음 업로드(Route Handler voice/route.ts 에서 부른다 — 서버 액션 본문 1MB 상한을 피하려고) */
export async function uploadRecording(projectId: string, file: unknown, durationSec: unknown): Promise<RecordingResult> {
  if (!(file instanceof File) || file.size === 0) return { ok: false, error: RECORDING_ERRORS.empty };
  if (file.size > RECORDING_MAX_BYTES) return { ok: false, error: RECORDING_ERRORS.tooBig };
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return NOT_FOUND;
  const blocked = precondition(project);
  if (blocked) return { ok: false, error: blocked };

  const bytes = new Uint8Array(await file.arrayBuffer());
  const checked = checkRecording(bytes, bytes.byteLength, durationSec);
  if (!checked.ok) return checked;

  const admin = createAdminClient();
  const objectPath = `${project.userId}/${project.id}/rec-${crypto.randomUUID()}.${checked.kind.ext}`;
  const { error: uploadError } = await admin.storage
    .from(BUCKET)
    .upload(objectPath, bytes, { contentType: checked.kind.mime, upsert: false });
  if (uploadError) return { ok: false, error: "녹음 파일을 저장하지 못했습니다. 잠시 뒤 다시 시도해 주세요." };

  const { data: row, error: insertError } = await admin
    .from("voice_takes")
    .insert({ project_id: project.id, source: "recording", audio_path: objectPath, duration_sec: checked.durationSec })
    .select(TAKE_COLUMNS)
    .single();
  if (insertError || !row) {
    await admin.storage.from(BUCKET).remove([objectPath]);
    return { ok: false, error: "녹음 파일을 저장하지 못했습니다. 잠시 뒤 다시 시도해 주세요." };
  }
  const take = await toTakeView(row as TakeRow);
  if (!take) return { ok: false, error: "녹음 파일을 저장하지 못했습니다." };
  const status = await markStep(project.id, 4, "ready");
  return { ok: true, take, status };
}
