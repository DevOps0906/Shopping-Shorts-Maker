"use client";

import { cn } from "@/lib/utils";
import { STUDIO_STEPS } from "@/lib/routes";
import { STEP_PILL, stepBanner } from "@/lib/steps/banner";
import type { StepNumber, StepStatusMap } from "@/lib/steps/state";
import { StatusBanner } from "./status-banner";
import { StepActions, btnClass } from "./step-actions";
import { StepStepper } from "./step-stepper";
import { useStepStatus } from "./use-step-status";

/* 단계 제목·설명 — 시각 참고: design/prototype/Main.dc.html TITLES · DESCS */
const STEP_COPY: Record<StepNumber, { title: string; description: string }> = {
  1: { title: "소재 고르기", description: "이번 영상에서 소개할 제품을 정해 주세요." },
  2: { title: "소스 모으기", description: "직접 확인한 원본을 모으고 쓸 장면을 살펴보세요." },
  3: { title: "대본 쓰기", description: "첫 3초부터 마지막 한마디까지 화면과 함께 생각합니다." },
  4: { title: "목소리 다듬기", description: "목소리를 들으며 단어와 쉼을 조정하세요." },
  5: { title: "편집하기", description: "원본 컷을 대사에 맞춰 이어 붙이고 MP4로 출력합니다." },
  6: { title: "발행하기", description: "제휴 링크를 붙이고 권리·정책 점검을 마친 뒤 채널에 올리거나 예약합니다." },
};

type StudioStepViewProps = {
  projectId: string;
  step: StepNumber;
  initialStatus: StepStatusMap;
  /** 이 단계의 진행 중 작업 시작 시각(jobs.started_at). 서버 렌더 시점 값 */
  runningStartedAt: string | null;
  children?: React.ReactNode;
};

export function StudioStepView({ projectId, step, initialStatus, runningStartedAt, children }: StudioStepViewProps) {
  const { status, setStatus, live, retry } = useStepStatus(projectId, initialStatus);
  const state = status[step];
  const label = STUDIO_STEPS[step - 1].label;
  const copy = STEP_COPY[step];
  // 실시간으로 상태가 바뀌었으면 서버 렌더 시점의 시작 시각은 다른 작업의 것일 수 있다
  const startedAt = state === "running" && initialStatus[step] === "running" ? runningStartedAt : null;

  return (
    <>
      <StepStepper projectId={projectId} current={step} status={status} />
      <StatusBanner key={state} content={stepBanner(state, step, label)} startedAt={startedAt} />
      {live === "offline" ? (
        <div
          role="alert"
          className="flex flex-wrap items-center justify-between gap-2 rounded-btn bg-warning-bg px-3.5 py-2.5 text-sm text-warning-fg"
        >
          <p>실시간 연결이 끊겨 다른 창의 변경이 바로 보이지 않을 수 있습니다.</p>
          <button type="button" onClick={retry} className={btnClass}>
            다시 연결
          </button>
        </div>
      ) : null}

      <div className="mt-1.5 flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="text-xs font-semibold tracking-widest text-muted">STEP 0{step} / 06</p>
          <h2 className="mt-1 mb-1 text-h font-bold">{copy.title}</h2>
          <p className="text-sm text-muted">{copy.description}</p>
        </div>
        <span
          className={cn(
            "shrink-0 rounded-pill px-3 py-1.5 text-xs font-bold whitespace-nowrap",
            state === "approved" ? "bg-success-bg text-success-fg" : "bg-accent-weak text-nav-on-ink",
          )}
        >
          {STEP_PILL[state]}
        </span>
      </div>

      {children}

      <StepActions projectId={projectId} step={step} status={status} onStatusChange={setStatus} />
    </>
  );
}
