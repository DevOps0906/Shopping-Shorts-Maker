import "server-only";

/*
 * YouTube Data API videos.insert resumable 업로드 HTTP(서버 전용). 근거: docs/04_API.md YouTube 1·4절.
 * - 세션 시작(POST) → 세션 URI(Location) → 바이트 전송(PUT). 결과를 모르면 상태 조회(PUT bytes *\/N)로 확인한다.
 * - fetch 를 주입받는다(테스트는 가짜 fetch, 실제 YouTube 호출 없음).
 * - 토큰·세션 URI 는 반환값으로만 넘기고 오류 코드·로그에 넣지 않는다.
 */

export const UPLOAD_INIT_URL =
  "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status";

const INIT_TIMEOUT_MS = 15_000;
const STATUS_TIMEOUT_MS = 15_000;
const PUT_TIMEOUT_MS = 10 * 60_000;

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export type VideoMeta = {
  title: string;
  description: string;
  tags: string[];
  privacyStatus: "private" | "public";
  /** UTC ISO. 있으면 privacyStatus 는 private 이어야 한다 */
  publishAt: string | null;
};

/** 실패 분류. gone = 세션이 사라짐(404·410) */
export type ApiFailure = { kind: "transient" | "quota" | "reconnect" | "permanent" | "gone"; code: string };

export type InitResult = { ok: true; uri: string } | ({ ok: false } & ApiFailure);
export type TransferResult =
  | { kind: "complete"; videoId: string }
  | { kind: "incomplete"; received: number }
  /** 응답을 받지 못함(네트워크·시간 초과) — 올라갔는지 모른다 */
  | { kind: "lost" }
  | ApiFailure;

const QUOTA_REASONS = new Set(["quotaExceeded", "uploadLimitExceeded", "dailyLimitExceeded"]);
const TRANSIENT_REASONS = new Set(["rateLimitExceeded", "userRateLimitExceeded", "backendError", "internalError"]);

/** 세션 URI 는 YouTube 업로드 주소만(다른 곳으로 토큰을 보내지 않는다) */
export function isSessionUri(uri: string) {
  try {
    const u = new URL(uri);
    return u.protocol === "https:" && u.host === "www.googleapis.com" && u.pathname === "/upload/youtube/v3/videos";
  } catch {
    return false;
  }
}

async function errorReason(res: Response): Promise<string | null> {
  try {
    const body = (await res.json()) as { error?: { errors?: { reason?: unknown }[] } };
    const reason = body.error?.errors?.[0]?.reason;
    return typeof reason === "string" && /^[A-Za-z]{1,60}$/.test(reason) ? reason : null;
  } catch {
    return null;
  }
}

/** HTTP 오류 응답 분류 */
export async function classifyError(res: Response): Promise<ApiFailure> {
  const reason = await errorReason(res);
  const code = reason ?? `http_${res.status}`;
  if (reason && QUOTA_REASONS.has(reason)) return { kind: "quota", code };
  if (res.status === 401) return { kind: "reconnect", code: "unauthorized" };
  if (res.status === 404 || res.status === 410) return { kind: "gone", code };
  if (res.status === 429 || res.status >= 500 || (reason && TRANSIENT_REASONS.has(reason))) return { kind: "transient", code };
  return { kind: "permanent", code };
}

/** 308 의 Range: bytes=0-N → 받은 바이트 수 */
function receivedBytes(res: Response) {
  const m = /^bytes=0-(\d+)$/.exec(res.headers.get("range") ?? "");
  return m ? Number(m[1]) + 1 : 0;
}

async function readVideoId(res: Response): Promise<string | null> {
  try {
    const body = (await res.json()) as { id?: unknown };
    return typeof body.id === "string" && /^[A-Za-z0-9_-]{6,64}$/.test(body.id) ? body.id : null;
  } catch {
    return null;
  }
}

async function transferResult(res: Response): Promise<TransferResult> {
  if (res.status === 200 || res.status === 201) {
    const videoId = await readVideoId(res);
    return videoId ? { kind: "complete", videoId } : { kind: "permanent", code: "no_video_id" };
  }
  if (res.status === 308) return { kind: "incomplete", received: receivedBytes(res) };
  return classifyError(res);
}

export function buildVideoResource(meta: VideoMeta) {
  return {
    snippet: { title: meta.title, description: meta.description, tags: meta.tags },
    status: {
      // 공개 상태를 빼면 기본값이 public 이므로 항상 명시한다
      privacyStatus: meta.publishAt ? "private" : meta.privacyStatus,
      ...(meta.publishAt ? { publishAt: meta.publishAt } : {}),
      selfDeclaredMadeForKids: false,
    },
  };
}

/** 세션 시작(videos.insert, 업로드 버킷 1회) */
export async function initSession(fetchFn: FetchLike, accessToken: string, meta: VideoMeta, size: number): Promise<InitResult> {
  let res: Response;
  try {
    res = await fetchFn(UPLOAD_INIT_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json; charset=UTF-8",
        "X-Upload-Content-Length": String(size),
        "X-Upload-Content-Type": "video/mp4",
      },
      body: JSON.stringify(buildVideoResource(meta)),
      signal: AbortSignal.timeout(INIT_TIMEOUT_MS),
    });
  } catch {
    // 세션 URI 를 받기 전이라 바이트를 보내지 않았다 → 다시 시도해도 중복 업로드가 아니다
    return { ok: false, kind: "transient", code: "network" };
  }
  if (res.status !== 200) return { ok: false, ...(await classifyError(res)) };
  const uri = res.headers.get("location") ?? "";
  if (!isSessionUri(uri)) return { ok: false, kind: "permanent", code: "bad_session_uri" };
  return { ok: true, uri };
}

/** 바이트 전송(offset 부터 끝까지) */
export async function putBytes(
  fetchFn: FetchLike,
  accessToken: string,
  uri: string,
  video: Uint8Array<ArrayBuffer>,
  offset: number,
): Promise<TransferResult> {
  if (!isSessionUri(uri)) return { kind: "permanent", code: "bad_session_uri" };
  const total = video.byteLength;
  let res: Response;
  try {
    res = await fetchFn(uri, {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "video/mp4",
        ...(offset > 0 ? { "Content-Range": `bytes ${offset}-${total - 1}/${total}` } : {}),
      },
      body: video.subarray(offset),
      redirect: "manual",
      signal: AbortSignal.timeout(PUT_TIMEOUT_MS),
    });
  } catch {
    return { kind: "lost" };
  }
  return transferResult(res);
}

/** 세션 상태 조회(PUT, 빈 본문, Content-Range: bytes *\/N). 연결 실패는 transient(code status_unreachable) */
export async function queryStatus(fetchFn: FetchLike, accessToken: string, uri: string, total: number): Promise<TransferResult> {
  if (!isSessionUri(uri)) return { kind: "permanent", code: "bad_session_uri" };
  let res: Response;
  try {
    res = await fetchFn(uri, {
      method: "PUT",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Range": `bytes */${total}` },
      body: "",
      redirect: "manual",
      signal: AbortSignal.timeout(STATUS_TIMEOUT_MS),
    });
  } catch {
    return { kind: "transient", code: "status_unreachable" };
  }
  return transferResult(res);
}
