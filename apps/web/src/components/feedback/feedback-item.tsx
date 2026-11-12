"use client";

import { type FocusEvent, useEffect, useRef, useState } from "react";
import { durationOf } from "@/lib/feedback/queue";
import { type PausableTimer, createPausableTimer } from "@/lib/feedback/timer";
import type { FeedbackItem } from "@/lib/feedback/types";

const ICON: Partial<Record<FeedbackItem["tone"], { char: string; className: string }>> = {
  success: { char: "✓", className: "text-success-line" },
  error: { char: "!", className: "text-alert" },
};

/**
 * 토스트(액션 없음)·스낵바(버튼 1개). 포커스를 옮기지 않고, 포인터 올림·포커스 중엔 타이머를 멈춘다.
 * 포커스가 안에 있으면 Esc로 닫는다(docs/ui-feedback.md 3-3·3-4).
 */
export function FeedbackItemView({ item, onDismiss }: { item: FeedbackItem; onDismiss: (id: string) => void }) {
  const [hovered, setHovered] = useState(false);
  const [focused, setFocused] = useState(false);
  const timer = useRef<PausableTimer | null>(null);
  const ms = durationOf(item);
  const { id, rev } = item;

  useEffect(() => {
    if (ms === null) return;
    const t = createPausableTimer(() => onDismiss(id), ms);
    timer.current = t;
    return () => {
      t.clear();
      timer.current = null;
    };
  }, [id, rev, ms, onDismiss]);

  useEffect(() => {
    if (hovered || focused) timer.current?.pause();
    else timer.current?.resume();
  }, [hovered, focused, rev]);

  const onBlur = (event: FocusEvent<HTMLDivElement>) => {
    if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setFocused(false);
  };
  const icon = ICON[item.tone];
  const isError = item.tone === "error";

  return (
    <div
      data-feedback-item={item.kind}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      onFocus={() => setFocused(true)}
      onBlur={onBlur}
      onKeyDown={(event) => {
        if (event.key === "Escape") onDismiss(id);
      }}
      className="pointer-events-auto flex w-full max-w-(--toast-max-w) items-center gap-3 rounded-btn bg-ink px-4 py-3 text-sm text-white shadow-fab transition-[opacity,translate] duration-(--motion-fast) starting:translate-y-2 starting:opacity-0 motion-reduce:transition-none"
    >
      {icon ? (
        <span aria-hidden="true" className={`font-bold ${icon.className}`}>
          {icon.char}
        </span>
      ) : null}
      <p className="min-w-0 flex-1">{item.message}</p>
      {item.action ? (
        <button
          type="button"
          onClick={() => {
            item.action?.onAction();
            onDismiss(id);
          }}
          className="shrink-0 rounded-btn-sm px-2 py-1 font-bold text-accent-line hover:underline"
        >
          {item.action.label}
        </button>
      ) : null}
      {isError ? (
        <button
          type="button"
          aria-label="알림 닫기"
          onClick={() => onDismiss(id)}
          className="shrink-0 rounded-btn-sm px-2 py-1 text-white"
        >
          <span aria-hidden="true">×</span>
        </button>
      ) : null}
    </div>
  );
}
