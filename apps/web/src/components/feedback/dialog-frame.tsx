"use client";

import { type KeyboardEvent, type ReactNode, type Ref } from "react";
import { cn } from "@/lib/utils";

/** 모달·알림 대화상자 공용 스크림 + 패널. 기본 모션은 아래에서 translate-y-2 + 페이드(--motion-fast). */
export function DialogFrame({
  panelRef,
  role,
  labelledBy,
  describedBy,
  onKeyDown,
  onScrimClick,
  className,
  children,
}: {
  panelRef: Ref<HTMLDivElement>;
  role: "dialog" | "alertdialog";
  labelledBy: string;
  describedBy?: string;
  onKeyDown: (event: KeyboardEvent<HTMLElement>) => void;
  onScrimClick?: () => void;
  className?: string;
  children: ReactNode;
}) {
  return (
    <div
      className="fixed inset-0 z-(--z-overlay) flex items-center justify-center bg-(--scrim) px-(--content-px) transition-opacity duration-(--motion-fast) starting:opacity-0 motion-reduce:transition-none"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onScrimClick?.();
      }}
    >
      <div
        ref={panelRef}
        role={role}
        aria-modal="true"
        aria-labelledby={labelledBy}
        aria-describedby={describedBy}
        tabIndex={-1}
        onKeyDown={onKeyDown}
        className={cn(
          "w-full max-w-(--toast-max-w) rounded-card bg-white p-6 text-ink shadow-card transition-[opacity,translate] duration-(--motion-fast) starting:translate-y-2 starting:opacity-0 motion-reduce:transition-none",
          className,
        )}
      >
        {children}
      </div>
    </div>
  );
}

export const dialogButton =
  "inline-flex min-h-11 items-center justify-center rounded-btn px-4 text-sm font-bold";
