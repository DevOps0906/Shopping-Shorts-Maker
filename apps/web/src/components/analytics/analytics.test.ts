import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { AnalyticsView } from "@/components/analytics/analytics-view";
import { formatDateTime } from "@/components/projects/project-view";
import { EMPTY_MESSAGE, estRevenue, periodDays, summarize } from "@/components/analytics/metrics";
import type { AnalyticsData } from "@/server/analytics/queries";

vi.mock("next/navigation", () => ({ useRouter: () => ({ refresh: () => {} }) }));

/* S-12 성과 분석(task-025): 빈·성공 렌더, 예상 수익 정수 */

const days = periodDays(new Date("2026-11-13T12:00:00Z"));
const channels = [
  { id: "00000000-0000-4000-8000-0000000000a1", name: "@살림", platform: "youtube" },
  { id: "00000000-0000-4000-8000-0000000000a2", name: "@주방", platform: "youtube" },
];
const videos = [
  { publicationId: "p1", title: "압축팩 리뷰", channelName: "@살림", categoryName: "생활·수납", publishedAt: "2026-11-05T03:00:00Z" },
  { publicationId: "p2", title: "프라이팬 비교", channelName: "@주방", categoryName: "주방", publishedAt: "2026-11-08T03:00:00Z" },
];
const metrics = [
  { publicationId: "p1", date: days[13], views: 1000, linkClicks: 30, avgViewPct: 70 },
  { publicationId: "p1", date: days[12], views: 1000, linkClicks: 10, avgViewPct: 50 },
  { publicationId: "p2", date: days[13], views: 500, linkClicks: 25, avgViewPct: 40 },
  // 기간 밖은 빼고 센다
  { publicationId: "p2", date: "2026-10-01", views: 9999, linkClicks: 999, avgViewPct: 99 },
];

const view = (data: AnalyticsData) => renderToStaticMarkup(createElement(AnalyticsView, { data }));

describe("estRevenue", () => {
  it.each([
    [0, 0],
    [1, 23],
    [2, 45],
    [3, 68],
    [100, 2250],
  ])("클릭 %i → %i원(정수)", (clicks, won) => {
    expect(estRevenue(clicks)).toBe(won);
    expect(Number.isInteger(estRevenue(clicks))).toBe(true);
  });
});

describe("summarize", () => {
  it("14일 합계·클릭률·가중 평균 시청 비율·인사이트", () => {
    const s = summarize(videos, metrics, days);
    expect(days).toHaveLength(14);
    expect(s.totals).toEqual({ views: 2500, clicks: 65, ctr: 2.6, revenue: estRevenue(65) });
    expect(s.days.at(-1)).toEqual({ date: days[13], views: 1500 });
    expect(s.videos[0]).toMatchObject({ publicationId: "p1", views: 2000, clicks: 40, avgViewPct: 60, ctr: 2 });
    expect(s.insights.topCategory).toEqual({ name: "주방", ctr: 5 });
    expect(s.insights.topRetention).toEqual({ title: "압축팩 리뷰", avgViewPct: 60 });
  });
});

describe("S-12 렌더", () => {
  it("빈 상태: 안내 문구, 통계·표 없음", () => {
    const out = view({ channels, channelId: channels[1].id, hasVideos: false, summary: summarize([], [], days), collectedAt: null });
    expect(out).toContain(EMPTY_MESSAGE);
    expect(out).toContain("최근 14일(고정)");
    expect(out).not.toContain("영상별 성과");
    expect(out).toContain("아직 없음");
    expect(out).toMatch(/aria-current="page"[^>]*>@주방</);
  });

  it("성공: 채널 필터·통계 4개·막대 14개·영상 표·인사이트 2개·가정값·수집 시각", () => {
    const out = view({ channels, channelId: null, hasVideos: true, summary: summarize(videos, metrics, days), collectedAt: "2026-11-13T00:31:00Z" });
    for (const text of ["전체", "@살림", "@주방", "조회수", "링크 클릭", "클릭률", "예상 제휴 수익", "2,500", "2.6%", `${estRevenue(65).toLocaleString("ko-KR")}원`]) {
      expect(out).toContain(text);
    }
    expect(out.match(/<li /g)).toHaveLength(14);
    for (const h of ["영상", "채널", "발행", "조회", "평균 시청 비율", "링크 클릭", "클릭률", "예상 수익"]) expect(out).toContain(`>${h}</th>`);
    expect(out).toContain("압축팩 리뷰");
    expect(out).toContain("클릭률 최고 카테고리");
    expect(out).toContain("주방 · 클릭률 5.0%");
    expect(out).toContain("시청 유지 최고 영상");
    expect(out).not.toContain("추천 발행 시간");
    expect(out).toContain("구매 전환율 3%");
    expect(out).toContain(`지표 수집 시각 ${formatDateTime("2026-11-13T00:31:00Z")}`);
    expect(out).not.toContain(EMPTY_MESSAGE);
  });
});
