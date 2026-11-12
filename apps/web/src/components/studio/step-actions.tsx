"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { approveStep, requestStepChange } from "@/app/(dashboard)/studio/actions";
import { InlineBanner, useFeedback } from "@/components/feedback";
import { cn } from "@/lib/utils";
import { STUDIO_STEPS } from "@/lib/routes";
import {
  LAST_APPROVABLE_STEP,
  type StepNumber,
  type StepStatusMap,
  canApprove,
  canProceed,
  canRequestChange,
  stepsResetByChange,
} from "@/lib/steps/state";

/*
 * 하단 액션 — docs/design.md 5-6 ⑤: 그대로 진행·승인 / 변경 필요 / 다음 단계.
 * 승인·변경은 사용자 클릭만 받는다(AI 도구 경로 없음). 버튼 활성 여부는 DB 함수와 같은 규칙(lib/steps/state).
 */

export const btnClass =
  "inline-flex min-h-11 items-center justify-center gap-1.5 rounded-btn border border-line bg-white px-4 text-sm font-semibold whitespace-nowrap text-ink transition-colors hover:border-accent-line hover:bg-sub-hover disabled:cursor-not-allowed disabled:hover:border-line disabled:hover:bg-white";
export const btnPrimaryClass =
  "border-accent bg-accent text-white hover:border-accent hover:bg-nav-on-ink disabled:border-accent-line disabled:bg-accent-line disabled:text-muted disabled:hover:border-accent-line disabled:hover:bg-accent-line";

type StepActionsProps = {
  projectId: string;
  step: StepNumber;
  status: StepStatusMap;
  onStatusChange: (status: StepStatusMap) => void;
};

const stepName = (n: number) => `${String(n).padStart(2, "0")} ${STUDIO_STEPS[n - 1].label}`;
/** 받침 있으면 "을", 없으면 "를" */
const withObject = (word: string) => word + ((word.charCodeAt(word.length - 1) - 0xac00) % 28 > 0 ? "을" : "를");

function approveHint(status: StepStatusMap, step: StepNumber) {
  if (status[step] === "approved") return null;
  for (let n = 1; n < step; n++) {
    if (status[n as StepNumber] !== "approved") return `${STUDIO_STEPS[n - 1].label} 단계를 먼저 승인해 주세요.`;
  }
  if (status[step] === "ready") return null;
  return "결과가 준비되면 승인할 수 있습니다.";
}

export function StepActions({ projectId, step, status, onStatusChange }: StepActionsProps) {
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const feedback = useFeedback();

  const state = status[step];
  const approvable = step <= LAST_APPROVABLE_STEP;
  const resets = stepsResetByChange(status, step);
  const hint = approvable ? approveHint(status, step) : null;

  function run(action: typeof approveStep) {
    setError(null);
    startTransition(async () => {
      const result = await action(projectId, step);
      if (!result.ok) {
        setError(result.error);
        return;
      }
      onStatusChange(result.status);
      // docs/ui-feedback.md 2장 #1: 승인 완료 토스트(4초)
      if (action === approveStep) feedback.toast({ message: `${withObject(stepName(step))} 승인했습니다`, tone: "success" });
    });
  }

  async function onChangeClick() {
    // docs/ui-feedback.md 2장 #2: 뒤 단계 초기화는 알림 대화상자(첫 포커스 취소)
    if (resets.length > 0) {
      const range = resets.length > 1 ? `${stepName(resets[0])}~${stepName(resets[resets.length - 1])}` : stepName(resets[0]);
      const ok = await feedback.confirm({
        title: `${withObject(stepName(step))} 다시 열까요?`,
        description: `${range} 결과가 초기화됩니다. 진행 중인 작업도 취소됩니다.`,
        confirmLabel: "다시 열기",
        danger: true,
      });
      if (!ok) return;
    }
    run(requestStepChange);
  }

  const nextStep = step < STUDIO_STEPS.length ? STUDIO_STEPS[step as Exclude<StepNumber, 6>] : null;
  const nextHref = nextStep ? `/studio/${projectId}/${nextStep.slug}` : "/analytics";
  const nextLabel = nextStep ? "다음 단계 →" : "성과 분석 보기 →";
  const proceed = canProceed(status, step);
  const footNote = !approvable
    ? "정책 점검 6개를 모두 통과하면 발행할 수 있습니다."
    : proceed
      ? "확인한 기준으로 다음 단계에 갑니다."
      : "이 단계를 승인해야 다음 단계가 열립니다.";

  return (
    <>
      <section aria-label="단계 승인" className="flex flex-col gap-3 rounded-card border border-line bg-white p-4 shadow-card tablet:p-5">
        <div className="flex flex-wrap gap-2">
          {approvable ? (
            <button
              type="button"
              onClick={() => run(approveStep)}
              disabled={pending || !canApprove(status, step)}
              className={cn(
                btnClass,
                state === "approved"
                  ? "disabled:border-success-line disabled:bg-success-bg disabled:text-success-fg disabled:hover:border-success-line disabled:hover:bg-success-bg"
                  : btnPrimaryClass,
              )}
            >
              {state === "approved" ? "✓ 승인됨" : pending ? "처리 중…" : "그대로 진행 · 승인"}
            </button>
          ) : null}
          <button
            type="button"
            onClick={onChangeClick}
            disabled={pending || !canRequestChange(status, step)}
            className={btnClass}
          >
            변경 필요
          </button>
        </div>
        {hint ? <p className="text-xs text-muted">{hint}</p> : null}

        {error ? <InlineBanner tone="error">{error}</InlineBanner> : null}
      </section>

      <div className="flex flex-wrap items-center justify-between gap-3 border-t border-line pt-4">
        <p className="flex-[1_1_15rem] text-xs text-muted">{footNote}</p>
        {proceed ? (
          <Link href={nextHref} className={cn(btnClass, btnPrimaryClass)}>
            {nextLabel}
          </Link>
        ) : (
          <button type="button" disabled className={cn(btnClass, btnPrimaryClass)}>
            {nextLabel}
          </button>
        )}
      </div>
    </>
  );
}
