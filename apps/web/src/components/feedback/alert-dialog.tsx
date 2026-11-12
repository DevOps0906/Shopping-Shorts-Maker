"use client";

import { useId, useRef } from "react";
import { AUTOFOCUS_ATTR } from "@/lib/feedback/focus";
import type { ConfirmOptions } from "@/lib/feedback/types";
import { cn } from "@/lib/utils";
import { DialogFrame, dialogButton } from "./dialog-frame";
import { useDialogFocus } from "./use-dialog-focus";

type AlertDialogProps = ConfirmOptions & {
  onConfirm: () => void;
  onCancel: () => void;
};

/**
 * role="alertdialog" + aria-describedby. 첫 포커스는 취소, Esc = 취소,
 * 배경 클릭으로 닫히지 않는다(docs/ui-feedback.md 3-4).
 */
export function AlertDialog({
  title,
  description,
  confirmLabel,
  cancelLabel = "취소",
  danger = false,
  onConfirm,
  onCancel,
}: AlertDialogProps) {
  const ref = useRef<HTMLDivElement>(null);
  const titleId = useId();
  const descId = useId();
  const onKeyDown = useDialogFocus(ref, onCancel);
  const autofocus = { [AUTOFOCUS_ATTR]: "" };

  return (
    <DialogFrame panelRef={ref} role="alertdialog" labelledBy={titleId} describedBy={descId} onKeyDown={onKeyDown}>
      <h2 id={titleId} className="text-base font-bold">
        {title}
      </h2>
      <p id={descId} className="mt-2 text-sm text-muted">
        {description}
      </p>
      <div className="mt-6 flex justify-end gap-2">
        <button
          type="button"
          {...autofocus}
          onClick={onCancel}
          className={cn(dialogButton, "border border-line bg-white text-ink hover:bg-nav-hover")}
        >
          {cancelLabel}
        </button>
        <button
          type="button"
          onClick={onConfirm}
          className={cn(dialogButton, danger ? "bg-danger-fg text-white" : "bg-accent text-white")}
        >
          {confirmLabel}
        </button>
      </div>
    </DialogFrame>
  );
}
