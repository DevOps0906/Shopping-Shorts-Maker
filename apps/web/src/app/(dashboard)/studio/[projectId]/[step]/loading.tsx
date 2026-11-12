/** 단계 화면 로딩 — 프로젝트 줄·스텝퍼·배너 자리를 먼저 보여 준다 */
export default function StudioStepLoading() {
  const block = "animate-pulse rounded-card border border-line bg-white shadow-card";
  return (
    <div className="mx-auto flex max-w-(--content-max) flex-col gap-4" aria-busy="true">
      <p role="status" className="text-sm text-muted">
        제작단계를 불러오는 중입니다…
      </p>
      <div className={`${block} h-14`} />
      <div className={`${block} h-36`} />
      <div className={`${block} h-20`} />
      <div className={`${block} h-48`} />
    </div>
  );
}
