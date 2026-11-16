import { NextResponse } from "next/server";
import { backToAccounts, readAccountId, sameOrigin, sessionOrganizationId } from "@/server/oauth/http";
import { createOAuthStore } from "@/server/oauth/store";
import { disconnect } from "@/server/oauth/youtube";

/* YouTube 연결 해제(폼 POST accountId): Google 토큰 폐기 후 Vault 삭제, 계정은 재연결 필요로 남는다. */

export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  if (!sameOrigin(request)) return NextResponse.json({ ok: false, error: "허용되지 않은 요청입니다." }, { status: 403 });
  const organizationId = await sessionOrganizationId();
  if (!organizationId) return NextResponse.json({ ok: false, error: "로그인이 필요합니다." }, { status: 401 });
  const accountId = await readAccountId(request);
  if (!accountId) return backToAccounts(request, "not_allowed");
  return backToAccounts(request, await disconnect(createOAuthStore(), organizationId, accountId));
}
