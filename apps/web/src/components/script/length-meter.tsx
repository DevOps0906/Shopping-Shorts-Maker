import { type MeterState, formatSec, meterState } from "@/lib/llm/script-metrics";
import { cn } from "@/lib/utils";

/** 예상 길이 미터 — 전체 예상 길이를 목표(15·20초)와 비교한다(docs/planning.md 3장 03) */
const LABEL: Record<MeterState, string> = { empty: "문장 없음", short: "짧음", fit: "적정", long: "김" };
const FILL: Record<MeterState, string> = {
  empty: "bg-line",
  short: "bg-warning-fg",
  fit: "bg-accent",
  long: "bg-danger-fg",
};

export function LengthMeter({ tenths, targetSec }: { tenths: number; targetSec: number }) {
  const state = meterState(tenths, targetSec);
  const percent = Math.min(100, Math.round((tenths / (targetSec * 10)) * 100));
  return (
    <div className="flex flex-col gap-1">
      <div className="flex items-center justify-between text-xs">
        <span className="font-semibold">
          예상 {formatSec(tenths)} / 목표 {targetSec}초
        </span>
        <span className={cn(state === "long" ? "text-danger-fg" : state === "fit" ? "text-accent" : "text-muted")}>
          {LABEL[state]}
        </span>
      </div>
      <div
        role="meter"
        aria-label="예상 길이"
        aria-valuemin={0}
        aria-valuemax={targetSec}
        aria-valuenow={tenths / 10}
        className="h-2 overflow-hidden rounded-pill bg-sub-hover"
      >
        <div className={cn("h-full rounded-pill", FILL[state])} style={{ width: `${percent}%` }} />
      </div>
    </div>
  );
}
