import "server-only";
import { randomInt } from "node:crypto";
import { checkAffiliateUrl, isProgramId } from "@/lib/publish/rules";
import { createAdminClient } from "@/server/supabase-admin";

/*
 * 자체 단축 링크(task-025, docs/planning.md 15-3 · 17-8).
 * - affiliate_links.short_url 에는 코드(8자, 혼동 문자 0·O·1·I·l·o 를 뺀 base56)만 둔다. 표시 = PUBLIC_APP_URL + /l/ + 코드.
 * - 코드는 처음 한 번만 만든다(제휴 URL 이 바뀌어도 유지 → 이미 등록한 링크인바이오가 깨지지 않는다).
 * - 리다이렉트는 등록된 제휴 도메인으로만(checkAffiliateUrl 재검사). naver.me 단축 주소로는 보내지 않는다.
 */

type Admin = ReturnType<typeof createAdminClient>;

const ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz";
export const SHORT_CODE_RE = /^[2-9A-HJ-NP-Za-km-np-z]{8}$/;
export const NAVER_ME_NOTICE = "naver.me 단축 주소는 단축 링크로 연결되지 않습니다. 원래 상품 주소를 붙여 넣어 주세요.";

export const isShortCode = (value: unknown): value is string => typeof value === "string" && SHORT_CODE_RE.test(value);

export function newShortCode(length = 8) {
  return Array.from({ length }, () => ALPHABET[randomInt(ALPHABET.length)]).join("");
}

/** 화면에 보일 단축 링크. PUBLIC_APP_URL 이 없거나 코드가 아니면 null */
export function shortLinkUrl(code: unknown): string | null {
  const base = process.env.PUBLIC_APP_URL?.trim().replace(/\/+$/, "");
  return base && isShortCode(code) ? `${base}/l/${code}` : null;
}

export function isNaverMeHost(url: string) {
  try {
    const host = new URL(url).hostname.toLowerCase();
    return host === "naver.me" || host.endsWith(".naver.me");
  } catch {
    return false;
  }
}

/**
 * 프로젝트 제휴 링크에 코드가 없으면 만든다(있으면 그대로). 소유 확인(사용자 세션 쓰기 성공) 뒤 서버(SR)만 부른다.
 * unique 충돌이면 3회까지 다시 뽑는다. 반환: 저장된 코드 또는 null(행 없음·실패).
 */
export async function ensureShortCode(admin: Admin, projectId: string): Promise<string | null> {
  for (let attempt = 0; attempt < 3; attempt++) {
    const { data, error } = await admin
      .from("affiliate_links")
      .update({ short_url: newShortCode() })
      .eq("project_id", projectId)
      .is("short_url", null)
      .select("short_url")
      .maybeSingle();
    if (error?.code === "23505") continue;
    if (error) return null;
    if (data && isShortCode(data.short_url)) return data.short_url;
    // 이미 코드가 있었으면(조건에 안 맞아 0행) 그 값을 돌려준다
    const existing = await admin.from("affiliate_links").select("short_url").eq("project_id", projectId).maybeSingle();
    return isShortCode(existing.data?.short_url) ? existing.data.short_url : null;
  }
  return null;
}

export type ClickPlatform = "youtube" | "instagram" | "tiktok" | "inpock" | "litly" | "other";

/** referrer 호스트 → 유입 플랫폼(앱 안 브라우저는 referrer 가 없을 때가 많다 → other) */
export function platformFromHost(host: string | null): ClickPlatform {
  if (!host) return "other";
  const is = (d: string) => host === d || host.endsWith(`.${d}`);
  if (is("youtube.com") || is("youtu.be")) return "youtube";
  if (is("instagram.com")) return "instagram";
  if (is("tiktok.com")) return "tiktok";
  if (is("inpock.co.kr")) return "inpock";
  if (is("litt.ly")) return "litly";
  return "other";
}

export function refererHost(referer: string | null): string | null {
  if (!referer) return null;
  try {
    return new URL(referer).hostname.toLowerCase().slice(0, 255) || null;
  } catch {
    return null;
  }
}

/**
 * 클라이언트 IP. CLIENT_IP_HEADER(기본 x-real-ip) 하나만 읽는다.
 * 전제: 앞단 리버스 프록시가 이 헤더를 실제 접속 IP 로 항상 덮어쓴다(클라이언트가 보낸 값을 그대로 넘기면 위조 가능).
 * 헤더가 없으면 "unknown"(모두 같은 방문자로 묶여 속도 제한을 함께 받는다).
 */
export function clientIp(headers: Headers) {
  const name = process.env.CLIENT_IP_HEADER?.trim().toLowerCase() || "x-real-ip";
  const value = headers.get(name)?.trim();
  // 덮어쓰기 헤더는 값이 하나다. 쉼표 목록이면 프록시가 덮어쓰지 않은(위조 가능한) 값으로 보고 쓰지 않는다
  if (!value || value.includes(",")) return "unknown";
  return value.slice(0, 64);
}

export type ClickMeta = { ip: string; refHost: string | null };

/**
 * 코드 → 이동할 제휴 URL. 클릭은 DB 함수 한 번으로 기록한다(실패해도 이동은 막지 않는다).
 * 없는 코드·허용되지 않은 도메인·naver.me 는 모두 null(호출자는 같은 404 로 답한다).
 */
export async function resolveShortLink(code: string, meta: ClickMeta, admin: Admin = createAdminClient()): Promise<string | null> {
  if (!isShortCode(code)) return null;
  let url: unknown = null;
  let program: unknown = null;
  const recorded = await admin.rpc("record_link_click", {
    p_code: code,
    p_ip: meta.ip,
    p_ref_host: meta.refHost,
    p_platform: platformFromHost(meta.refHost),
  });
  const row: unknown = Array.isArray(recorded.data) ? recorded.data[0] : null;
  if (!recorded.error) {
    if (!row || typeof row !== "object") return null;
    ({ url, program } = row as Record<string, unknown>);
  } else {
    // 기록 실패: 이동만 한다
    const { data, error } = await admin.from("affiliate_links").select("url, program").eq("short_url", code).maybeSingle();
    if (error || !data) return null;
    ({ url, program } = data as Record<string, unknown>);
  }
  if (typeof url !== "string" || !isProgramId(program)) return null;
  const checked = checkAffiliateUrl(program, url);
  if (!checked.ok || isNaverMeHost(checked.url)) return null;
  return checked.url;
}
