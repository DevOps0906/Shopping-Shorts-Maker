import { isProjectId } from "@/lib/steps/project-id";

/*
 * 새 프로젝트·목록 입력 검사(순수 함수, 테스트 대상). 서버 액션이 DB에 넘기기 전에 거른다.
 * 소유자 검사는 RLS와 projects(account_id, user_id) 복합 FK가 최종 방어선이다.
 */

export const START_MODES = ["trend", "direct", "link"] as const;
export type StartMode = (typeof START_MODES)[number];

export const START_OPTIONS: readonly { value: StartMode; name: string; desc: string }[] = [
  { value: "trend", name: "트렌드에서 고르기", desc: "이 카테고리의 급상승 상품 중에서 고릅니다" },
  { value: "direct", name: "제품명 직접 입력", desc: "이미 정한 제품이 있을 때" },
  { value: "link", name: "상품 링크로 시작", desc: "쇼핑몰 상품 페이지에서 정보를 읽습니다" },
];

export function isStartMode(value: unknown): value is StartMode {
  return typeof value === "string" && (START_MODES as readonly string[]).includes(value);
}

export const NAME_MAX = 80;
export const URL_MAX = 2000;

export type NewProjectField = "accountId" | "categoryId" | "product" | "url" | "targetSec" | "name";

export type NewProjectValues = {
  accountId: string;
  categoryId: string;
  start: StartMode;
  product: string;
  url: string;
  targetSec: string;
  name: string;
};

export type NewProjectState = {
  error?: string;
  fields?: Partial<Record<NewProjectField, string>>;
  values?: NewProjectValues;
};

export type ParsedNewProject =
  | { ok: true; start: "trend"; categoryId: string; accountId: string | null }
  | {
      ok: true;
      start: "direct" | "link";
      accountId: string;
      categoryId: string;
      targetSec: 15 | 20;
      name: string;
      /** 01 소재 입력에 미리 채울 원문(projects에 열이 없어 저장하지 않는다) */
      product: string;
      url: string;
    }
  | { ok: false; state: NewProjectState };

function text(form: FormData, key: string) {
  const value = form.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function isHttpUrl(value: string) {
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

/** 상품 링크에서 이름 대신 쓸 짧은 문구(호스트) */
function hostOf(value: string) {
  try {
    return new URL(value).hostname.replace(/^www\./, "");
  } catch {
    return "";
  }
}

export function parseNewProject(form: FormData): ParsedNewProject {
  const rawStart = text(form, "start");
  const values: NewProjectValues = {
    accountId: text(form, "accountId"),
    categoryId: text(form, "categoryId"),
    start: isStartMode(rawStart) ? rawStart : "direct",
    product: text(form, "product"),
    url: text(form, "url"),
    targetSec: text(form, "targetSec"),
    name: text(form, "name"),
  };
  const fields: Partial<Record<NewProjectField, string>> = {};

  if (!isProjectId(values.categoryId)) fields.categoryId = "카테고리를 골라 주세요.";

  if (values.start !== "trend") {
    if (!isProjectId(values.accountId)) fields.accountId = "올릴 채널을 골라 주세요.";
    if (values.targetSec !== "15" && values.targetSec !== "20") fields.targetSec = "영상 길이를 골라 주세요.";
    if (values.start === "direct" && !values.product) fields.product = "제품명을 입력해 주세요.";
    if (values.product.length > NAME_MAX) fields.product = `제품명은 ${NAME_MAX}자까지 쓸 수 있습니다.`;
    if (values.start === "link" && (!isHttpUrl(values.url) || values.url.length > URL_MAX)) {
      fields.url = "http(s)로 시작하는 상품 링크를 입력해 주세요.";
    }
    if (values.name.length > NAME_MAX) fields.name = `프로젝트 이름은 ${NAME_MAX}자까지 쓸 수 있습니다.`;
  }

  if (Object.keys(fields).length > 0) {
    return { ok: false, state: { error: "필수 항목을 확인해 주세요.", fields, values } };
  }
  if (values.start === "trend") {
    return {
      ok: true,
      start: "trend",
      categoryId: values.categoryId,
      accountId: isProjectId(values.accountId) ? values.accountId : null,
    };
  }

  const name = values.name || values.product || hostOf(values.url) || "새 프로젝트";
  return {
    ok: true,
    start: values.start,
    accountId: values.accountId,
    categoryId: values.categoryId,
    targetSec: values.targetSec === "20" ? 20 : 15,
    name: name.slice(0, NAME_MAX),
    product: values.start === "direct" ? values.product : "",
    url: values.start === "link" ? values.url : "",
  };
}

/** 생성 직후 01 소재로 넘기는 링크: 제품명·상품 링크(전체 URL)를 쿼리로 넘겨 소재 입력에 미리 채운다 */
export function topicHref(projectId: string, product: string, url: string) {
  const sp = new URLSearchParams();
  if (product) sp.set("product", product);
  if (url) sp.set("url", url);
  const q = sp.toString();
  return `/studio/${projectId}/topic${q ? `?${q}` : ""}`;
}

/** 트렌드 화면 링크: 기간·카테고리·선택 채널을 쿼리로 유지한다 */
export function trendsUrl(params: { period?: string; categoryId?: string | null; accountId?: string | null }) {
  const sp = new URLSearchParams();
  if (params.period) sp.set("period", params.period);
  if (params.categoryId) sp.set("category", params.categoryId);
  if (params.accountId) sp.set("account", params.accountId);
  const q = sp.toString();
  return `/trends${q ? `?${q}` : ""}`;
}

/** ilike 패턴용 이스케이프(%, _, \) */
export function escapeLike(value: string) {
  return value.replace(/[\\%_]/g, (c) => `\\${c}`);
}

/** URL ?q= 검색어: 앞뒤 공백 제거, 100자 제한 */
export function parseQuery(value: unknown) {
  return typeof value === "string" ? value.trim().slice(0, 100) : "";
}

/** URL ?page= : 1 이상 정수, 그 밖은 1 */
export function parsePage(value: unknown) {
  const n = typeof value === "string" ? Number.parseInt(value, 10) : Number.NaN;
  return Number.isInteger(n) && n >= 1 ? Math.min(n, 1000) : 1;
}
