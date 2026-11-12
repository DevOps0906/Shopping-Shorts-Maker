import { cn } from "@/lib/utils";

const block = "animate-pulse rounded-card border border-line bg-white shadow-card";

/** 로딩 스켈레톤 — 지표 카드·목록·표 자리를 먼저 보여 준다 */
export function PageSkeleton({ label, cards = 0, rows = 2 }: { label: string; cards?: number; rows?: number }) {
  return (
    <div className="mx-auto flex max-w-(--content-max) flex-col gap-4" aria-busy="true">
      <p role="status" className="text-sm text-muted">
        {label}
      </p>
      {cards > 0 ? (
        <div className={cn("grid grid-cols-2 gap-3.5", cards === 3 ? "desktop:grid-cols-3" : "desktop:grid-cols-4")}>
          {Array.from({ length: cards }, (_, i) => (
            <div key={i} className={`${block} h-24`} />
          ))}
        </div>
      ) : null}
      {Array.from({ length: rows }, (_, i) => (
        <div key={i} className={`${block} h-48`} />
      ))}
    </div>
  );
}
