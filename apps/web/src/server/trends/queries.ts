import "server-only";
import { createClient } from "@/lib/supabase/server";
import { embeddedText } from "@/components/projects/project-view";
import type { TrendPeriod, TrendRow } from "@/components/trends/trend-view";
import type { Tables } from "@/types/db";

/*
 * 트렌드 조회(trend_items, 로그인 읽기 전용). 지금은 task-010 시드 데이터다. 실수집은 이후 작업.
 * 원문 오류는 내보내지 않고 던져서 화면의 오류 상태로 보낸다.
 */

type RawTrend = Pick<
  Tables<"trend_items">,
  | "id"
  | "name"
  | "category_id"
  | "overseas_growth"
  | "kr_search_growth"
  | "kr_competition"
  | "opportunity_score"
  | "sellable"
  | "captured_at"
> & { categories?: unknown };

/** 기간의 모든 카테고리 상품을 기회 점수 높은 순으로 */
export async function listTrends(period: TrendPeriod, limit?: number): Promise<TrendRow[]> {
  const supabase = await createClient();
  let query = supabase
    .from("trend_items")
    .select(
      "id, name, category_id, overseas_growth, kr_search_growth, kr_competition, opportunity_score, sellable, captured_at, categories(name)",
    )
    .eq("period", period)
    .order("opportunity_score", { ascending: false, nullsFirst: false });
  if (limit) query = query.limit(limit);
  const { data, error } = await query;
  if (error) throw new Error("load_failed");
  return ((data ?? []) as RawTrend[]).map((t) => ({
    id: t.id,
    name: t.name,
    categoryId: t.category_id,
    categoryName: embeddedText(t.categories, "name") ?? "",
    overseasGrowth: t.overseas_growth === null ? null : Number(t.overseas_growth),
    krSearchGrowth: t.kr_search_growth === null ? null : Number(t.kr_search_growth),
    krCompetition: t.kr_competition === null ? null : Number(t.kr_competition),
    score: t.opportunity_score === null ? null : Number(t.opportunity_score),
    sellable: t.sellable,
    capturedAt: t.captured_at,
  }));
}
