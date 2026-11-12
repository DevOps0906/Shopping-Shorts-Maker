import { PageSkeleton } from "@/components/home/skeleton";

export default function NewProjectLoading() {
  return <PageSkeleton label="새 프로젝트 양식을 불러오는 중입니다…" rows={2} />;
}
