import Link from "next/link";
import { RefreshButton } from "@/components/home/load-error";
import { formatDateTime } from "@/components/projects/project-view";
import { cardClass, noteClass, sectClass, segBtnClass, segBtnOnClass, segClass, tdClass, thClass } from "@/components/projects/ui";
import { cn } from "@/lib/utils";
import type { AnalyticsData } from "@/server/analytics/queries";
import { ASSUMPTION_NOTE, EMPTY_MESSAGE, PERIOD_DAYS, formatCount, formatDay, formatPct, formatWon } from "./metrics";

/*
 * S-12 성과 분석 — 구성: 채널 필터 / 최근 14일(고정) / 통계 4개 / 14일 조회 막대(툴팁) / 영상별 표 / 인사이트 2개 /
 * 가정값 안내 / 지표 수집 시각. 상태: 빈 · 로딩(loading.tsx) · 오류(error.tsx) · 성공. 근거: spec S-12, design/wireframes/S-12.html.
 */

const filterHref = (id: string | null) => (id ? `/analytics?channel=${id}` : "/analytics");

function ChannelFilter({ data }: { data: AnalyticsData }) {
  const options = [{ id: null, name: "전체" }, ...data.channels];
  return (
    <nav aria-label="채널 선택" className={segClass}>
      {options.map((c) => {
        const on = c.id === data.channelId;
        return (
          <Link
            key={c.id ?? "all"}
            href={filterHref(c.id)}
            aria-current={on ? "page" : undefined}
            className={cn(segBtnClass, on && segBtnOnClass)}
          >
            {c.name}
          </Link>
        );
      })}
    </nav>
  );
}

function ViewsChart({ days }: { days: AnalyticsData["summary"]["days"] }) {
  const max = Math.max(1, ...days.map((d) => d.views));
  return (
    <section className={sectClass} aria-labelledby="analytics-chart">
      <h3 id="analytics-chart" className="mb-3 text-base font-bold">
        최근 {PERIOD_DAYS}일 조회
      </h3>
      <ol className="flex h-40 items-end gap-1 tablet:gap-1.5">
        {days.map((d) => {
          const label = `${formatDay(d.date)} 조회 ${formatCount(d.views)}회`;
          return (
            <li key={d.date} className="group relative flex h-full min-w-0 flex-1 flex-col justify-end" title={label}>
              <span className="sr-only">{label}</span>
              <span
                aria-hidden="true"
                className="block w-full rounded-t-btn-sm bg-accent opacity-70 transition-opacity group-hover:opacity-100"
                style={{ height: `${Math.max(2, Math.round((d.views / max) * 100))}%` }}
              />
              <span
                aria-hidden="true"
                className="pointer-events-none absolute bottom-full left-1/2 z-(--z-popover) mb-1 hidden -translate-x-1/2 rounded-btn-sm bg-ink px-2 py-1 text-xs whitespace-nowrap text-white group-hover:block"
              >
                {label}
              </span>
            </li>
          );
        })}
      </ol>
      <div className={cn(noteClass, "mt-1.5 flex justify-between")} aria-hidden="true">
        <span>{formatDay(days[0].date)}</span>
        <span>{formatDay(days[days.length - 1].date)}</span>
      </div>
    </section>
  );
}

export function AnalyticsView({ data }: { data: AnalyticsData }) {
  const { totals, videos, insights } = data.summary;
  const stats = [
    { label: "조회수", value: formatCount(totals.views) },
    { label: "링크 클릭", value: formatCount(totals.clicks) },
    { label: "클릭률", value: formatPct(totals.ctr) },
    { label: "예상 제휴 수익", value: formatWon(totals.revenue) },
  ];

  return (
    <>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <ChannelFilter data={data} />
        <p className={noteClass}>
          <span aria-hidden="true">📅 </span>기간: 최근 {PERIOD_DAYS}일(고정)
        </p>
      </div>

      {!data.hasVideos ? (
        <section className={cn(sectClass, "text-center")}>
          <p className="text-sm text-muted">{EMPTY_MESSAGE}</p>
          <Link href="/projects?status=awaiting_publish" className="mt-2 inline-block text-sm font-semibold text-accent hover:underline">
            발행 대기 프로젝트 보기 →
          </Link>
        </section>
      ) : (
        <>
          <div className="grid grid-cols-2 gap-3.5 desktop:grid-cols-4">
            {stats.map((s) => (
              <div key={s.label} className={cn(cardClass, "flex flex-col gap-1 px-5 py-4.5")}>
                <span className={noteClass}>{s.label}</span>
                <span className="text-app leading-tight font-bold tabular-nums">{s.value}</span>
              </div>
            ))}
          </div>

          <ViewsChart days={data.summary.days} />

          <section className={sectClass} aria-labelledby="analytics-videos">
            <h3 id="analytics-videos" className="mb-2.5 text-base font-bold">
              영상별 성과
            </h3>
            <div className="overflow-x-auto">
              <table className="w-full min-w-180 border-collapse text-sm">
                <thead>
                  <tr>
                    {["영상", "채널", "발행", "조회", "평균 시청 비율", "링크 클릭", "클릭률", "예상 수익"].map((h) => (
                      <th key={h} scope="col" className={thClass}>
                        {h}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {videos.map((v) => (
                    <tr key={v.publicationId}>
                      <td className={cn(tdClass, "max-w-60 truncate font-semibold")}>{v.title}</td>
                      <td className={tdClass}>{v.channelName}</td>
                      <td className={cn(tdClass, "whitespace-nowrap")}>{v.publishedAt ? formatDateTime(v.publishedAt) : "-"}</td>
                      <td className={cn(tdClass, "tabular-nums")}>{formatCount(v.views)}</td>
                      <td className={cn(tdClass, "tabular-nums")}>{formatPct(v.avgViewPct)}</td>
                      <td className={cn(tdClass, "tabular-nums")}>{formatCount(v.clicks)}</td>
                      <td className={cn(tdClass, "tabular-nums")}>{formatPct(v.ctr)}</td>
                      <td className={cn(tdClass, "tabular-nums")}>{formatWon(v.revenue)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>

          <div className="grid grid-cols-1 gap-3.5 tablet:grid-cols-2">
            <section className={sectClass} aria-labelledby="analytics-insight-category">
              <h3 id="analytics-insight-category" className="text-sm font-bold">
                클릭률 최고 카테고리
              </h3>
              <p className={cn(noteClass, "mt-1")}>
                {insights.topCategory
                  ? `${insights.topCategory.name} · 클릭률 ${formatPct(insights.topCategory.ctr)}`
                  : "조회가 쌓이면 카테고리별 클릭률을 비교해 보여 드립니다."}
              </p>
            </section>
            <section className={sectClass} aria-labelledby="analytics-insight-retention">
              <h3 id="analytics-insight-retention" className="text-sm font-bold">
                시청 유지 최고 영상
              </h3>
              <p className={cn(noteClass, "mt-1")}>
                {insights.topRetention
                  ? `${insights.topRetention.title} · 평균 시청 비율 ${formatPct(insights.topRetention.avgViewPct)}`
                  : "평균 시청 비율이 수집되면 보여 드립니다."}
              </p>
            </section>
          </div>
        </>
      )}

      <p className={noteClass}>{ASSUMPTION_NOTE}</p>
      <p className={cn(noteClass, "flex items-center gap-1")}>
        지표 수집 시각 {data.collectedAt ? formatDateTime(data.collectedAt) : "아직 없음"} · 하루 1회 수집
        <RefreshButton />
      </p>
    </>
  );
}
