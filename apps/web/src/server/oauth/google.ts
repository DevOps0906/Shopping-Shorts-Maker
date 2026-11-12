import "server-only";
import type { GoogleOAuthConfig } from "./config";

/*
 * Google OAuth·YouTube HTTP 호출(서버 전용). 토큰 원문은 반환값으로만 넘기고 로그·오류 메시지에 넣지 않는다.
 * 근거: docs/04_API.md YouTube 1·2절. youtube.force-ssl 은 요청하지 않는다(MVP 제외).
 */

export const AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth";
export const TOKEN_URL = "https://oauth2.googleapis.com/token";
export const REVOKE_URL = "https://oauth2.googleapis.com/revoke";
export const CHANNELS_URL = "https://www.googleapis.com/youtube/v3/channels?part=id&mine=true";

export const YOUTUBE_SCOPES = [
  "https://www.googleapis.com/auth/youtube.upload",
  "https://www.googleapis.com/auth/youtube.readonly",
  "https://www.googleapis.com/auth/yt-analytics.readonly",
] as const;

const TIMEOUT_MS = 10_000;

/** Google 오류. code 는 OAuth 오류 코드(invalid_grant 등) 또는 http_<상태>·network. 토큰은 담지 않는다. */
export class GoogleOAuthError extends Error {
  constructor(readonly code: string) {
    super(`Google OAuth 오류: ${code}`);
    this.name = "GoogleOAuthError";
  }
}

export type TokenResponse = {
  accessToken: string;
  refreshToken: string | null;
  scopes: string[];
};

export function buildAuthUrl(cfg: GoogleOAuthConfig, state: string, codeChallenge: string) {
  const url = new URL(AUTH_URL);
  url.search = new URLSearchParams({
    client_id: cfg.clientId,
    redirect_uri: cfg.redirectUri,
    response_type: "code",
    scope: YOUTUBE_SCOPES.join(" "),
    // 갱신 토큰을 받기 위해 offline + 매번 동의 화면
    access_type: "offline",
    prompt: "consent",
    state,
    code_challenge: codeChallenge,
    code_challenge_method: "S256",
  }).toString();
  return url.toString();
}

async function postForm(url: string, form: Record<string, string>) {
  try {
    return await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(form).toString(),
      signal: AbortSignal.timeout(TIMEOUT_MS),
      cache: "no-store",
    });
  } catch {
    throw new GoogleOAuthError("network");
  }
}

async function readTokenResponse(res: Response): Promise<TokenResponse> {
  const body = (await res.json().catch(() => null)) as Record<string, unknown> | null;
  if (!res.ok || !body) {
    const code = body && typeof body.error === "string" ? body.error : `http_${res.status}`;
    throw new GoogleOAuthError(code);
  }
  if (typeof body.access_token !== "string" || body.access_token === "") throw new GoogleOAuthError("no_access_token");
  const refresh = typeof body.refresh_token === "string" && body.refresh_token.trim() !== "" ? body.refresh_token : null;
  const scopes = typeof body.scope === "string" ? body.scope.split(/\s+/).filter(Boolean) : [];
  return { accessToken: body.access_token, refreshToken: refresh, scopes };
}

export async function exchangeCode(cfg: GoogleOAuthConfig, code: string, codeVerifier: string) {
  const res = await postForm(TOKEN_URL, {
    grant_type: "authorization_code",
    code,
    code_verifier: codeVerifier,
    client_id: cfg.clientId,
    client_secret: cfg.clientSecret,
    redirect_uri: cfg.redirectUri,
  });
  return readTokenResponse(res);
}

export async function refreshAccessToken(cfg: GoogleOAuthConfig, refreshToken: string) {
  const res = await postForm(TOKEN_URL, {
    grant_type: "refresh_token",
    refresh_token: refreshToken,
    client_id: cfg.clientId,
    client_secret: cfg.clientSecret,
  });
  return readTokenResponse(res);
}

/** 토큰 폐기. 200 = 폐기됨, 400 = 이미 무효(폐기된 것으로 본다). 그 밖은 오류. */
export async function revokeToken(token: string) {
  const res = await postForm(REVOKE_URL, { token });
  if (res.ok || res.status === 400) return;
  throw new GoogleOAuthError(`http_${res.status}`);
}

/** channels.list mine=true → 채널 id. 채널이 없으면 null */
export async function fetchMyChannelId(accessToken: string): Promise<string | null> {
  let res: Response;
  try {
    res = await fetch(CHANNELS_URL, {
      headers: { Authorization: `Bearer ${accessToken}` },
      signal: AbortSignal.timeout(TIMEOUT_MS),
      cache: "no-store",
    });
  } catch {
    throw new GoogleOAuthError("network");
  }
  if (!res.ok) throw new GoogleOAuthError(`http_${res.status}`);
  const body = (await res.json().catch(() => null)) as { items?: { id?: unknown }[] } | null;
  const items = Array.isArray(body?.items) ? body.items : [];
  if (items.length !== 1 || typeof items[0].id !== "string" || items[0].id === "") return null;
  return items[0].id;
}
