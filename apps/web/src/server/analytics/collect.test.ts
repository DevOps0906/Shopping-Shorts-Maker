import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));
vi.mock("@/server/supabase-admin", () => ({ createAdminClient: () => ({}) }));
vi.mock("@/server/oauth/access-token", () => ({ getAccessToken: vi.fn() }));

/* 성과 수집(task-025): 계정별 토큰 1회, Analytics reports.query(모의 fetch), 최근 3일 범위, 실행 기록 */

const { collectMetrics, collectRange } = await import("./collect");
const { fetchVideoDailyMetrics, ANALYTICS_REPORTS_URL } = await import("@/server/oauth/google");

const NOW = new Date("2026-11-13T12:00:00Z"); // LA 2026-11-13 04:00
const target = (pub: string, acc: string, video: string, publishedAt = "2026-11-01T00:00:00Z") => ({
  publication_id: pub,
  account_id: acc,
  organization_id: `user-${acc}`,
  platform_video_id: video,
  published_at: publishedAt,
});

type Fail = { start?: boolean; targets?: boolean; finish?: number };

function fakeAdmin(targets: unknown[], fail: Fail = {}) {
  const calls: { fn: string; args: unknown }[] = [];
  let finishFails = fail.finish ?? 0;
  const admin = {
    rpc: vi.fn(async (fn: string, args?: unknown) => {
      calls.push({ fn, args });
      if (fn === "metrics_run_start") return fail.start ? { data: null, error: { code: "PGRST202" } } : { data: 7, error: null };
      if (fn === "metrics_targets") return fail.targets ? { data: null, error: { code: "57014" } } : { data: targets, error: null };
      if (fn === "metrics_run_finish" && finishFails-- > 0) return { data: null, error: { code: "08006" } };
      return { data: 1, error: null };
    }),
  };
  return { admin, calls };
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("collectRange", () => {
  it("최근 3일 ~ 오늘(LA), 발행이 더 최근이면 발행일부터", () => {
    expect(collectRange("2026-11-01T00:00:00Z", NOW)).toEqual({ start: "2026-11-10", end: "2026-11-13" });
    expect(collectRange("2026-11-12T20:00:00Z", NOW)).toEqual({ start: "2026-11-12", end: "2026-11-13" });
  });
});

describe("collectMetrics — 실행 기록", () => {
  const deps = (admin: unknown) => ({ admin: admin as never, getToken: vi.fn(), fetchDaily: vi.fn(), now: () => NOW });

  it("시작 기록 실패면 수집하지 않고 코드만 로그", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const { admin, calls } = fakeAdmin([], { start: true });
    expect(await collectMetrics(deps(admin))).toEqual({ ok: 0, skipped: 0, error: "run_start_failed" });
    expect(calls.map((c) => c.fn)).toEqual(["metrics_run_start"]);
    expect(log).toHaveBeenCalledWith("metrics_collect: run_start_failed", "PGRST202");
  });

  it("대상 조회 실패 분기에서도 끝 기록(finished_at)을 남긴다", async () => {
    const { admin, calls } = fakeAdmin([], { targets: true });
    expect(await collectMetrics(deps(admin))).toEqual({ ok: 0, skipped: 0, error: "targets_failed" });
    expect(calls.at(-1)).toEqual({ fn: "metrics_run_finish", args: { p_id: 7, p_ok: 0, p_skipped: 0, p_error: "targets_failed" } });
  });

  it("끝 기록 실패는 1회 다시 시도, 두 번 실패하면 코드만 로그", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const once = fakeAdmin([], { finish: 1 });
    await collectMetrics(deps(once.admin));
    expect(once.calls.filter((c) => c.fn === "metrics_run_finish")).toHaveLength(2);
    expect(log).not.toHaveBeenCalled();
    const twice = fakeAdmin([], { finish: 5 });
    await collectMetrics(deps(twice.admin));
    expect(twice.calls.filter((c) => c.fn === "metrics_run_finish")).toHaveLength(2);
    expect(log).toHaveBeenCalledWith("metrics_collect: run_finish_failed", "08006");
  });
});

describe("collectMetrics", () => {
  it("계정별 토큰 1회, 영상마다 reports.query → save_video_metrics, 실행 기록 끝", async () => {
    const fetchMock = vi.fn(async (input: URL | string) => {
      const url = new URL(String(input));
      expect(`${url.origin}${url.pathname}`).toBe(ANALYTICS_REPORTS_URL);
      expect(url.searchParams.get("ids")).toBe("channel==MINE");
      expect(url.searchParams.get("metrics")).toBe("views,averageViewPercentage");
      expect(url.searchParams.get("dimensions")).toBe("day");
      return Response.json({
        columnHeaders: [{ name: "day" }, { name: "views" }, { name: "averageViewPercentage" }],
        rows: [
          ["2026-11-10", 120, 61.5],
          ["2026-11-11", 80.4, null],
          ["bad", 1, 1],
        ],
      });
    });
    vi.stubGlobal("fetch", fetchMock);
    const getToken = vi.fn(async () => "at-SECRET");
    const { admin, calls } = fakeAdmin([
      target("p1", "a1", "vid_AAAAAAA"),
      target("p2", "a1", "vid_BBBBBBB"),
      target("p3", "a2", "vid_CCCCCCC"),
      target("p4", "a2", "bad id;x"),
    ]);
    const result = await collectMetrics({ admin: admin as never, getToken, fetchDaily: fetchVideoDailyMetrics, now: () => NOW });

    expect(getToken).toHaveBeenCalledTimes(2);
    expect(getToken).toHaveBeenCalledWith("user-a1", "a1");
    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(new URL(String(fetchMock.mock.calls[0][0])).searchParams.get("filters")).toBe("video==vid_AAAAAAA");
    const saves = calls.filter((c) => c.fn === "save_video_metrics");
    expect(saves).toHaveLength(3);
    expect(saves[0].args).toEqual({
      p_publication_id: "p1",
      p_start: "2026-11-10",
      p_end: "2026-11-13",
      p_rows: [
        { date: "2026-11-10", views: 120, avg_view_pct: 61.5 },
        { date: "2026-11-11", views: 80, avg_view_pct: null },
      ],
    });
    expect(result).toEqual({ ok: 3, skipped: 1, error: null });
    expect(calls.at(-1)).toEqual({ fn: "metrics_run_finish", args: { p_id: 7, p_ok: 3, p_skipped: 1, p_error: null } });
    expect(JSON.stringify(calls)).not.toContain("SECRET");
  });

  it("토큰 실패 계정은 건너뛰고, API 오류는 코드만 기록한다", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("{}", { status: 403 })));
    const getToken = vi.fn(async (_u: string, acc: string) => {
      if (acc === "a1") throw Object.assign(new Error("x"), { name: "ReconnectRequiredError" });
      return "at";
    });
    const { admin, calls } = fakeAdmin([target("p1", "a1", "vid_AAAAAAA"), target("p2", "a1", "vid_BBBBBBB"), target("p3", "a2", "vid_CCCCCCC")]);
    const result = await collectMetrics({ admin: admin as never, getToken, fetchDaily: fetchVideoDailyMetrics, now: () => NOW });
    expect(getToken).toHaveBeenCalledTimes(2);
    expect(result).toEqual({ ok: 0, skipped: 3, error: "token:ReconnectRequiredError" });
    expect(calls.some((c) => c.fn === "save_video_metrics")).toBe(false);
    expect(calls.at(-1)?.fn).toBe("metrics_run_finish");
  });
});
