import "server-only";
import {
  type BioService,
  type ChannelPlatform,
  type CopyDraft,
  type PolicyItemId,
  type PolicyView,
  type ProgramId,
  BODY_MAX,
  HASHTAG_MAX,
  TITLE_MAX,
  checkAffiliateUrl,
  copyVariants,
  isBioService,
  isLinkProgram,
  isProgramId,
  parsePolicy,
  recommendedSlots,
} from "@/lib/publish/rules";
import { loadOwnedProject } from "@/server/llm/project-access";
import { createAdminClient } from "@/server/supabase-admin";

/*
 * 06 발행(S-11) — docs/planning.md 3장 06 · 15-1 · 15-4 · 16-3 · 16-4.
 * - 정책 점검 6항목 판정·사용자 체크 기록·링크인바이오 번호·발행 준비 저장은 모두 사용자 세션으로 DB 함수(public 래퍼 →
 *   private SECURITY DEFINER)를 부른다. 소유자 검사·함수 전용 열 쓰기는 DB가 한다. 사용자가 누른 요청의 서버 액션만 이 모듈을 부른다
 *   (제작 파트너 AI 도구 목록에는 없다, 17-7).
 * - affiliate_links.url 은 서버(SR)만 쓴다: 사용자 세션으로 소유를 확인하고 프로그램별 허용 도메인을 검사한 뒤 service_role 로 쓴다.
 * - 정책이 바뀌면 DB가 pending 발행 행을 invalidated 로 돌린다. 업로드 직전 재판정은 public.publish_recheck(서버 service_role, task-024).
 * - 발행 버튼은 "발행 준비 완료"(publications 행 + projects.status = awaiting_publish)까지. 실제 업로드는 Compose 서비스
 *   uploader(src/server/publish/uploader.ts, task-024a)가 publications 상태로 한다. 화면은 상태 표시와 다시 시도만.
 */

export type LinkView = {
  program: ProgramId;
  url: string | null;
  disclosed: boolean;
  bioService: BioService | null;
  bioNo: number | null;
  bioRegistered: boolean;
};

export type PublicationView = {
  mode: "scheduled" | "now";
  scheduledAt: string | null;
  title: string;
  body: string;
  description: string;
  hashtags: string[];
  pinComment: boolean;
  preparedAt: string | null;
  status: string;
  /** 업로드 실패 분류 코드(kind:code, 원문 응답·토큰 없음) */
  error: string | null;
  nextAttemptAt: string | null;
  retryCount: number;
  videoId: string | null;
};

export type CopyInput = { title: string; body: string; hashtags: string[] };

export type PublishStepData = {
  productName: string;
  categoryName: string | null;
  channel: { platform: ChannelPlatform; name: string };
  scriptLines: string[];
  bannedTerms: string[];
  link: LinkView | null;
  publication: PublicationView | null;
  variants: CopyDraft[];
  initialCopy: CopyInput;
  policy: PolicyView;
  /** 추천 시간 3개(ISO). 서버 시각 기준으로 한 번 계산해 하이드레이션 차이를 없앤다 */
  slots: string[];
};

export type PolicyActionResult =
  | { ok: true; policy: PolicyView; link: LinkView | null; publication: PublicationView | null }
  | { ok: false; error: string };
export type PrepareResult = { ok: true; publication: PublicationView; policy: PolicyView } | { ok: false; error: string };

const NOT_FOUND = { ok: false, error: "프로젝트를 찾을 수 없거나 권한이 없습니다." } as const;
const INVALID = { ok: false, error: "잘못된 요청입니다." } as const;
const LINK_COLUMNS = "program, url, disclosed, bio_service, bio_no, bio_registered_at";
const PUBLICATION_COLUMNS =
  "mode, scheduled_at, title, body, description, hashtags, pin_comment, prepared_at, status, error, next_attempt_at, retry_count, platform_video_id";

type Client = NonNullable<Awaited<ReturnType<typeof loadOwnedProject>>["supabase"]>;

/** DB 오류 코드 → 화면 문구. 원문 메시지는 화면·로그에 내보내지 않는다 */
function toMessage(code: string | undefined) {
  switch (code) {
    case "42501":
      return "이 프로젝트를 바꿀 권한이 없습니다. 다시 로그인해 주세요.";
    case "55000":
      return "지금 상태에서는 할 수 없습니다. 앞 단계와 링크인바이오 번호를 확인한 뒤 다시 시도해 주세요.";
    case "22023":
      return "입력값을 확인해 주세요(제목 1~100자, 예약 시각은 지금 이후, 해시태그 15개·30자 이하).";
    case "PC001":
      return "정책 점검 6개 항목을 모두 통과해야 발행할 수 있습니다.";
    case "PC002":
      return "설명란이 YouTube 한도(5000바이트)를 넘습니다. 본문을 줄여 다시 발행 준비해 주세요.";
    case "PC003":
      return "해시태그가 YouTube 태그 한도(500자)를 넘습니다. 해시태그를 줄여 주세요.";
    case "RT001":
      return "보관 정리 중인 파일이 있어 잠시 후 다시 시도해 주세요.";
    default:
      return "요청을 처리하지 못했습니다. 잠시 뒤 다시 시도해 주세요.";
  }
}

function toLinkView(row: Record<string, unknown> | null): LinkView | null {
  if (!row || !isProgramId(row.program)) return null;
  return {
    program: row.program,
    url: typeof row.url === "string" ? row.url : null,
    disclosed: row.disclosed !== false,
    bioService: isBioService(row.bio_service) ? row.bio_service : null,
    bioNo: typeof row.bio_no === "number" ? row.bio_no : null,
    bioRegistered: typeof row.bio_registered_at === "string",
  };
}

function toPublicationView(row: Record<string, unknown> | null): PublicationView | null {
  if (!row) return null;
  return {
    mode: row.mode === "scheduled" ? "scheduled" : "now",
    scheduledAt: typeof row.scheduled_at === "string" ? row.scheduled_at : null,
    title: typeof row.title === "string" ? row.title : "",
    body: typeof row.body === "string" ? row.body : "",
    description: typeof row.description === "string" ? row.description : "",
    hashtags: Array.isArray(row.hashtags) ? row.hashtags.filter((t): t is string => typeof t === "string") : [],
    pinComment: row.pin_comment === true,
    preparedAt: typeof row.prepared_at === "string" ? row.prepared_at : null,
    status: typeof row.status === "string" ? row.status : "pending",
    error: typeof row.error === "string" ? row.error : null,
    nextAttemptAt: typeof row.next_attempt_at === "string" ? row.next_attempt_at : null,
    retryCount: typeof row.retry_count === "number" ? row.retry_count : 0,
    videoId: typeof row.platform_video_id === "string" ? row.platform_video_id : null,
  };
}

/** 입력 문구 정리(길이 상한). DB가 다시 검사한다 */
function cleanCopy(copy: unknown): CopyInput | null {
  if (typeof copy !== "object" || copy === null) return null;
  const c = copy as Record<string, unknown>;
  if (typeof c.title !== "string" || typeof c.body !== "string" || !Array.isArray(c.hashtags)) return null;
  if (!c.hashtags.every((t) => typeof t === "string")) return null;
  return {
    title: c.title.slice(0, TITLE_MAX * 2),
    body: c.body.slice(0, BODY_MAX * 2),
    hashtags: (c.hashtags as string[]).slice(0, HASHTAG_MAX * 2),
  };
}

async function evaluate(supabase: Client, projectId: string, copy: CopyInput): Promise<PolicyView | null> {
  const { data, error } = await supabase.rpc("publish_policy", {
    p_project_id: projectId,
    p_title: copy.title,
    p_body: copy.body,
    p_hashtags: copy.hashtags,
  });
  return error ? null : parsePolicy(data);
}

async function readLink(supabase: Client, projectId: string) {
  const { data, error } = await supabase.from("affiliate_links").select(LINK_COLUMNS).eq("project_id", projectId).maybeSingle();
  if (error) throw new Error("publish_link_load_failed");
  return toLinkView(data);
}

async function readPublication(supabase: Client, projectId: string) {
  const { data, error } = await supabase.from("publications").select(PUBLICATION_COLUMNS).eq("project_id", projectId).maybeSingle();
  if (error) throw new Error("publish_publication_load_failed");
  return toPublicationView(data);
}

/** 점검 결과 + 링크 + 발행 행(정책이 바뀌면 DB가 발행 준비를 무효화하므로 상태를 함께 돌려준다) */
async function policyResult(supabase: Client, projectId: string, copy: CopyInput): Promise<PolicyActionResult> {
  // 판정이 무효화를 일으킬 수 있으니 판정 뒤에 링크·발행 행을 읽는다
  const policy = await evaluate(supabase, projectId, copy);
  if (!policy) return { ok: false, error: toMessage(undefined) };
  const [link, publication] = await Promise.all([readLink(supabase, projectId), readPublication(supabase, projectId)]);
  return { ok: true, policy, link, publication };
}

/** 본문 로더: 채널·상품명·승인 대본·제휴 링크·발행 준비 행·정책 점검(DB 판정) */
export async function loadPublishStep(projectId: string): Promise<PublishStepData | null> {
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return null;
  const [projRes, topicRes, scriptRes] = await Promise.all([
    supabase.from("projects").select("accounts(platform, channel_name)").eq("id", project.id).maybeSingle(),
    supabase.from("topics").select("name").eq("project_id", project.id).eq("picked", true).order("created_at", { ascending: false }).limit(1).maybeSingle(),
    supabase
      .from("scripts")
      .select("lines")
      .eq("project_id", project.id)
      .not("approved_at", "is", null)
      .order("version", { ascending: false })
      .limit(1)
      .maybeSingle(),
  ]);
  if (projRes.error || topicRes.error || scriptRes.error) throw new Error("publish_load_failed");

  const accountRaw: unknown = projRes.data?.accounts;
  const account = (Array.isArray(accountRaw) ? accountRaw[0] : accountRaw) as Record<string, unknown> | null | undefined;
  const platform = account?.platform;
  const channel = {
    platform: (platform === "instagram" || platform === "tiktok" || platform === "xiaohongshu" ? platform : "youtube") as ChannelPlatform,
    name: typeof account?.channel_name === "string" ? account.channel_name : "",
  };
  const scriptLines = Array.isArray(scriptRes.data?.lines)
    ? scriptRes.data.lines.filter((l): l is string => typeof l === "string" && l.trim() !== "").map((l) => l.trim())
    : [];
  const productName = typeof topicRes.data?.name === "string" ? topicRes.data.name : project.name;
  const variants = copyVariants(productName, project.categoryName, scriptLines);
  const saved = await readPublication(supabase, project.id);
  const initialCopy: CopyInput = saved
    ? { title: saved.title, body: saved.body, hashtags: saved.hashtags }
    : { title: variants[0].title, body: variants[0].body, hashtags: variants[0].hashtags };

  // 판정이 발행 준비를 무효화할 수 있으므로 링크·발행 행은 판정 뒤에 읽는다
  const policy = await evaluate(supabase, project.id, initialCopy);
  if (!policy) throw new Error("publish_policy_failed");
  const [link, publication] = await Promise.all([readLink(supabase, project.id), readPublication(supabase, project.id)]);

  return {
    productName,
    categoryName: project.categoryName,
    channel,
    scriptLines,
    bannedTerms: project.bannedTerms,
    link,
    publication,
    variants,
    initialCopy,
    policy,
    slots: recommendedSlots(new Date()).map((d) => d.toISOString()),
  };
}

/** 문구가 바뀐 뒤 점검 다시 하기 */
export async function refreshPolicy(projectId: string, rawCopy: unknown): Promise<PolicyActionResult> {
  const copy = cleanCopy(rawCopy);
  if (!copy) return INVALID;
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return NOT_FOUND;
  return policyResult(supabase, project.id, copy);
}

/** 제휴 프로그램·링크·고지 스위치 저장. 프로그램·링크가 바뀌면 링크인바이오 등록 완료 체크를 푼다(다시 등록해야 한다) */
export async function saveAffiliate(projectId: string, input: unknown, rawCopy: unknown): Promise<PolicyActionResult> {
  const copy = cleanCopy(rawCopy);
  if (!copy || typeof input !== "object" || input === null) return INVALID;
  const { program, url: rawUrl, disclosed } = input as Record<string, unknown>;
  if (!isProgramId(program) || typeof disclosed !== "boolean" || (rawUrl !== null && typeof rawUrl !== "string")) return INVALID;

  let url: string | null = null;
  if (isLinkProgram(program) && typeof rawUrl === "string" && rawUrl.trim() !== "") {
    const checked = checkAffiliateUrl(program, rawUrl);
    if (!checked.ok) return checked;
    url = checked.url;
  }

  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return NOT_FOUND;
  const before = await readLink(supabase, project.id);

  // 본인 쓰기 열(program·disclosed)은 사용자 세션으로
  const write = before
    ? await supabase.from("affiliate_links").update({ program, disclosed }).eq("project_id", project.id)
    : await supabase.from("affiliate_links").insert({ project_id: project.id, program, disclosed });
  if (write.error) return { ok: false, error: toMessage(write.error.code) };

  // url 은 서버(SR)만. 소유 확인(위 사용자 세션 쓰기 성공) 뒤에만 쓴다
  if ((before?.url ?? null) !== url) {
    const { error } = await createAdminClient().from("affiliate_links").update({ url }).eq("project_id", project.id);
    if (error) return { ok: false, error: "제휴 링크를 저장하지 못했습니다. 잠시 뒤 다시 시도해 주세요." };
  }

  const changed = !before || before.program !== program || (before.url ?? null) !== url;
  if (changed && before?.bioRegistered) {
    const { error } = await supabase.rpc("confirm_policy_check", { p_project_id: project.id, p_item: "purchase_path", p_checked: false });
    if (error) return { ok: false, error: toMessage(error.code) };
  }
  return policyResult(supabase, project.id, copy);
}

/** 링크인바이오 서비스 고르기 → 이번 영상 번호 받기(16-4). "사용 안 함"이면 서비스만 비운다(번호는 다시 쓰지 않는다) */
export async function chooseBioService(projectId: string, service: unknown, rawCopy: unknown): Promise<PolicyActionResult> {
  const copy = cleanCopy(rawCopy);
  if (!copy || (service !== "none" && !isBioService(service))) return INVALID;
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return NOT_FOUND;
  // bio 열·bio_items 는 함수 전용. "none" 이면 함수가 서비스·등록 완료만 해제한다(번호는 프로젝트에 남음)
  const { error } = await supabase.rpc("assign_bio_number", { p_project_id: project.id, p_service: service as string });
  if (error) return { ok: false, error: toMessage(error.code) };
  return policyResult(supabase, project.id, copy);
}

/** 사용자 체크(출처 표기·고지 확인 / 링크인바이오 등록 완료) */
export async function setUserCheck(projectId: string, item: unknown, checked: unknown, rawCopy: unknown): Promise<PolicyActionResult> {
  const copy = cleanCopy(rawCopy);
  const allowed: PolicyItemId[] = ["attribution_notice", "purchase_path"];
  if (!copy || !allowed.includes(item as PolicyItemId) || typeof checked !== "boolean") return INVALID;
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return NOT_FOUND;
  const { error } = await supabase.rpc("confirm_policy_check", { p_project_id: project.id, p_item: item as string, p_checked: checked });
  if (error) return { ok: false, error: toMessage(error.code) };
  return policyResult(supabase, project.id, copy);
}

export type PrepareInput = { mode: "scheduled" | "now"; scheduledAt: string | null; purchaseGuide: boolean; pinComment: boolean };

/** 발행 준비 저장 — DB가 6/6 통과를 다시 확인한다(실제 업로드는 task-024) */
export async function preparePublication(projectId: string, input: unknown, rawCopy: unknown): Promise<PrepareResult> {
  const copy = cleanCopy(rawCopy);
  if (!copy || typeof input !== "object" || input === null) return INVALID;
  const { mode, scheduledAt, purchaseGuide, pinComment } = input as Record<string, unknown>;
  if ((mode !== "scheduled" && mode !== "now") || typeof purchaseGuide !== "boolean" || typeof pinComment !== "boolean") return INVALID;
  if (mode === "scheduled" && (typeof scheduledAt !== "string" || Number.isNaN(Date.parse(scheduledAt)))) {
    return { ok: false, error: "예약 시각을 골라 주세요." };
  }
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return NOT_FOUND;

  const { error } = await supabase.rpc("prepare_publication", {
    p_project_id: project.id,
    p_mode: mode,
    // 지금 올리기면 DB가 예약 시각을 비운다
    p_scheduled_at: mode === "scheduled" ? (scheduledAt as string) : new Date().toISOString(),
    p_title: copy.title,
    p_body: copy.body,
    p_hashtags: copy.hashtags,
    p_purchase_guide: purchaseGuide,
    p_pin_comment: pinComment,
  });
  const policy = await evaluate(supabase, project.id, copy);
  if (error) return { ok: false, error: toMessage(error.code) };
  const publication = await readPublication(supabase, project.id);
  if (!publication || !policy) return { ok: false, error: toMessage(undefined) };
  return { ok: true, publication, policy };
}

export type RetryResult = { ok: true; publication: PublicationView } | { ok: false; error: string };

/** 업로드 다시 시도(failed·needs_check·reconnect_wait). 소유자·상태·영상 ID 없음·세션 미완료는 DB가 검사한다 */
export async function retryUpload(projectId: string): Promise<RetryResult> {
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return NOT_FOUND;
  const { error } = await supabase.rpc("publication_retry", { p_project_id: project.id });
  if (error) {
    return {
      ok: false,
      error: error.code === "55000" ? "지금은 다시 시도할 수 없습니다. 화면을 새로 고쳐 상태를 확인해 주세요." : toMessage(error.code),
    };
  }
  const publication = await readPublication(supabase, project.id);
  if (!publication) return { ok: false, error: toMessage(undefined) };
  return { ok: true, publication };
}

/** 결과 불명(needs_check)에서 사용자가 Studio 에 영상이 없음을 확인 → 세션 폐기·새 업로드. 소유자·상태는 DB가 검사, 감사 이벤트 기록 */
export async function confirmUploadAbsent(projectId: string): Promise<RetryResult> {
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return NOT_FOUND;
  const { error } = await supabase.rpc("publication_confirm_absent", { p_project_id: project.id });
  if (error) {
    return {
      ok: false,
      error: error.code === "55000" ? "지금은 새로 업로드할 수 없습니다. 화면을 새로 고쳐 상태를 확인해 주세요." : toMessage(error.code),
    };
  }
  const publication = await readPublication(supabase, project.id);
  if (!publication) return { ok: false, error: toMessage(undefined) };
  return { ok: true, publication };
}
