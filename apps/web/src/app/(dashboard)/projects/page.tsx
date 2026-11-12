import { PageHeader } from "@/components/page-header";
import { ProjectRowActions } from "@/components/projects/project-row-actions";
import { parseStatusFilter, studioHref } from "@/components/projects/project-view";
import { ProjectsView } from "@/components/projects/projects-view";
import { parsePage, parseQuery } from "@/server/projects/input";
import { PAGE_SIZE, listProjects } from "@/server/projects/queries";
import { deleteProjectAction, duplicateProjectAction } from "./actions";

type ProjectsPageProps = {
  searchParams: Promise<{ status?: string; q?: string; page?: string }>;
};

/** S-03 프로젝트 관리. 로드 실패는 error.tsx(오류 안내 + 다시 시도)로 간다. */
export default async function ProjectsPage({ searchParams }: ProjectsPageProps) {
  const sp = await searchParams;
  const status = parseStatusFilter(sp.status);
  const q = parseQuery(sp.q);
  const page = parsePage(sp.page);
  const { rows, total, counts, all } = await listProjects({ status, q, page });

  return (
    <div className="mx-auto flex max-w-(--content-max) flex-col gap-4">
      <PageHeader eyebrow="PROJECTS" title="프로젝트 관리" />
      <ProjectsView
        rows={rows}
        status={status}
        q={q}
        page={page}
        pageCount={Math.max(1, Math.ceil(total / PAGE_SIZE))}
        counts={counts}
        all={all}
        renderActions={(row) => (
          <ProjectRowActions
            projectId={row.id}
            name={row.name}
            openHref={studioHref(row.id, row.currentStep)}
            onDuplicate={duplicateProjectAction}
            onDelete={deleteProjectAction}
          />
        )}
      />
    </div>
  );
}
