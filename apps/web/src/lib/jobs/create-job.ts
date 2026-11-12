import type { Database, Json } from "@/types/db";

/**
 * 작업 생성(docs/planning.md 17-5, ADR-0001). Route Handler·서버 액션에서 **사용자 세션 클라이언트**
 * (`@/lib/supabase/server`의 createClient)로 부른다. service_role 로 부르면 auth.uid()가 없어 거부된다.
 * - 같은 idempotencyKey 면 기존 작업을 돌려준다(created: false). 키는 버튼을 누를 때 한 번 만들어 재시도에 그대로 쓴다.
 * - 단계는 DB가 종류로 정한다(collect·select_sources 02 · analyze 03 · tts 04 · render 05). 앞 단계 미승인·이미 승인이면 step_not_ready.
 * - 같은 키를 다른 프로젝트·종류에 쓰면 conflict. 키는 사용자 단위로 유일하다.
 * - 예상 크레딧은 DB(private.job_cost)가 정한다. 잔액이 부족하면 작업을 만들지 않고 필요·잔액을 돌려준다.
 */
type CreateJobArgs = Database["public"]["Functions"]["create_job"]["Args"];

export type JobType = "render" | "tts" | "analyze" | "collect" | "select_sources";
export type JobStatus = "queued" | "waiting_extension" | "running" | "succeeded" | "failed" | "canceled";

export type CreateJobInput = {
  projectId: string;
  type: JobType;
  idempotencyKey: string;
  payload?: Json;
};

export type CreatedJob = {
  id: string;
  projectId: string;
  step: number;
  type: JobType;
  status: JobStatus;
  created: boolean;
};

export type CreateJobResult =
  | { ok: true; job: CreatedJob }
  | { ok: false; code: "insufficient_credits"; required: number; balance: number }
  | { ok: false; code: "forbidden" | "step_not_ready" | "conflict" | "invalid" | "error"; message: string };

type RpcError = { code?: string; message: string; details?: string | null };
type RpcClient = {
  rpc(fn: "create_job", args: CreateJobArgs): PromiseLike<{ data: unknown; error: RpcError | null }>;
};

export async function createJob(supabase: RpcClient, input: CreateJobInput): Promise<CreateJobResult> {
  const { data, error } = await supabase.rpc("create_job", {
    p_project_id: input.projectId,
    p_type: input.type,
    p_idempotency_key: input.idempotencyKey,
    p_payload: input.payload ?? {},
  });

  if (error) {
    if (error.code === "CR001") {
      const detail = parseDetail(error.details);
      return { ok: false, code: "insufficient_credits", required: detail.required, balance: detail.balance };
    }
    if (error.code === "42501") return { ok: false, code: "forbidden", message: error.message };
    if (error.code === "55000") return { ok: false, code: "step_not_ready", message: error.message };
    if (error.code === "JK001") return { ok: false, code: "conflict", message: error.message };
    if (error.code === "22023" || error.code === "23514") return { ok: false, code: "invalid", message: error.message };
    return { ok: false, code: "error", message: "작업을 만들지 못했습니다. 잠시 후 다시 시도해 주세요" };
  }

  const row = data as {
    id: string;
    project_id: string;
    step: number;
    type: JobType;
    status: JobStatus;
    created: boolean;
  };
  return {
    ok: true,
    job: {
      id: row.id,
      projectId: row.project_id,
      step: row.step,
      type: row.type,
      status: row.status,
      created: row.created,
    },
  };
}

function parseDetail(details: string | null | undefined): { required: number; balance: number } {
  try {
    const parsed = JSON.parse(details ?? "{}") as { required?: number; balance?: number };
    return { required: Number(parsed.required ?? 0), balance: Number(parsed.balance ?? 0) };
  } catch {
    return { required: 0, balance: 0 };
  }
}
