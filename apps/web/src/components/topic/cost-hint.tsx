import { type LlmTask, estimateCallCost } from "@/lib/llm/pricing";

/** 생성 버튼 옆 호출 전 모델별 예상 비용(docs/planning.md 17-2 D9). 정수 원 */
export function CostHint({ task }: { task: LlmTask }) {
  const lines = estimateCallCost(task);
  return (
    <p className="text-xs text-muted">
      호출 1회 예상 비용 · {lines.map((l) => `${l.label} 약 ${l.krw.toLocaleString("ko-KR")}원`).join(" · ")}
    </p>
  );
}
