import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

export type BannerTone = "error" | "warning" | "success";

const TONE: Record<BannerTone, { icon: string; role: "alert" | "status"; className: string }> = {
  error: { icon: "!", role: "alert", className: "bg-danger-bg text-danger-fg" },
  warning: { icon: "⚠", role: "alert", className: "bg-warning-bg text-warning-fg" },
  success: { icon: "✓", role: "status", className: "bg-success-bg text-success-fg" },
};

/**
 * 화면 안 인라인 배너(오류·경고·성공). 자동으로 닫히지 않는다 — 원인이 해소될 때까지 남는다
 * (docs/ui-feedback.md 2장 #4·#10·#14, 4장). 색만으로 구분하지 않도록 아이콘 + 텍스트.
 */
export function InlineBanner({
  tone,
  children,
  action,
  className,
}: {
  tone: BannerTone;
  children: ReactNode;
  /** 다시 시도·이동 등 버튼 1개 */
  action?: ReactNode;
  className?: string;
}) {
  const t = TONE[tone];
  return (
    <div
      role={t.role}
      className={cn("flex items-start gap-3 rounded-btn px-4 py-3 text-sm", t.className, className)}
    >
      <span aria-hidden="true" className="font-bold">
        {t.icon}
      </span>
      <div className="min-w-0 flex-1">{children}</div>
      {action ? <div className="shrink-0">{action}</div> : null}
    </div>
  );
}
