import { SourcePanel } from "@/components/source/source-panel";
import { loadOwnedProject } from "@/server/llm/project-access";
import { loadSourceState } from "@/server/sources/sources";

/** S-07 02 소스 본문 로더(서버). 원본 목록·고지 확인·부족 사유를 사용자 세션으로 읽는다 */
export async function SourceStep({ projectId }: { projectId: string }) {
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return null;
  const state = await loadSourceState(supabase, project.id);
  if (!state) return null;
  return <SourcePanel initialSources={state.sources} initialNoticeAck={state.noticeAck} initialReason={state.reason} />;
}
