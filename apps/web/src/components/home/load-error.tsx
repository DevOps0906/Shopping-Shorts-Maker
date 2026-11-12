"use client";

import { startTransition } from "react";
import { useRouter } from "next/navigation";
import { InlineBanner } from "@/components/feedback";
import { btnClass, btnSmClass } from "@/components/projects/ui";
import { cn } from "@/lib/utils";

/**
 * 화면 로드 오류 — 오류 안내 + 다시 시도(docs/03_SCREENS_UX.md 상태 표).
 * 원문 오류는 보여 주지 않는다. onRetry가 없으면 서버 데이터를 다시 불러온다.
 */
export function LoadError({ message, onRetry }: { message: string; onRetry?: () => void }) {
  const router = useRouter();
  return (
    <InlineBanner
      tone="error"
      action={
        <button
          type="button"
          className={cn(btnClass, btnSmClass)}
          onClick={() => {
            // 서버 컴포넌트를 다시 불러오고, error.tsx 경계면 reset으로 다시 그린다
            startTransition(() => {
              router.refresh();
              onRetry?.();
            });
          }}
        >
          다시 시도
        </button>
      }
    >
      <p className="font-bold">{message}</p>
      <p>잠시 뒤 다시 시도해 주세요. 문제가 계속되면 새로 고침해 주세요.</p>
    </InlineBanner>
  );
}

/** 마지막 갱신 옆 ↻ — 서버 데이터를 다시 불러온다 */
export function RefreshButton() {
  const router = useRouter();
  return (
    <button
      type="button"
      onClick={() => router.refresh()}
      className="inline-flex min-h-9 items-center rounded-btn-sm px-2 text-xs font-semibold text-accent hover:bg-sub-hover"
      aria-label="지표 다시 불러오기"
    >
      ↻ 새로 고침
    </button>
  );
}
