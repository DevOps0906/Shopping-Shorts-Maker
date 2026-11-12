import { PageHeader } from "@/components/page-header";
import { isUploadPlatform } from "@/components/projects/project-view";
import { TrendBoard } from "@/components/trends/trend-board";
import { parsePeriod } from "@/components/trends/trend-view";
import { listCategories, listChannels } from "@/server/projects/queries";
import { listTrends } from "@/server/trends/queries";

type TrendsPageProps = {
  searchParams: Promise<{ period?: string; category?: string; account?: string }>;
};

/** S-04 트렌드 분석. 로드 실패는 error.tsx(오류 안내 + 다시 시도)로 간다. */
export default async function TrendsPage({ searchParams }: TrendsPageProps) {
  const sp = await searchParams;
  const period = parsePeriod(sp.period);
  const [rows, categories, channels] = await Promise.all([listTrends(period), listCategories(), listChannels()]);
  const categoryId = categories.some((c) => c.id === sp.category) ? (sp.category as string) : null;
  const uploadChannels = channels.filter((c) => isUploadPlatform(c.platform));
  // 선택 채널(?account=)이 내 업로드 채널이면 유지, 아니면 기본 채널
  const channel = uploadChannels.find((c) => c.id === sp.account) ?? uploadChannels[0];

  return (
    <div className="mx-auto flex max-w-(--content-max) flex-col gap-4">
      <PageHeader eyebrow="TREND" title="트렌드 분석" />
      <TrendBoard
        rows={rows}
        categories={categories}
        period={period}
        categoryId={categoryId}
        channelName={channel?.channel_name ?? null}
        accountId={channel?.id ?? null}
      />
    </div>
  );
}
