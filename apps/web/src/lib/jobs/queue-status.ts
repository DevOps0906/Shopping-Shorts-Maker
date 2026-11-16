import { uploadStatusView } from "@/components/publish/upload-status-copy";
import type { Json } from "@/types/db";

/*
 * 작업 현황(S-17) 데이터·문구 — 근거: docs/planning.md 17-5-1 화면 행·작업 현황 패널 행, docs/design.md 작업 현황 패널.
 * DB 함수 nomad_shorts.job_queue_status()(본인 행만)의 jsonb 를 화면 모델로 바꾼다. 필드를 추정하지 않고 모르는 값은 버린다.
 */

export type QueueKind = "render" | "tts" | "analyze";
export type ProductionState = "running" | "queued" | "deferred";
export type PostingState = "pending" | "retry_wait" | "uploading" | "scheduled" | "failed" | "reconnect_wait";

export type ProductionItem = {
  jobId: string;
  projectId: string;
  projectName: string;
  step: number;
  queue: QueueKind;
  state: ProductionState;
  startedAt: string | null;
  position: number | null;
  etaSeconds: number | null;
};

export type PostingItem = {
  publicationId: string;
  projectId: string;
  projectName: string;
  state: PostingState;
  /** publications.status 원문(needs_check 는 state 로는 failed). 사유 문구를 고를 때만 쓴다 */
  rawStatus: string;
  startedAt: string | null;
  scheduledAt: string | null;
  position: number | null;
  estStartAt: string | null;
  retryCount: number;
  error: string | null;
};

export type QueueStatus = { production: ProductionItem[]; posting: PostingItem[] };

export const EMPTY_QUEUE_STATUS: QueueStatus = { production: [], posting: [] };

function obj(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
}
const str = (v: unknown): string | null => (typeof v === "string" ? v : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

const QUEUES: readonly string[] = ["render", "tts", "analyze"];
const PRODUCTION_STATES: readonly string[] = ["running", "queued", "deferred"];
const POSTING_STATES: readonly string[] = ["pending", "retry_wait", "uploading", "scheduled", "failed", "reconnect_wait"];

export function parseQueueStatus(raw: Json | null | undefined): QueueStatus {
  const root = obj(raw);
  if (!root) return EMPTY_QUEUE_STATUS;

  const production: ProductionItem[] = [];
  for (const entry of Array.isArray(root.production) ? root.production : []) {
    const e = obj(entry);
    const jobId = str(e?.job_id);
    const projectId = str(e?.project_id);
    const queue = str(e?.queue);
    const state = str(e?.state);
    const step = num(e?.step);
    if (!e || !jobId || !projectId || !queue || !QUEUES.includes(queue) || !state || !PRODUCTION_STATES.includes(state) || step === null) {
      continue;
    }
    production.push({
      jobId,
      projectId,
      projectName: str(e.project_name) ?? "",
      step,
      queue: queue as QueueKind,
      state: state as ProductionState,
      startedAt: str(e.started_at),
      position: num(e.position),
      etaSeconds: num(e.eta_seconds),
    });
  }

  const posting: PostingItem[] = [];
  for (const entry of Array.isArray(root.posting) ? root.posting : []) {
    const e = obj(entry);
    const publicationId = str(e?.publication_id);
    const projectId = str(e?.project_id);
    const state = str(e?.state);
    if (!e || !publicationId || !projectId || !state || !POSTING_STATES.includes(state)) continue;
    posting.push({
      publicationId,
      projectId,
      projectName: str(e.project_name) ?? "",
      state: state as PostingState,
      rawStatus: str(e.raw_status) ?? state,
      startedAt: str(e.started_at),
      scheduledAt: str(e.scheduled_at),
      position: num(e.position),
      estStartAt: str(e.est_start_at),
      retryCount: num(e.retry_count) ?? 0,
      error: str(e.error),
    });
  }

  return { production, posting };
}

/** GNB 배지: 제작 중 전체 + 포스팅 대기 중 업로드 대기·재시도 대기·업로드 중(예약됨·실패·재연결 필요 제외) */
export function activeCount(status: QueueStatus): number {
  const posting = status.posting.filter((p) => p.state === "pending" || p.state === "retry_wait" || p.state === "uploading");
  return status.production.length + posting.length;
}

export function badgeText(count: number): string {
  return count > 9 ? "9+" : String(count);
}

export function badgeLabel(count: number): string {
  return `작업 현황, 진행·대기 중 ${count}건`;
}

export const QUEUE_LABEL: Record<QueueKind, string> = { render: "렌더링", tts: "음성 생성", analyze: "분석" };

/** 예상 대기 시간 문구: 1분 미만은 "곧", 그 외 올림한 분 */
export function waitPhrase(seconds: number): string {
  if (seconds < 60) return "곧";
  return `약 ${Math.ceil(seconds / 60)}분 뒤`;
}

export function elapsedPhrase(startedAt: string | null, now: number): string {
  const started = startedAt ? Date.parse(startedAt) : Number.NaN;
  if (Number.isNaN(started)) return "진행 중";
  const minutes = Math.floor(Math.max(0, now - started) / 60_000);
  return minutes < 1 ? "1분 미만 경과" : `${minutes}분 경과`;
}

function secondsUntil(iso: string | null, now: number): number | null {
  const at = iso ? Date.parse(iso) : Number.NaN;
  return Number.isNaN(at) ? null : Math.max(0, Math.round((at - now) / 1000));
}

export type JobRowView = {
  key: string;
  projectId: string;
  /** 프로젝트 · 단계 */
  title: string;
  sub: string;
  chip: string;
  tone: "run" | "wait" | "ok" | "bad" | "none";
  when: string;
  /** 이동할 단계 번호(1~6) */
  step: number;
};

/** 예약 시각: 오늘·내일은 말로, 그 외는 월/일 */
export function scheduleLabel(iso: string | null, now: number): string {
  const at = iso ? new Date(iso) : null;
  if (!at || Number.isNaN(at.getTime())) return "예약 시각 확인 필요";
  const today = new Date(now);
  const startOf = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const diffDays = Math.round((startOf(at) - startOf(today)) / 86_400_000);
  const time = `${String(at.getHours()).padStart(2, "0")}:${String(at.getMinutes()).padStart(2, "0")}`;
  const day = diffDays === 0 ? "오늘" : diffDays === 1 ? "내일" : `${at.getMonth() + 1}월 ${at.getDate()}일`;
  return `${day} ${time}에 올라갑니다`;
}

const STEP_NAMES = ["소재", "소스", "대본", "목소리", "편집", "발행"];
const stepTitle = (name: string, step: number) => `${name || "프로젝트"} · 0${step} ${STEP_NAMES[step - 1] ?? ""}`.trim();

export function productionRow(item: ProductionItem, now: number): JobRowView {
  const base = { key: item.jobId, projectId: item.projectId, title: stepTitle(item.projectName, item.step), sub: QUEUE_LABEL[item.queue], step: item.step };
  if (item.state === "running") return { ...base, chip: "진행 중", tone: "run", when: elapsedPhrase(item.startedAt, now) };
  if (item.state === "deferred") return { ...base, chip: "미룸", tone: "none", when: "앞 작업이 끝나면 시작" };
  return {
    ...base,
    chip: item.position ? `대기 ${item.position}번째` : "대기",
    tone: "wait",
    when: item.etaSeconds === null ? "곧 시작" : item.etaSeconds < 60 ? "곧 시작" : `${waitPhrase(item.etaSeconds)} 시작`,
  };
}

const REASON_FALLBACK = "업로드 상태를 확인해 주세요.";

/** 실패·재연결 필요 사유: DB 분류 코드(kind:code)는 06 발행의 사용자 문구로 바꿔 보여 주고, 원문 코드는 노출하지 않는다 */
function reasonText(item: PostingItem): string {
  const view = uploadStatusView(
    { status: item.rawStatus, error: item.error, nextAttemptAt: null, retryCount: item.retryCount, scheduledAt: null, videoId: null },
    (iso) => iso,
  );
  return view?.message ?? REASON_FALLBACK;
}

export function postingRow(item: PostingItem, now: number): JobRowView {
  const base = { key: item.publicationId, projectId: item.projectId, title: item.projectName || "프로젝트", step: 6 };
  switch (item.state) {
    case "pending": {
      const eta = secondsUntil(item.estStartAt, now);
      return {
        ...base,
        sub: "업로드 대기",
        chip: item.position ? `순번 ${item.position}번째` : "업로드 대기",
        tone: "wait",
        when: eta === null ? "곧 시작" : eta < 60 ? "곧 시작" : `예상 시작 ${waitPhrase(eta)}`,
      };
    }
    case "retry_wait": {
      const eta = secondsUntil(item.estStartAt, now);
      return {
        ...base,
        sub: `업로드 실패, 자동 재시도 ${Math.min(item.retryCount + 1, 3)}/3`,
        chip: "재시도 대기",
        tone: "wait",
        when: eta === null || eta < 60 ? "곧 다시 시도" : `${waitPhrase(eta)} 다시 시도(자동 3회까지)`,
      };
    }
    case "uploading":
      return { ...base, sub: "업로드 중", chip: "업로드 중", tone: "run", when: elapsedPhrase(item.startedAt, now) };
    case "scheduled":
      return { ...base, sub: "예약 발행", chip: "예약됨", tone: "ok", when: scheduleLabel(item.scheduledAt, now) };
    case "reconnect_wait":
      return { ...base, sub: reasonText(item), chip: "재연결 필요", tone: "bad", when: "발행 화면에서 확인하기" };
    case "failed":
      return { ...base, sub: reasonText(item), chip: "실패", tone: "bad", when: "발행 화면에서 확인하기" };
  }
}

/** 02~05 단계 상태 배너의 대기 문구(design.md 5-6 ③). 실행 중·해당 작업 없음이면 null */
export type QueueBanner = { title: string; chip: string; description: string };

export function queueBanner(items: ProductionItem[], projectId: string, step: number): QueueBanner | null {
  const item = items.find((i) => i.projectId === projectId && i.step === step && i.state !== "running");
  if (!item) return null;
  if (item.state === "deferred") {
    return {
      title: "앞 작업이 끝나면 시작",
      chip: "미룸",
      description: "같은 종류의 작업은 한 번에 하나씩 실행합니다. 앞 작업이 끝나면 자동으로 시작합니다.",
    };
  }
  const ahead = Math.max((item.position ?? 1) - 1, 0);
  const eta = item.etaSeconds;
  const label = QUEUE_LABEL[item.queue];
  const when = eta !== null && eta >= 60 ? ` · ${waitPhrase(eta)} 시작` : " · 곧 시작";
  return {
    title: `${label} 대기 ${item.position ?? 1}번째${when}`,
    chip: `${item.position ?? 1}번째`,
    description:
      ahead > 0
        ? `앞선 작업 ${ahead}개가 끝나면 시작합니다. 이 화면을 닫아도 작업은 이어지고 작업 현황에서 볼 수 있습니다.`
        : "곧 시작합니다. 이 화면을 닫아도 작업은 이어지고 작업 현황에서 볼 수 있습니다.",
  };
}

/** 사용자당 같은 종류 대기·실행 상한(가설). DB nomad_shorts_private.job_queue_limit 과 같은 값 — 안내 문구 판단에만 쓴다 */
export const QUEUE_LIMIT: Record<QueueKind, number> = { render: 3, tts: 5, analyze: 5 };

/** 상한에 이른 종류가 있으면 사전 안내(role=status). 실제 거절(JQ001)은 TOO_MANY_JOBS_MESSAGE 경고(role=alert)로 따로 보인다. 없으면 null */
export function limitNotice(items: ProductionItem[]): string | null {
  for (const queue of ["render", "tts", "analyze"] as const) {
    const count = items.filter((i) => i.queue === queue).length;
    if (count >= QUEUE_LIMIT[queue]) {
      return `${QUEUE_LABEL[queue]} 작업이 이미 ${count}개 대기·진행 중입니다. 새 작업은 앞 작업이 끝나야 시작할 수 있어요.`;
    }
  }
  return null;
}

/** JQ001(too_many_jobs) 거절 안내 문구(크레딧은 차감되지 않는다) */
export const TOO_MANY_JOBS_MESSAGE = "앞 작업이 끝난 뒤 다시 시도해 주세요(크레딧 차감 없음)";
