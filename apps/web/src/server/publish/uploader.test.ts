import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

const { runOnce, videoMeta, copyLimitError, youtubeTagsLength } = await import("./uploader");
const { ReconnectRequiredError } = await import("@/server/oauth/youtube");
const { UPLOAD_INIT_URL } = await import("./youtube-upload");
const { parseClaim } = await import("./uploader-store");
type Claim = import("./uploader").Claim;
type UploaderStore = import("./uploader").UploaderStore;
type FailKind = import("./uploader").FailKind;

/*
 * 업로더 목 테스트(실제 YouTube·DB 호출 없음). 가짜 저장소는 DB 함수(20261112280000)와 같은 상태 규칙,
 * 가짜 fetch 는 YouTube resumable 업로드 응답을 흉내 낸다.
 */

const ACCESS = "at-SECRET-1";
const SESSION_URI = "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&upload_id=SESSION-SECRET";
const VIDEO = new Uint8Array(1000).fill(7);

type Pub = {
  status: string;
  retryCount: number;
  error: string | null;
  videoId: string | null;
  session: { uri: string; totalBytes: number; completed: boolean } | null;
  token: string | null;
  claimable: boolean;
};

function fakeStore(
  init: Partial<Pub> & {
    mode?: "now" | "scheduled";
    scheduledAt?: string | null;
    quotaFull?: boolean;
    description?: string;
    /** finish 가 RT001(보관 정리 경합)로 취소되는 횟수 */
    finishBusy?: number;
  } = {},
) {
  const pub: Pub = { status: "pending", retryCount: 0, error: null, videoId: null, session: null, token: null, claimable: true, ...init };
  let seq = 0;
  const calls = { claim: 0, begin: 0, finish: [] as { testPrivate: boolean }[], rejected: [] as string[] };
  let busy = init.finishBusy ?? 0;
  const own = (token: string) => {
    if (pub.status !== "uploading" || pub.token !== token) throw new Error("55000");
  };
  const store: UploaderStore = {
    async claim() {
      calls.claim++;
      if (!pub.claimable) return { claimed: false, reason: "policy_failed" };
      if (pub.status !== "pending" && pub.status !== "retry_wait") return { claimed: false, reason: "idle" };
      pub.status = "uploading";
      pub.token = `tok-${++seq}`;
      const claim: Claim = {
        publicationId: "pub-1",
        attemptToken: pub.token,
        projectId: "proj-1",
        userId: "user-1",
        accountId: "acc-1",
        mode: init.mode ?? "now",
        scheduledAt: init.scheduledAt ?? null,
        title: "압축팩 정리 꿀팁",
        description: init.description ?? "설명",
        hashtags: ["수납"],
        mp4Path: "user-1/proj-1/v1.mp4",
        session: pub.session ? { uri: pub.session.uri, totalBytes: pub.session.totalBytes } : null,
      };
      return { claimed: true, claim };
    },
    async sessionBegin(_id, token) {
      own(token);
      if (pub.session) throw new Error("55000");
      calls.begin++;
      if (init.quotaFull) {
        pub.status = "retry_wait";
        pub.error = "quota:daily_limit";
        pub.token = null;
        return false;
      }
      return true;
    },
    async sessionSave(_id, token, uri, totalBytes) {
      own(token);
      pub.session = { uri, totalBytes, completed: false };
    },
    async finish(_id, token, videoId, testPrivate) {
      own(token);
      if (busy > 0) {
        busy--;
        throw Object.assign(new Error("RT001"), { code: "RT001" });
      }
      calls.finish.push({ testPrivate });
      pub.videoId = videoId;
      pub.status = (init.mode ?? "now") === "scheduled" && !testPrivate ? "scheduled" : "uploaded";
      if (pub.session) pub.session.completed = true;
      pub.token = null;
      return pub.status;
    },
    async rejectCopy(_id, token, code) {
      own(token);
      if (pub.session) throw new Error("55000");
      calls.rejected.push(code);
      pub.status = "invalidated";
      pub.error = `confirm:${code}`;
      pub.token = null;
      return pub.status;
    },
    async fail(_id, token, kind: FailKind, code) {
      own(token);
      pub.token = null;
      pub.error = `${kind}:${code}`;
      if (kind === "transient") {
        pub.retryCount = Math.min(pub.retryCount + 1, 3);
        pub.status = pub.retryCount >= 3 ? (pub.session ? "needs_check" : "failed") : "retry_wait";
      } else if (kind === "quota" || kind === "deferred") pub.status = "retry_wait";
      else if (kind === "reconnect") pub.status = "reconnect_wait";
      else if (kind === "unknown") pub.status = "needs_check";
      else pub.status = "failed";
      return pub.status;
    },
  };
  return { store, pub, calls };
}

type Step = (url: string, init: RequestInit) => Response | Promise<Response>;

/** 가짜 YouTube. 요청마다 다음 응답 함수를 꺼낸다. 남은 응답이 없으면 실패 */
function fakeYouTube(steps: Step[]) {
  const log: { method: string; url: string; headers: Record<string, string>; body?: unknown }[] = [];
  const fetchFn = vi.fn(async (url: string, init: RequestInit = {}) => {
    const headers = Object.fromEntries(new Headers(init.headers).entries());
    log.push({ method: init.method ?? "GET", url, headers, body: init.body });
    const step = steps.shift();
    if (!step) throw new Error(`예상하지 않은 요청 ${init.method} ${url}`);
    return step(url, init);
  });
  const count = (pred: (e: (typeof log)[number]) => boolean) => log.filter(pred).length;
  return {
    fetchFn,
    log,
    inserts: () => count((e) => e.method === "POST" && e.url === UPLOAD_INIT_URL),
    puts: () => count((e) => e.method === "PUT" && !String(e.headers["content-range"] ?? "").startsWith("bytes */")),
    statusQueries: () => count((e) => e.method === "PUT" && String(e.headers["content-range"] ?? "").startsWith("bytes */")),
  };
}

const initOk: Step = () => new Response(null, { status: 200, headers: { Location: SESSION_URI } });
const done = (id = "dQw4w9WgXcQ"): Step => () => Response.json({ id }, { status: 200 });
const http = (status: number, reason?: string): Step => () =>
  Response.json({ error: { code: status, errors: reason ? [{ reason }] : [] } }, { status });
const lost: Step = () => {
  throw new TypeError("fetch failed");
};
const partial = (received: number): Step => () =>
  new Response(null, { status: 308, headers: received > 0 ? { Range: `bytes=0-${received - 1}` } : {} });

function deps(
  store: UploaderStore,
  fetchFn: ReturnType<typeof fakeYouTube>["fetchFn"],
  opts: { testPrivate?: boolean; token?: () => Promise<string>; video?: Uint8Array<ArrayBuffer> | null } = {},
) {
  const lines: string[] = [];
  const getAccessToken = vi.fn(opts.token ?? (async () => ACCESS));
  return {
    lines,
    getAccessToken,
    deps: {
      store,
      fetch: fetchFn,
      getAccessToken,
      loadVideo: async () => (opts.video === undefined ? VIDEO : opts.video),
      testPrivate: opts.testPrivate ?? false,
      log: (l: string) => lines.push(l),
    },
  };
}

describe("업로더(목)", () => {
  it("지금 올리기: 세션 시작 → 세션 저장 → 전송 → uploaded, 공개 상태 명시, 토큰·세션 URI 는 로그에 없음", async () => {
    const { store, pub, calls } = fakeStore();
    const yt = fakeYouTube([initOk, done()]);
    const d = deps(store, yt.fetchFn);
    const r = await runOnce(d.deps);
    expect(r).toMatchObject({ kind: "done", status: "uploaded" });
    expect(pub.videoId).toBe("dQw4w9WgXcQ");
    expect(calls.begin).toBe(1);
    const meta = JSON.parse(String(yt.log[0].body));
    expect(meta.status).toEqual({ privacyStatus: "public", selfDeclaredMadeForKids: false });
    expect(yt.log[0].headers.authorization).toBe(`Bearer ${ACCESS}`);
    expect(yt.log[1].url).toBe(SESSION_URI);
    expect(d.lines.join("\n")).not.toMatch(/SECRET/);
  });

  it("예약: publishAt 은 UTC ISO, privacyStatus=private → scheduled", async () => {
    const { store, pub } = fakeStore({ mode: "scheduled", scheduledAt: "2026-11-20T19:00:00+09:00" });
    const yt = fakeYouTube([initOk, done()]);
    await runOnce(deps(store, yt.fetchFn).deps);
    const meta = JSON.parse(String(yt.log[0].body));
    expect(meta.status.privacyStatus).toBe("private");
    expect(meta.status.publishAt).toBe("2026-11-20T10:00:00.000Z");
    expect(pub.status).toBe("scheduled");
  });

  it("UPLOAD_TEST_PRIVATE: 예약이어도 private·publishAt 없음", async () => {
    const { store, pub, calls } = fakeStore({ mode: "scheduled", scheduledAt: "2026-11-20T10:00:00Z" });
    const yt = fakeYouTube([initOk, done()]);
    await runOnce(deps(store, yt.fetchFn, { testPrivate: true }).deps);
    const meta = JSON.parse(String(yt.log[0].body));
    expect(meta.status).toEqual({ privacyStatus: "private", selfDeclaredMadeForKids: false });
    expect(calls.finish).toEqual([{ testPrivate: true }]);
    expect(pub.status).toBe("uploaded");
    expect(videoMeta({ mode: "now", scheduledAt: null } as Claim, true).privacyStatus).toBe("private");
  });

  it("일시 오류(5xx·네트워크) 3회 → failed, 시도마다 access token 새로 받음", async () => {
    const { store, pub } = fakeStore();
    const yt = fakeYouTube([http(503), lost, http(500, "backendError")]);
    const d = deps(store, yt.fetchFn);
    for (let i = 0; i < 3; i++) await runOnce(d.deps);
    expect(pub.status).toBe("failed");
    expect(pub.retryCount).toBe(3);
    expect(yt.inserts()).toBe(3);
    expect(d.getAccessToken).toHaveBeenCalledTimes(3);
    expect(d.getAccessToken).toHaveBeenCalledWith("user-1", "acc-1");
    expect(await runOnce(d.deps)).toEqual({ kind: "idle" });
  });

  it("quotaExceeded·uploadLimitExceeded: 재시도 횟수 미차감, 다음 날 대기", async () => {
    for (const reason of ["quotaExceeded", "uploadLimitExceeded"]) {
      const { store, pub } = fakeStore();
      const yt = fakeYouTube([http(403, reason)]);
      await runOnce(deps(store, yt.fetchFn).deps);
      expect(pub).toMatchObject({ status: "retry_wait", retryCount: 0, error: `quota:${reason}` });
    }
  });

  it("전역 일일 카운터 소진: insert 호출 없이 대기", async () => {
    const { store, pub } = fakeStore({ quotaFull: true });
    const yt = fakeYouTube([]);
    const r = await runOnce(deps(store, yt.fetchFn).deps);
    expect(r).toMatchObject({ status: "retry_wait" });
    expect(yt.inserts()).toBe(0);
    expect(pub.retryCount).toBe(0);
  });

  it("응답 유실 + 세션 확인 불가 → needs_check, 재업로드 0", async () => {
    const { store, pub, calls } = fakeStore();
    const yt = fakeYouTube([initOk, lost, lost]);
    const d = deps(store, yt.fetchFn);
    await runOnce(d.deps);
    expect(pub.status).toBe("needs_check");
    expect(pub.error).toBe("unknown:response_lost");
    expect(yt.inserts()).toBe(1);
    expect(yt.puts()).toBe(1);
    expect(yt.statusQueries()).toBe(1);
    // 자동으로 다시 선점되지 않는다
    expect(await runOnce(d.deps)).toEqual({ kind: "idle" });
    expect(calls.begin).toBe(1);
  });

  it("응답 유실 뒤 상태 조회가 완료면 그대로 성공(재업로드 없음)", async () => {
    const { store, pub } = fakeStore();
    const yt = fakeYouTube([initOk, lost, done("abcDEF12345")]);
    await runOnce(deps(store, yt.fetchFn).deps);
    expect(pub).toMatchObject({ status: "uploaded", videoId: "abcDEF12345" });
    expect(yt.puts()).toBe(1);
  });

  it("세션 이어 올리기: 재시도는 새 insert 대신 상태 조회 → 받은 바이트 뒤부터 전송", async () => {
    const { store, pub } = fakeStore();
    const yt = fakeYouTube([initOk, http(503), partial(500), done()]);
    const d = deps(store, yt.fetchFn);
    await runOnce(d.deps);
    expect(pub).toMatchObject({ status: "retry_wait", retryCount: 1 });
    expect(pub.session?.uri).toBe(SESSION_URI);
    await runOnce(d.deps);
    expect(pub.status).toBe("uploaded");
    expect(yt.inserts()).toBe(1);
    const resume = yt.log[3];
    expect(resume.headers["content-range"]).toBe("bytes 500-999/1000");
    expect((resume.body as Uint8Array).byteLength).toBe(500);
    expect(yt.log[2].headers["content-range"]).toBe("bytes */1000");
  });

  it("invalid_grant·연결 해제 → reconnect_wait(재시도 횟수 미차감), YouTube 호출 없음", async () => {
    const { store, pub } = fakeStore();
    const yt = fakeYouTube([]);
    const d = deps(store, yt.fetchFn, {
      token: async () => {
        throw new ReconnectRequiredError();
      },
    });
    await runOnce(d.deps);
    expect(pub).toMatchObject({ status: "reconnect_wait", retryCount: 0 });
    expect(yt.fetchFn).not.toHaveBeenCalled();
  });

  it("세션이 사라짐(404·410): 항상 needs_check, 새 insert 없음(새 업로드는 사용자 영상 없음 확인 뒤에만)", async () => {
    for (const status of [404, 410]) {
      const a = fakeStore({ status: "retry_wait", session: { uri: SESSION_URI, totalBytes: 1000, completed: false } });
      const yt = fakeYouTube([http(status)]);
      await runOnce(deps(a.store, yt.fetchFn).deps);
      expect(a.pub).toMatchObject({ status: "needs_check", error: "unknown:session_gone" });
      expect(yt.inserts()).toBe(0);
      expect(a.calls.begin).toBe(0);
    }
  });

  it("세션 상태 조회가 완료면 바로 기록(이미 올라간 영상 재업로드 없음)", async () => {
    const { store, pub } = fakeStore({
      status: "retry_wait",
      session: { uri: SESSION_URI, totalBytes: 1000, completed: false },
    });
    const yt = fakeYouTube([done("alreadyUp01")]);
    await runOnce(deps(store, yt.fetchFn).deps);
    expect(pub).toMatchObject({ status: "uploaded", videoId: "alreadyUp01" });
    expect(yt.puts()).toBe(0);
  });

  it("선점 거부(정책 미통과·예약 시각 지남·다른 채널)면 토큰도 YouTube 도 부르지 않음", async () => {
    const { store } = fakeStore({ claimable: false });
    const yt = fakeYouTube([]);
    const d = deps(store, yt.fetchFn);
    expect(await runOnce(d.deps)).toEqual({ kind: "skipped", reason: "policy_failed" });
    expect(d.getAccessToken).not.toHaveBeenCalled();
    expect(yt.fetchFn).not.toHaveBeenCalled();
  });

  it("Location 이 YouTube 업로드 주소가 아니면 바이트·토큰을 보내지 않고 failed", async () => {
    const { store, pub } = fakeStore();
    const yt = fakeYouTube([() => new Response(null, { status: 200, headers: { Location: "https://evil.example.com/up" } })]);
    await runOnce(deps(store, yt.fetchFn).deps);
    expect(pub).toMatchObject({ status: "failed", error: "permanent:bad_session_uri" });
    expect(yt.log).toHaveLength(1);
  });

  it("영상 파일 없음 → failed(video_missing), insert 없음", async () => {
    const { store, pub } = fakeStore();
    const yt = fakeYouTube([]);
    await runOnce(deps(store, yt.fetchFn, { video: null }).deps);
    expect(pub).toMatchObject({ status: "failed", error: "permanent:video_missing" });
    expect(yt.inserts()).toBe(0);
  });

  it("parseClaim: 세션 포함 결과 변환, 빈 결과는 idle", () => {
    expect(parseClaim({ claimed: false, reason: "idle" })).toEqual({ claimed: false, reason: "idle" });
    const r = parseClaim({
      claimed: true,
      publication_id: "p",
      attempt_token: "t",
      project_id: "pr",
      user_id: "u",
      account_id: "a",
      mode: "scheduled",
      scheduled_at: "2026-11-20T10:00:00+00:00",
      title: "제목",
      description: "설명",
      hashtags: ["수납"],
      mp4_path: "u/pr/v1.mp4",
      session: { uri: SESSION_URI, total_bytes: 1000 },
    });
    expect(r.claimed && r.claim.session).toEqual({ uri: SESSION_URI, totalBytes: 1000 });
    expect(() => parseClaim({ claimed: true })).toThrow();
  });

  it("설명란 5000바이트 초과(한글 4000자): insert 전에 발행 준비 해제(자동 재시도 없음)", async () => {
    const { store, pub, calls } = fakeStore({ description: "가".repeat(4000) });
    const yt = fakeYouTube([]);
    const r = await runOnce(deps(store, yt.fetchFn).deps);
    expect(r).toMatchObject({ status: "invalidated", code: "description_too_long" });
    expect(pub.error).toBe("confirm:description_too_long");
    expect(calls.begin).toBe(0);
    expect(yt.fetchFn).not.toHaveBeenCalled();
    expect(copyLimitError({ title: "가".repeat(100), description: "가".repeat(1666), hashtags: ["수납"] })).toBeNull();
    expect(copyLimitError({ title: "가".repeat(101), description: "", hashtags: [] })).toBe("title_too_long");
    expect(youtubeTagsLength(["a b", "cc"])).toBe(8);
  });

  it("RT001(보관 정리 경합)로 기록이 취소되면 deferred: 횟수 미차감, 다음 시도는 상태 조회로 완료 확인(재업로드 0)", async () => {
    const { store, pub } = fakeStore({ finishBusy: 1 });
    const yt = fakeYouTube([initOk, done("rtVideo0001"), done("rtVideo0001")]);
    const d = deps(store, yt.fetchFn);
    await runOnce(d.deps);
    expect(pub).toMatchObject({ status: "retry_wait", retryCount: 0, error: "deferred:RT001", videoId: null });
    await runOnce(d.deps);
    expect(pub).toMatchObject({ status: "uploaded", videoId: "rtVideo0001" });
    expect(yt.inserts()).toBe(1);
    expect(yt.puts()).toBe(1);
    expect(yt.statusQueries()).toBe(1);
  });
});
