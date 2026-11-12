import { STUDIO_STEPS } from "@/lib/routes";

/*
 * 프로젝트 목록·홈에서 쓰는 표시용 순수 함수. 근거: docs/03_SCREENS_UX.md S-01·S-03,
 * design/prototype/Main.dc.html projView(진행 문구·진행 바·상태 배지).
 * projects.status 값은 supabase/migrations/20261112160300 의 check 제약과 같다.
 */

export const PROJECT_STATUSES = ["in_progress", "awaiting_publish", "scheduled", "uploaded"] as const;
export type ProjectStatus = (typeof PROJECT_STATUSES)[number];
export type StatusFilter = ProjectStatus | "all";

export const STATUS_LABEL: Record<ProjectStatus, string> = {
  in_progress: "진행 중",
  awaiting_publish: "발행 대기",
  scheduled: "예약됨",
  uploaded: "업로드됨",
};

/** 상태 배지 색. 예약됨의 파란 배지(프로토타입 .s-up)는 토큰이 없어 보라 계열 중립색으로 대신한다. */
export const STATUS_BADGE: Record<ProjectStatus, string> = {
  in_progress: "bg-accent-weak text-nav-on-ink",
  awaiting_publish: "bg-warning-bg text-warning-fg",
  scheduled: "bg-count-bg text-nav-ink",
  uploaded: "bg-success-bg text-success-fg",
};

export function isProjectStatus(value: unknown): value is ProjectStatus {
  return typeof value === "string" && (PROJECT_STATUSES as readonly string[]).includes(value);
}

/** URL ?status= 값. 모르는 값은 전체로 본다. */
export function parseStatusFilter(value: unknown): StatusFilter {
  return isProjectStatus(value) ? value : "all";
}

/** 진행 중·발행 대기 = 아직 손이 가는 프로젝트(홈 "이어서 만들기") */
export function isActive(status: ProjectStatus) {
  return status === "in_progress" || status === "awaiting_publish";
}

function clampStep(step: number) {
  return Math.min(6, Math.max(1, Math.trunc(step) || 1));
}

/** 진행 칸 문구: "03 대본" · "06 발행 대기" · "예약됨" · "발행 완료" */
export function stepLabel(status: ProjectStatus, currentStep: number) {
  if (status === "awaiting_publish") return "06 발행 대기";
  if (status === "scheduled") return "발행 예약";
  if (status === "uploaded") return "발행 완료";
  const step = clampStep(currentStep);
  return `0${step} ${STUDIO_STEPS[step - 1].label}`;
}

/** 진행 바(%) — 진행 중이면 현재 단계의 절반까지, 발행 이후는 100 */
export function progressPercent(status: ProjectStatus, currentStep: number) {
  if (!isActive(status)) return 100;
  return Math.round(((clampStep(currentStep) - 0.5) / 6) * 100);
}

/** 이어서 하기·열기 링크: 현재 단계 화면 */
export function studioHref(projectId: string, currentStep: number) {
  return `/studio/${projectId}/${STUDIO_STEPS[clampStep(currentStep) - 1].slug}`;
}

/* 채널 플랫폼 — accounts.platform check 제약과 같다. xiaohongshu는 수집 전용이라 업로드 채널이 아니다. */
export const PLATFORM_LABEL: Record<string, string> = {
  youtube: "YouTube",
  instagram: "Instagram",
  tiktok: "TikTok",
  xiaohongshu: "샤오홍슈",
};
export const UPLOAD_LABEL: Record<string, string> = {
  youtube: "YouTube Shorts",
  instagram: "Instagram Reels",
  tiktok: "TikTok",
};
export const PLATFORM_TAG: Record<string, string> = {
  youtube: "bg-pt-yt-bg text-pt-yt-fg",
  instagram: "bg-pt-ig-bg text-pt-ig-fg",
  tiktok: "bg-pt-tt-bg text-pt-tt-fg",
  xiaohongshu: "bg-pt-xhs-bg text-pt-xhs-fg",
};

export function isUploadPlatform(platform: string) {
  return platform in UPLOAD_LABEL;
}

const KST_FORMAT = new Intl.DateTimeFormat("ko-KR", {
  timeZone: "Asia/Seoul",
  month: "numeric",
  day: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  hour12: false,
});

/** 수정 시각 표시(한국 시간) */
export function formatDateTime(iso: string) {
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? "-" : KST_FORMAT.format(date);
}

/** 이번 주 시작(한국 시간 월요일 0시)의 UTC ISO 문자열 — 홈 "이번 주 업로드" 기준 */
export function weekStartKst(now: Date) {
  const kstMs = now.getTime() + 9 * 3600_000;
  const kst = new Date(kstMs);
  const daysSinceMonday = (kst.getUTCDay() + 6) % 7;
  const mondayKst = Date.UTC(kst.getUTCFullYear(), kst.getUTCMonth(), kst.getUTCDate() - daysSinceMonday);
  return new Date(mondayKst - 9 * 3600_000).toISOString();
}

/** PostgREST 임베드는 관계에 따라 객체 또는 배열로 온다 */
export function embeddedText(value: unknown, key: string): string | null {
  const row = Array.isArray(value) ? value[0] : value;
  if (typeof row !== "object" || row === null) return null;
  const text = (row as Record<string, unknown>)[key];
  return typeof text === "string" ? text : null;
}
