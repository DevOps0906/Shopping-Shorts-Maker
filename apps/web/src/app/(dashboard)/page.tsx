import { Suspense } from "react";
import { HomeView } from "@/components/home/home-view";
import { LoadError } from "@/components/home/load-error";
import { PageSkeleton } from "@/components/home/skeleton";
import { PageHeader } from "@/components/page-header";
import { type HomeData, getHomeData, listCategories } from "@/server/projects/queries";
import { listTrends } from "@/server/trends/queries";
import type { TrendRow } from "@/components/trends/trend-view";

async function HomeContent() {
  let data: HomeData;
  let trends: TrendRow[];
  let categoryNames: Record<string, string>;
  try {
    const [home, today, categories] = await Promise.all([getHomeData(), listTrends("today", 5), listCategories()]);
    data = home;
    trends = today;
    categoryNames = Object.fromEntries(categories.map((c) => [c.id, c.name]));
  } catch {
    return <LoadError message="홈 지표를 불러오지 못했습니다" />;
  }
  return <HomeView data={data} trends={trends} categoryNames={categoryNames} />;
}

export default function HomePage() {
  return (
    <div className="mx-auto flex max-w-(--content-max) flex-col gap-4">
      <PageHeader eyebrow="OVERVIEW" title="홈" />
      <Suspense fallback={<PageSkeleton label="홈 지표를 불러오는 중입니다…" cards={4} rows={2} />}>
        <HomeContent />
      </Suspense>
    </div>
  );
}
