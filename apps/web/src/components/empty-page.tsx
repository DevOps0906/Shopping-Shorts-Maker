import { PageHeader } from "@/components/page-header";

type EmptyPageProps = {
  eyebrow: string;
  title: string;
};

/** 라우트 뼈대용 빈 화면. 화면 내용은 각 화면 작업에서 채운다. */
export function EmptyPage({ eyebrow, title }: EmptyPageProps) {
  return (
    <div className="mx-auto flex max-w-(--content-max) flex-col gap-4">
      <PageHeader eyebrow={eyebrow} title={title} />
      <section className="rounded-card border border-line bg-white p-6 shadow-card">
        <p className="text-sm text-muted">이 화면은 준비 중입니다.</p>
      </section>
    </div>
  );
}
