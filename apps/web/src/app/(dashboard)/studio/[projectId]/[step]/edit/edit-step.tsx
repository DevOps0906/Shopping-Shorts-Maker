import { EditPanel } from "@/components/edit/edit-panel";
import { loadEditStep } from "@/server/edit/edit";

/** S-10 05 편집 본문 로더(서버). 승인 대본·음성·매칭 후보(편집 입력 원본)·버전 목록·render 작업을 사용자 세션으로 읽는다 */
export async function EditStep({ projectId }: { projectId: string }) {
  const data = await loadEditStep(projectId);
  if (!data) return null;
  return <EditPanel {...data} />;
}
