"use client";

import { type ReactNode, useId, useRef } from "react";
import { DialogFrame } from "./dialog-frame";
import { useDialogFocus } from "./use-dialog-focus";

type ModalProps = {
  open: boolean;
  title: string;
  /** Esc·취소·배경 클릭 */
  onClose: () => void;
  /** 본문과 버튼(취소 포함)을 함께 넣는다. 모달 위에 모달을 열지 않는다(docs/ui-feedback.md 4장). */
  children: ReactNode;
};

/** role="dialog" aria-modal. 첫 입력칸에 포커스, 포커스 트랩, Esc로 닫고 트리거로 복귀. */
export function Modal({ open, ...rest }: ModalProps) {
  if (!open) return null;
  return <ModalBody {...rest} />;
}

function ModalBody({ title, onClose, children }: Omit<ModalProps, "open">) {
  const ref = useRef<HTMLDivElement>(null);
  const titleId = useId();
  const onKeyDown = useDialogFocus(ref, onClose);
  return (
    <DialogFrame panelRef={ref} role="dialog" labelledBy={titleId} onKeyDown={onKeyDown} onScrimClick={onClose}>
      <h2 id={titleId} className="text-base font-bold">
        {title}
      </h2>
      <div className="mt-3 text-sm">{children}</div>
    </DialogFrame>
  );
}
