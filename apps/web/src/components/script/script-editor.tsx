"use client";

import { useMemo, useState, useTransition } from "react";
import { draftScriptAction, saveScriptAction } from "@/app/(dashboard)/studio/[projectId]/[step]/script/actions";
import { InlineBanner, useFeedback } from "@/components/feedback";
import { btnClass, btnPrimaryClass } from "@/components/studio/step-actions";
import { useStudioStep } from "@/components/studio/studio-step-view";
import { CostHint } from "@/components/topic/cost-hint";
import { useElapsed } from "@/components/topic/use-elapsed";
import { type BannedHit, findBannedTerms } from "@/lib/llm/banned";
import { MAX_SCRIPT_LINES, formatSec, lineTenths, splitScript, totalTenths } from "@/lib/llm/script-metrics";
import { cn } from "@/lib/utils";
import { LengthMeter } from "./length-meter";

/*
 * S-08 03 대본 본문 — docs/planning.md 3장 03, docs/03_SCREENS_UX.md S-08(빈·로딩·오류·성공).
 * 초안은 제안 칸에 먼저 보이고, "추천 대본을 작업칸에 적용"을 눌러야 작업칸에 들어간다(적용은 사용자, 17-7).
 * 금지 표현 문장은 화면에서 바로 표시하고 서버가 저장 때 다시 검사한다. 승인은 아래 StepActions만.
 */

type ScriptEditorProps = {
  initialLines: string[];
  targetSec: number;
  bannedTerms: string[];
  checkedCount: number;
};

function BannedList({ hits, lines }: { hits: BannedHit[]; lines: string[] }) {
  return (
    <ul className="mt-1 flex flex-col gap-1">
      {hits.map((hit) => (
        <li key={hit.line}>
          {hit.line + 1}번 문장 「{lines[hit.line]}」 · 금지 표현: {hit.terms.join(", ")}
        </li>
      ))}
    </ul>
  );
}

export function ScriptEditor({ initialLines, targetSec, bannedTerms, checkedCount }: ScriptEditorProps) {
  const { projectId, status, setStatus } = useStudioStep();
  const feedback = useFeedback();
  const [text, setText] = useState(initialLines.join("\n"));
  const [draft, setDraft] = useState<string[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [drafting, startDraft] = useTransition();
  const [saving, startSave] = useTransition();
  const elapsed = useElapsed(drafting);

  const lines = useMemo(() => splitScript(text), [text]);
  const hits = useMemo(() => findBannedTerms(lines, bannedTerms), [lines, bannedTerms]);
  const draftHits = useMemo(() => (draft ? findBannedTerms(draft, bannedTerms) : []), [draft, bannedTerms]);
  const total = totalTenths(lines);

  const locked = status[3] === "approved";
  const ready = status[1] === "approved" && status[2] === "approved";
  const hitLines = new Set(hits.map((h) => h.line));

  function runDraft() {
    setError(null);
    startDraft(async () => {
      const result = await draftScriptAction(projectId);
      if (!result.ok) {
        setError(result.error);
        return;
      }
      setDraft(result.lines);
      if (result.status) setStatus(result.status);
    });
  }

  function save() {
    setError(null);
    startSave(async () => {
      const result = await saveScriptAction(projectId, lines);
      if (!result.ok) {
        setError(result.error);
        return;
      }
      if (result.status) setStatus(result.status);
      feedback.toast({ message: "대본을 저장했습니다", tone: "success" });
    });
  }

  return (
    <div className="flex flex-col gap-4">
      <section aria-label="대본 초안" className="flex flex-col gap-3 rounded-card border border-line bg-white p-4 shadow-card tablet:p-6">
        <div className="flex flex-wrap items-center gap-2">
          <button
            type="button"
            onClick={runDraft}
            disabled={locked || !ready || drafting || checkedCount === 0}
            className={cn(btnClass, draft === null && btnPrimaryClass)}
          >
            {drafting ? `원본 영상 분석 중… ${elapsed}초` : "이 소스에 맞는 대본 초안"}
          </button>
          <span className="text-xs text-muted">체크된 원본 {checkedCount}편 기준</span>
        </div>
        <CostHint task="script" />
        {!ready ? <p className="text-sm text-muted">01 소재와 02 소스를 승인하면 초안을 만들 수 있습니다.</p> : null}
        {ready && checkedCount === 0 ? (
          <p className="text-sm text-muted">02 소스에서 원본을 체크하면 초안을 만들 수 있습니다.</p>
        ) : null}

        {draft ? (
          <div className="flex flex-col gap-2 rounded-btn border border-accent-line bg-accent-weak p-3">
            <p className="text-xs font-semibold text-nav-on-ink">추천 대본 · 예상 {formatSec(totalTenths(draft))}</p>
            <ol className="flex list-decimal flex-col gap-1 pl-5 text-sm">
              {draft.map((line, i) => (
                <li key={i}>{line}</li>
              ))}
            </ol>
            {draftHits.length > 0 ? (
              <InlineBanner tone="warning">
                추천 대본에 금지 표현이 있습니다. 적용한 뒤 고쳐 주세요.
                <BannedList hits={draftHits} lines={draft} />
              </InlineBanner>
            ) : null}
            <div>
              <button
                type="button"
                disabled={locked}
                onClick={() => {
                  setText(draft.join("\n"));
                  setDraft(null);
                }}
                className={cn(btnClass, btnPrimaryClass)}
              >
                추천 대본을 작업칸에 적용
              </button>
            </div>
          </div>
        ) : null}
      </section>

      <section
        aria-label="내레이션 작업칸"
        className="flex flex-col gap-3 rounded-card border border-line bg-white p-4 shadow-card tablet:p-6"
      >
        <label htmlFor="script-lines" className="text-sm font-semibold">
          내레이션(한 줄에 한 문장)<span className="text-danger-fg">*</span>
        </label>
        <textarea
          id="script-lines"
          value={text}
          onChange={(event) => setText(event.target.value)}
          disabled={locked}
          rows={Math.max(5, Math.min(MAX_SCRIPT_LINES, lines.length + 1))}
          placeholder="첫 문장은 문제 제기 또는 결과 장면, 마지막은 행동 유도 한마디로 적어 주세요."
          className="rounded-btn border border-line bg-white px-3 py-2 text-base leading-relaxed text-ink disabled:bg-sub-hover"
        />

        <LengthMeter tenths={total} targetSec={targetSec} />

        {lines.length > 0 ? (
          <ol aria-label="문장별 예상 초" className="flex flex-col gap-1 text-sm">
            {lines.map((line, i) => (
              <li
                key={i}
                className={cn(
                  "flex items-start justify-between gap-3 rounded-btn px-2 py-1",
                  hitLines.has(i) && "bg-danger-bg text-danger-fg",
                )}
              >
                <span className="min-w-0">
                  <span className="mr-2 font-semibold">{i + 1}</span>
                  {line}
                  {hitLines.has(i) ? <span className="sr-only"> (금지 표현 포함)</span> : null}
                </span>
                <span className="shrink-0 text-xs text-muted">{formatSec(lineTenths(line))}</span>
              </li>
            ))}
          </ol>
        ) : null}

        {hits.length > 0 ? (
          <InlineBanner tone="error">
            금지 표현이 들어간 문장이 있습니다. 고친 뒤 저장해 주세요.
            <BannedList hits={hits} lines={lines} />
          </InlineBanner>
        ) : null}
        {error ? <InlineBanner tone="error">{error}</InlineBanner> : null}

        <div className="flex flex-wrap items-center gap-2">
          <button
            type="button"
            onClick={save}
            disabled={locked || !ready || saving || lines.length === 0 || hits.length > 0}
            className={cn(btnClass, btnPrimaryClass)}
          >
            {saving ? "저장 중…" : "대본 저장"}
          </button>
          <p className="text-xs text-muted">
            {locked ? "승인된 대본입니다. 바꾸려면 아래 변경 필요를 눌러 주세요." : "저장하면 승인할 수 있습니다."}
          </p>
        </div>
      </section>
    </div>
  );
}
