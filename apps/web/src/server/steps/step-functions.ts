import "server-only";
import { createClient } from "@/lib/supabase/server";
import { isProjectId } from "@/lib/steps/project-id";
import { type StepStatusMap, isStepNumber, parseStepStatus } from "@/lib/steps/state";

/*
 * 단계 승인·변경 요청 구현. 사용자 세션으로 DB 함수(public.approve_step · public.request_step_change)를 부르고,
 * 소유자·전이 규칙·이벤트 기록(step_approved · step_change_requested)은 함수가 맡는다.
 * 사용자가 누른 버튼의 서버 액션에서만 부른다(제작 파트너 AI 도구 목록에는 없다, planning.md 17-7).
 */

export type StepActionResult = { ok: true; status: StepStatusMap } | { ok: false; error: string };

/** DB 오류 코드를 화면 문구로 바꾼다. 원문 메시지는 화면·로그에 내보내지 않는다. */
function toMessage(code: string | undefined) {
  switch (code) {
    case "42501":
      return "이 프로젝트를 바꿀 권한이 없습니다. 다시 로그인해 주세요.";
    case "55000":
      return "단계 상태가 이미 바뀌었습니다. 화면의 최신 상태를 확인한 뒤 다시 시도해 주세요.";
    case "22023":
      return "이 단계에서는 할 수 없는 동작입니다.";
    case "BT001":
      return "대본에 금지 표현이 있어 승인할 수 없습니다. 표시된 문장을 고친 뒤 다시 승인해 주세요.";
    default:
      return "요청을 처리하지 못했습니다. 잠시 뒤 다시 시도해 주세요.";
  }
}

export async function callStepFunction(
  fn: "approve_step" | "request_step_change",
  projectId: string,
  step: number,
): Promise<StepActionResult> {
  if (!isProjectId(projectId) || !isStepNumber(step)) {
    return { ok: false, error: "잘못된 요청입니다." };
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc(fn, { p_project_id: projectId, p_step: step });
  if (error) return { ok: false, error: toMessage(error.code) };

  const status = parseStepStatus(data);
  if (!status) return { ok: false, error: toMessage(undefined) };
  return { ok: true, status };
}
