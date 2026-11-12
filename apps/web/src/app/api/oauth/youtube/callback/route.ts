import { getGoogleOAuthConfig } from "@/server/oauth/config";
import { backToAccounts, sessionUserId } from "@/server/oauth/http";
import { createOAuthStore } from "@/server/oauth/store";
import { finishConnect } from "@/server/oauth/youtube";

/*
 * Google 리디렉션 콜백(GET ?code&state | ?error&state). 세션 사용자 = state 를 만든 사용자일 때만 1회 처리한다.
 * 응답은 결과 코드만 싣고 계정 화면으로 돌려보낸다(code·토큰은 화면·로그로 나가지 않는다).
 */

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const userId = await sessionUserId();
  if (!userId) return backToAccounts(request, "invalid_state");
  const q = new URL(request.url).searchParams;
  const result = await finishConnect(createOAuthStore(), getGoogleOAuthConfig(), userId, {
    code: q.get("code"),
    state: q.get("state"),
    error: q.get("error"),
  });
  return backToAccounts(request, result);
}
