/*
 * 06 발행 규칙 — docs/planning.md 3장 06 · 15-1 · 15-4 · 16-1~16-4.
 * 판정·설명란의 정본은 DB(supabase/migrations/20261112260000_publish_policy.sql)다. 여기 함수는 입력 중 미리보기와
 * 버튼 비활성(UX)용 미러이고, 발행 준비 저장은 DB가 6/6을 다시 확인한다.
 */

export const PROGRAMS = [
  { id: "coupang_partners", label: "쿠팡 파트너스", fits: [] as string[], link: true, hint: "전 카테고리 · 기본값" },
  { id: "naver_shopping_connect", label: "네이버 쇼핑 커넥트", fits: ["생활", "주방", "가전", "반려", "유아", "건강"], link: true, hint: "생활·주방·가전·반려·유아·건강" },
  { id: "ohouse_curator", label: "오늘의집 큐레이터", fits: ["생활", "수납", "주방", "인테리어", "캠핑"], link: true, hint: "생활·수납·주방·인테리어·캠핑" },
  { id: "musinsa_curator", label: "무신사 큐레이터", fits: ["패션"], link: true, hint: "패션잡화" },
  { id: "oliveyoung_curator", label: "올리브영 쇼핑 큐레이터", fits: ["뷰티", "헬스"], link: true, hint: "뷰티·헬스" },
  { id: "youtube_shopping", label: "유튜브 쇼핑 상품 태그", fits: [], link: false, hint: "YouTube 채널 · YPP + 구독자 500명" },
  { id: "aliexpress", label: "알리익스프레스", fits: ["디지털", "캠핑"], link: true, hint: "디지털 소품·캠핑" },
  { id: "none", label: "사용 안 함", fits: [], link: false, hint: "채널 성장 단계용" },
] as const;

export type ProgramId = (typeof PROGRAMS)[number]["id"];
export type ChannelPlatform = "youtube" | "instagram" | "tiktok" | "xiaohongshu";

export const isProgramId = (value: unknown): value is ProgramId => PROGRAMS.some((p) => p.id === value);
export const isLinkProgram = (program: ProgramId | null | undefined) => PROGRAMS.find((p) => p.id === program)?.link ?? false;
export const programLabel = (program: ProgramId) => PROGRAMS.find((p) => p.id === program)?.label ?? program;

/** 16-2 추천 규칙: 쿠팡 파트너스(전 카테고리) · 카테고리가 맞는 프로그램 · YouTube 채널이면 유튜브 쇼핑 태그 */
export function recommendedPrograms(categoryName: string | null, platform: ChannelPlatform): ProgramId[] {
  const name = categoryName ?? "";
  return PROGRAMS.filter(
    (p) => p.id === "coupang_partners" || (p.id === "youtube_shopping" && platform === "youtube") || p.fits.some((f) => name.includes(f)),
  ).map((p) => p.id);
}

/** 프로그램별 허용 도메인(DB affiliate_links.url CHECK 의 부분집합). 링크가 없는 프로그램은 빈 목록 */
const PROGRAM_DOMAINS: Record<ProgramId, string[]> = {
  coupang_partners: ["coupang.com", "coupa.ng"],
  naver_shopping_connect: ["naver.com", "naver.me"],
  ohouse_curator: ["ohou.se"],
  musinsa_curator: ["musinsa.com"],
  oliveyoung_curator: ["oliveyoung.co.kr"],
  youtube_shopping: [],
  aliexpress: ["aliexpress.com"],
  none: [],
};

export type UrlCheck = { ok: true; url: string } | { ok: false; error: string };

export function checkAffiliateUrl(program: ProgramId, raw: string): UrlCheck {
  const domains = PROGRAM_DOMAINS[program];
  const value = raw.trim();
  if (domains.length === 0) return { ok: false, error: "이 프로그램은 링크를 쓰지 않습니다." };
  if (value === "") return { ok: false, error: "상품 제휴 링크를 붙여 넣어 주세요." };
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return { ok: false, error: "링크 형식이 올바르지 않습니다. https:// 로 시작하는 주소를 붙여 넣어 주세요." };
  }
  const host = url.hostname.toLowerCase();
  if (url.protocol !== "https:" || url.username || url.password || url.port || /\s/.test(value) || value.length > 2048) {
    return { ok: false, error: "https:// 로 시작하는 제휴 링크만 쓸 수 있습니다." };
  }
  if (!/^([a-z0-9-]+\.)+[a-z]+$/.test(host) || !domains.some((d) => host === d || host.endsWith(`.${d}`))) {
    return { ok: false, error: `${programLabel(program)} 링크(${domains.join(" · ")})만 쓸 수 있습니다.` };
  }
  return { ok: true, url: url.toString() };
}

export const BIO_SERVICES = [
  { id: "inpock", label: "인포크링크" },
  { id: "litly", label: "리틀리" },
  { id: "linktree", label: "링크트리" },
  { id: "none", label: "사용 안 함" },
] as const;
export type BioService = Exclude<(typeof BIO_SERVICES)[number]["id"], "none">;
export const isBioService = (value: unknown): value is BioService =>
  value === "inpock" || value === "litly" || value === "linktree";

/** 16-1 링크 삽입 위치 */
export type PlacementBadge = "사용" | "조건부" | "보조" | "클릭 안 됨";
export type Placement = { place: string; badge: PlacementBadge; note: string };

const PLACEMENTS: Record<"youtube" | "instagram" | "tiktok", Placement[]> = {
  youtube: [
    { place: "프로필 링크(링크인바이오)", badge: "사용", note: "채널 맞춤설정 › 링크에 한 번만 등록" },
    { place: "영상 위 상품 태그", badge: "조건부", note: "유튜브 쇼핑(YPP + 구독자 500명) 제휴몰 상품만" },
    { place: "관련 동영상", badge: "보조", note: "롱폼 리뷰 영상 연결" },
    { place: "설명란·댓글 링크", badge: "클릭 안 됨", note: "쇼츠 설명란·댓글 링크는 눌리지 않습니다(2023-08-31부터)" },
  ],
  instagram: [
    { place: "프로필 링크(링크인바이오)", badge: "사용", note: "프로필 편집 › 링크" },
    { place: "스토리 링크 스티커", badge: "조건부", note: "24시간만 노출" },
    { place: "댓글 키워드 → DM 자동응답", badge: "보조", note: "댓글로 키워드를 받으면 DM으로 링크 안내" },
    { place: "캡션·댓글 링크", badge: "클릭 안 됨", note: "캡션·댓글의 링크는 눌리지 않습니다" },
  ],
  tiktok: [
    { place: "프로필 바이오 링크", badge: "조건부", note: "계정 조건을 충족해야 바이오 링크가 열립니다" },
    { place: "고정 댓글 번호 안내", badge: "보조", note: "“구매 정보는 프로필 링크 N번” 문구" },
    { place: "캡션·댓글 링크", badge: "클릭 안 됨", note: "캡션·댓글의 링크는 눌리지 않습니다" },
  ],
};

export function linkPlacements(platform: ChannelPlatform): Placement[] {
  return PLACEMENTS[platform === "xiaohongshu" ? "tiktok" : platform];
}

/** 15-4 정책 점검 6항목(정본 순서·이름). 항목을 더하거나 빼지 않는다 */
export const POLICY_ITEMS = [
  { id: "source_record", label: "원본 출처 기록", kind: "자동" },
  { id: "attribution_notice", label: "출처 표기·고지 확인", kind: "사용자 체크" },
  { id: "original_elements", label: "새로 만든 요소", kind: "자동" },
  { id: "banned_terms", label: "금지·과장 표현", kind: "자동" },
  { id: "affiliate_disclosure", label: "제휴 고지", kind: "자동" },
  { id: "purchase_path", label: "구매 경로", kind: "자동 + 사용자 체크" },
] as const;
export type PolicyItemId = (typeof POLICY_ITEMS)[number]["id"];
export type PolicyResult = "pass" | "fail" | "pending";
export type PolicyCheck = { item: PolicyItemId; result: PolicyResult; detail: string; checkedAt: string | null };
export type PolicyView = { items: PolicyCheck[]; credits: string; disclosure: string; purchase: string };

const isPolicyItem = (value: unknown): value is PolicyItemId => POLICY_ITEMS.some((p) => p.id === value);

/** DB publish_policy 결과(jsonb) → 화면 값. 6항목이 모두 없으면 빠진 항목은 미통과로 둔다 */
export function parsePolicy(raw: unknown): PolicyView {
  const obj = typeof raw === "object" && raw !== null ? (raw as Record<string, unknown>) : {};
  const rows = Array.isArray(obj.items) ? obj.items : [];
  const byId = new Map<PolicyItemId, PolicyCheck>();
  for (const row of rows) {
    if (typeof row !== "object" || row === null) continue;
    const r = row as Record<string, unknown>;
    if (!isPolicyItem(r.item)) continue;
    const result: PolicyResult = r.result === "pass" ? "pass" : r.result === "pending" ? "pending" : "fail";
    byId.set(r.item, {
      item: r.item,
      result,
      detail: typeof r.detail === "string" ? r.detail : "",
      checkedAt: typeof r.checked_at === "string" ? r.checked_at : null,
    });
  }
  const str = (v: unknown) => (typeof v === "string" ? v : "");
  return {
    items: POLICY_ITEMS.map((p) => byId.get(p.id) ?? { item: p.id, result: "fail", detail: "점검 결과를 불러오지 못했습니다", checkedAt: null }),
    credits: str(obj.credits),
    disclosure: str(obj.disclosure),
    purchase: str(obj.purchase),
  };
}

export const passedCount = (items: readonly PolicyCheck[]) => items.filter((i) => i.result === "pass").length;

/** 발행 버튼 활성 조건: 15-4 6항목이 모두 통과 */
export function canPublish(items: readonly PolicyCheck[]) {
  return POLICY_ITEMS.every((p) => items.find((i) => i.item === p.id)?.result === "pass");
}

/* ── 금지·과장 표현(DB private.publish_banned_term 미러) ─────────── */
export const COMMON_BANNED_TERMS = ["최고", "완벽", "100%", "무조건", "기적", "치료"] as const;

/** DB normalize_for_ban 과 같은 규칙: NFC → 제로폭 문자·공백 제거 → 소문자 */
const normalizeForBan = (value: string) => value.normalize("NFC").replace(/[​-‍﻿⁠\s]/g, "").toLowerCase();

/** 제목·본문·해시태그·승인 대본을 이어 붙여 걸린 첫 금지어. 없으면 null */
export function findPublishBanned(texts: readonly string[], scriptLines: readonly string[], categoryTerms: readonly string[]) {
  const body = normalizeForBan(texts.join("") + scriptLines.join(""));
  for (const term of [...COMMON_BANNED_TERMS, ...categoryTerms]) {
    const key = normalizeForBan(term);
    if (key && body.includes(key)) return term;
  }
  return null;
}

/**
 * 입력 중인 문구로 금지·과장 표현 항목만 다시 판정한 점검 목록(나머지는 DB 결과 그대로).
 * sameAsDb = DB가 지금 문구 그대로 판정한 결과이면 DB 미통과를 유지한다(더 엄격한 쪽).
 */
export function withLocalBanned(items: readonly PolicyCheck[], banned: string | null, sameAsDb = false): PolicyCheck[] {
  return items.map((i) =>
    i.item !== "banned_terms" || (sameAsDb && !banned && i.result !== "pass")
      ? i
      : banned
        ? { ...i, result: "fail", detail: `금지·과장 표현 "${banned}"을(를) 고쳐 주세요` }
        : { ...i, result: "pass", detail: "제목·설명·해시태그·대본에 금지·과장 표현이 없습니다" },
  );
}

/* ── 설명란(DB private.publish_description 미러) ───────────────── */
export const TITLE_MAX = 100;
export const BODY_MAX = 4000;
export const HASHTAG_MAX = 15;

/** "#수납 압축팩, #수납" → ["수납", "압축팩"] (앞의 # 제거, 빈 값·중복 제거, 순서 유지) */
export function parseHashtags(raw: string): string[] {
  const out: string[] = [];
  for (const part of raw.split(/[\s,]+/)) {
    const tag = part.replace(/^#+/, "").trim();
    if (tag && !out.includes(tag)) out.push(tag);
  }
  return out;
}

export type DescriptionParts = { disclosure: string; purchase: string; body: string; credits: string; hashtags: readonly string[] };

/** 설명란 고정 순서: 고지 → 구매 안내 → 본문(+ 출처 문구) → 해시태그. 빈 블록은 건너뛰고 빈 줄 하나로 잇는다 */
export function composeDescription({ disclosure, purchase, body, credits, hashtags }: DescriptionParts) {
  const tags = hashtags.map((t) => `#${t}`).join(" ");
  return [disclosure, purchase, body, credits, tags]
    .map((s) => s.trim())
    .filter(Boolean)
    .join("\n\n");
}

/* ── 제목·설명·해시태그 자동 작성(3가지 안 순환) ─────────────────── */
export type CopyDraft = { title: string; body: string; hashtags: string[] };

export function copyVariants(productName: string, categoryName: string | null, lines: readonly string[]): CopyDraft[] {
  const product = productName.trim() || "오늘의 살림템";
  const first = lines[0] ?? "";
  const story = lines.join(" ").trim();
  const tagBase = [product.replace(/\s+/g, ""), ...(categoryName ?? "").split(/[·\s]+/).filter(Boolean)];
  const tags = (extra: string[]) => parseHashtags([...tagBase, ...extra].join(" ")).slice(0, 6);
  return [
    { title: `${product} 써 보니 이렇게 편해요`, body: story || `${product}를 직접 써 본 짧은 후기입니다.`, hashtags: tags(["쇼츠", "살림템"]) },
    { title: `${first || `${product} 한 번에 정리`}`.slice(0, TITLE_MAX), body: `${product} 핵심만 짧게 담았어요.\n${story}`.trim(), hashtags: tags(["꿀템", "추천템"]) },
    { title: `요즘 많이 찾는 ${product}, 이렇게 써요`, body: `${story}\n궁금한 점은 댓글로 남겨 주세요.`.trim(), hashtags: tags(["리뷰", "생활팁"]) },
  ];
}

/* ── 추천 시간 3개(성과 데이터 전 기본값: KST 12:00 · 18:00 · 21:00) ─── */
const SLOT_HOURS_KST = [12, 18, 21];
const KST_OFFSET_MS = 9 * 60 * 60 * 1000;

/** now + 30분 이후의 가장 가까운 추천 시각 3개(UTC Date) */
export function recommendedSlots(now: Date): Date[] {
  const earliest = now.getTime() + 30 * 60 * 1000;
  const kst = new Date(now.getTime() + KST_OFFSET_MS);
  const out: Date[] = [];
  for (let day = 0; out.length < 3 && day < 3; day++) {
    for (const hour of SLOT_HOURS_KST) {
      const t = Date.UTC(kst.getUTCFullYear(), kst.getUTCMonth(), kst.getUTCDate() + day, hour) - KST_OFFSET_MS;
      if (t > earliest && out.length < 3) out.push(new Date(t));
    }
  }
  return out;
}

/** "11월 13일 (금) 18:00" (KST) */
export function formatSlot(date: Date) {
  return new Intl.DateTimeFormat("ko-KR", {
    timeZone: "Asia/Seoul",
    month: "long",
    day: "numeric",
    weekday: "short",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(date);
}

/** datetime-local 입력값(KST로 해석) ↔ ISO */
export function kstInputToIso(value: string): string | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(value);
  if (!m) return null;
  const t = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]) - KST_OFFSET_MS;
  return Number.isNaN(t) ? null : new Date(t).toISOString();
}

export function isoToKstInput(iso: string): string {
  const d = new Date(new Date(iso).getTime() + KST_OFFSET_MS);
  return d.toISOString().slice(0, 16);
}
