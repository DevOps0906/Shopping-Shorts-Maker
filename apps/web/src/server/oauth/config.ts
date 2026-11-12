import "server-only";

/*
 * YouTube OAuth 설정(서버 환경 변수만). 값은 루트 .env 에 사용자가 넣는다 — 저장소·번들·로그 금지.
 *   GOOGLE_OAUTH_CLIENT_ID · GOOGLE_OAUTH_CLIENT_SECRET · OAUTH_REDIRECT_BASE_URL(예: https://app.example.com)
 * Google Cloud Console 의 승인된 리디렉션 URI 에 `${OAUTH_REDIRECT_BASE_URL}/api/oauth/youtube/callback` 을 등록한다.
 */

export type GoogleOAuthConfig = {
  clientId: string;
  clientSecret: string;
  redirectUri: string;
};

export const YOUTUBE_CALLBACK_PATH = "/api/oauth/youtube/callback";

export function getGoogleOAuthConfig(): GoogleOAuthConfig | null {
  const clientId = process.env.GOOGLE_OAUTH_CLIENT_ID?.trim();
  const clientSecret = process.env.GOOGLE_OAUTH_CLIENT_SECRET?.trim();
  const base = process.env.OAUTH_REDIRECT_BASE_URL?.trim().replace(/\/+$/, "");
  if (!clientId || !clientSecret || !base) return null;
  let url: URL;
  try {
    url = new URL(base);
  } catch {
    return null;
  }
  // 운영은 https 만. 개발용 localhost 만 http 허용
  const local = url.hostname === "localhost" || url.hostname === "127.0.0.1";
  if (url.protocol !== "https:" && !(local && url.protocol === "http:")) return null;
  return { clientId, clientSecret, redirectUri: `${url.origin}${YOUTUBE_CALLBACK_PATH}` };
}

export function isGoogleOAuthConfigured() {
  return getGoogleOAuthConfig() !== null;
}
