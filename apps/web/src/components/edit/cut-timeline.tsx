"use client";

import { btnClass } from "@/components/studio/step-actions";
import { type Candidate, type CutRow, PLATFORM_LABEL, creditLabel } from "@/lib/edit/plan";
import { cn } from "@/lib/utils";

/*
 * S-10 컷 타임라인 + 대사와 장면 연결표(docs/planning.md 3장 05).
 * 막대: 컷마다 완성 영상 안 길이 비율(flex-grow). 표: 컷 번호 · 대사 · 원본(순위·출처) · 원본 구간 · 영상 안 시간 · 교체.
 * 실패한 컷은 위험 색으로 표시한다(17-6 "실패한 컷 번호 → 다음 순위 원본 교체").
 */

export const cutMark = (no: number) => (no >= 1 && no <= 20 ? String.fromCharCode(0x2460 + no - 1) : `${no}`);
const sec = (x: number) => `${x.toFixed(1)}초`;
const range = (a: number, b: number) => `${a.toFixed(1)}–${b.toFixed(1)}초`;

type CutTimelineProps = {
  cuts: CutRow[];
  candidates: Candidate[];
  failed: number[];
  /** 교체 가능 여부(잠금·진행 중·후보 1편이면 false) */
  canReplace: boolean;
  onReplace: (no: number) => void;
};

export function CutTimeline({ cuts, candidates, failed, canReplace, onReplace }: CutTimelineProps) {
  const rank = new Map(candidates.map((c) => [c.id, c.rank]));
  const isFailed = (no: number) => failed.includes(no);
  return (
    <div className="flex flex-col gap-3">
      <div aria-label="컷 타임라인" role="img" className="flex h-12 w-full gap-0.5 overflow-hidden rounded-btn-sm border border-line">
        {cuts.map((c) => (
          <div
            key={c.no}
            style={{ flexGrow: Math.max(c.outEnd - c.outStart, 0.1), flexBasis: 0 }}
            className={cn(
              "flex min-w-0 items-center justify-center text-xs font-semibold",
              isFailed(c.no) ? "bg-danger-bg text-danger-fg" : c.no % 2 ? "bg-accent-weak text-ink" : "bg-sub-hover text-ink",
            )}
            title={`컷 ${c.no} · ${range(c.outStart, c.outEnd)}`}
          >
            <span className="truncate">
              {cutMark(c.no)} {sec(c.outEnd - c.outStart)}
            </span>
          </div>
        ))}
      </div>

      <div className="overflow-x-auto">
        <table className="w-full min-w-160 border-collapse text-sm">
          <caption className="sr-only">대사와 장면 연결표</caption>
          <thead>
            <tr className="border-b border-line text-left text-xs text-muted">
              <th scope="col" className="px-2 py-2 font-semibold">컷</th>
              <th scope="col" className="px-2 py-2 font-semibold">대사</th>
              <th scope="col" className="px-2 py-2 font-semibold">원본</th>
              <th scope="col" className="px-2 py-2 font-semibold">원본 구간</th>
              <th scope="col" className="px-2 py-2 font-semibold">영상 안 시간</th>
              <th scope="col" className="px-2 py-2 font-semibold">
                <span className="sr-only">교체</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {cuts.map((c) => (
              <tr key={c.no} className={cn("border-b border-line align-top", isFailed(c.no) && "bg-danger-bg")}>
                <td className="px-2 py-2 font-semibold whitespace-nowrap">
                  {cutMark(c.no)}
                  {isFailed(c.no) ? <span className="ml-1 text-xs text-danger-fg">실패</span> : null}
                </td>
                <td className="px-2 py-2">{c.line}</td>
                <td className="px-2 py-2 whitespace-nowrap">
                  <span className="font-semibold">{rank.has(c.sourceId) ? `${rank.get(c.sourceId)}순위` : "후보 아님"}</span>
                  <span className="block text-xs text-muted">
                    {creditLabel(c.author)} · {PLATFORM_LABEL[c.platform] ?? c.platform}
                  </span>
                </td>
                <td className="px-2 py-2 whitespace-nowrap tabular-nums">{range(c.srcStart, c.srcEnd)}</td>
                <td className="px-2 py-2 whitespace-nowrap tabular-nums">{range(c.outStart, c.outEnd)}</td>
                <td className="px-2 py-2 text-right">
                  <button
                    type="button"
                    onClick={() => onReplace(c.no)}
                    disabled={!canReplace}
                    aria-label={`컷 ${c.no} 다음 순위 원본으로 교체`}
                    className={btnClass}
                  >
                    다음 순위로 교체
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
