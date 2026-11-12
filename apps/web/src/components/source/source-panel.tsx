"use client";

import { useMemo, useRef, useState, useTransition } from "react";
import {
  addDirectSourceAction,
  saveSourceUseAction,
  setDownloadChecksAction,
  startSourceSelectionAction,
} from "@/app/(dashboard)/studio/[projectId]/[step]/source/actions";
import { InlineBanner, useFeedback } from "@/components/feedback";
import { btnClass, btnPrimaryClass } from "@/components/studio/step-actions";
import { useStudioStep } from "@/components/studio/studio-step-view";
import {
  MAX_DOWNLOAD_CHECKS,
  MAX_REASON,
  PLATFORM_LABEL,
  PROBLEM_MESSAGE,
  type RightsBasis,
  type SourcePlatform,
  type SourceView,
  USE_TARGET,
  approvalProblem,
  defaultRightsBasis,
  editInputSources,
  listSources,
  recommendedIds,
  toUseEntries,
} from "@/lib/sources/rules";
import { cn } from "@/lib/utils";
import type { SourceActionResult } from "@/server/sources/sources";
import { AddSourceForm } from "./add-source-form";
import { SourceCard } from "./source-card";
import { SourceNotice } from "./source-notice";

/*
 * S-07 02 소스 본문 — docs/planning.md 3장 02·17-2 D1·D7·D8, design/wireframes/S-07.html.
 * 목록(점수 순 20편, 기본 체크 해제) → 다운로드 체크 10편 → 내려받은 원본에서 권리 근거를 골라 사용 5편.
 * 저장하면 DB가 승인 조건을 다시 계산해 02 상태를 ready(승인 버튼 활성)로 바꾼다. 승인은 아래 StepActions만.
 */

type Filter = "all" | SourcePlatform;
const EDITABLE_STATES = new Set(["idle", "change", "suggested", "ready"]);

type SourcePanelProps = {
  initialSources: SourceView[];
  initialNoticeAck: boolean;
  initialReason: string | null;
};

export function SourcePanel({ initialSources, initialNoticeAck, initialReason }: SourcePanelProps) {
  const { projectId, status, setStatus } = useStudioStep();
  const feedback = useFeedback();
  const [sources, setSources] = useState(initialSources);
  const [noticeAck, setNoticeAck] = useState(initialNoticeAck);
  const [reason, setReason] = useState(initialReason);
  const [reasonDraft, setReasonDraft] = useState(initialReason ?? "");
  // 사용 체크 전 고른 권리 근거(저장 전). 저장된 원본은 rightsBasis 가 정본
  const [pendingBasis, setPendingBasis] = useState<Record<string, RightsBasis | null>>({});
  const [filter, setFilter] = useState<Filter>("all");
  const [adding, setAdding] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const selectKey = useRef<string | null>(null);

  const editable = status[1] === "approved" && EDITABLE_STATES.has(status[2]);
  const listed = useMemo(() => listSources(sources), [sources]);
  const recommended = useMemo(() => recommendedIds(sources), [sources]);
  const shown = filter === "all" ? listed : listed.filter((s) => s.platform === filter);
  const checkedCount = sources.filter((s) => s.checked).length;
  const downloadedCount = sources.filter((s) => s.downloaded).length;
  const usable = editInputSources(sources, noticeAck);
  const usedCount = sources.filter((s) => s.used && !s.quarantined && s.rightsBasis !== null && s.downloaded).length;
  const problem = approvalProblem(sources, noticeAck, reason);
  const quarantinedCount = sources.filter((s) => s.quarantined).length;
  const excludedCount = sources.length - listed.length - quarantinedCount;

  function apply(result: SourceActionResult, success?: string) {
    if (!result.ok) {
      setError(result.error);
      return false;
    }
    setError(null);
    setSources(result.sources);
    setNoticeAck(result.noticeAck);
    setReason(result.reason);
    setStatus(result.status);
    if (success) feedback.toast({ message: success, tone: "success" });
    return true;
  }

  function basisOf(s: SourceView): RightsBasis | null {
    if (s.id in pendingBasis) return pendingBasis[s.id];
    return s.rightsBasis ?? defaultRightsBasis(s.platform);
  }

  function saveUse(next: SourceView[], ack: boolean, nextReason: string | null, success?: string) {
    startTransition(async () => {
      apply(await saveSourceUseAction(projectId, toUseEntries(next), ack, nextReason), success);
    });
  }

  function toggleCheck(id: string) {
    const ids = sources.filter((s) => (s.id === id ? !s.checked : s.checked)).map((s) => s.id);
    startTransition(async () => {
      apply(await setDownloadChecksAction(projectId, ids));
    });
  }

  function toggleUse(source: SourceView) {
    const basis = basisOf(source);
    if (!source.used && basis === null) {
      setError("권리 근거를 먼저 골라 주세요.");
      return;
    }
    const next = sources.map((s) => (s.id === source.id ? { ...s, used: !s.used, rightsBasis: s.used ? null : basis } : s));
    saveUse(next, noticeAck, reason);
  }

  function changeBasis(source: SourceView, basis: RightsBasis | null) {
    setPendingBasis((prev) => ({ ...prev, [source.id]: basis }));
    if (!source.used) return;
    // 사용 중인 원본의 근거를 바꾸면 바로 저장(비우면 사용 해제)
    const next = sources.map((s) => (s.id === source.id ? { ...s, used: basis !== null, rightsBasis: basis } : s));
    saveUse(next, noticeAck, reason);
  }

  function startSelection() {
    selectKey.current ??= crypto.randomUUID();
    const key = selectKey.current;
    startTransition(async () => {
      const result = await startSourceSelectionAction(projectId, key);
      if (!result.ok) {
        setError(result.error);
        if (!result.retryable) selectKey.current = null;
        return;
      }
      selectKey.current = null;
      setError(null);
      feedback.toast({
        message: result.created ? "원본 선정을 시작했습니다. 끝나면 점수 순으로 바뀝니다" : "이미 시작한 원본 선정 작업입니다",
        tone: "success",
      });
    });
  }

  async function addDirect(url: string, author: string, title: string) {
    return new Promise<boolean>((resolve) => {
      startTransition(async () => {
        const ok = apply(await addDirectSourceAction(projectId, url, author, title), "원본을 추가했습니다");
        if (ok) setAdding(false);
        resolve(ok);
      });
    });
  }

  const counts: Record<Filter, number> = {
    all: listed.length,
    tiktok: listed.filter((s) => s.platform === "tiktok").length,
    xiaohongshu: listed.filter((s) => s.platform === "xiaohongshu").length,
    direct: listed.filter((s) => s.platform === "direct").length,
  };
  const reasonNeeded = usedCount >= 3 && usedCount < USE_TARGET;

  return (
    <section aria-label="소스 모으기" className="flex flex-col gap-4 rounded-card border border-line bg-white p-4 shadow-card tablet:p-6">
      <div className="flex flex-col gap-2">
        <p className="text-sm text-muted">
          20편을 목록으로 찾고, 체크한 {MAX_DOWNLOAD_CHECKS}편만 내려받아 그중 {USE_TARGET}편을 편집에 씁니다. 자동으로 찾은 영상은 참고용·권리
          미확인 원본이며, 원본 파일은 발행 30일 뒤 삭제하고 출처 기록만 남깁니다.
        </p>
        <div className="flex flex-wrap gap-2">
          <button type="button" onClick={() => setAdding((v) => !v)} disabled={!editable} className={btnClass}>
            + 원본 영상 추가
          </button>
          {sources.length > 0 ? (
            <button type="button" onClick={startSelection} disabled={!editable || pending} className={btnClass}>
              원본 선정 시작
            </button>
          ) : null}
        </div>
        {sources.length > 0 ? (
          <p className="text-xs text-muted">원본 선정은 제품 이미지 일치도로 점수를 매겨 상위 20편을 고릅니다(크레딧 차감 작업).</p>
        ) : null}
      </div>

      {adding ? <AddSourceForm pending={pending} onSubmit={addDirect} onCancel={() => setAdding(false)} /> : null}
      {error ? <InlineBanner tone="error">{error}</InlineBanner> : null}

      <SourceNotice
        checked={noticeAck}
        disabled={!editable || pending}
        onChange={(ack) => saveUse(sources, ack, reason, ack ? "고지 확인을 저장했습니다" : undefined)}
      />

      {listed.length === 0 ? (
        <div className="flex flex-col gap-1 rounded-btn border border-dashed border-line p-6 text-center">
          <p className="text-base font-bold">아직 원본이 없습니다</p>
          <p className="text-sm text-muted">
            브라우저 확장 프로그램으로 소스를 찾거나, 원본 영상 추가로 URL과 작성자를 넣어 주세요. 다운로드 0편 · 사용 0편.
          </p>
        </div>
      ) : (
        <>
          <div className="flex flex-wrap items-center justify-between gap-2">
            <p className="text-sm">
              목록 <strong>{listed.length}편</strong> · 다운로드 체크 <strong>{checkedCount}</strong>/{MAX_DOWNLOAD_CHECKS} · 내려받음{" "}
              <strong>{downloadedCount}편</strong> · 사용 <strong>{usedCount}편</strong>
              {excludedCount > 0 ? <span className="text-muted"> · 순위 밖 제외 {excludedCount}편</span> : null}
              {quarantinedCount > 0 ? <span className="text-danger-fg"> · 파일 확인 실패로 격리 {quarantinedCount}편(사용 불가)</span> : null}
            </p>
            <div role="group" aria-label="플랫폼 필터" className="flex flex-wrap gap-1.5">
              {(["all", "tiktok", "xiaohongshu", "direct"] as const).map((f) => (
                <button
                  key={f}
                  type="button"
                  aria-pressed={filter === f}
                  onClick={() => setFilter(f)}
                  className={cn(btnClass, "min-h-9 px-3 text-xs", filter === f && "border-accent bg-accent-weak")}
                >
                  {f === "all" ? "전체" : PLATFORM_LABEL[f]} {counts[f]}
                </button>
              ))}
            </div>
          </div>
          <p className="text-xs text-muted">
            AI 추천은 점수 상위 {MAX_DOWNLOAD_CHECKS}편 표시일 뿐 체크하지 않습니다. 내려받을 원본은 직접 체크해 주세요(확장 프로그램이 체크한 원본만
            내려받습니다).
          </p>
          <div className="grid gap-3 tablet:grid-cols-2 desktop:grid-cols-3">
            {shown.map((s) => (
              <SourceCard
                key={s.id}
                no={listed.indexOf(s) + 1}
                source={s}
                recommended={recommended.has(s.id)}
                basis={basisOf(s)}
                editable={editable && !pending}
                checkLimitReached={checkedCount >= MAX_DOWNLOAD_CHECKS}
                onToggleCheck={() => toggleCheck(s.id)}
                onToggleUse={() => toggleUse(s)}
                onBasisChange={(b) => changeBasis(s, b)}
              />
            ))}
          </div>
        </>
      )}

      <div className="flex flex-col gap-2 rounded-btn bg-sub-hover p-4">
        <p className="text-sm font-bold">
          승인 기준 · 사용 {USE_TARGET}편 이상 + 출처 표기 고지 확인 (3~4편은 부족 사유를 남기면 예외 승인, 0~2편은 승인 불가)
        </p>
        <p className={cn("text-sm", problem ? "text-warning-fg" : "text-success-fg")}>
          {problem ? PROBLEM_MESSAGE[problem] : `승인 조건을 채웠습니다. 편집에 넘길 원본 ${usable.length}편. 아래 그대로 진행 · 승인을 눌러 주세요.`}
        </p>
        {reasonNeeded || reason ? (
          <form
            className="flex flex-col gap-2"
            onSubmit={(event) => {
              event.preventDefault();
              saveUse(sources, noticeAck, reasonDraft, "부족 사유를 저장하고 채팅에 남겼습니다");
            }}
          >
            <label htmlFor="source-reason" className="text-sm font-semibold">
              부족 사유(제작 파트너 채팅에도 남습니다)
            </label>
            <textarea
              id="source-reason"
              value={reasonDraft}
              onChange={(event) => setReasonDraft(event.target.value)}
              maxLength={MAX_REASON}
              rows={2}
              disabled={!editable}
              placeholder="예: 같은 구조의 영상이 3편뿐이라 직접 촬영본으로 보완합니다"
              className="rounded-btn border border-line bg-white px-3 py-2 text-base text-ink disabled:bg-sub-hover"
            />
            <div>
              <button
                type="submit"
                disabled={!editable || pending || reasonDraft.trim() === (reason ?? "")}
                className={cn(btnClass, btnPrimaryClass)}
              >
                사유 저장
              </button>
            </div>
          </form>
        ) : null}
        {status[2] === "approved" ? (
          <p className="text-xs text-muted">승인된 소스입니다. 바꾸려면 아래 변경 필요를 눌러 주세요.</p>
        ) : null}
      </div>
    </section>
  );
}
