"use client";

import { useState } from "react";
import Link from "next/link";
import { costSummary } from "@/components/projects/ai-cost";
import {
  badgeClass,
  barClass,
  btnClass,
  btnPrimaryClass,
  btnSmClass,
  noteClass,
  sectClass,
  tdClass,
  thClass,
  trackClass,
} from "@/components/projects/ui";
import { cn } from "@/lib/utils";
import { type TrendRow, competitionLevel, formatGrowth, formatScore, newProjectHref } from "./trend-view";

/*
 * S-04 급상승 상품 TOP 표 + 선택 바. 선택은 화면 안 상태(체크박스).
 * "숏폼 제작하기"는 상품 1개를 새 프로젝트로 넘긴다. 여러 상품 일괄 생성(01 자동 승인·소스 찾기 자동 시작)은 이후 작업.
 */

type TrendTableProps = { rows: TrendRow[]; channelName: string | null; accountId: string | null };

export function TrendTable({ rows, channelName, accountId }: TrendTableProps) {
  const [selected, setSelected] = useState<ReadonlySet<string>>(() => new Set());
  const picked = rows.filter((r) => selected.has(r.id));
  const allShown = rows.length > 0 && picked.length === rows.length;
  const single = picked.length === 1 ? picked[0] : null;

  function toggle(id: string) {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  const cta = single ? (
    <Link href={newProjectHref(single, accountId)} className={cn(btnClass, btnPrimaryClass)}>
      숏폼 제작하기 →
    </Link>
  ) : (
    <button type="button" className={cn(btnClass, btnPrimaryClass)} disabled>
      숏폼 제작하기 →
    </button>
  );

  return (
    <>
      <section className={sectClass} aria-labelledby="trend-top">
        <div className="mb-2.5 flex flex-wrap items-center justify-between gap-2.5">
          <h3 id="trend-top" className="text-base font-bold">
            급상승 상품 TOP {rows.length}
          </h3>
          <div className="flex flex-wrap items-center gap-2">
            <span className={noteClass} aria-live="polite">
              {picked.length}개 선택
            </span>
            <button
              type="button"
              className={cn(btnClass, btnSmClass)}
              onClick={() => setSelected(new Set(rows.slice(0, 3).map((r) => r.id)))}
              disabled={rows.length === 0}
            >
              상위 3개 선택
            </button>
            {cta}
          </div>
        </div>
        <p className={cn(noteClass, "mb-3")}>
          기회 점수 = 해외 영상 증가(40%) + 국내 검색 증가(30%) + 국내 숏폼 경쟁이 낮을수록(30%). 상품을 골라 &ldquo;숏폼
          제작하기&rdquo;를 누르면 그 상품으로 새 프로젝트를 만듭니다.
        </p>
        {rows.length === 0 ? (
          <p className={noteClass}>이 카테고리의 급상승 상품이 아직 없습니다.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full border-collapse text-sm">
              <thead>
                <tr>
                  <th scope="col" className={thClass}>
                    <input
                      type="checkbox"
                      className="size-5 cursor-pointer accent-accent"
                      checked={allShown}
                      onChange={() => setSelected(allShown ? new Set() : new Set(rows.map((r) => r.id)))}
                      aria-label="보이는 상품 모두 선택"
                    />
                  </th>
                  {["순위", "상품", "7일 추이", "해외 영상", "국내 검색", "국내 경쟁", "기회 점수"].map((h) => (
                    <th key={h} scope="col" className={thClass}>
                      {h}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {rows.map((t, i) => {
                  const comp = competitionLevel(t.krCompetition);
                  const on = selected.has(t.id);
                  return (
                    <tr key={t.id} className={cn("transition-colors hover:bg-sub-hover", on && "bg-accent-weak")}>
                      <td className={tdClass}>
                        <input
                          id={`tr-${t.id}`}
                          type="checkbox"
                          className="size-5 cursor-pointer accent-accent"
                          checked={on}
                          onChange={() => toggle(t.id)}
                        />
                      </td>
                      <td className={cn(tdClass, "font-bold text-nav-on-ink tabular-nums")}>{i + 1}</td>
                      <td className={cn(tdClass, "min-w-44")}>
                        <label htmlFor={`tr-${t.id}`} className="block cursor-pointer">
                          <b>{t.name}</b>
                          <span className={cn(noteClass, "block")}>
                            {t.categoryName}
                            {t.sellable ? "" : " · 판매처 확인 필요"}
                          </span>
                        </label>
                      </td>
                      <td className={cn(tdClass, noteClass, "whitespace-nowrap")}>수집 후 표시</td>
                      <td className={cn(tdClass, "font-bold whitespace-nowrap text-success-fg tabular-nums")}>
                        {formatGrowth(t.overseasGrowth)}
                      </td>
                      <td className={cn(tdClass, "font-bold whitespace-nowrap text-success-fg tabular-nums")}>
                        {formatGrowth(t.krSearchGrowth)}
                      </td>
                      <td className={tdClass}>
                        {comp ? <span className={cn(badgeClass, comp.className)}>{comp.label}</span> : "—"}
                      </td>
                      <td className={cn(tdClass, "min-w-28")}>
                        <div className={cn(trackClass, "mb-1")}>
                          <span className={barClass} style={{ width: `${t.score ?? 0}%` }} />
                        </div>
                        <b className="tabular-nums">{formatScore(t.score)}</b>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {picked.length > 0 ? (
        <div
          role="region"
          aria-label="선택한 상품"
          className="sticky bottom-4 z-(--z-popover) mr-16 flex flex-wrap items-center gap-x-4 gap-y-2.5 rounded-card bg-ink py-3 pr-3.5 pl-4.5 text-white shadow-fab tablet:mr-19"
        >
          <p className="min-w-0 flex-1 basis-full text-sm tablet:basis-52">
            <b>{picked.length}개 선택</b> · {picked.map((p) => p.name).join(", ")}
            <span className="block text-xs opacity-75">
              {channelName ? `${channelName} 채널로 만듭니다` : "연결된 채널이 없습니다. 새 프로젝트에서 채널 연결을 안내합니다"}
              {picked.length > 1 ? " · 여러 상품을 한 번에 만드는 기능은 준비 중입니다. 1개만 골라 주세요" : ""}
            </span>
            <span className="block text-xs opacity-75">{costSummary(picked.length)}</span>
          </p>
          <button
            type="button"
            className={cn(btnClass, btnSmClass, "border-white/30 bg-transparent text-white hover:border-white/30 hover:bg-white/10")}
            onClick={() => setSelected(new Set())}
          >
            선택 해제
          </button>
          {cta}
        </div>
      ) : null}
    </>
  );
}
