import { PageHeader } from "@/components/page-header";
import { type ChannelOption, NewProjectForm } from "@/components/projects/new-project-form";
import { isUploadPlatform } from "@/components/projects/project-view";
import { isProjectId } from "@/lib/steps/project-id";
import { NAME_MAX, type StartMode, isStartMode } from "@/server/projects/input";
import { listCategories, listChannels } from "@/server/projects/queries";
import { createProject } from "./actions";

type NewProjectPageProps = {
  searchParams: Promise<{ start?: string; product?: string; category?: string; account?: string }>;
};

/** S-02 새로운 프로젝트. 트렌드·홈의 "숏폼 제작"은 ?start=direct&product=&category= 로 미리 채운다. */
export default async function NewProjectPage({ searchParams }: NewProjectPageProps) {
  const sp = await searchParams;
  // 로드 실패는 error.tsx(오류 안내 + 다시 시도)로 간다
  const [allChannels, categories] = await Promise.all([listChannels(), listCategories()]);
  const channels: ChannelOption[] = allChannels
    .filter((c) => isUploadPlatform(c.platform))
    .map((c) => ({ id: c.id, platform: c.platform, name: c.channel_name, categoryId: c.category_id, tone: c.tone }));

  const picked = channels.find((c) => c.id === sp.account) ?? channels[0];
  const categoryFromUrl = typeof sp.category === "string" && isProjectId(sp.category) ? sp.category : "";
  const initial: { accountId: string; categoryId: string; start: StartMode; product: string } = {
    accountId: picked?.id ?? "",
    categoryId: categories.some((c) => c.id === categoryFromUrl) ? categoryFromUrl : (picked?.categoryId ?? ""),
    start: isStartMode(sp.start) ? sp.start : "direct",
    product: typeof sp.product === "string" ? sp.product.slice(0, NAME_MAX) : "",
  };

  return (
    <div className="mx-auto flex max-w-(--content-max) flex-col gap-4">
      <PageHeader eyebrow="NEW PROJECT" title="새로운 프로젝트" />
      <NewProjectForm channels={channels} categories={categories} initial={initial} action={createProject} />
    </div>
  );
}
