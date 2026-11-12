import type { ReactNode } from "react";
import Link from "next/link";
import {
  PROJECT_STATUSES,
  type ProjectStatus,
  STATUS_BADGE,
  STATUS_LABEL,
  type StatusFilter,
  formatDateTime,
  progressPercent,
  stepLabel,
  studioHref,
} from "@/components/projects/project-view";
import {
  badgeClass,
  barClass,
  btnClass,
  btnPrimaryClass,
  btnSmClass,
  cardClass,
  noteClass,
  segBtnClass,
  segBtnOnClass,
  segClass,
  tdClass,
  thClass,
  trackClass,
} from "@/components/projects/ui";
import { cn } from "@/lib/utils";
import type { ProjectRow } from "@/server/projects/queries";

/*
 * S-03 프로젝트 관리 — 상태 필터 · 검색 · + 새로운 프로젝트 · 표(프로젝트·채널·카테고리·진행·버전·수정·상태·관리) · 페이지.
 * 필터·검색·페이지는 URL(?status=&q=&page=)이라 새로 고침·공유해도 유지된다. 시각 정본: Main.dc.html vProjects.
 */

type ProjectsViewProps = {
  rows: ProjectRow[];
  status: StatusFilter;
  q: string;
  page: number;
  pageCount: number;
  counts: Record<ProjectStatus, number>;
  all: number;
  /** 관리 칸(열기·복제·삭제) — 클라이언트 컴포넌트를 페이지가 넣는다 */
  renderActions: (row: ProjectRow) => ReactNode;
};

export function projectsHref(params: { status: StatusFilter; q: string; page?: number }) {
  const sp = new URLSearchParams();
  if (params.status !== "all") sp.set("status", params.status);
  if (params.q) sp.set("q", params.q);
  if (params.page && params.page > 1) sp.set("page", String(params.page));
  const s = sp.toString();
  return s ? `/projects?${s}` : "/projects";
}

export function ProjectsView({ rows, status, q, page, pageCount, counts, all, renderActions }: ProjectsViewProps) {
  const filters: { value: StatusFilter; label: string }[] = [
    { value: "all", label: `전체 ${all}` },
    ...PROJECT_STATUSES.map((s) => ({ value: s, label: `${STATUS_LABEL[s]} ${counts[s]}` })),
  ];

  return (
    <>
      <div className="flex flex-wrap items-center justify-between gap-2.5">
        <nav aria-label="상태 필터" className={segClass}>
          {filters.map((f) => (
            <Link
              key={f.value}
              href={projectsHref({ status: f.value, q })}
              aria-current={status === f.value ? "page" : undefined}
              className={cn(segBtnClass, status === f.value && segBtnOnClass)}
            >
              {f.label}
            </Link>
          ))}
        </nav>
        <form
          action="/projects"
          method="get"
          role="search"
          className="flex min-h-11 flex-1 basis-56 items-center gap-2 rounded-btn border border-line bg-white px-3 text-muted focus-within:border-accent tablet:max-w-90"
        >
          {status !== "all" ? <input type="hidden" name="status" value={status} /> : null}
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true" className="size-4.5 shrink-0">
            <circle cx="11" cy="11" r="7" />
            <path d="M20 20l-4-4" />
          </svg>
          <input
            type="search"
            name="q"
            defaultValue={q}
            aria-label="프로젝트 검색"
            placeholder="프로젝트·제품 검색"
            className="min-w-0 flex-1 bg-transparent text-sm text-ink outline-0"
          />
        </form>
        <Link href="/new" className={cn(btnClass, btnPrimaryClass)}>
          + 새로운 프로젝트
        </Link>
      </div>

      <section className={cardClass} aria-label="프로젝트 목록">
        <div className="relative overflow-x-auto">
          <table className="w-full border-collapse text-sm">
            <thead>
              <tr>
                {["프로젝트", "채널", "카테고리", "진행", "버전", "수정", "상태"].map((h) => (
                  <th key={h} scope="col" className={thClass}>
                    {h}
                  </th>
                ))}
                <th scope="col" className={thClass}>
                  <span className="sr-only">관리</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {rows.map((p) => (
                <tr key={p.id} className="transition-colors hover:bg-sub-hover">
                  <td className={cn(tdClass, "min-w-40")}>
                    <Link href={studioHref(p.id, p.currentStep)} className="font-bold text-ink hover:text-accent hover:underline">
                      {p.name}
                    </Link>
                  </td>
                  <td className={cn(tdClass, "whitespace-nowrap")}>{p.channelName ?? "연결 해제된 채널"}</td>
                  <td className={tdClass}>
                    {p.categoryName ? <span className={cn(badgeClass, "bg-hot-bg text-hot-fg")}>{p.categoryName}</span> : "-"}
                  </td>
                  <td className={cn(tdClass, "min-w-32")}>
                    <span className={noteClass}>{stepLabel(p.status, p.currentStep)}</span>
                    <div className={cn(trackClass, "mt-1.5")}>
                      <span className={barClass} style={{ width: `${progressPercent(p.status, p.currentStep)}%` }} />
                    </div>
                  </td>
                  <td className={tdClass}>{p.version ? `V${p.version}` : "-"}</td>
                  <td className={cn(tdClass, "whitespace-nowrap")}>{formatDateTime(p.updatedAt)}</td>
                  <td className={tdClass}>
                    <span className={cn(badgeClass, STATUS_BADGE[p.status])}>{STATUS_LABEL[p.status]}</span>
                  </td>
                  <td className={tdClass}>{renderActions(p)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {rows.length === 0 ? <p className={cn(noteClass, "m-0 p-5")}>조건에 맞는 프로젝트가 없습니다.</p> : null}
      </section>

      {pageCount > 1 ? (
        <nav aria-label="페이지" className="flex flex-wrap items-center justify-center gap-1">
          {page > 1 ? (
            <Link href={projectsHref({ status, q, page: page - 1 })} className={cn(btnClass, btnSmClass)} aria-label="이전 페이지">
              ‹
            </Link>
          ) : null}
          {Array.from({ length: pageCount }, (_, i) => i + 1).map((n) => (
            <Link
              key={n}
              href={projectsHref({ status, q, page: n })}
              aria-current={n === page ? "page" : undefined}
              className={cn(btnClass, btnSmClass, n === page && btnPrimaryClass)}
            >
              {n}
            </Link>
          ))}
          {page < pageCount ? (
            <Link href={projectsHref({ status, q, page: page + 1 })} className={cn(btnClass, btnSmClass)} aria-label="다음 페이지">
              ›
            </Link>
          ) : null}
        </nav>
      ) : null}
    </>
  );
}
