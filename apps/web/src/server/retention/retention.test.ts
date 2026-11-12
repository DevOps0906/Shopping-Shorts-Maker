import { describe, expect, it, vi } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/types/db";
import { isSafeItem, isSafePath, runRetentionOnce, type DueItem } from "./retention";

const U = "00000000-0000-4000-a000-00000000000a";
const P = "00000000-0000-4000-a000-0000000000a1";
const OTHER_P = "00000000-0000-4000-a000-0000000000b1";

function item(kind: string, id: string, bucket: string, path: string, project = P, due = "2026-11-01"): DueItem {
  return { kind, id, bucket, path, user_id: U, project_id: project, due_on: due };
}

const key = (d: DueItem) => `${d.kind}:${d.id}`;
const cmp = (a: DueItem, b: DueItem) =>
  a.due_on.localeCompare(b.due_on) || a.kind.localeCompare(b.kind) || a.id.localeCompare(b.id);

/**
 * DB(rpc)·Storage 목. retention_due 는 아직 표시되지 않은 항목을 (due_on, kind, id) 커서로,
 * retention_reserve 는 extended 에 없는 항목에 토큰을, retention_mark_deleted 는 같은 토큰 항목만 표시한다(실제 DB와 같은 동작).
 */
function mockClient(due: DueItem[], removeImpl?: (bucket: string, paths: string[]) => Promise<{ error: unknown }>) {
  const marked = new Set<string>();
  const tokens = new Map<string, string>();
  const extended = new Set<string>();
  const removeCalls: { bucket: string; paths: string[] }[] = [];
  const markCalls: { p_kind: string; p_ids: string[]; p_token: string }[] = [];
  const dueCalls: Record<string, unknown>[] = [];
  let markError: { message: string } | null = null;
  let seq = 0;
  const client = {
    rpc: vi.fn(async (fn: string, args: Record<string, unknown>) => {
      if (fn === "retention_due") {
        dueCalls.push(args);
        const after = args.p_after_due
          ? ({ due_on: args.p_after_due, kind: args.p_after_kind, id: args.p_after_id } as DueItem)
          : null;
        const rows = due
          .filter((d) => !marked.has(key(d)) && (!after || cmp(d, after) > 0))
          .sort(cmp)
          .slice(0, args.p_limit as number);
        return { data: rows, error: null };
      }
      if (fn === "retention_reserve") {
        const a = args as { p_kind: string; p_ids: string[] };
        const token = `tok-${(seq += 1)}`;
        const rows = due
          .filter((d) => d.kind === a.p_kind && a.p_ids.includes(d.id) && !marked.has(key(d)) && !extended.has(key(d)))
          .map((d) => {
            tokens.set(key(d), token);
            return { id: d.id, path: d.path, user_id: d.user_id, project_id: d.project_id, token };
          });
        return { data: rows, error: null };
      }
      if (fn === "retention_mark_deleted") {
        const a = args as { p_kind: string; p_ids: string[]; p_token: string };
        markCalls.push(a);
        if (markError) return { data: null, error: markError };
        let n = 0;
        for (const id of a.p_ids) {
          const k = `${a.p_kind}:${id}`;
          if (tokens.get(k) === a.p_token && !marked.has(k)) {
            marked.add(k);
            n += 1;
          }
        }
        return { data: n, error: null };
      }
      throw new Error(`unexpected rpc ${fn}`);
    }),
    storage: {
      from: (bucket: string) => ({
        remove: async (paths: string[]) => {
          removeCalls.push({ bucket, paths });
          return removeImpl ? removeImpl(bucket, paths) : { data: [], error: null };
        },
      }),
    },
  };
  return {
    client: client as unknown as SupabaseClient<Database>,
    removeCalls,
    markCalls,
    dueCalls,
    marked,
    tokens,
    extended,
    failMark: () => {
      markError = { message: "db down" };
    },
  };
}

const quiet = { sleep: async () => {}, log: () => {} };

describe("isSafePath·isSafeItem", () => {
  it("이 프로젝트 폴더 안의 평범한 파일 이름과 종류에 맞는 버킷만 허용", () => {
    expect(isSafeItem(item("source", "s1", "sources", `${U}/${P}/a.mp4`))).toBe(true);
    expect(isSafeItem(item("source", "s1", "renders", `${U}/${P}/a.mp4`))).toBe(false);
    expect(isSafeItem(item("source", "s1", "sources", `${U}/${OTHER_P}/a.mp4`))).toBe(false);
    expect(isSafeItem(item("project", "s1", "sources", `${U}/${P}/a.mp4`))).toBe(false);
  });

  it("상위 이동·인코딩·역슬래시·이중 슬래시·빈 이름 거부", () => {
    for (const rest of [
      "../x/a.mp4",
      "./a.mp4",
      "",
      "%2e%2e/a.mp4",
      "%2E%2E%2Fa.mp4",
      "a%2fb.mp4",
      "..\\..\\a.mp4",
      "a\\b.mp4",
      "a//b.mp4",
      "/a.mp4",
      "a.mp4/",
      "a b.mp4",
      "a.mp4\u0000",
      "..",
    ]) {
      expect(isSafePath(`${U}/${P}/${rest}`, U, P), rest).toBe(false);
    }
    expect(isSafePath(`${U}/${P}/render-1.v2_final.mp4`, U, P)).toBe(true);
    expect(isSafePath(`${U}//${P}/a.mp4`, U, P)).toBe(false);
  });
});

describe("runRetentionOnce", () => {
  it("예약 → 버킷별 삭제 → 같은 토큰으로 표시", async () => {
    const due = [
      item("source", "s1", "sources", `${U}/${P}/s1.mp4`),
      item("thumbnail", "s1", "thumbnails", `${U}/${P}/s1.jpg`),
      item("voice", "v1", "voices", `${U}/${P}/v1.wav`),
      item("render", "r1", "renders", `${U}/${P}/r1.mp4`),
    ];
    const m = mockClient(due);
    const result = await runRetentionOnce(m.client, quiet);
    expect(result).toEqual({ deleted: 4, failed: 0, skipped: 0, markFailed: 0 });
    expect(m.removeCalls.map((c) => c.bucket).sort()).toEqual(["renders", "sources", "thumbnails", "voices"]);
    for (const c of m.markCalls) expect(c.p_token).toBe(m.tokens.get(`${c.p_kind}:${c.p_ids[0]}`));
  });

  it("목록 뒤 발행 등으로 예약에서 빠진 항목은 지우지 않는다", async () => {
    const m = mockClient([
      item("render", "r1", "renders", `${U}/${P}/r1.mp4`),
      item("render", "r2", "renders", `${U}/${P}/r2.mp4`),
    ]);
    m.extended.add("render:r1");
    const result = await runRetentionOnce(m.client, quiet);
    expect(result).toEqual({ deleted: 1, failed: 0, skipped: 1, markFailed: 0 });
    expect(m.removeCalls).toEqual([{ bucket: "renders", paths: [`${U}/${P}/r2.mp4`] }]);
  });

  it("남의 프로젝트 경로·버킷 불일치는 예약·삭제·표시하지 않는다", async () => {
    const m = mockClient([
      item("source", "s1", "sources", `${U}/${OTHER_P}/s1.mp4`),
      item("render", "r1", "sources", `${U}/${P}/r1.mp4`),
      item("voice", "v1", "voices", `${U}/${P}/%2e%2e/v1.wav`),
      item("voice", "v2", "voices", `${U}/${P}/v2.wav`),
    ]);
    const result = await runRetentionOnce(m.client, quiet);
    expect(result).toEqual({ deleted: 1, failed: 0, skipped: 3, markFailed: 0 });
    expect(m.removeCalls).toEqual([{ bucket: "voices", paths: [`${U}/${P}/v2.wav`] }]);
    expect([...m.marked]).toEqual(["voice:v2"]);
  });

  it("일시 오류는 재시도해 성공하면 표시한다", async () => {
    let calls = 0;
    const sleep = vi.fn(async () => {});
    const m = mockClient([item("source", "s1", "sources", `${U}/${P}/s1.mp4`)], async () => {
      calls += 1;
      if (calls === 1) throw new Error("ECONNRESET");
      if (calls === 2) return { error: { message: "503" } };
      return { error: null };
    });
    const result = await runRetentionOnce(m.client, { ...quiet, sleep });
    expect(calls).toBe(3);
    expect(sleep).toHaveBeenCalledTimes(2);
    expect(result.deleted).toBe(1);
    expect([...m.marked]).toEqual(["source:s1"]);
  });

  it("재시도까지 실패하면 DB에 표시하지 않고 다음 회차에 다시 시도한다", async () => {
    let fail = true;
    const m = mockClient([item("render", "r1", "renders", `${U}/${P}/r1.mp4`)], async () =>
      fail ? { error: { message: "500" } } : { error: null },
    );
    const first = await runRetentionOnce(m.client, quiet);
    expect(first).toEqual({ deleted: 0, failed: 1, skipped: 0, markFailed: 0 });
    expect(m.removeCalls).toHaveLength(3);
    expect(m.markCalls).toHaveLength(0);

    fail = false;
    const second = await runRetentionOnce(m.client, quiet);
    expect(second.deleted).toBe(1);
    expect([...m.marked]).toEqual(["render:r1"]);
  });

  it("표시 실패는 따로 센다(객체는 지워졌고 다음 회차가 다시 예약·표시)", async () => {
    const m = mockClient([item("voice", "v1", "voices", `${U}/${P}/v1.wav`)]);
    m.failMark();
    const result = await runRetentionOnce(m.client, quiet);
    expect(result).toEqual({ deleted: 0, failed: 0, skipped: 0, markFailed: 1 });
  });

  it("키셋 커서로 전체를 돌고, 실패 항목이 앞에 있어도 뒤 항목을 처리한다", async () => {
    const due = Array.from({ length: 5 }, (_, i) =>
      item("source", `s${i}`, "sources", `${U}/${P}/s${i}.mp4`, P, `2026-10-0${i + 1}`),
    );
    const m = mockClient(due, async (_bucket, paths) =>
      paths.includes(`${U}/${P}/s0.mp4`) ? { error: { message: "500" } } : { error: null },
    );
    const result = await runRetentionOnce(m.client, { ...quiet, pageSize: 2, maxAttempts: 1 });
    // 첫 페이지(s0·s1)는 한 묶음이라 함께 실패, 이후 페이지는 커서로 이어서 처리
    expect(result).toEqual({ deleted: 3, failed: 2, skipped: 0, markFailed: 0 });
    expect(m.marked.has("source:s0")).toBe(false);
    expect(m.dueCalls[1]).toMatchObject({ p_after_due: "2026-10-02", p_after_kind: "source", p_after_id: "s1" });
  });

  it("대상 조회 오류는 예외로 올린다", async () => {
    const client = {
      rpc: async () => ({ data: null, error: { message: "permission denied" } }),
    } as unknown as SupabaseClient<Database>;
    await expect(runRetentionOnce(client, quiet)).rejects.toThrow("대상 목록 조회 실패");
  });
});
