"use client";

import { useEffect, useMemo, useState, useTransition } from "react";
import { pollRenderAction, startRenderAction } from "@/app/(dashboard)/studio/[projectId]/[step]/edit/actions";
import { InlineBanner, useFeedback } from "@/components/feedback";
import { btnClass, btnPrimaryClass } from "@/components/studio/step-actions";
import { useStudioStep } from "@/components/studio/studio-step-view";
import { useElapsed } from "@/components/topic/use-elapsed";
import {
  RENDER_COST_LINE,
  RENDER_TIME_LIMIT_SEC,
  creditsText,
  failedCutNumbers,
  nextCandidate,
  planCuts,
  reconcileAssignment,
} from "@/lib/edit/plan";
import { cn } from "@/lib/utils";
import type { EditStepData } from "@/server/edit/edit";
import { CutTimeline, cutMark } from "./cut-timeline";
import { RenderVersions } from "./render-versions";

/*
 * S-10 05 편집 본문 — docs/planning.md 3장 05 · 17-6, docs/ui-feedback.md 2장 #4(같은 화면 실패: 배너 오류 + 다시 시도).
 * 상태: 빈(대기 · MP4 만들기 버튼) · 로딩(자막과 음성 합치는 중 · 경과 초) · 오류(실패한 컷 번호 · 다음 순위 원본 교체·재시도)
 * · 성공(검토본 V1 · 승인 시 06 발행 열림). 렌더는 render 작업(워커)으로 돌고, 화면은 2초마다 작업 상태를 확인한다.
 * 스케일업·자막/워터마크 제거는 3단계 유료 후보라 비활성 표시만 한다(워터마크 제거는 권리 확인 원본만, 출처 표기 원본 금지 — D7).
 */

const ACTIVE = new Set(["queued", "running"]);
const POLL_MS = 2000;
const FAILED_PREFIX = "MP4 만들기에 실패했습니다.";

export function EditPanel({ targetSec, lines, take, candidates, renders: initialRenders, job: initialJob, lastError }: EditStepData) {
  const { projectId, status, setStatus } = useStudioStep();
  const feedback = useFeedback();
  const [renders, setRenders] = useState(initialRenders);
  const [job, setJob] = useState(initialJob);
  const [error, setError] = useState<string | null>(lastError ? `${FAILED_PREFIX} ${lastError}` : null);
  const [assignment, setAssignment] = useState(() =>
    reconcileAssignment(lines.length, candidates, initialRenders[0]?.cuts.map((c) => c.sourceId) ?? null),
  );
  const [starting, startTransition] = useTransition();

  const running = job !== null && ACTIVE.has(job.status);
  const elapsed = useElapsed(running);
  const ready = status[4] === "approved";
  const locked = status[5] === "approved";
  const busy = running || starting;
  const failed = failedCutNumbers(error);

  const plan = useMemo(
    () => (take ? planCuts(lines, take.sentences, take.durationSec, targetSec, assignment, candidates) : null),
    [lines, take, targetSec, assignment, candidates],
  );
  const usesAttribution = plan?.ok
    ? plan.cuts.some((c) => candidates.find((s) => s.id === c.sourceId)?.rightsBasis === "attribution_notice")
    : false;

  // 작업 상태 확인(2초마다). 성공·실패면 멈춘다
  const jobId = running ? job.id : null;
  useEffect(() => {
    if (!jobId) return;
    let active = true;
    const timer = setInterval(async () => {
      const result = await pollRenderAction(projectId, jobId);
      if (!active || !result.ok) return; // 확인 실패는 다음 주기에 다시
      const next = result.job;
      if (next.status === "succeeded") {
        setJob(null);
        const made = result.render;
        if (made) setRenders((prev) => [made, ...prev.filter((r) => r.id !== made.id)]);
        if (result.status) setStatus(result.status);
        feedback.toast({ message: made ? `검토본 V${made.version}을 만들었습니다` : "MP4를 만들었습니다", tone: "success" });
      } else if (!ACTIVE.has(next.status)) {
        setJob(null);
        setError(`${FAILED_PREFIX} ${next.error ?? "잠시 뒤 다시 시도해 주세요."}`);
      } else {
        setJob(next);
      }
    }, POLL_MS);
    return () => {
      active = false;
      clearInterval(timer);
    };
  }, [jobId, projectId, setStatus, feedback]);

  function render() {
    setError(null);
    const key = crypto.randomUUID();
    const cuts = assignment;
    startTransition(async () => {
      const result = await startRenderAction(projectId, cuts, key);
      if (!result.ok) {
        setError(result.error);
        return;
      }
      setJob({ id: result.jobId, status: "queued", error: null, startedAt: null });
    });
  }

  function replace(no: number) {
    const next = nextCandidate(candidates, assignment[no - 1]);
    if (!next) return;
    setAssignment((prev) => prev.map((id, i) => (i === no - 1 ? next.id : id)));
    if (failed.includes(no)) setError(null);
    feedback.toast({ message: `컷 ${no}번을 ${next.rank}순위 원본으로 바꿨습니다`, tone: "success" });
  }

  const canRender = ready && !locked && !busy && take !== null && plan?.ok === true;

  return (
    <div className="flex flex-col gap-4">
      <section aria-label="컷 타임라인과 대사·장면 연결표" className="flex flex-col gap-3 rounded-card border border-line bg-white p-4 shadow-card tablet:p-6">
        <div className="flex flex-wrap items-baseline justify-between gap-2">
          <p className="text-sm font-semibold">대사와 장면 연결표</p>
          <p className="text-xs text-muted">
            목표 {targetSec}초 · 9:16(1080×1920) 크롭 · 편집 입력 원본 {candidates.length}편
          </p>
        </div>
        {!ready ? <p className="text-sm text-muted">04 목소리를 승인하면 컷을 맞출 수 있습니다.</p> : null}
        {ready && !take ? <p className="text-sm text-muted">04 목소리의 음성이 없습니다. 음성을 만든 뒤 다시 와 주세요.</p> : null}
        {ready && candidates.length === 0 ? (
          <InlineBanner tone="warning">
            편집에 쓸 수 있는 원본이 없습니다. 02 소스에서 사용할 원본의 권리 근거를 확인하고, 출처 표기 원본은 고지 확인을 체크해 주세요. 권리 미확인·격리된
            원본은 편집에 쓰지 않습니다.
          </InlineBanner>
        ) : null}
        {plan && !plan.ok && candidates.length > 0 ? <InlineBanner tone="error">{plan.error}</InlineBanner> : null}
        {plan?.ok ? (
          <CutTimeline
            cuts={plan.cuts}
            candidates={candidates}
            failed={failed}
            canReplace={!locked && !busy && candidates.length > 1}
            onReplace={replace}
          />
        ) : null}
        {plan?.ok && candidates.length === 1 ? <p className="text-xs text-muted">원본이 1편뿐이라 컷을 교체할 수 없습니다.</p> : null}
      </section>

      <section aria-label="영상 다듬기" className="flex flex-col gap-3 rounded-card border border-line bg-white p-4 shadow-card tablet:p-6">
        <p className="text-sm font-semibold">영상 다듬기</p>
        <p className="text-sm">모든 컷을 여백 없는 9:16으로 맞춥니다(비율 유지 확대·가운데 크롭). 원본이 컷보다 짧으면 마지막 장면을 멈춰 채웁니다.</p>
        <div className="flex flex-wrap items-center gap-2">
          <button type="button" disabled aria-describedby="edit-upscale-note" className={cn(btnClass, "opacity-60")}>
            스케일업
          </button>
          <button type="button" disabled aria-describedby="edit-clean-note" className={cn(btnClass, "opacity-60")}>
            자막 및 워터마크 제거
          </button>
        </div>
        <ul className="flex list-disc flex-col gap-1 pl-5 text-xs text-muted">
          <li id="edit-upscale-note">스케일업: 준비 중(유료 기능 후보). 지금은 기본 화질로 만듭니다.</li>
          <li id="edit-clean-note">
            자막 및 워터마크 제거: 준비 중. 권리를 확인한 원본(직접 촬영·판매자 제공·이용 허락)에만 쓸 수 있고, 출처 표기 원본에는 쓸 수 없습니다.
            {usesAttribution ? " 지금 컷에 출처 표기 원본이 있습니다." : null}
          </li>
          <li>출처 표기: 쓰인 원본의 @작성자를 영상 오른쪽 아래에 작은 글씨로 계속 넣습니다.</li>
        </ul>
        {plan?.ok && creditsText(plan.cuts) ? (
          <p className="text-xs">
            <span className="font-semibold">설명란 출처 문구</span> <span className="text-muted">{creditsText(plan.cuts)}</span>
          </p>
        ) : null}
      </section>

      <section aria-label="MP4 만들기" className="flex flex-col gap-3 rounded-card border border-line bg-white p-4 shadow-card tablet:p-6">
        <div className="flex flex-wrap items-center gap-2">
          <button type="button" onClick={render} disabled={!canRender} className={cn(btnClass, btnPrimaryClass)}>
            {running ? `자막과 음성 합치는 중… ${elapsed}초` : starting ? "시작하는 중…" : "좋은 컷을 골라 MP4 만들기"}
          </button>
          <span className="text-xs text-muted">최대 {RENDER_TIME_LIMIT_SEC / 60}분</span>
        </div>
        <p className="text-xs text-muted">컷 선택 → 음성 합치기 → 한 줄 자막 → MP4 저장 · {RENDER_COST_LINE}</p>
        {error ? (
          <InlineBanner
            tone="error"
            action={
              !locked && take ? (
                <button type="button" onClick={render} disabled={busy || plan?.ok !== true} className={btnClass}>
                  다시 시도
                </button>
              ) : undefined
            }
          >
            {error}
            {failed.length > 0 ? ` 실패한 컷: ${failed.map(cutMark).join(" ")} — 표에서 "다음 순위로 교체"를 누른 뒤 다시 시도하세요.` : null}
            {error.startsWith(FAILED_PREFIX) ? " 실패한 작업의 크레딧은 돌려드립니다." : null}
          </InlineBanner>
        ) : null}
      </section>

      <RenderVersions renders={renders} />
    </div>
  );
}

