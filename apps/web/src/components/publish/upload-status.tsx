"use client";

import Link from "next/link";
import { InlineBanner } from "@/components/feedback";
import { btnClass } from "@/components/studio/step-actions";
import { formatSlot } from "@/lib/publish/rules";
import { cn } from "@/lib/utils";
import type { PublicationView } from "@/server/publish/publish";
import { uploadStatusView } from "./upload-status-copy";

/** 06 발행 업로드 상태(표시·다시 시도만). 상태 전환은 업로더·DB 함수가 한다 */
export function UploadStatus({
  publication,
  busy,
  onRetry,
  onConfirmAbsent,
}: {
  publication: PublicationView;
  busy: boolean;
  onRetry: () => void;
  /** Studio 에 영상이 없음을 사용자가 확인(위험 확인 대화상자는 부모가 띄운다) */
  onConfirmAbsent: () => void;
}) {
  const view = uploadStatusView(publication, (iso) => formatSlot(new Date(iso)));
  if (!view) return null;

  const actions =
    view.retry || view.studioUrl || view.reconnect || view.confirmAbsent ? (
      <div className="flex flex-wrap gap-2">
        {view.studioUrl ? (
          <a href={view.studioUrl} target="_blank" rel="noopener noreferrer" className={btnClass}>
            YouTube Studio 열기
          </a>
        ) : null}
        {view.reconnect ? (
          <Link href="/settings/accounts" className={btnClass}>
            채널 다시 연결
          </Link>
        ) : null}
        {view.retry ? (
          <button type="button" onClick={onRetry} disabled={busy} aria-busy={busy} className={btnClass}>
            {busy ? "요청하는 중…" : "다시 시도"}
          </button>
        ) : null}
        {view.confirmAbsent ? (
          <button
            type="button"
            onClick={onConfirmAbsent}
            disabled={busy}
            className={cn(btnClass, "border-danger-fg text-danger-fg")}
          >
            영상 없음 확인 · 새로 업로드
          </button>
        ) : null}
      </div>
    ) : undefined;

  if (view.tone === "info") {
    return (
      <p role="status" className="text-sm text-muted">
        {view.message}
      </p>
    );
  }
  return (
    <InlineBanner tone={view.tone} action={actions}>
      {view.message}
    </InlineBanner>
  );
}
