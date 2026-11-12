import "server-only";
import { createAdminClient } from "@/server/supabase-admin";
import type { Claim, ClaimResult, UploaderStore } from "./uploader";

/*
 * 업로더 저장소 — DB public 래퍼(service_role 전용, 20261112280000)만 부른다.
 * 세션 URI 는 publication_upload_sessions 에만 있고, 이 모듈 밖으로는 업로더에게만 넘긴다(브라우저 반환 금지).
 */

export class UploaderStoreError extends Error {
  constructor(readonly code: string) {
    super(`업로더 저장소 오류: ${code}`);
    this.name = "UploaderStoreError";
  }
}

function check(error: { code?: string } | null) {
  if (error) throw new UploaderStoreError(error.code ?? "unknown");
}

const str = (v: unknown) => (typeof v === "string" ? v : null);

/** publication_claim 결과(jsonb) → Claim. 형식이 어긋나면 예외 */
export function parseClaim(data: unknown): ClaimResult {
  if (typeof data !== "object" || data === null) throw new UploaderStoreError("bad_claim");
  const d = data as Record<string, unknown>;
  if (d.claimed !== true) return { claimed: false, reason: str(d.reason) ?? "idle" };
  const s = d.session as Record<string, unknown> | null | undefined;
  const claim: Claim = {
    publicationId: str(d.publication_id) ?? "",
    attemptToken: str(d.attempt_token) ?? "",
    projectId: str(d.project_id) ?? "",
    userId: str(d.user_id) ?? "",
    accountId: str(d.account_id) ?? "",
    mode: d.mode === "scheduled" ? "scheduled" : "now",
    scheduledAt: str(d.scheduled_at),
    title: str(d.title) ?? "",
    description: str(d.description) ?? "",
    hashtags: Array.isArray(d.hashtags) ? d.hashtags.filter((t): t is string => typeof t === "string") : [],
    mp4Path: str(d.mp4_path),
    session:
      s && typeof s === "object" && typeof s.uri === "string" && typeof s.total_bytes === "number"
        ? { uri: s.uri, totalBytes: s.total_bytes }
        : null,
  };
  if (!claim.publicationId || !claim.attemptToken || !claim.userId || !claim.accountId) {
    throw new UploaderStoreError("bad_claim");
  }
  return { claimed: true, claim };
}

export function createUploaderStore(): UploaderStore {
  const db = createAdminClient();
  return {
    async claim() {
      const { data, error } = await db.rpc("publication_claim");
      check(error);
      return parseClaim(data);
    },
    async sessionBegin(publicationId, attemptToken) {
      const { data, error } = await db.rpc("publication_session_begin", {
        p_publication_id: publicationId,
        p_attempt_token: attemptToken,
      });
      check(error);
      return (data as { ok?: unknown } | null)?.ok === true;
    },
    async sessionSave(publicationId, attemptToken, uri, totalBytes) {
      const { error } = await db.rpc("publication_session_save", {
        p_publication_id: publicationId,
        p_attempt_token: attemptToken,
        p_session_uri: uri,
        p_total_bytes: totalBytes,
      });
      check(error);
    },
    async finish(publicationId, attemptToken, videoId, testPrivate) {
      const { data, error } = await db.rpc("publication_finish", {
        p_publication_id: publicationId,
        p_attempt_token: attemptToken,
        p_video_id: videoId,
        p_test_private: testPrivate,
      });
      check(error);
      return str((data as { status?: unknown } | null)?.status) ?? "unknown";
    },
    async rejectCopy(publicationId, attemptToken, code) {
      const { data, error } = await db.rpc("publication_reject_copy", {
        p_publication_id: publicationId,
        p_attempt_token: attemptToken,
        p_code: code,
      });
      check(error);
      return str((data as { status?: unknown } | null)?.status) ?? "unknown";
    },
    async fail(publicationId, attemptToken, kind, code) {
      const { data, error } = await db.rpc("publication_attempt_fail", {
        p_publication_id: publicationId,
        p_attempt_token: attemptToken,
        p_kind: kind,
        p_code: code,
      });
      check(error);
      return str((data as { status?: unknown } | null)?.status) ?? "unknown";
    },
  };
}

/** 렌더 MP4(비공개 버킷 renders). 경로는 <user_id>/<project_id>/ 로 시작해야 한다. 없으면 null */
export function createVideoLoader() {
  const db = createAdminClient();
  return async (claim: Claim): Promise<Uint8Array<ArrayBuffer> | null> => {
    const path = claim.mp4Path;
    if (!path || !path.startsWith(`${claim.userId}/${claim.projectId}/`) || path.includes("..")) return null;
    const { data, error } = await db.storage.from("renders").download(path);
    if (error) {
      const status = (error as { status?: unknown; statusCode?: unknown }).status ?? (error as { statusCode?: unknown }).statusCode;
      if (status === 404 || status === "404" || /not.?found/i.test(error.message)) return null;
      throw new UploaderStoreError("storage");
    }
    return new Uint8Array(await data.arrayBuffer());
  };
}
