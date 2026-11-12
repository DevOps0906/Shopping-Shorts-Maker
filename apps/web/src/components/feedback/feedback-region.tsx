"use client";

import type { Ref } from "react";
import { isError } from "@/lib/feedback/queue";
import type { FeedbackItem } from "@/lib/feedback/types";
import { cn } from "@/lib/utils";
import { FeedbackItemView } from "./feedback-item";

/**
 * 알림 영역 (docs/ui-feedback.md 3-1·3-4).
 * - 모바일·태블릿: 작업 영역 하단 가운데, FAB 위. 제작 파트너 팝업이 열리면 위쪽 가운데.
 * - 데스크톱: 작업 영역 하단 가운데, 아래 --fab-inset. 팝업이 열리면 오른쪽 경계를 팝업 왼쪽 − --toast-gap.
 * 컨테이너 2개(status·alert)는 처음부터 DOM에 있고 내용만 바뀐다.
 */
export function FeedbackRegion({
  items,
  partnerOpen,
  onDismiss,
  regionRef,
}: {
  items: FeedbackItem[];
  partnerOpen: boolean;
  onDismiss: (id: string) => void;
  regionRef?: Ref<HTMLDivElement>;
}) {
  const errors = items.filter(isError);
  const infos = items.filter((it) => !isError(it));
  const stack = "flex w-full flex-col items-center gap-(--toast-gap)";

  return (
    <div
      ref={regionRef}
      data-partner={partnerOpen ? "open" : "closed"}
      className={cn(
        "pointer-events-none fixed z-(--z-toast) flex flex-col items-center",
        "right-(--content-px) left-[calc(var(--gnb-w)+var(--content-px))]",
        "bottom-[calc(var(--fab-inset)+var(--fab-size)+var(--toast-gap)+env(safe-area-inset-bottom))]",
        "max-desktop:data-[partner=open]:top-[calc(var(--content-pt)+env(safe-area-inset-top))] max-desktop:data-[partner=open]:bottom-auto",
        "desktop:bottom-(--fab-inset)",
        "desktop:data-[partner=open]:right-[calc(var(--fab-inset)+var(--partner-w)+var(--toast-gap))]",
      )}
    >
      <div role="alert" className={cn(stack, errors.length > 0 && infos.length > 0 && "mb-(--toast-gap)")}>
        {errors.map((it) => (
          <FeedbackItemView key={it.id} item={it} onDismiss={onDismiss} />
        ))}
      </div>
      <div role="status" aria-live="polite" className={stack}>
        {infos.map((it) => (
          <FeedbackItemView key={it.id} item={it} onDismiss={onDismiss} />
        ))}
      </div>
    </div>
  );
}
