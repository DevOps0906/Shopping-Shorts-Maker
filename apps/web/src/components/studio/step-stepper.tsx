import Link from "next/link";
import { cn } from "@/lib/utils";
import { STUDIO_STEPS } from "@/lib/routes";
import { STEP_NUMBERS, type StepNumber, type StepStatusMap, approvedCount } from "@/lib/steps/state";

/*
 * "쇼핑쇼츠 제작단계" 스텝퍼 — docs/design.md 5-6 ②: 완료 수와 진행 바, 단계 번호 원(대기 회색 · 현재 강조 · 승인 ✓)
 * 시각 참고: design/prototype/Main.dc.html .stepper · .tab · .tnum
 */

type StepStepperProps = {
  projectId: string;
  current: StepNumber;
  status: StepStatusMap;
};

function subLabel(state: StepStatusMap[StepNumber], isCurrent: boolean) {
  if (state === "approved") return "승인 완료";
  if (state === "running") return "진행 중";
  return isCurrent ? "작업 중" : "대기";
}

export function StepStepper({ projectId, current, status }: StepStepperProps) {
  const done = approvedCount(status);

  return (
    <section
      aria-labelledby="stepper-title"
      className="rounded-card border border-line bg-white px-3 pt-4 pb-3 shadow-card tablet:px-5.5 tablet:pt-5 tablet:pb-4"
    >
      <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
        <h2 id="stepper-title" className="text-base font-bold">
          쇼핑쇼츠 제작단계
        </h2>
        <p className="text-xs text-muted">
          {done} / 6 단계 완료<span className="hidden tablet:inline"> · 단계를 눌러 각 화면을 볼 수 있어요</span>
        </p>
      </div>
      <div
        role="progressbar"
        aria-label="승인한 단계"
        aria-valuemin={0}
        aria-valuemax={6}
        aria-valuenow={done}
        className="mt-3 mb-4 h-1.5 overflow-hidden rounded-pill bg-count-bg"
      >
        <span
          className="block h-full rounded-pill bg-accent transition-[width] duration-500"
          style={{ width: `${(done / 6) * 100}%` }}
        />
      </div>
      <nav aria-label="제작 단계">
        <ol className="grid grid-cols-6">
          {STEP_NUMBERS.map((n) => {
            const step = STUDIO_STEPS[n - 1];
            const state = status[n];
            const isCurrent = n === current;
            const isDone = state === "approved";
            return (
              <li key={n} className="relative">
                {n > 1 ? (
                  <span
                    aria-hidden="true"
                    className={cn(
                      "absolute top-4 right-1/2 h-0.5 w-full tablet:top-4.5",
                      isDone || isCurrent ? "bg-accent" : "bg-line",
                    )}
                  />
                ) : null}
                <Link
                  href={`/studio/${projectId}/${step.slug}`}
                  aria-current={isCurrent ? "step" : undefined}
                  className={cn(
                    "relative flex min-h-16 flex-col items-center gap-1.5 rounded-btn px-0.5 pt-0.5 pb-1.5 text-center text-step-dot-ink",
                    isDone && "text-success-fg",
                    isCurrent && "text-nav-on-ink",
                  )}
                >
                  <span
                    className={cn(
                      "relative z-10 flex size-8 items-center justify-center rounded-full border-2 border-step-dot-line bg-white text-xs font-bold text-step-dot-ink transition-colors tablet:size-9",
                      isDone && "border-success-line bg-success-bg text-success-fg",
                      isCurrent && "border-accent bg-accent text-white ring-4 ring-accent-weak tablet:ring-6",
                    )}
                  >
                    {isDone ? "✓" : `0${n}`}
                  </span>
                  <span className="text-xs font-semibold tablet:text-sm">{step.label}</span>
                  <span className="hidden text-xs tablet:block">{subLabel(state, isCurrent)}</span>
                </Link>
              </li>
            );
          })}
        </ol>
      </nav>
    </section>
  );
}
