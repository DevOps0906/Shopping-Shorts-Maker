"use client";

import { useRef } from "react";
import { useFeedback } from "@/components/feedback";
import { btnClass } from "@/components/studio/step-actions";

/** YouTube 연결 해제 — 공용 알림 대화상자(위험 색)로 확인한 뒤 폼 POST(docs/ui-feedback.md 알림 대화상자) */
export function DisconnectButton({ accountId }: { accountId: string }) {
  const fb = useFeedback();
  const formRef = useRef<HTMLFormElement>(null);

  async function confirmDisconnect() {
    const ok = await fb.confirm({
      title: "YouTube 연결을 해제할까요?",
      description: "예약된 업로드가 실패할 수 있습니다.",
      confirmLabel: "연결 해제",
      cancelLabel: "취소",
      danger: true,
    });
    if (ok) formRef.current?.requestSubmit();
  }

  return (
    <form ref={formRef} method="post" action="/api/oauth/youtube/disconnect">
      <input type="hidden" name="accountId" value={accountId} />
      <button type="button" onClick={confirmDisconnect} className={btnClass}>
        연결 해제
      </button>
    </form>
  );
}
