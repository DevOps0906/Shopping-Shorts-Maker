import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

/* /l/{코드} 단축 링크(task-025): 등록 제휴 도메인만 302, 나머지는 같은 404, 항상 no-store */

const rpc = vi.fn();
const fallback = vi.fn();
vi.mock("@/server/supabase-admin", () => ({
  createAdminClient: () => ({
    rpc,
    from: () => ({ select: () => ({ eq: () => ({ maybeSingle: fallback }) }) }),
  }),
}));

const { GET } = await import("./route");
const { config } = await import("@/proxy");
const { newShortCode, isShortCode, clientIp, platformFromHost } = await import("@/server/analytics/short-link");

const CODE = "Ab3dEf7h";
const call = (code: string, headers: Record<string, string> = {}) =>
  GET(new Request(`http://app.test/l/${code}`, { headers }), { params: Promise.resolve({ code }) });
const row = (url: string, program = "coupang_partners") => ({ data: [{ url, program }], error: null });

beforeEach(() => {
  rpc.mockReset();
  fallback.mockReset();
  delete process.env.CLIENT_IP_HEADER;
});

describe("/l/{코드}", () => {
  it("정상 코드는 302 + no-store 로 제휴 URL 에 보낸다", async () => {
    rpc.mockResolvedValue(row("https://link.coupang.com/a/abc"));
    const res = await call(CODE, { "x-real-ip": "203.0.113.7", referer: "https://m.youtube.com/watch?v=1" });
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("https://link.coupang.com/a/abc");
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(rpc).toHaveBeenCalledWith("record_link_click", {
      p_code: CODE,
      p_ip: "203.0.113.7",
      p_ref_host: "m.youtube.com",
      p_platform: "youtube",
    });
  });

  it.each([
    ["없는 코드", { data: [], error: null }],
    ["등록되지 않은 도메인", row("https://evil.example.com/a")],
    ["프로그램과 다른 도메인", row("https://www.musinsa.com/x", "coupang_partners")],
    ["naver.me", row("https://naver.me/xYz", "naver_shopping_connect")],
    ["http", row("http://link.coupang.com/a/abc")],
  ])("%s → 404 no-store", async (_label, result) => {
    rpc.mockResolvedValue(result);
    const res = await call(CODE);
    expect(res.status).toBe(404);
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("location")).toBeNull();
  });

  it("형식이 틀린 코드는 DB 를 부르지 않고 404", async () => {
    for (const code of ["abc", "Ab3dEf7hX", "Ab3dEf7O", "../etc/x"]) {
      const res = await call(code);
      expect(res.status).toBe(404);
    }
    expect(rpc).not.toHaveBeenCalled();
  });

  it("클릭 기록이 실패해도 이동은 막지 않는다(직접 조회 후 재검사)", async () => {
    rpc.mockResolvedValue({ data: null, error: { code: "XX000" } });
    fallback.mockResolvedValue({ data: { url: "https://link.coupang.com/a/abc", program: "coupang_partners" }, error: null });
    const res = await call(CODE);
    expect(res.status).toBe(302);
    fallback.mockResolvedValue({ data: { url: "https://naver.me/abc", program: "naver_shopping_connect" }, error: null });
    expect((await call(CODE)).status).toBe(404);
  });

  it("IP 는 CLIENT_IP_HEADER 하나만 읽고 없으면 unknown", () => {
    expect(clientIp(new Headers({ "x-forwarded-for": "1.1.1.1" }))).toBe("unknown");
    expect(clientIp(new Headers({ "x-real-ip": "2.2.2.2" }))).toBe("2.2.2.2");
    process.env.CLIENT_IP_HEADER = "CF-Connecting-IP";
    expect(clientIp(new Headers({ "x-real-ip": "2.2.2.2", "cf-connecting-ip": "3.3.3.3" }))).toBe("3.3.3.3");
    // 덮어쓰기 헤더 전용: 목록(쉼표)이면 프록시가 덮어쓰지 않은 것으로 보고 unknown
    expect(clientIp(new Headers({ "cf-connecting-ip": "6.6.6.6, 3.3.3.3" }))).toBe("unknown");
    delete process.env.CLIENT_IP_HEADER;
    expect(clientIp(new Headers({ "x-real-ip": "1.1.1.1,2.2.2.2" }))).toBe("unknown");
  });

  it("코드는 8자 base56(혼동 문자 제외), referrer 로 플랫폼 구분", () => {
    for (let i = 0; i < 200; i++) {
      const code = newShortCode();
      expect(isShortCode(code)).toBe(true);
      expect(code).not.toMatch(/[01OIlo]/);
    }
    expect(platformFromHost("www.instagram.com")).toBe("instagram");
    expect(platformFromHost("link.inpock.co.kr")).toBe("inpock");
    expect(platformFromHost("litt.ly")).toBe("litly");
    expect(platformFromHost("notyoutube.com")).toBe("other");
    expect(platformFromHost(null)).toBe("other");
  });
});

describe("proxy matcher — 익명 경로 제외", () => {
  const matcher = new RegExp(`^${config.matcher[0]}$`);
  it.each(["/l/Ab3dEf7h", "/l/없는코드", "/api/internal/metrics"])("%s 는 로그인 검사를 건너뛴다", (path) => {
    expect(matcher.test(path)).toBe(false);
  });
  it.each(["/analytics", "/login", "/lists", "/api/oauth/youtube/start", "/", "/channels/xpng", "/l"])("%s 는 로그인 검사를 거친다", (path) => {
    expect(matcher.test(path)).toBe(true);
  });
  it.each(["/logo.png", "/a/b.svg"])("%s(정적 파일 확장자)는 건너뛴다", (path) => {
    expect(matcher.test(path)).toBe(false);
  });
});
