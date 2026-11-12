import "server-only";
import { reconcileAssignment, nextCandidate } from "@/lib/edit/plan";
import { MAX_COLLECT_ROUNDS } from "@/lib/agent-tools/policy";
import type { ParsedCall } from "@/lib/agent-tools/tools";
import type { ToolOutcome, ToolProject } from "@/lib/agent-tools/turn";
import { voiceLabel } from "@/lib/voice/voices";
import { loadEditStep, startRender } from "@/server/edit/edit";
import { loadOwnedProject } from "@/server/llm/project-access";
import { draftScript } from "@/server/llm/script";
import { suggestTopics } from "@/server/llm/topics";
import { callStepFunction } from "@/server/steps/step-functions";
import { startTts } from "@/server/voice/voice";

/*
 * 도구 6종 실행 — 기존 서버 함수를 그대로 부른다. 각 함수가 사용자 세션으로 소유권(RLS)·단계 상태·크레딧을 다시 검사한다.
 * 승인·발행·권리 확인 함수는 여기서 부르지 않는다. search_topics 의 "다시 열기"(request_step_change)는
 * 사용자가 확인 대화상자에서 "다시 열고 검색"을 누른 요청에서만 실행된다(policy.ts → chat_proposals → turn.ts runProposal).
 */

const NOT_FOUND: ToolOutcome = { ok: false, error: "프로젝트를 찾을 수 없거나 권한이 없습니다." };
const ACTIVE_COLLECT = ["queued", "waiting_extension", "running", "succeeded"];

/** 소유 프로젝트 + 쓴 탐색 회차(실패·취소 작업은 세지 않는다). 없거나 남의 프로젝트면 null */
export async function loadToolProject(projectId: string): Promise<ToolProject | null> {
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return null;
  const { count, error } = await supabase
    .from("jobs")
    .select("id", { count: "exact", head: true })
    .eq("project_id", project.id)
    .eq("type", "collect")
    .in("status", ACTIVE_COLLECT);
  if (error) throw new Error("collect_count_failed");
  return { id: project.id, userId: project.userId, status: project.status, collectRounds: count ?? 0 };
}

const jobKey = (key: string | null) => key ?? `chat-${crypto.randomUUID()}`;

/** 회차 검사와 collect 작업 생성은 DB 함수 chat_start_collect 하나(프로젝트 행 잠금 안)에서 한다 — 병렬 확인으로 3회를 넘지 못한다 */
async function collect(project: ToolProject, platform: string, key: string | null): Promise<ToolOutcome> {
  const { supabase, project: owned } = await loadOwnedProject(project.id);
  if (!owned || !supabase) return NOT_FOUND;
  const { data: topic } = await supabase.from("topics").select("name").eq("project_id", owned.id).eq("picked", true).limit(1).maybeSingle();
  const { error } = await supabase.rpc("chat_start_collect", {
    p_project_id: owned.id,
    p_platform: platform,
    p_query: typeof topic?.name === "string" ? topic.name : owned.name,
    p_idempotency_key: jobKey(key),
  });
  if (!error) {
    const label = platform === "tiktok" ? "TikTok" : "小红书";
    return { ok: true, text: `${label} 원본 수집을 요청했습니다. 브라우저 확장이 열린 탭에서 수집하면 02 소스 목록에 추가됩니다.` };
  }
  switch (error.code) {
    case "CR003":
      return { ok: false, error: `탐색 회차 ${MAX_COLLECT_ROUNDS}회를 모두 썼습니다. 02 소스에서 원본을 직접 추가해 주세요.` };
    case "55000":
      return { ok: false, error: "01 소재를 먼저 승인해 주세요. 이미 승인된 소스는 변경 필요 후 다시 찾을 수 있습니다." };
    case "42501":
      return NOT_FOUND;
    default:
      return { ok: false, error: "수집을 시작하지 못했습니다. 잠시 뒤 다시 시도해 주세요." };
  }
}

async function render(project: ToolProject, cutNo: number | null, key: string | null): Promise<ToolOutcome> {
  const data = await loadEditStep(project.id);
  if (!data) return NOT_FOUND;
  const assignment = reconcileAssignment(data.lines.length, data.candidates, data.renders[0]?.cuts.map((c) => c.sourceId) ?? null);
  if (cutNo !== null) {
    if (cutNo > assignment.length) return { ok: false, error: `${cutNo}번 컷이 없습니다(컷 ${assignment.length}개).` };
    const next = nextCandidate(data.candidates, assignment[cutNo - 1]);
    if (!next) return { ok: false, error: "바꿀 수 있는 다른 원본이 없습니다." };
    assignment[cutNo - 1] = next.id;
  }
  const result = await startRender(project.id, assignment, jobKey(key));
  if (!result.ok) return result;
  return {
    ok: true,
    text: cutNo === null
      ? "MP4 만들기를 시작했습니다. 05 편집에서 새 버전을 확인할 수 있습니다."
      : `${cutNo}번 컷을 다음 순위 원본으로 바꿔 새 버전을 만들기 시작했습니다. 05 편집에서 확인할 수 있습니다.`,
  };
}

/** key: 사용자가 확인을 누를 때 화면이 만든 멱등 키(작업 생성 도구만 쓴다). 없으면 서버가 새로 만든다 */
export async function executeTool(call: ParsedCall, project: ToolProject, key: string | null): Promise<ToolOutcome> {
  switch (call.name) {
    case "search_topics": {
      if (project.status[1] === "approved") {
        const reopened = await callStepFunction("request_step_change", project.id, 1);
        if (!reopened.ok) return reopened;
      }
      const result = await suggestTopics(project.id, call.args.hint);
      if (!result.ok) return result;
      if (result.topics.length === 0) return { ok: true, text: "힌트로 고를 만한 소재를 찾지 못했습니다. 제품명을 조금 더 구체적으로 알려 주세요." };
      const names = result.topics.filter((t) => !t.picked).map((t) => t.name);
      return { ok: true, text: `소재 후보를 찾았습니다: ${names.join(" · ")}. 01 소재에서 하나를 골라 저장해 주세요.` };
    }
    case "search_sources":
      return collect(project, call.args.platform, key);
    case "draft_script": {
      const result = await draftScript(project.id);
      if (!result.ok) return result;
      const warn = result.banned.length > 0 ? ` 금지 표현이 있는 문장 ${result.banned.length}개는 적용 뒤 고쳐 주세요.` : "";
      return { ok: true, text: `대본 초안 ${result.lines.length}문장을 제안합니다. 아래 버튼을 눌러야 작업칸에 적용됩니다.${warn}`, draft: result.lines };
    }
    case "synthesize_voice": {
      const result = await startTts(project.id, call.args.voice_id, jobKey(key));
      if (!result.ok) return result;
      return { ok: true, text: `${voiceLabel(call.args.voice_id)} 목소리로 음성 합성을 시작했습니다. 04 목소리에서 진행 상황을 볼 수 있습니다.` };
    }
    case "replace_cut":
      return render(project, call.args.cut_no, key);
    case "render_mp4":
      return render(project, null, key);
  }
}
