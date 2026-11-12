import "server-only";
import { getGoogleOAuthConfig } from "./config";
import { createOAuthStore } from "./store";
import { getAccessTokenWith } from "./youtube";

/**
 * 서버 전용: 사용자 계정의 YouTube access token(매번 새로 발급, 캐시 없음). accounts.user_id ≠ userId 면 예외.
 * 결과를 브라우저·로그로 내보내지 않는다.
 */
export function getAccessToken(userId: string, accountId: string) {
  return getAccessTokenWith(createOAuthStore(), getGoogleOAuthConfig(), userId, accountId);
}
