import { NextResponse } from "next/server";
import { getGoogleOAuthConfig } from "@/server/oauth/config";
import { backToAccounts, readAccountId, sameOrigin, sessionUserId } from "@/server/oauth/http";
import { createOAuthStore } from "@/server/oauth/store";
import { startConnect } from "@/server/oauth/youtube";

/*
 * YouTube 연결·재연결 시작(폼 POST accountId). 세션 사용자의 YouTube 계정인지 DB 함수가 확인하고
 * state·PKCE verifier 를 서버에 저장한 뒤 Google 동의 화면으로 보낸다(시스템 브라우저 흐름은 W7, ADR-0005).
 */

export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  if (!sameOrigin(request)) return NextResponse.json({ ok: false, error: "허용되지 않은 요청입니다." }, { status: 403 });
  const userId = await sessionUserId();
  if (!userId) return NextResponse.json({ ok: false, error: "로그인이 필요합니다." }, { status: 401 });
  const accountId = await readAccountId(request);
  if (!accountId) return backToAccounts(request, "not_allowed");

  const result = await startConnect(createOAuthStore(), getGoogleOAuthConfig(), userId, accountId);
  if (!result.ok) return backToAccounts(request, result.result);
  const res = NextResponse.redirect(result.url, 303);
  res.headers.set("Cache-Control", "no-store");
  return res;
}
