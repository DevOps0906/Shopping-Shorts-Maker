import { NextRequest } from "next/server";
import { beforeEach, describe, expect, it, vi } from "vitest";

const getClaims = vi.fn();

vi.mock("@supabase/ssr", () => ({
  createServerClient: () => ({ auth: { getClaims } }),
}));

const { updateSession } = await import("./proxy");
const { safeNextPath } = await import("./paths");

function signedOut() {
  getClaims.mockResolvedValue({ data: null, error: null });
}
function signedIn() {
  getClaims.mockResolvedValue({ data: { claims: { sub: "user-1" } }, error: null });
}
const request = (url: string) => new NextRequest(new URL(url, "http://localhost:3000"));

beforeEach(() => {
  process.env.NEXT_PUBLIC_SUPABASE_URL = "http://localhost:8000";
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY = "test-anon-key";
  getClaims.mockReset();
});

describe("updateSession — 비로그인", () => {
  it.each(["/", "/projects", "/studio/p1/topic", "/settings/profile"])(
    "%s 는 /login 으로 리다이렉트하고 돌아올 경로를 남긴다",
    async (path) => {
      signedOut();
      const res = await updateSession(request(path));
      expect(res.status).toBe(307);
      const location = new URL(res.headers.get("location")!);
      expect(location.pathname).toBe("/login");
      expect(location.searchParams.get("next")).toBe(path);
    },
  );

  it("쿼리 문자열도 next 에 보존한다", async () => {
    signedOut();
    const res = await updateSession(request("/projects?status=done"));
    expect(new URL(res.headers.get("location")!).searchParams.get("next")).toBe(
      "/projects?status=done",
    );
  });

  it("/login 은 그대로 연다", async () => {
    signedOut();
    const res = await updateSession(request("/login"));
    expect(res.headers.get("location")).toBeNull();
  });

  it("세션 확인 오류는 비로그인으로 처리한다", async () => {
    getClaims.mockResolvedValue({ data: null, error: new Error("network") });
    const res = await updateSession(request("/new"));
    expect(new URL(res.headers.get("location")!).pathname).toBe("/login");
  });
});

describe("updateSession — 로그인", () => {
  it("대시보드는 통과시킨다", async () => {
    signedIn();
    const res = await updateSession(request("/projects"));
    expect(res.headers.get("location")).toBeNull();
  });

  it("/login 에 오면 next(안전한 경로)로 보낸다", async () => {
    signedIn();
    const res = await updateSession(request("/login?next=%2Ftrends"));
    expect(new URL(res.headers.get("location")!).pathname).toBe("/trends");
  });

  it("외부 주소 next 는 홈으로 보낸다", async () => {
    signedIn();
    const res = await updateSession(request("/login?next=%2F%2Fevil.example"));
    const location = new URL(res.headers.get("location")!);
    expect(location.origin).toBe("http://localhost:3000");
    expect(location.pathname).toBe("/");
  });
});

describe("safeNextPath", () => {
  it.each([
    [null, "/"],
    ["", "/"],
    ["https://evil.example", "/"],
    ["//evil.example", "/"],
    ["/\\evil.example", "/"],
    ["/\t//evil.example", "/"],
    ["/\n/evil.example", "/"],
    ["/projects\\..\\x", "/"],
    ["/login", "/"],
    ["/login?next=/x", "/"],
    ["/projects?x=1", "/projects?x=1"],
  ])("%s → %s", (raw, expected) => {
    expect(safeNextPath(raw)).toBe(expected);
  });
});
