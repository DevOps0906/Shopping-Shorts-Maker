import Link from "next/link";
import { RefreshButton } from "@/components/home/load-error";
import { formatDateTime } from "@/components/projects/project-view";
import {
  cardClass,
  chipClass,
  chipOnClass,
  labelClass,
  noteClass,
  sectClass,
  segBtnClass,
  segBtnOnClass,
  segClass,
} from "@/components/projects/ui";
import { cn } from "@/lib/utils";
import { trendsUrl } from "@/server/projects/input";
import { TrendTable } from "./trend-table";
import {
  TREND_PERIODS,
  type TrendPeriod,
  type TrendRow,
  categoryBars,
  latestCapturedAt,
  periodLabel,
  trendInsights,
} from "./trend-view";

/*
 * S-04 트렌드 분석 — 필터(카테고리·기간·해외 데이터 출처) / 인사이트 3개 / 급상승 상품 TOP 표·선택 바 /
 * 카테고리별 기회 점수 막대 / 산식 안내 / 수집 시각. 필터는 URL(?category=&period=). 시각 정본: Main.dc.html vTrend.
 */

type TrendBoardProps = {
  rows: TrendRow[];
  categories: { id: string; name: string }[];
  period: TrendPeriod;
  categoryId: string | null;
  channelName: string | null;
  /** 선택 채널 — 트렌드 안 이동·새 프로젝트로 넘길 때 ?account= 로 유지한다 */
  accountId: string | null;
};

export function TrendBoard({ rows, categories, period, categoryId, channelName, accountId }: TrendBoardProps) {
  const trendsHref = (p: TrendPeriod, c: string | null) => trendsUrl({ period: p, categoryId: c, accountId });
  const shown = categoryId ? rows.filter((r) => r.categoryId === categoryId) : rows;
  const insights = trendInsights(rows, shown);
  const bars = categoryBars(rows);
  const captured = latestCapturedAt(rows);
  const categoryName = categories.find((c) => c.id === categoryId)?.name ?? "전체";

  return (
    <>
      <section className={cn(sectClass, "flex flex-col gap-3.5")} aria-label="필터">
        <div>
          <span className={labelClass}>카테고리</span>
          <nav aria-label="카테고리" className="flex flex-wrap gap-2">
            {[{ id: null, name: "전체" }, ...categories].map((c) => {
              const on = (c.id ?? null) === categoryId;
              return (
                <Link
                  key={c.id ?? "all"}
                  href={trendsHref(period, c.id)}
                  aria-current={on ? "page" : undefined}
                  className={cn(chipClass, on && chipOnClass)}
                >
                  {c.name}
                </Link>
              );
            })}
          </nav>
        </div>
        <div className="flex flex-wrap gap-x-8 gap-y-4">
          <div>
            <span className={labelClass}>기간</span>
            <nav aria-label="기간" className={segClass}>
              {TREND_PERIODS.map((p) => (
                <Link
                  key={p.value}
                  href={trendsHref(p.value, categoryId)}
                  aria-current={period === p.value ? "page" : undefined}
                  className={cn(segBtnClass, period === p.value && segBtnOnClass)}
                >
                  {p.label}
                </Link>
              ))}
            </nav>
          </div>
          <div>
            <span className={labelClass}>해외 데이터</span>
            <div role="group" aria-label="해외 데이터 출처" className={segClass}>
              <button type="button" className={cn(segBtnClass, segBtnOnClass)} aria-pressed="true">
                전체
              </button>
              {["틱톡", "샤오홍슈"].map((s) => (
                <button key={s} type="button" className={segBtnClass} aria-pressed="false" disabled title="출처별 데이터는 수집 연동 후 제공합니다">
                  {s}
                </button>
              ))}
            </div>
          </div>
        </div>
      </section>

      <div className="grid grid-cols-1 gap-3.5 tablet:grid-cols-2 desktop:grid-cols-3">
        <div className={cn(cardClass, "flex flex-col gap-1 px-5 py-4.5")}>
          <span className={noteClass}>가장 기회가 큰 카테고리</span>
          <b className="text-app leading-tight">{insights.topCategory?.name ?? "—"}</b>
          <span className={noteClass}>평균 기회 점수 {insights.topCategory?.score ?? "—"}</span>
        </div>
        <div className={cn(cardClass, "flex flex-col gap-1 px-5 py-4.5")}>
          <span className={noteClass}>해외 선행 상품</span>
          <b className="text-app leading-tight tabular-nums">{insights.leadCount}개</b>
          <span className={noteClass}>해외 영상 +100% 이상 · 국내 경쟁 낮음</span>
        </div>
        <div className={cn(cardClass, "flex flex-col gap-1 px-5 py-4.5")}>
          <span className={noteClass}>평균 해외 영상 증가</span>
          <b className="text-app leading-tight tabular-nums">
            {insights.avgOverseas === null ? "—" : `+${insights.avgOverseas}%`}
          </b>
          <span className={noteClass}>
            {periodLabel(period)} 기준 · {categoryName}
          </span>
        </div>
      </div>

      <TrendTable key={`${period}:${categoryId ?? "all"}`} rows={shown} channelName={channelName} accountId={accountId} />

      <section className={sectClass} aria-labelledby="trend-bars">
        <h3 id="trend-bars" className="mb-2.5 text-base font-bold">
          카테고리별 기회 점수
        </h3>
        <p className={cn(noteClass, "mb-2.5")}>카테고리를 누르면 위 목록이 그 카테고리로 바뀝니다.</p>
        {bars.length === 0 ? (
          <p className={noteClass}>이 기간에 집계된 카테고리가 없습니다.</p>
        ) : (
          <nav aria-label="카테고리별 기회 점수" className="flex flex-col gap-1">
            {bars.map((b) => {
              const on = b.categoryId === categoryId;
              return (
                <Link
                  key={b.categoryId}
                  href={trendsHref(period, on ? null : b.categoryId)}
                  aria-current={on ? "page" : undefined}
                  className={cn(
                    "grid min-h-10 grid-cols-[minmax(0,2fr)_minmax(0,5fr)_auto] items-center gap-3 rounded-btn-sm px-2.5 text-ink transition-colors hover:bg-sub-hover",
                    on && "bg-sub-hover",
                  )}
                >
                  <span className="truncate text-sm font-semibold">{b.name}</span>
                  <span className="h-2.5 overflow-hidden rounded-pill bg-count-bg">
                    <span className="block h-full rounded-pill bg-accent" style={{ width: `${b.score}%` }} />
                  </span>
                  <b className="text-right tabular-nums">{b.score}</b>
                </Link>
              );
            })}
          </nav>
        )}
      </section>

      <p className={cn(noteClass, "flex flex-wrap items-center gap-1")}>
        수집 시각 {captured ? formatDateTime(captured) : "—"} · 지금은 시드(예시) 데이터입니다
        <RefreshButton />
      </p>
    </>
  );
}
