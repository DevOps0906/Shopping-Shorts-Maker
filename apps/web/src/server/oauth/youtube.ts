import "server-only";
import { createHash, randomBytes } from "node:crypto";
import type { GoogleOAuthConfig } from "./config";
import {
  buildAuthUrl,
  exchangeCode,
  fetchMyChannelId,
  GoogleOAuthError,
  refreshAccessToken,
  revokeToken,
  YOUTUBE_SCOPES,
} from "./google";
import { type OAuthStore, OAuthStoreError } from "./store";

/*
 * YouTube 연결·재연결·해제 흐름(task-022a). 근거: docs/04_API.md YouTube 2절, docs/w4/threat-022a.md.
 * - 시작: 세션 사용자의 계정인지 DB가 다시 확인하고 state(해시)·PKCE verifier 를 서버에 10분·1회로 저장
 * - 콜백: 세션 사용자 = state 사용자, 필수 범위 3개, channels.list mine=true 채널이 기존 값과 같아야 저장
 * - 해제: Google 폐기 → Vault 삭제. 반환값·로그에 토큰 원문을 넣지 않는다.
 */

/** 화면 안내용 결과 코드(쿼리 ?oauth=). 토큰·코드는 담지 않는다. */
export type OAuthResult =
  | "connected"
  | "disconnected"
  | "config_missing"
  | "not_allowed"
  | "invalid_state"
  | "denied"
  | "scope_missing"
  | "no_channel"
  | "channel_mismatch"
  | "channel_taken"
  | "no_refresh_token"
  | "too_many"
  | "revoke_failed"
  | "failed";

export function base64url(buf: Buffer) {
  return buf.toString("base64url");
}

export function sha256Hex(value: string) {
  return createHash("sha256").update(value).digest("hex");
}

export function pkceChallenge(verifier: string) {
  return base64url(createHash("sha256").update(verifier).digest());
}

export function hasRequiredScopes(scopes: string[]) {
  return YOUTUBE_SCOPES.every((s) => scopes.includes(s));
}

const storeCode = (e: unknown) => (e instanceof OAuthStoreError ? e.code : null);

/** 연결 시작. 성공하면 Google 동의 화면 주소 */
export async function startConnect(
  store: OAuthStore,
  cfg: GoogleOAuthConfig | null,
  userId: string,
  accountId: string,
): Promise<{ ok: true; url: string } | { ok: false; result: OAuthResult }> {
  if (!cfg) return { ok: false, result: "config_missing" };
  const state = base64url(randomBytes(32));
  const verifier = base64url(randomBytes(48)); // 64자(43~128)
  try {
    await store.createState(userId, accountId, sha256Hex(state), verifier);
  } catch (e) {
    const code = storeCode(e);
    return { ok: false, result: code === "42501" ? "not_allowed" : code === "54000" ? "too_many" : "failed" };
  }
  return { ok: true, url: buildAuthUrl(cfg, state, pkceChallenge(verifier)) };
}

/** 콜백 처리. 쿼리의 code·state·error 를 그대로 받는다 */
export async function finishConnect(
  store: OAuthStore,
  cfg: GoogleOAuthConfig | null,
  userId: string,
  query: { code: string | null; state: string | null; error: string | null },
): Promise<OAuthResult> {
  if (!cfg) return "config_missing";
  if (!query.state || query.state.length > 200) return "invalid_state";
  let pending: Awaited<ReturnType<OAuthStore["consumeState"]>>;
  try {
    pending = await store.consumeState(userId, sha256Hex(query.state));
  } catch {
    return "failed";
  }
  if (!pending) return "invalid_state";
  if (query.error || !query.code) return "denied";

  let channelId: string | null;
  let tokens: Awaited<ReturnType<typeof exchangeCode>>;
  try {
    tokens = await exchangeCode(cfg, query.code, pending.codeVerifier);
    // 범위가 모자라면 저장하지 않는다(미연결). 거부된 토큰은 폐기하지 않는다 — 같은 Google 계정의 기존 연결까지 끊길 수 있다
    if (!hasRequiredScopes(tokens.scopes)) return "scope_missing";
    channelId = await fetchMyChannelId(tokens.accessToken);
  } catch (e) {
    return e instanceof GoogleOAuthError && e.code === "invalid_grant" ? "invalid_state" : "failed";
  }
  if (!channelId) return "no_channel";

  try {
    const status = await store.saveConnection({
      userId,
      accountId: pending.accountId,
      channelId,
      refreshToken: tokens.refreshToken,
      scopes: tokens.scopes,
    });
    return status === "connected" ? "connected" : "no_refresh_token";
  } catch (e) {
    switch (storeCode(e)) {
      case "OA001":
        return "channel_mismatch";
      case "OA002":
        return "scope_missing";
      case "23505":
        return "channel_taken";
      case "42501":
        return "not_allowed";
      default:
        return "failed";
    }
  }
}

/** 연결 해제: 소유 확인 → Google 폐기 → Vault 삭제. 폐기가 실패하면 Vault 를 남기고 다시 시도하게 한다 */
export async function disconnect(store: OAuthStore, userId: string, accountId: string): Promise<OAuthResult> {
  let token: string | null;
  try {
    token = await store.getRefreshToken(accountId, userId);
  } catch (e) {
    return storeCode(e) === "42501" ? "not_allowed" : "failed";
  }
  if (token) {
    try {
      await revokeToken(token);
    } catch {
      return "revoke_failed";
    }
  }
  try {
    await store.clearToken(accountId, userId);
  } catch (e) {
    return storeCode(e) === "42501" ? "not_allowed" : "failed";
  }
  return "disconnected";
}

/** 재연결이 필요한 계정(토큰 없음·invalid_grant). 업로드 쪽은 이 오류면 사용자에게 재연결을 안내한다 */
export class ReconnectRequiredError extends Error {
  constructor() {
    super("YouTube 계정을 다시 연결해야 합니다.");
    this.name = "ReconnectRequiredError";
  }
}

/**
 * 서버 전용 access token 발급(업로드 주체 = Next.js 서버). 요청마다 갱신 토큰으로 새로 받고 캐시하지 않는다.
 * accounts.user_id = userId 가 아니면 예외(DB 42501). invalid_grant 면 갱신에 쓴 토큰 버전이 아직 현재일 때만
 * Vault 를 지우고 reconnect_required 로 바꾼다(그사이 재연결로 받은 새 토큰은 지우지 않는다).
 */
export async function getAccessTokenWith(
  store: OAuthStore,
  cfg: GoogleOAuthConfig | null,
  userId: string,
  accountId: string,
): Promise<string> {
  if (!cfg) throw new Error("GOOGLE_OAUTH_* 환경 변수가 설정되지 않았습니다.");
  const current = await store.getTokenForUse(userId, accountId);
  if (!current) throw new ReconnectRequiredError();
  try {
    const tokens = await refreshAccessToken(cfg, current.refreshToken);
    return tokens.accessToken;
  } catch (e) {
    if (e instanceof GoogleOAuthError && e.code === "invalid_grant") {
      await store.expireToken(accountId, current.ref);
      throw new ReconnectRequiredError();
    }
    throw e;
  }
}
