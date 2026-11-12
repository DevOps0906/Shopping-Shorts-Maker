/*
 * 트렌드 화면 표시용 순수 함수. 근거: docs/03_SCREENS_UX.md S-04, docs/planning.md 10장(기회 점수),
 * design/prototype/Main.dc.html 트렌드(insights·catBars·compCls).
 */

export const TREND_PERIODS = [
  { value: "today", label: "오늘" },
  { value: "7d", label: "7일" },
  { value: "30d", label: "30일" },
] as const;
export type TrendPeriod = (typeof TREND_PERIODS)[number]["value"];
export const DEFAULT_PERIOD: TrendPeriod = "7d";

export function parsePeriod(value: unknown): TrendPeriod {
  return TREND_PERIODS.some((p) => p.value === value) ? (value as TrendPeriod) : DEFAULT_PERIOD;
}

export function periodLabel(period: TrendPeriod) {
  return TREND_PERIODS.find((p) => p.value === period)?.label ?? "";
}

export type TrendRow = {
  id: string;
  name: string;
  categoryId: string;
  categoryName: string;
  overseasGrowth: number | null;
  krSearchGrowth: number | null;
  krCompetition: number | null;
  score: number | null;
  sellable: boolean;
  capturedAt: string;
};

export type Competition = { label: "낮음" | "보통" | "높음"; className: string };

/** 국내 숏폼 경쟁 0~100 → 3단계(가정: 33 이하 낮음 · 66 이하 보통 · 그 위 높음) */
export function competitionLevel(value: number | null): Competition | null {
  if (value === null) return null;
  if (value <= 33) return { label: "낮음", className: "bg-success-bg text-success-fg" };
  if (value <= 66) return { label: "보통", className: "bg-warning-bg text-warning-fg" };
  return { label: "높음", className: "bg-danger-bg text-danger-fg" };
}

export function formatGrowth(value: number | null) {
  return value === null ? "—" : `+${Math.round(value)}%`;
}

export function formatScore(value: number | null) {
  return value === null ? "—" : String(Math.round(value));
}

export type CategoryBar = { categoryId: string; name: string; score: number };

/** 카테고리별 평균 기회 점수(높은 순) */
export function categoryBars(rows: readonly TrendRow[]): CategoryBar[] {
  const agg = new Map<string, { name: string; sum: number; n: number }>();
  for (const row of rows) {
    if (row.score === null) continue;
    const cur = agg.get(row.categoryId) ?? { name: row.categoryName, sum: 0, n: 0 };
    cur.sum += row.score;
    cur.n += 1;
    agg.set(row.categoryId, cur);
  }
  return [...agg.entries()]
    .map(([categoryId, c]) => ({ categoryId, name: c.name, score: Math.round(c.sum / c.n) }))
    .sort((a, b) => b.score - a.score);
}

export type TrendInsights = {
  topCategory: CategoryBar | null;
  leadCount: number;
  avgOverseas: number | null;
};

/**
 * 인사이트 3개: 가장 기회가 큰 카테고리(전체 기간 행 기준) · 해외 선행 상품 수(해외 영상 +100% 이상이고
 * 국내 경쟁 낮음) · 평균 해외 영상 증가(보이는 행 기준)
 */
export function trendInsights(allRows: readonly TrendRow[], shownRows: readonly TrendRow[]): TrendInsights {
  const overseas = shownRows.map((r) => r.overseasGrowth).filter((v): v is number => v !== null);
  return {
    topCategory: categoryBars(allRows)[0] ?? null,
    leadCount: shownRows.filter(
      (r) => (r.overseasGrowth ?? 0) >= 100 && competitionLevel(r.krCompetition)?.label === "낮음",
    ).length,
    avgOverseas: overseas.length ? Math.round(overseas.reduce((a, b) => a + b, 0) / overseas.length) : null,
  };
}

/** 가장 최근 수집 시각 */
export function latestCapturedAt(rows: readonly TrendRow[]) {
  return rows.reduce<string | null>((latest, r) => (latest === null || r.capturedAt > latest ? r.capturedAt : latest), null);
}

/** 숏폼 제작하기 → 새 프로젝트(제품명·카테고리 미리 채움). 여러 상품 일괄 생성은 이후 작업. */
export function newProjectHref(row: Pick<TrendRow, "name" | "categoryId">, accountId?: string | null) {
  const params = new URLSearchParams({ start: "direct", product: row.name, category: row.categoryId });
  if (accountId) params.set("account", accountId);
  return `/new?${params.toString()}`;
}
