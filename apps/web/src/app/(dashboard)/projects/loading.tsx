import { PageSkeleton } from "@/components/home/skeleton";

export default function ProjectsLoading() {
  return <PageSkeleton label="프로젝트 목록을 불러오는 중입니다…" rows={1} />;
}
