/*
 * 현재 프로젝트 줄 — docs/design.md 5-6 ①: 카테고리 태그 · 프로젝트명 · 채널 · 저장 시각.
 * 프로젝트 삭제·처음부터 다시 버튼은 프로젝트 관리 작업에서 붙인다.
 * 시각 참고: design/prototype/Main.dc.html .projbar · .ctag
 */

type ProjectBarProps = {
  name: string;
  categoryName: string | null;
  channelName: string | null;
  updatedAt: string;
};

const savedAtFormat = new Intl.DateTimeFormat("ko-KR", {
  timeZone: "Asia/Seoul",
  month: "numeric",
  day: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  hour12: false,
});

export function ProjectBar({ name, categoryName, channelName, updatedAt }: ProjectBarProps) {
  return (
    <section
      aria-label="현재 프로젝트"
      className="flex flex-wrap items-center gap-2.5 rounded-card border border-line bg-white px-4 py-3.5 shadow-card"
    >
      {categoryName ? (
        <span className="inline-flex items-center rounded-pill bg-hot-bg px-2.5 py-0.75 text-xs font-bold whitespace-nowrap text-hot-fg">
          {categoryName}
        </span>
      ) : null}
      <b className="text-base">{name}</b>
      <span className="text-xs text-muted">
        {channelName ?? "채널 없음"} · 저장됨 <time dateTime={updatedAt}>{savedAtFormat.format(new Date(updatedAt))}</time>
      </span>
    </section>
  );
}
