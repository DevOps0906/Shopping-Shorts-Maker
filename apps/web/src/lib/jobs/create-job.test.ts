import { describe, expect, it, vi } from "vitest";
import { createJob } from "./create-job";

const input = { projectId: "p1", type: "render" as const, idempotencyKey: "render-p1-0001" };

function client(result: { data: unknown; error: { code?: string; message: string; details?: string | null } | null }) {
  return { rpc: vi.fn().mockResolvedValue(result) };
}

describe("createJob", () => {
  it("create_job 을 멱등 키·빈 payload 와 함께 부르고 작업을 돌려준다", async () => {
    const supabase = client({
      data: { id: "j1", project_id: "p1", step: 5, type: "render", status: "queued", created: false },
      error: null,
    });
    const result = await createJob(supabase, input);
    expect(supabase.rpc).toHaveBeenCalledWith("create_job", {
      p_project_id: "p1",
      p_type: "render",
      p_idempotency_key: "render-p1-0001",
      p_payload: {},
    });
    expect(result).toEqual({
      ok: true,
      job: { id: "j1", projectId: "p1", step: 5, type: "render", status: "queued", created: false },
    });
  });

  it("잔액 부족(CR001)이면 필요·잔액 크레딧을 돌려준다", async () => {
    const supabase = client({
      data: null,
      error: { code: "CR001", message: "크레딧이 부족합니다", details: '{"required": 30, "balance": 4}' },
    });
    expect(await createJob(supabase, input)).toEqual({
      ok: false,
      code: "insufficient_credits",
      required: 30,
      balance: 4,
    });
  });

  it("단계 위반(55000)은 step_not_ready, 키 충돌(JK001)은 conflict", async () => {
    expect(await createJob(client({ data: null, error: { code: "55000", message: "앞 단계" } }), input)).toMatchObject({
      ok: false,
      code: "step_not_ready",
    });
    expect(await createJob(client({ data: null, error: { code: "JK001", message: "키" } }), input)).toMatchObject({
      ok: false,
      code: "conflict",
    });
  });

  it("권한 오류는 forbidden, 그 밖의 오류는 내부 메시지를 숨긴다", async () => {
    expect(await createJob(client({ data: null, error: { code: "42501", message: "권한 없음" } }), input)).toMatchObject({
      ok: false,
      code: "forbidden",
    });
    const other = await createJob(client({ data: null, error: { code: "XX000", message: "internal detail" } }), input);
    expect(other).toMatchObject({ ok: false, code: "error" });
    expect(JSON.stringify(other)).not.toContain("internal detail");
  });
});
