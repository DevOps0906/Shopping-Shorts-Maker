import { TopicPanel } from "@/components/topic/topic-panel";
import { loadOwnedProject } from "@/server/llm/project-access";
import { selectTopics } from "@/server/llm/topics";

/** S-06 01 소재 본문 로더(서버). 후보·선택 소재를 사용자 세션으로 읽는다 */
export async function TopicStep({ projectId }: { projectId: string }) {
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return null;
  const topics = await selectTopics(supabase, project.id);
  return <TopicPanel initialTopics={topics} categoryName={project.categoryName} />;
}
