import { PageSkeleton } from "@/components/home/skeleton";

export default function TrendsLoading() {
  return <PageSkeleton label="트렌드를 불러오는 중입니다…" cards={3} rows={2} />;
}
