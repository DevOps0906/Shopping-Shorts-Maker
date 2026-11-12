import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

const { YOUTUBE_SCOPES, TOKEN_URL, REVOKE_URL, CHANNELS_URL } = await import("./google");
const { OAuthStoreError } = await import("./store");
const { startConnect, finishConnect, disconnect, getAccessTokenWith, ReconnectRequiredError, sha256Hex, pkceChallenge } =
  await import("./youtube");
type OAuthStore = import("./store").OAuthStore;

const USER_A = "00000000-0000-4000-8000-00000000000a";
const USER_B = "00000000-0000-4000-8000-00000000000b";
const ACC_A = "00000000-0000-4000-8000-0000000000a1";
const ACC_B = "00000000-0000-4000-8000-0000000000b1";
const CFG = { clientId: "cid", clientSecret: "csecret", redirectUri: "https://app.test/api/oauth/youtube/callback" };
const ALL_SCOPES = [...YOUTUBE_SCOPES];
const NEW_REFRESH = "rt-new-SECRET-1";
const OLD_REFRESH = "rt-old-SECRET-0";
const ACCESS = "at-SECRET-9";

/** DB 함수(20261112270000)와 같은 규칙의 메모리 저장소 */
function fakeStore() {
  const owners: Record<string, string> = { [ACC_A]: USER_A, [ACC_B]: USER_B };
  const states = new Map<string, { userId: string; accountId: string; verifier: string; expires: number; used: boolean }>();
  const accounts: Record<string, { channel: string | null; token: string | null; status: string }> = {
    [ACC_A]: { channel: null, token: null, status: "reconnect_required" },
    [ACC_B]: { channel: null, token: null, status: "reconnect_required" },
  };
  // 토큰 버전(Vault secret id): 새 토큰마다 바뀐다
  const versions: Record<string, string> = {};
  let seq = 0;
  const ver = (id: string) => (versions[id] ??= `ref-${++seq}`);
  const store: OAuthStore = {
    async createState(userId, accountId, stateHash, verifier) {
      if (owners[accountId] !== userId) throw new OAuthStoreError("42501");
      states.set(stateHash, { userId, accountId, verifier, expires: Date.now() + 600_000, used: false });
    },
    async consumeState(userId, stateHash) {
      const s = states.get(stateHash);
      if (!s || s.used) return null;
      s.used = true;
      if (s.expires <= Date.now() || s.userId !== userId) return null;
      return { accountId: s.accountId, codeVerifier: s.verifier };
    },
    async saveConnection({ userId, accountId, channelId, refreshToken, scopes }) {
      if (owners[accountId] !== userId) throw new OAuthStoreError("42501");
      const acc = accounts[accountId];
      if (acc.channel && acc.channel !== channelId) throw new OAuthStoreError("OA001");
      if (!YOUTUBE_SCOPES.every((s) => scopes.includes(s))) throw new OAuthStoreError("OA002");
      if (Object.entries(accounts).some(([id, a]) => id !== accountId && a.channel === channelId)) {
        throw new OAuthStoreError("23505");
      }
      if (refreshToken && refreshToken.trim()) {
        acc.token = refreshToken;
        versions[accountId] = `ref-${++seq}`;
      }
      acc.channel = channelId;
      acc.status = acc.token ? "connected" : "reconnect_required";
      return acc.status;
    },
    async getRefreshToken(accountId, userId) {
      if (userId && owners[accountId] !== userId) throw new OAuthStoreError("42501");
      return accounts[accountId].token;
    },
    async clearToken(accountId, userId) {
      if (userId && owners[accountId] !== userId) throw new OAuthStoreError("42501");
      accounts[accountId].token = null;
      accounts[accountId].status = "reconnect_required";
    },
    async getTokenForUse(userId, accountId) {
      if (owners[accountId] !== userId) throw new OAuthStoreError("42501");
      const t = accounts[accountId].token;
      return t ? { ref: ver(accountId), refreshToken: t } : null;
    },
    async expireToken(accountId, ref) {
      if (!accounts[accountId].token || ver(accountId) !== ref) return false;
      accounts[accountId].token = null;
      accounts[accountId].status = "reconnect_required";
      return true;
    },
  };
  return { store, states, accounts, versions };
}

type GoogleMock = {
  token?: { status: number; body: Record<string, unknown> };
  channelId?: string | null;
  revokeStatus?: number;
};

function mockGoogle(m: GoogleMock) {
  const calls: { url: string; body: string }[] = [];
  const fetchMock = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, body: typeof init?.body === "string" ? init.body : "" });
    if (url === TOKEN_URL) {
      const t = m.token ?? {
        status: 200,
        body: { access_token: ACCESS, refresh_token: NEW_REFRESH, scope: ALL_SCOPES.join(" ") },
      };
      return new Response(JSON.stringify(t.body), { status: t.status });
    }
    if (url === CHANNELS_URL) {
      const items = m.channelId === null ? [] : [{ id: m.channelId ?? "UC-A" }];
      return new Response(JSON.stringify({ items }), { status: 200 });
    }
    if (url === REVOKE_URL) return new Response("{}", { status: m.revokeStatus ?? 200 });
    return new Response("not found", { status: 404 });
  });
  vi.stubGlobal("fetch", fetchMock);
  return calls;
}

/** 시작 → 동의 화면 URL 의 state 를 꺼내 콜백 흉내 */
async function start(store: OAuthStore, userId = USER_A, accountId = ACC_A) {
  const r = await startConnect(store, CFG, userId, accountId);
  if (!r.ok) throw new Error(r.result);
  const url = new URL(r.url);
  return { url, state: url.searchParams.get("state")! };
}

beforeEach(() => {
  vi.unstubAllGlobals();
});
afterEach(() => {
  vi.unstubAllGlobals();
});

describe("시작", () => {
  it("동의 화면: 필수 범위 3개·offline·consent·PKCE S256, force-ssl 없음, verifier·state 원문은 해시만 저장", async () => {
    const { store, states } = fakeStore();
    const { url, state } = await start(store);
    const p = url.searchParams;
    expect(p.get("scope")?.split(" ").sort()).toEqual([...ALL_SCOPES].sort());
    expect(p.get("scope")).not.toContain("force-ssl");
    expect(p.get("access_type")).toBe("offline");
    expect(p.get("prompt")).toBe("consent");
    expect(p.get("code_challenge_method")).toBe("S256");
    const saved = states.get(sha256Hex(state))!;
    expect(saved).toBeDefined();
    expect(states.has(state)).toBe(false);
    expect(p.get("code_challenge")).toBe(pkceChallenge(saved.verifier));
    expect(url.toString()).not.toContain(saved.verifier);
  });

  it("남의 account_id 로 시작하면 거부", async () => {
    const { store, states } = fakeStore();
    const r = await startConnect(store, CFG, USER_A, ACC_B);
    expect(r).toEqual({ ok: false, result: "not_allowed" });
    expect(states.size).toBe(0);
  });

  it("설정이 없으면 config_missing", async () => {
    const { store } = fakeStore();
    expect(await startConnect(store, null, USER_A, ACC_A)).toEqual({ ok: false, result: "config_missing" });
  });
});

describe("콜백", () => {
  it("정상: 연결되고 갱신 토큰만 저장, 결과에 토큰 원문 없음", async () => {
    const { store, accounts } = fakeStore();
    mockGoogle({});
    const { state } = await start(store);
    const r = await finishConnect(store, CFG, USER_A, { code: "c1", state, error: null });
    expect(r).toBe("connected");
    expect(accounts[ACC_A]).toEqual({ channel: "UC-A", token: NEW_REFRESH, status: "connected" });
    expect(JSON.stringify(r)).not.toMatch(/SECRET/);
  });

  it("코드 교환에 서버가 보관한 verifier 를 쓴다", async () => {
    const { store, states } = fakeStore();
    const calls = mockGoogle({});
    const { state } = await start(store);
    const verifier = states.get(sha256Hex(state))!.verifier;
    await finishConnect(store, CFG, USER_A, { code: "c1", state, error: null });
    const tokenCall = calls.find((c) => c.url === TOKEN_URL)!;
    expect(new URLSearchParams(tokenCall.body).get("code_verifier")).toBe(verifier);
  });

  it("state 불일치·재사용·만료·다른 사용자 콜백은 거부, Google 호출 없음", async () => {
    const { store, states, accounts } = fakeStore();
    const calls = mockGoogle({});
    expect(await finishConnect(store, CFG, USER_A, { code: "c", state: "wrong", error: null })).toBe("invalid_state");
    expect(await finishConnect(store, CFG, USER_A, { code: "c", state: null, error: null })).toBe("invalid_state");

    const s1 = await start(store);
    expect(await finishConnect(store, CFG, USER_B, { code: "c", state: s1.state, error: null })).toBe("invalid_state");
    // 다른 사용자가 건드린 state 는 소모되어 본인도 못 쓴다
    expect(await finishConnect(store, CFG, USER_A, { code: "c", state: s1.state, error: null })).toBe("invalid_state");

    const s2 = await start(store);
    states.get(sha256Hex(s2.state))!.expires = Date.now() - 1;
    expect(await finishConnect(store, CFG, USER_A, { code: "c", state: s2.state, error: null })).toBe("invalid_state");

    expect(calls).toHaveLength(0);
    const s3 = await start(store);
    expect(await finishConnect(store, CFG, USER_A, { code: "c", state: s3.state, error: null })).toBe("connected");
    expect(await finishConnect(store, CFG, USER_A, { code: "c", state: s3.state, error: null })).toBe("invalid_state");
    expect(accounts[ACC_A].status).toBe("connected");
  });

  it("필수 범위가 빠지면 미연결(저장 안 함)", async () => {
    const { store, accounts } = fakeStore();
    mockGoogle({
      token: {
        status: 200,
        body: { access_token: ACCESS, refresh_token: NEW_REFRESH, scope: ALL_SCOPES.slice(0, 2).join(" ") },
      },
    });
    const { state } = await start(store);
    expect(await finishConnect(store, CFG, USER_A, { code: "c", state, error: null })).toBe("scope_missing");
    expect(accounts[ACC_A]).toEqual({ channel: null, token: null, status: "reconnect_required" });
  });

  it("다른 채널로 재연결하면 거부하고 기존 토큰 유지", async () => {
    const { store, accounts } = fakeStore();
    accounts[ACC_A] = { channel: "UC-A", token: OLD_REFRESH, status: "connected" };
    mockGoogle({ channelId: "UC-OTHER" });
    const { state } = await start(store);
    expect(await finishConnect(store, CFG, USER_A, { code: "c", state, error: null })).toBe("channel_mismatch");
    expect(accounts[ACC_A]).toEqual({ channel: "UC-A", token: OLD_REFRESH, status: "connected" });
  });

  it("다른 계정에 연결된 채널이면 거부", async () => {
    const { store, accounts } = fakeStore();
    accounts[ACC_B] = { channel: "UC-A", token: "rt-b", status: "connected" };
    mockGoogle({ channelId: "UC-A" });
    const { state } = await start(store);
    expect(await finishConnect(store, CFG, USER_A, { code: "c", state, error: null })).toBe("channel_taken");
    expect(accounts[ACC_A].token).toBeNull();
  });

  it("재연결 응답에 refresh_token 이 비어도 기존 토큰을 덮어쓰지 않는다", async () => {
    const { store, accounts } = fakeStore();
    accounts[ACC_A] = { channel: "UC-A", token: OLD_REFRESH, status: "connected" };
    mockGoogle({ token: { status: 200, body: { access_token: ACCESS, refresh_token: "", scope: ALL_SCOPES.join(" ") } } });
    const { state } = await start(store);
    expect(await finishConnect(store, CFG, USER_A, { code: "c", state, error: null })).toBe("connected");
    expect(accounts[ACC_A].token).toBe(OLD_REFRESH);
  });

  it("사용자가 동의를 취소하면 denied, 채널 없음은 no_channel", async () => {
    const { store } = fakeStore();
    mockGoogle({ channelId: null });
    const s1 = await start(store);
    expect(await finishConnect(store, CFG, USER_A, { code: null, state: s1.state, error: "access_denied" })).toBe("denied");
    const s2 = await start(store);
    expect(await finishConnect(store, CFG, USER_A, { code: "c", state: s2.state, error: null })).toBe("no_channel");
  });
});

describe("access token·해제", () => {
  it("getAccessToken: 매번 갱신 토큰으로 새로 발급(캐시 없음)", async () => {
    const { store, accounts } = fakeStore();
    accounts[ACC_A] = { channel: "UC-A", token: OLD_REFRESH, status: "connected" };
    const calls = mockGoogle({ token: { status: 200, body: { access_token: ACCESS, scope: ALL_SCOPES.join(" ") } } });
    expect(await getAccessTokenWith(store, CFG, USER_A, ACC_A)).toBe(ACCESS);
    expect(await getAccessTokenWith(store, CFG, USER_A, ACC_A)).toBe(ACCESS);
    expect(calls.filter((c) => c.url === TOKEN_URL)).toHaveLength(2);
    expect(new URLSearchParams(calls[0].body).get("grant_type")).toBe("refresh_token");
  });

  it("invalid_grant → reconnect_required, Vault 토큰 삭제", async () => {
    const { store, accounts } = fakeStore();
    accounts[ACC_A] = { channel: "UC-A", token: OLD_REFRESH, status: "connected" };
    mockGoogle({ token: { status: 400, body: { error: "invalid_grant" } } });
    await expect(getAccessTokenWith(store, CFG, USER_A, ACC_A)).rejects.toBeInstanceOf(ReconnectRequiredError);
    expect(accounts[ACC_A]).toEqual({ channel: "UC-A", token: null, status: "reconnect_required" });
  });

  it("getAccessToken: 남의 계정이면 예외, Google 호출 없음", async () => {
    const { store, accounts } = fakeStore();
    accounts[ACC_A] = { channel: "UC-A", token: OLD_REFRESH, status: "connected" };
    const calls = mockGoogle({});
    await expect(getAccessTokenWith(store, CFG, USER_B, ACC_A)).rejects.toBeInstanceOf(OAuthStoreError);
    expect(calls).toHaveLength(0);
  });

  it("늦게 온 invalid_grant 는 그사이 재연결한 새 토큰을 지우지 않는다", async () => {
    const { store, accounts } = fakeStore();
    accounts[ACC_A] = { channel: "UC-A", token: OLD_REFRESH, status: "connected" };
    let release!: () => void;
    let called!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const fetched = new Promise<void>((r) => (called = r));
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        called();
        await gate;
        return new Response(JSON.stringify({ error: "invalid_grant" }), { status: 400 });
      }),
    );
    const pending = getAccessTokenWith(store, CFG, USER_A, ACC_A);
    await fetched;
    // 갱신 응답이 오기 전에 사용자가 재연결(새 버전)
    await store.saveConnection({
      userId: USER_A,
      accountId: ACC_A,
      channelId: "UC-A",
      refreshToken: NEW_REFRESH,
      scopes: ALL_SCOPES,
    });
    release();
    await expect(pending).rejects.toBeInstanceOf(ReconnectRequiredError);
    expect(accounts[ACC_A]).toEqual({ channel: "UC-A", token: NEW_REFRESH, status: "connected" });
  });

  it("오류 메시지에 토큰 원문이 없다", async () => {
    const { store, accounts } = fakeStore();
    accounts[ACC_A] = { channel: "UC-A", token: OLD_REFRESH, status: "connected" };
    mockGoogle({ token: { status: 500, body: { error: "server_error" } } });
    const err = await getAccessTokenWith(store, CFG, USER_A, ACC_A).catch((e: Error) => e);
    expect(String(err)).not.toMatch(/SECRET/);
  });

  it("해제: Google revoke 호출 후 Vault 삭제", async () => {
    const { store, accounts } = fakeStore();
    accounts[ACC_A] = { channel: "UC-A", token: OLD_REFRESH, status: "connected" };
    const calls = mockGoogle({});
    expect(await disconnect(store, USER_A, ACC_A)).toBe("disconnected");
    const revoke = calls.find((c) => c.url === REVOKE_URL)!;
    expect(new URLSearchParams(revoke.body).get("token")).toBe(OLD_REFRESH);
    expect(accounts[ACC_A]).toEqual({ channel: "UC-A", token: null, status: "reconnect_required" });
  });

  it("해제: 이미 무효(400)면 삭제 진행, 폐기 실패(5xx)면 Vault 유지", async () => {
    const a = fakeStore();
    a.accounts[ACC_A] = { channel: "UC-A", token: OLD_REFRESH, status: "connected" };
    mockGoogle({ revokeStatus: 400 });
    expect(await disconnect(a.store, USER_A, ACC_A)).toBe("disconnected");
    expect(a.accounts[ACC_A].token).toBeNull();

    const b = fakeStore();
    b.accounts[ACC_A] = { channel: "UC-A", token: OLD_REFRESH, status: "connected" };
    mockGoogle({ revokeStatus: 503 });
    expect(await disconnect(b.store, USER_A, ACC_A)).toBe("revoke_failed");
    expect(b.accounts[ACC_A].token).toBe(OLD_REFRESH);
  });

  it("해제: 남의 계정은 revoke 없이 거부", async () => {
    const { store, accounts } = fakeStore();
    accounts[ACC_B] = { channel: "UC-B", token: "rt-b", status: "connected" };
    const calls = mockGoogle({});
    expect(await disconnect(store, USER_A, ACC_B)).toBe("not_allowed");
    expect(calls).toHaveLength(0);
    expect(accounts[ACC_B].token).toBe("rt-b");
  });
});
