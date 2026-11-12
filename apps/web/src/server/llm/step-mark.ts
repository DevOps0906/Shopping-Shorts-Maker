import "server-only";
import { createClient } from "@/lib/supabase/server";
import { type StepNumber, type StepStatusMap, parseStepStatus } from "@/lib/steps/state";

/*
 * AI 결과가 준비되면 단계 상태를 suggested(제안 도착) 또는 ready(승인 필요)로 바꾼다(docs/planning.md 3장 머리말·6장).
 * step_status 는 사용자 권한으로 직접 바꿀 수 없는 열이라, 사용자 세션으로 DB 함수 mark_step_ready 를 부른다.
 * 함수가 소유자·허용 전이(idle·change·suggested·ready → suggested·ready, approved 불가)·앞 단계 승인을 검사하고
 * 행 잠금(FOR UPDATE)으로 다른 요청과 겹치지 않게 바꾼다. 거부되면 null 을 돌려준다.
 */

export async function markStep(projectId: string, step: StepNumber, to: "suggested" | "ready"): Promise<StepStatusMap | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("mark_step_ready", { p_project_id: projectId, p_step: step, p_status: to });
  if (error) return null;
  return parseStepStatus(data);
}
