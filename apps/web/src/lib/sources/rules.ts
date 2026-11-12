/*
 * 02 소스 규칙 — 정본은 docs/planning.md 3장 02(승인 조건)와 17-2 D1·D7·D8,
 * DB 강제는 supabase/migrations/20261112210000_source_selection.sql
 * (private.source_approval_problem · public.edit_input_sources). 이 파일은 같은 판단을 하는 순수 함수만 둔다.
 * 화면의 안내·버튼 상태에 쓰고, 실제 저장·승인은 항상 DB 함수가 다시 검사한다.
 */

export const PLATFORMS = ["tiktok", "xiaohongshu", "direct"] as const;
export type SourcePlatform = (typeof PLATFORMS)[number];

export const RIGHTS_BASES = ["attribution_notice", "own", "seller", "licensed"] as const;
export type RightsBasis = (typeof RIGHTS_BASES)[number];

/** D8: 체크(다운로드)는 10편까지, 사용은 5편 이상(3~4편은 사유 예외) */
export const MAX_DOWNLOAD_CHECKS = 10;
export const USE_TARGET = 5;
export const USE_MINIMUM = 3;
/** 4장: 자동 수집 목록은 점수 상위 20편 */
export const LIST_LIMIT = 20;
export const MAX_REASON = 500;

export const PLATFORM_LABEL: Record<SourcePlatform, string> = {
  tiktok: "TikTok",
  xiaohongshu: "小红书",
  direct: "직접 추가",
};

export const RIGHTS_LABEL: Record<RightsBasis, string> = {
  attribution_notice: "출처 표기(고지 확인)",
  own: "자체 촬영",
  seller: "판매자 제공",
  licensed: "사용 허락 받음",
};

export type SourceView = {
  id: string;
  platform: SourcePlatform;
  url: string;
  author: string;
  title: string | null;
  collectedAt: string;
  width: number | null;
  height: number | null;
  durationSec: number | null;
  score: number | null;
  /** 내려받은 파일이 있음(file_path 있고 삭제되지 않음) */
  downloaded: boolean;
  checked: boolean;
  used: boolean;
  excludeReason: string | null;
  /** 워커가 형식 위장·경로 오류로 거부한 원본. 사용·편집 입력에서 빠진다(순위 밖 제외와 다름) */
  quarantined: boolean;
  rightsBasis: RightsBasis | null;
  rightsConfirmedAt: string | null;
};

export type ApprovalProblem = "too_few" | "reason_required" | "notice_required";

/** 편집에 쓸 수 있는 원본: 사용 + 권리 근거 확인 + 내려받은 파일 */
function isConfirmedUse(s: SourceView) {
  return s.used && !s.quarantined && s.rightsBasis !== null && s.rightsConfirmedAt !== null && s.downloaded;
}

/** private.source_approval_problem 과 같은 판단. 통과면 null */
export function approvalProblem(sources: readonly SourceView[], noticeAck: boolean, reason: string | null): ApprovalProblem | null {
  const used = sources.filter(isConfirmedUse);
  if (used.length < USE_MINIMUM) return "too_few";
  if (used.length < USE_TARGET && (reason ?? "").trim() === "") return "reason_required";
  // 고지 확인은 편수·원본 종류와 관계없이 항상 필요(3장 02, 20261112210100)
  if (!noticeAck) return "notice_required";
  return null;
}

/** public.edit_input_sources 와 같은 판단: 미확인 원본(권리 근거 없음)·고지 미확인 출처 표기 원본은 빠진다 */
export function editInputSources(sources: readonly SourceView[], noticeAck: boolean): SourceView[] {
  return sources.filter((s) => isConfirmedUse(s) && (s.rightsBasis !== "attribution_notice" || noticeAck));
}

/** 체크 시 권리 근거 기본값: 플랫폼 원본은 출처 표기(D7), 직접 추가는 사용자가 골라야 한다 */
export function defaultRightsBasis(platform: SourcePlatform): RightsBasis | null {
  return platform === "direct" ? null : "attribution_notice";
}

/**
 * 화면 목록: 순위 밖 제외 사유가 있는 자동 수집 원본은 빼고, 점수 순 상위 20편 + 직접 추가 원본.
 * 점수가 같거나 없으면 수집 순.
 */
export function listSources(sources: readonly SourceView[]): SourceView[] {
  const byScore = (a: SourceView, b: SourceView) =>
    (b.score ?? -1) - (a.score ?? -1) || a.collectedAt.localeCompare(b.collectedAt) || a.id.localeCompare(b.id);
  const auto = sources.filter((s) => s.platform !== "direct" || s.score !== null);
  const direct = sources.filter((s) => s.platform === "direct" && s.score === null && !s.quarantined);
  // 사용 중인 원본은 순위와 관계없이 남긴다(사용 해제 전까지 보이도록)
  const shown = auto.filter((s) => !s.quarantined && (s.excludeReason === null || s.used)).sort(byScore).slice(0, LIST_LIMIT);
  return [...shown, ...direct.sort(byScore)];
}

/** 제작 파트너 추천(점수 상위 10편). 체크는 하지 않고 표시만 한다 — 체크는 사용자만(D1) */
export function recommendedIds(sources: readonly SourceView[]): Set<string> {
  return new Set(
    sources
      .filter((s) => s.score !== null && s.excludeReason === null)
      .sort((a, b) => (b.score ?? 0) - (a.score ?? 0))
      .slice(0, MAX_DOWNLOAD_CHECKS)
      .map((s) => s.id),
  );
}

export type UseEntry = { id: string; rights_basis: RightsBasis };

/** save_source_use 인자: 사용 체크된 원본만 권리 근거와 함께 */
export function toUseEntries(sources: readonly SourceView[]): UseEntry[] {
  return sources
    .filter((s): s is SourceView & { rightsBasis: RightsBasis } => s.used && !s.quarantined && s.rightsBasis !== null)
    .map((s) => ({ id: s.id, rights_basis: s.rightsBasis }));
}

export function isRightsBasis(value: unknown): value is RightsBasis {
  return typeof value === "string" && (RIGHTS_BASES as readonly string[]).includes(value);
}

export function isPlatform(value: unknown): value is SourcePlatform {
  return typeof value === "string" && (PLATFORMS as readonly string[]).includes(value);
}

/** 제어 문자·양방향 제어 문자(U+202A–U+202E, U+2066–U+2069). DB private.has_unsafe_chars 와 같다 */
const UNSAFE_CHARS = /[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/;
const HOST_PATTERN = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/;

/** URL의 호스트(소문자, 포트 제외). userinfo(@)가 있거나 형식이 틀리면 null */
export function urlHost(url: string): string | null {
  const match = /^https?:\/\/([^/?#]*)/i.exec(url.trim());
  if (!match || match[1].includes("@")) return null;
  const host = match[1].replace(/:\d*$/, "").toLowerCase();
  return HOST_PATTERN.test(host) ? host : null;
}

/** 호스트로 플랫폼 판별(add_direct_source 와 같다) */
export function platformFromUrl(url: string): SourcePlatform {
  const host = urlHost(url) ?? "";
  if (/(^|\.)tiktok\.com$/.test(host)) return "tiktok";
  if (/(^|\.)(xiaohongshu\.com|xhslink\.com)$/.test(host)) return "xiaohongshu";
  return "direct";
}

/** 직접 추가 입력 검사(DB도 다시 검사). 문제 없으면 null */
export function directSourceError(url: string, author: string, title: string): string | null {
  const u = url.trim();
  if (u.length === 0 || u.length > 2000 || !/^https?:\/\/[^\s/?#]+\S*$/i.test(u) || UNSAFE_CHARS.test(u)) {
    return "http(s)로 시작하는 원본 URL을 입력해 주세요.";
  }
  if (urlHost(u) === null) return "URL 주소 형식이 올바르지 않습니다. 아이디·비밀번호(@)가 든 주소는 쓸 수 없습니다.";
  const a = author.trim();
  if (a.length === 0) return "작성자를 입력해 주세요. 출처 표기에 씁니다.";
  if (a.length > 100) return "작성자는 100자까지 쓸 수 있습니다.";
  if (UNSAFE_CHARS.test(a)) return "작성자에 쓸 수 없는 문자(제어·방향 문자)가 있습니다.";
  if (title.trim().length > 200) return "제목은 200자까지 쓸 수 있습니다.";
  if (UNSAFE_CHARS.test(title)) return "제목에 쓸 수 없는 문자(제어·방향 문자)가 있습니다.";
  return null;
}

export const PROBLEM_MESSAGE: Record<ApprovalProblem, string> = {
  too_few: "권리 근거를 고른 사용 원본이 3편 미만이라 승인할 수 없습니다. 원본을 더 내려받거나 직접 추가해 주세요.",
  reason_required: "사용 원본이 5편 미만입니다. 부족 사유를 남기면 예외로 승인할 수 있습니다.",
  notice_required: "위 출처 표기 고지를 확인해야 승인할 수 있습니다.",
};
