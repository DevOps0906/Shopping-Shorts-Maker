import "server-only";
import { createAdminClient } from "@/server/supabase-admin";

/*
 * OAuth 서버 저장소 — DB public 래퍼(service_role 전용, 20261112270000)만 부른다.
 * 토큰 원문은 Vault 에만 있고, 이 모듈 밖으로는 getAccessToken·해제 경로에서만 나간다(브라우저 반환 금지).
 */

/** DB 오류 코드(SQLSTATE) 를 서비스가 구분하도록 넘긴다. 메시지에는 토큰을 넣지 않는다. */
export class OAuthStoreError extends Error {
  constructor(readonly code: string) {
    super(`OAuth 저장소 오류: ${code}`);
    this.name = "OAuthStoreError";
  }
}

export type OAuthStore = {
  createState(userId: string, accountId: string, stateHash: string, verifier: string): Promise<void>;
  /** 1회 소모. 없음·재사용·만료·다른 사용자는 null */
  consumeState(userId: string, stateHash: string): Promise<{ accountId: string; codeVerifier: string } | null>;
  /** 반환: connected | reconnect_required. 오류 코드: 42501 · OA001(다른 채널) · OA002(범위) · 23505(다른 계정 채널) */
  saveConnection(input: {
    userId: string;
    accountId: string;
    channelId: string;
    refreshToken: string | null;
    scopes: string[];
  }): Promise<string>;
  /** userId 를 주면 소유자까지 확인한다(해제 경로) */
  getRefreshToken(accountId: string, userId?: string): Promise<string | null>;
  /** Vault 삭제 + 재연결 필요(해제 경로) */
  clearToken(accountId: string, userId?: string): Promise<void>;
  /** access token 발급용: 소유자 확인(42501) + 토큰 버전(Vault secret id). 토큰 없으면 null */
  getTokenForUse(userId: string, accountId: string): Promise<{ ref: string; refreshToken: string } | null>;
  /** invalid_grant: 그 버전이 아직 현재일 때만 재연결 필요·Vault 삭제. 반환 = 바꿨는지 */
  expireToken(accountId: string, ref: string): Promise<boolean>;
};

type RpcError = { code?: string } | null;

function check(error: RpcError) {
  if (error) throw new OAuthStoreError(error.code ?? "unknown");
}

export function createOAuthStore(): OAuthStore {
  const db = createAdminClient();
  return {
    async createState(userId, accountId, stateHash, verifier) {
      const { error } = await db.rpc("oauth_state_create", {
        p_user_id: userId,
        p_account_id: accountId,
        p_state_hash: stateHash,
        p_verifier: verifier,
      });
      check(error);
    },
    async consumeState(userId, stateHash) {
      const { data, error } = await db.rpc("oauth_state_consume", { p_user_id: userId, p_state_hash: stateHash });
      check(error);
      const row = data?.[0];
      return row ? { accountId: row.account_id, codeVerifier: row.code_verifier } : null;
    },
    async saveConnection({ userId, accountId, channelId, refreshToken, scopes }) {
      const { data, error } = await db.rpc("youtube_save_connection", {
        p_user_id: userId,
        p_account_id: accountId,
        p_channel_id: channelId,
        // 생성 타입은 text 를 non-null 로 적지만 함수는 null·빈 값 = 기존 토큰 유지로 처리한다
        p_refresh_token: refreshToken ?? "",
        p_scopes: scopes,
      });
      check(error);
      return String(data);
    },
    async getRefreshToken(accountId, userId) {
      const { data, error } = await db.rpc("youtube_refresh_token", {
        p_account_id: accountId,
        ...(userId ? { p_user_id: userId } : {}),
      });
      check(error);
      return typeof data === "string" && data !== "" ? data : null;
    },
    async clearToken(accountId, userId) {
      const { error } = await db.rpc("youtube_clear_token", {
        p_account_id: accountId,
        ...(userId ? { p_user_id: userId } : {}),
      });
      check(error);
    },
    async getTokenForUse(userId, accountId) {
      const { data, error } = await db.rpc("youtube_token_for", { p_user_id: userId, p_account_id: accountId });
      check(error);
      const row = data?.[0];
      return row?.token_ref && row.refresh_token ? { ref: row.token_ref, refreshToken: row.refresh_token } : null;
    },
    async expireToken(accountId, ref) {
      const { data, error } = await db.rpc("youtube_expire_token", { p_account_id: accountId, p_token_ref: ref });
      check(error);
      return data === true;
    },
  };
}
