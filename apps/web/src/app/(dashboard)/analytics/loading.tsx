import { PageSkeleton } from "@/components/home/skeleton";

export default function AnalyticsLoading() {
  return <PageSkeleton label="성과 지표를 불러오는 중입니다…" cards={4} rows={2} />;
}
