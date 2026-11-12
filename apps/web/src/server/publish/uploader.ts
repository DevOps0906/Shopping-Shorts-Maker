import "server-only";
import { ReconnectRequiredError } from "@/server/oauth/youtube";
import {
  type FetchLike,
  type TransferResult,
  type VideoMeta,
  initSession,
  putBytes,
  queryStatus,
} from "./youtube-upload";

/*
 * YouTube 업로더 1회 실행(task-024a). 상태는 publications 만으로 관리한다(jobs·크레딧 없음).
 * 1) publication_claim: 6/6 재판정 + uploading 전환을 DB 한 트랜잭션에서, 시도 토큰 발급
 * 2) 시도마다 getAccessToken 으로 새 access token. invalid_grant·연결 해제 → reconnect_wait(재시도 횟수 미차감)
 * 3) 세션이 있으면 새 insert 대신 상태 조회로 이어 올린다. 없으면 전역 쿼터 확인 → insert → 세션 URI 저장 → 바이트 전송
 * 4) 응답 유실이면 바로 상태 조회, 그것도 안 되면 needs_check(자동 재업로드 없음)
 * 토큰·세션 URI 는 로그·오류 코드에 넣지 않는다.
 */

export type ClaimSession = { uri: string; totalBytes: number };

export type Claim = {
  publicationId: string;
  attemptToken: string;
  projectId: string;
  userId: string;
  accountId: string;
  mode: "scheduled" | "now";
  scheduledAt: string | null;
  title: string;
  description: string;
  hashtags: string[];
  mp4Path: string | null;
  session: ClaimSession | null;
};

export type ClaimResult = { claimed: true; claim: Claim } | { claimed: false; reason: string };

/** deferred = 보관 정리 경합(024b RT001) 등 잠시 뒤 다시(횟수 미차감, 5분) */
export type FailKind = "transient" | "quota" | "reconnect" | "unknown" | "permanent" | "deferred";

/** YouTube 한도: 제목 100자 · 설명란 5000바이트(UTF-8) · 태그 합 500자(쉼표 포함, 공백 있는 태그는 따옴표 2자) */
export const YOUTUBE_TITLE_MAX = 100;
export const YOUTUBE_DESCRIPTION_MAX_BYTES = 5000;
export const YOUTUBE_TAGS_MAX = 500;
export type CopyLimitCode = "title_too_long" | "description_too_long" | "tags_too_long";

export function utf8Bytes(text: string) {
  return new TextEncoder().encode(text).byteLength;
}

export function youtubeTagsLength(tags: string[]) {
  return tags.reduce((n, t) => n + [...t].length + (/\s/.test(t) ? 2 : 0), 0) + Math.max(tags.length - 1, 0);
}

export function copyLimitError(c: { title: string; description: string; hashtags: string[] }): CopyLimitCode | null {
  if ([...c.title].length > YOUTUBE_TITLE_MAX) return "title_too_long";
  if (utf8Bytes(c.description) > YOUTUBE_DESCRIPTION_MAX_BYTES) return "description_too_long";
  if (youtubeTagsLength(c.hashtags) > YOUTUBE_TAGS_MAX) return "tags_too_long";
  return null;
}

/** DB SQLSTATE RT001: 보관 정리(024b)가 같은 프로젝트 파일을 예약 중 → 상태 전환 취소, 잠시 뒤 다시 */
const isRetentionBusy = (e: unknown) =>
  typeof e === "object" && e !== null && (e as { code?: unknown }).code === "RT001";

/** DB 함수(20261112280000) 래퍼. 시도 토큰이 맞지 않으면(선점이 끝남) 예외 */
export type UploaderStore = {
  claim(): Promise<ClaimResult>;
  /** 전역 일일 카운터 확인·증가. false = 쿼터 소진(DB가 이미 PT 자정 이후로 미룸) */
  sessionBegin(publicationId: string, attemptToken: string): Promise<boolean>;
  sessionSave(publicationId: string, attemptToken: string, uri: string, totalBytes: number): Promise<void>;
  finish(publicationId: string, attemptToken: string, videoId: string, testPrivate: boolean): Promise<string>;
  /** 문구가 YouTube 한도를 넘음(세션 전) → 자동 재시도 없이 발행 준비 해제(invalidated, confirm:<코드>) */
  rejectCopy(publicationId: string, attemptToken: string, code: CopyLimitCode): Promise<string>;
  fail(publicationId: string, attemptToken: string, kind: FailKind, code: string): Promise<string>;
};

export type UploaderDeps = {
  store: UploaderStore;
  fetch: FetchLike;
  getAccessToken(userId: string, accountId: string): Promise<string>;
  /** 렌더 MP4 바이트. 없으면 null(보관 기간 삭제 등) */
  loadVideo(claim: Claim): Promise<Uint8Array<ArrayBuffer> | null>;
  /** 서버 전용 설정 UPLOAD_TEST_PRIVATE=1: privacyStatus=private · publishAt 없음 */
  testPrivate: boolean;
  log?: (line: string) => void;
};

export type RunResult =
  | { kind: "idle" }
  | { kind: "skipped"; reason: string }
  | { kind: "done"; status: string; code?: string }
  | { kind: "error"; code: string };

const MAX_TRANSFER_ROUNDS = 3;

export function videoMeta(claim: Claim, testPrivate: boolean): VideoMeta {
  const scheduled = claim.mode === "scheduled" && claim.scheduledAt !== null && !testPrivate;
  return {
    title: claim.title,
    description: claim.description,
    tags: claim.hashtags,
    privacyStatus: testPrivate || scheduled ? "private" : "public",
    publishAt: scheduled ? new Date(claim.scheduledAt as string).toISOString() : null,
  };
}

async function attempt(deps: UploaderDeps, c: Claim): Promise<RunResult> {
  const { store } = deps;
  const id = c.publicationId;
  const tok = c.attemptToken;
  const fail = async (kind: FailKind, code: string): Promise<RunResult> => ({
    kind: "done",
    status: await store.fail(id, tok, kind, code),
    code,
  });
  const finish = async (videoId: string): Promise<RunResult> => {
    try {
      return { kind: "done", status: await store.finish(id, tok, videoId, deps.testPrivate) };
    } catch (e) {
      // 영상은 올라갔다. 세션이 남아 있으므로 다음 시도는 상태 조회로 완료를 확인해 기록한다(재업로드 없음)
      if (isRetentionBusy(e)) return fail("deferred", "RT001");
      throw e;
    }
  };
  const failFrom = (r: Exclude<TransferResult, { kind: "complete" | "incomplete" | "lost" }>, ctx: "insert" | "session") =>
    r.kind === "gone" ? fail(ctx === "insert" ? "permanent" : "unknown", "session_gone") : fail(r.kind, r.code);

  let accessToken: string;
  try {
    accessToken = await deps.getAccessToken(c.userId, c.accountId);
  } catch (e) {
    return e instanceof ReconnectRequiredError ? fail("reconnect", "reconnect_required") : fail("transient", "token_error");
  }

  const loadVideo = async () => {
    try {
      return { video: await deps.loadVideo(c) };
    } catch {
      return { error: true as const };
    }
  };

  /** offset 부터 끝까지 전송. 응답 유실이면 상태 조회로 확인하고, 확인도 안 되면 needs_check */
  const transfer = async (uri: string, video: Uint8Array<ArrayBuffer>, offset: number): Promise<RunResult> => {
    for (let round = 0; round < MAX_TRANSFER_ROUNDS; round++) {
      let r = await putBytes(deps.fetch, accessToken, uri, video, offset);
      if (r.kind === "lost") {
        r = await queryStatus(deps.fetch, accessToken, uri, video.byteLength);
        if (r.kind !== "complete" && r.kind !== "incomplete") return fail("unknown", "response_lost");
      }
      if (r.kind === "complete") return finish(r.videoId);
      if (r.kind === "incomplete") {
        offset = r.received;
        continue;
      }
      return failFrom(r as Exclude<TransferResult, { kind: "complete" | "incomplete" | "lost" }>, "session");
    }
    return fail("transient", "incomplete");
  };

  const session = c.session;
  if (session) {
    const st = await queryStatus(deps.fetch, accessToken, session.uri, session.totalBytes);
    if (st.kind === "complete") return finish(st.videoId);
    if (st.kind === "incomplete") {
      const loaded = await loadVideo();
      if ("error" in loaded) return fail("transient", "storage_error");
      if (!loaded.video) return fail("permanent", "video_missing");
      // 세션을 만든 파일과 다르면 이어 올리지 않는다
      if (loaded.video.byteLength !== session.totalBytes) return fail("unknown", "video_changed");
      return transfer(session.uri, loaded.video, st.received);
    }
    if (st.kind === "lost") return fail("unknown", "response_lost");
    // 세션이 사라짐(404·410): 이미 올라갔을 수 있다 → needs_check. 새 업로드는 사용자 "영상 없음 확인"(세션 폐기) 뒤에만
    if (st.kind === "gone") return fail("unknown", "session_gone");
    // 세션이 남아 있을 수 있다 → 횟수를 다 쓰면 DB가 needs_check 로 둔다
    return st.kind === "permanent" ? fail("unknown", st.code) : fail(st.kind, st.code);
  }

  const loaded = await loadVideo();
  if ("error" in loaded) return fail("transient", "storage_error");
  if (!loaded.video || loaded.video.byteLength === 0) return fail("permanent", "video_missing");
  const video = loaded.video;

  const limit = copyLimitError(c);
  if (limit) return { kind: "done", status: await store.rejectCopy(id, tok, limit), code: limit };

  if (!(await store.sessionBegin(id, tok))) return { kind: "done", status: "retry_wait", code: "daily_limit" };
  const init = await initSession(deps.fetch, accessToken, videoMeta(c, deps.testPrivate), video.byteLength);
  if (!init.ok) return failFrom(init, "insert");
  // 바이트 전송 전에 세션 URI 를 저장한다(재시도는 이 세션으로 이어 올린다)
  await store.sessionSave(id, tok, init.uri, video.byteLength);
  return transfer(init.uri, video, 0);
}

/** 대기 발행 1건을 선점해 올린다. 예외는 코드만 남기고 삼킨다(멈춘 시도는 DB가 30분 뒤 정리) */
export async function runOnce(deps: UploaderDeps): Promise<RunResult> {
  const log = deps.log ?? (() => {});
  let claimed: ClaimResult;
  try {
    claimed = await deps.store.claim();
  } catch {
    log("[uploader] 선점 실패");
    return { kind: "error", code: "claim_failed" };
  }
  if (!claimed.claimed) {
    if (claimed.reason !== "idle") log(`[uploader] 선점 거부: ${claimed.reason}`);
    return claimed.reason === "idle" ? { kind: "idle" } : { kind: "skipped", reason: claimed.reason };
  }
  const c = claimed.claim;
  try {
    const result = await attempt(deps, c);
    if (result.kind === "done") log(`[uploader] ${c.publicationId} → ${result.status}${result.code ? ` (${result.code})` : ""}`);
    return result;
  } catch (e) {
    if (isRetentionBusy(e)) {
      try {
        await deps.store.fail(c.publicationId, c.attemptToken, "deferred", "RT001");
        log(`[uploader] ${c.publicationId} → retry_wait (RT001)`);
        return { kind: "done", status: "retry_wait", code: "RT001" };
      } catch {
        // 아래로
      }
    }
    log(`[uploader] ${c.publicationId} 기록 실패`);
    return { kind: "error", code: "store_failed" };
  }
}
