/*
 * S-12 성과 분석 표시용 순수 함수(task-025). 근거: docs/planning.md 15-3, spec S-12.
 * - 날짜는 YouTube Analytics day(America/Los_Angeles) 기준. 링크 클릭도 같은 날짜로 묶여 저장된다.
 * - 예상 제휴 수익 = 링크 클릭 × 구매 전환율 3% × 평균 결제액 25,000원 × 수수료율 3% (가정값). 정수 원.
 */

export const PERIOD_DAYS = 14;
export const ASSUMED = { conversion: 0.03, avgOrderWon: 25_000, commission: 0.03 } as const;
export const ASSUMPTION_NOTE =
  "예상 제휴 수익 = 링크 클릭 × 구매 전환율 3% × 평균 결제액 25,000원 × 수수료율 3%로 계산한 가정값입니다. 실제 정산 금액과 다를 수 있습니다.";
export const EMPTY_MESSAGE = "이 채널에서 발행한 영상이 아직 없습니다.";

/** 예상 제휴 수익(정수 원) */
export function estRevenue(clicks: number) {
  return Math.round(clicks * ASSUMED.conversion * ASSUMED.avgOrderWon * ASSUMED.commission);
}

/** 클릭률(%) = 링크 클릭 ÷ 조회수. 조회가 0이면 null */
export function clickRate(clicks: number, views: number) {
  return views > 0 ? (clicks / views) * 100 : null;
}

export type ChannelOption = { id: string; name: string; platform: string };

export type VideoInput = {
  publicationId: string;
  title: string;
  channelName: string;
  categoryName: string | null;
  publishedAt: string | null;
};

export type MetricRow = { publicationId: string; date: string; views: number; linkClicks: number; avgViewPct: number | null };

export type VideoStat = VideoInput & {
  views: number;
  clicks: number;
  ctr: number | null;
  avgViewPct: number | null;
  revenue: number;
};

export type DayStat = { date: string; views: number };

export type AnalyticsSummary = {
  totals: { views: number; clicks: number; ctr: number | null; revenue: number };
  days: DayStat[];
  videos: VideoStat[];
  insights: { topCategory: { name: string; ctr: number } | null; topRetention: { title: string; avgViewPct: number } | null };
};

const LA_DATE = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Los_Angeles", year: "numeric", month: "2-digit", day: "2-digit" });

function addDays(day: string, delta: number) {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + delta)).toISOString().slice(0, 10);
}

/** 최근 14일(오늘 포함, LA 날짜) YYYY-MM-DD 목록 */
export function periodDays(now: Date) {
  const end = LA_DATE.format(now);
  return Array.from({ length: PERIOD_DAYS }, (_, i) => addDays(end, i - (PERIOD_DAYS - 1)));
}

export function summarize(videos: VideoInput[], metrics: MetricRow[], days: string[]): AnalyticsSummary {
  const inPeriod = new Set(days);
  const rows = metrics.filter((m) => inPeriod.has(m.date));
  const byDay = new Map(days.map((d) => [d, 0]));
  for (const m of rows) byDay.set(m.date, (byDay.get(m.date) ?? 0) + m.views);

  const stats: VideoStat[] = videos.map((v) => {
    const mine = rows.filter((m) => m.publicationId === v.publicationId);
    const views = mine.reduce((s, m) => s + m.views, 0);
    const clicks = mine.reduce((s, m) => s + m.linkClicks, 0);
    // 평균 시청 비율: 날짜별 값을 조회수로 가중 평균(조회가 없으면 단순 평균)
    const pct = mine.filter((m) => m.avgViewPct !== null) as (MetricRow & { avgViewPct: number })[];
    const weight = pct.reduce((s, m) => s + m.views, 0);
    const avgViewPct =
      pct.length === 0
        ? null
        : weight > 0
          ? pct.reduce((s, m) => s + m.avgViewPct * m.views, 0) / weight
          : pct.reduce((s, m) => s + m.avgViewPct, 0) / pct.length;
    return { ...v, views, clicks, ctr: clickRate(clicks, views), avgViewPct, revenue: estRevenue(clicks) };
  });

  const views = stats.reduce((s, v) => s + v.views, 0);
  const clicks = stats.reduce((s, v) => s + v.clicks, 0);

  const byCategory = new Map<string, { views: number; clicks: number }>();
  for (const v of stats) {
    if (!v.categoryName) continue;
    const c = byCategory.get(v.categoryName) ?? { views: 0, clicks: 0 };
    byCategory.set(v.categoryName, { views: c.views + v.views, clicks: c.clicks + v.clicks });
  }
  let topCategory: AnalyticsSummary["insights"]["topCategory"] = null;
  for (const [name, c] of byCategory) {
    const ctr = clickRate(c.clicks, c.views);
    if (ctr !== null && (topCategory === null || ctr > topCategory.ctr)) topCategory = { name, ctr };
  }
  let topRetention: AnalyticsSummary["insights"]["topRetention"] = null;
  for (const v of stats) {
    if (v.avgViewPct !== null && (topRetention === null || v.avgViewPct > topRetention.avgViewPct)) {
      topRetention = { title: v.title, avgViewPct: v.avgViewPct };
    }
  }

  return {
    totals: { views, clicks, ctr: clickRate(clicks, views), revenue: estRevenue(clicks) },
    days: days.map((date) => ({ date, views: byDay.get(date) ?? 0 })),
    videos: stats.sort((a, b) => b.views - a.views),
    insights: { topCategory, topRetention },
  };
}

export const formatCount = (n: number) => n.toLocaleString("ko-KR");
export const formatWon = (n: number) => `${n.toLocaleString("ko-KR")}원`;
export const formatPct = (n: number | null) => (n === null ? "-" : `${n.toFixed(1)}%`);
/** YYYY-MM-DD → M/D */
export const formatDay = (day: string) => `${Number(day.slice(5, 7))}/${Number(day.slice(8, 10))}`;
