import { AnalyticsView } from "@/components/analytics/analytics-view";
import { PageHeader } from "@/components/page-header";
import { isProjectId } from "@/lib/steps/project-id";
import { getAnalytics } from "@/server/analytics/queries";

type AnalyticsPageProps = {
  searchParams: Promise<{ channel?: string }>;
};

/** S-12 성과 분석. 로딩은 loading.tsx(카드·그래프 스켈레톤), 로드 실패는 error.tsx(오류 안내 + 다시 시도). */
export default async function AnalyticsPage({ searchParams }: AnalyticsPageProps) {
  const sp = await searchParams;
  const channelId = typeof sp.channel === "string" && isProjectId(sp.channel) ? sp.channel : null;
  const data = await getAnalytics(channelId);
  return (
    <div className="mx-auto flex max-w-(--content-max) flex-col gap-4">
      <PageHeader eyebrow="ANALYTICS" title="성과 분석" />
      <AnalyticsView data={data} />
    </div>
  );
}
