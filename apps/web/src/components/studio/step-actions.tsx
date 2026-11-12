"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { approveStep, requestStepChange } from "@/app/(dashboard)/studio/actions";
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
  const [confirmReset, setConfirmReset] = useState(false);

  const state = status[step];
  const approvable = step <= LAST_APPROVABLE_STEP;
  const resets = stepsResetByChange(status, step);
  const hint = approvable ? approveHint(status, step) : null;

  function run(action: typeof approveStep) {
    setError(null);
    setConfirmReset(false);
    startTransition(async () => {
      const result = await action(projectId, step);
      if (result.ok) onStatusChange(result.status);
      else setError(result.error);
    });
  }

  function onChangeClick() {
    if (resets.length > 0) setConfirmReset(true);
    else run(requestStepChange);
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

        {confirmReset ? (
          <div role="alertdialog" aria-labelledby="reset-title" className="rounded-btn border border-warning-fg bg-warning-bg p-3.5 text-warning-fg">
            <p id="reset-title" className="text-sm font-bold">
              뒤 단계가 처음으로 돌아갑니다
            </p>
            <p className="mt-1 text-sm">
              {resets.map((n) => `${String(n).padStart(2, "0")} ${STUDIO_STEPS[n - 1].label}`).join(" · ")} 단계의 결과가
              비워지고 대기로 바뀝니다. 진행 중인 작업도 취소됩니다.
            </p>
            <div className="mt-3 flex flex-wrap gap-2">
              <button type="button" onClick={() => run(requestStepChange)} disabled={pending} className={cn(btnClass, btnPrimaryClass)}>
                초기화하고 변경 요청
              </button>
              <button type="button" onClick={() => setConfirmReset(false)} disabled={pending} className={btnClass}>
                취소
              </button>
            </div>
          </div>
        ) : null}

        {error ? (
          <p role="alert" className="rounded-btn bg-danger-bg px-3.5 py-2.5 text-sm text-danger-fg">
            {error}
          </p>
        ) : null}
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
