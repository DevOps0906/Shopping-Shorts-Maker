import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

/* POST /api/internal/metrics(task-025): 키가 틀리면 401, 맞으면 즉시 202 + 수집은 after() 로 */

const after = vi.fn();
const collectMetrics = vi.fn();
vi.mock("next/server", async (orig) => ({ ...(await orig<typeof import("next/server")>()), after }));
vi.mock("@/server/analytics/collect", () => ({ collectMetrics }));

const { POST } = await import("./route");

const KEY = "internal-test-key-0123456789abcdef";
const post = (headers: Record<string, string> = {}) =>
  POST(new Request("http://app.test/api/internal/metrics", { method: "POST", headers }));

beforeEach(() => {
  process.env.INTERNAL_METRICS_KEY = KEY;
  after.mockReset();
  collectMetrics.mockReset();
});
afterEach(() => {
  delete process.env.INTERNAL_METRICS_KEY;
});

describe("POST /api/internal/metrics", () => {
  it.each([
    ["키 없음", {}],
    ["틀린 키", { "x-internal-key": "wrong" }],
    ["길이만 같은 키", { "x-internal-key": KEY.replace(/.$/, "X") }],
  ])("%s → 401, 수집하지 않음", async (_label, headers) => {
    const res = await post(headers);
    expect(res.status).toBe(401);
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(after).not.toHaveBeenCalled();
  });

  it("서버 키가 비어 있으면 어떤 값도 401", async () => {
    process.env.INTERNAL_METRICS_KEY = "";
    expect((await post({ "x-internal-key": "" })).status).toBe(401);
    expect((await post({ "x-internal-key": "anything" })).status).toBe(401);
  });

  it("서버 키가 32자 미만이면 맞는 값도 401, 설정 오류는 키 없이 로그 1줄", async () => {
    const short = "short-key-0123456789";
    process.env.INTERNAL_METRICS_KEY = short;
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    expect((await post({ "x-internal-key": short })).status).toBe(401);
    expect(log).toHaveBeenCalledTimes(1);
    expect(JSON.stringify(log.mock.calls)).not.toContain(short);
    expect(after).not.toHaveBeenCalled();
    log.mockRestore();
  });

  it("맞는 키 → 202, 수집은 응답 뒤(after)", async () => {
    const res = await post({ "x-internal-key": KEY });
    expect(res.status).toBe(202);
    expect(after).toHaveBeenCalledTimes(1);
    expect(collectMetrics).not.toHaveBeenCalled();
    collectMetrics.mockRejectedValue(new Error("boom-SECRET"));
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    await expect(after.mock.calls[0][0]()).resolves.toBeUndefined();
    expect(JSON.stringify(log.mock.calls)).not.toContain("SECRET");
    log.mockRestore();
    expect(collectMetrics).toHaveBeenCalledTimes(1);
  });
});
