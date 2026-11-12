import { PublishPanel } from "@/components/publish/publish-panel";
import { loadPublishStep } from "@/server/publish/publish";

/** S-11 06 발행 본문 로더(서버). 채널·승인 대본·제휴 링크·발행 준비 행·정책 점검(DB 판정)을 사용자 세션으로 읽는다 */
export async function PublishStep({ projectId }: { projectId: string }) {
  const data = await loadPublishStep(projectId);
  if (!data) return null;
  return <PublishPanel {...data} />;
}
