import { VoicePanel } from "@/components/voice/voice-panel";
import { loadVoiceStep } from "@/server/voice/voice";

/** S-09 04 목소리 본문 로더(서버). 승인 대본·최신 음성 테이크·진행 중 tts 작업을 사용자 세션으로 읽는다 */
export async function VoiceStep({ projectId }: { projectId: string }) {
  const data = await loadVoiceStep(projectId);
  if (!data) return null;
  return <VoicePanel lines={data.lines} initialTake={data.take} initialJob={data.job} />;
}
