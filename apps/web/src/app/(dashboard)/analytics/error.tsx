"use client";

import { LoadError } from "@/components/home/load-error";

/** 원문 오류는 보여 주지 않고 다시 시도만 안내한다 */
export default function AnalyticsError({ reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <div className="mx-auto flex max-w-(--content-max) flex-col gap-4">
      <LoadError message="성과 지표를 불러오지 못했습니다" onRetry={reset} />
    </div>
  );
}
