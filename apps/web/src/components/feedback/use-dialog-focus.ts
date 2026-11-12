"use client";

import { type KeyboardEvent, type RefObject, useEffect, useRef } from "react";
import { AUTOFOCUS_ATTR, FOCUSABLE, dialogKeyAction } from "@/lib/feedback/focus";

const INPUTS = "input:not([disabled]), select:not([disabled]), textarea:not([disabled])";

/**
 * 열릴 때 첫 포커스(data-autofocus → 첫 입력칸 → 첫 포커스 가능 요소),
 * 안에서 Tab 순환, Esc로 닫기, 닫히면 트리거로 포커스 복귀 (docs/ui-feedback.md 3-4).
 */
export function useDialogFocus(ref: RefObject<HTMLElement | null>, onClose: () => void) {
  const onCloseRef = useRef(onClose);
  useEffect(() => {
    onCloseRef.current = onClose;
  });

  useEffect(() => {
    const root = ref.current;
    if (!root) return;
    const trigger = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const first =
      root.querySelector<HTMLElement>(`[${AUTOFOCUS_ATTR}]`) ??
      root.querySelector<HTMLElement>(INPUTS) ??
      root.querySelector<HTMLElement>(FOCUSABLE) ??
      root;
    first.focus();
    return () => {
      if (trigger?.isConnected) trigger.focus();
    };
  }, [ref]);

  return (event: KeyboardEvent<HTMLElement>) => {
    const root = ref.current;
    if (!root) return;
    const items = Array.from(root.querySelectorAll<HTMLElement>(FOCUSABLE));
    const index = items.indexOf(document.activeElement as HTMLElement);
    const result = dialogKeyAction(event.key, event.shiftKey, index, items.length);
    if (!result) return;
    event.preventDefault();
    if (result.type === "close") onCloseRef.current();
    else items[result.index]?.focus();
  };
}
