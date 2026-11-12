import { describe, expect, it } from "vitest";
import { type TrendRow, categoryBars, competitionLevel, newProjectHref, parsePeriod, trendInsights } from "./trend-view";

function row(partial: Partial<TrendRow>): TrendRow {
  return {
    id: "id",
    name: "상품",
    categoryId: "c1",
    categoryName: "주방",
    overseasGrowth: 50,
    krSearchGrowth: 40,
    krCompetition: 50,
    score: 60,
    sellable: true,
    capturedAt: "2026-11-12T00:00:00Z",
    ...partial,
  };
}

describe("트렌드 표시", () => {
  it("기간은 오늘·7일·30일, 모르는 값은 7일", () => {
    expect(parsePeriod("today")).toBe("today");
    expect(parsePeriod("1y")).toBe("7d");
  });

  it("국내 경쟁 3단계", () => {
    expect(competitionLevel(22)?.label).toBe("낮음");
    expect(competitionLevel(45)?.label).toBe("보통");
    expect(competitionLevel(80)?.label).toBe("높음");
    expect(competitionLevel(null)).toBeNull();
  });

  it("카테고리 평균 점수 높은 순, 인사이트 3개", () => {
    const rows = [
      row({ id: "a", categoryId: "c1", categoryName: "주방", score: 60, overseasGrowth: 120, krCompetition: 20 }),
      row({ id: "b", categoryId: "c2", categoryName: "뷰티", score: 80, overseasGrowth: 80 }),
      row({ id: "c", categoryId: "c1", categoryName: "주방", score: 70 }),
    ];
    expect(categoryBars(rows)).toEqual([
      { categoryId: "c2", name: "뷰티", score: 80 },
      { categoryId: "c1", name: "주방", score: 65 },
    ]);
    const ins = trendInsights(rows, rows);
    expect(ins.topCategory?.name).toBe("뷰티");
    expect(ins.leadCount).toBe(1);
    expect(ins.avgOverseas).toBe(83);
    expect(trendInsights([], []).avgOverseas).toBeNull();
  });

  it("숏폼 제작하기 → 새 프로젝트 미리 채움", () => {
    expect(newProjectHref({ name: "의류 압축팩", categoryId: "c1" })).toBe(
      "/new?start=direct&product=%EC%9D%98%EB%A5%98+%EC%95%95%EC%B6%95%ED%8C%A9&category=c1",
    );
    expect(newProjectHref({ name: "a", categoryId: "c1" }, "acc")).toBe("/new?start=direct&product=a&category=c1&account=acc");
  });
});
