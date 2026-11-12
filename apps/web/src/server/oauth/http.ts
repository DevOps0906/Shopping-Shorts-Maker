import "server-only";
import { NextResponse } from "next/server";
import { isProjectId } from "@/lib/steps/project-id";
import { createClient } from "@/lib/supabase/server";
import type { OAuthResult } from "./youtube";

/*
 * /api/oauth/youtube/* 공통. 시작·해제는 쿠키 세션 폼 POST 라 다른 사이트 요청(CSRF)을 막는다:
 * Origin 이 있으면 같은 호스트, 없으면 Sec-Fetch-Site 가 cross-site 가 아니어야 한다.
 */

export const ACCOUNTS_PATH = "/settings/accounts";

export function sameOrigin(request: Request) {
  const origin = request.headers.get("origin");
  const host = request.headers.get("x-forwarded-host") ?? request.headers.get("host");
  if (origin !== null) {
    try {
      return !!host && new URL(origin).host === host;
    } catch {
      return false;
    }
  }
  return request.headers.get("sec-fetch-site") !== "cross-site";
}

/** 결과 코드만 쿼리로 싣고 계정 화면으로 돌려보낸다(303: POST → GET) */
export function backToAccounts(request: Request, result: OAuthResult) {
  const url = new URL(ACCOUNTS_PATH, request.url);
  url.searchParams.set("oauth", result);
  const res = NextResponse.redirect(url, 303);
  res.headers.set("Cache-Control", "no-store");
  res.headers.set("Referrer-Policy", "no-referrer");
  return res;
}

/** 세션 사용자 id(서명 검증된 JWT). 없으면 null */
export async function sessionUserId() {
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  const sub = data?.claims?.sub;
  return typeof sub === "string" ? sub : null;
}

/** 폼의 accountId(uuid) */
export async function readAccountId(request: Request) {
  const type = request.headers.get("content-type") ?? "";
  if (!type.startsWith("application/x-www-form-urlencoded") && !type.startsWith("multipart/form-data")) return null;
  const form = await request.formData().catch(() => null);
  const id = form?.get("accountId");
  return typeof id === "string" && isProjectId(id) ? id : null;
}
