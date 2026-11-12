"use client";

import { btnClass, btnPrimaryClass } from "@/components/studio/step-actions";
import { cn } from "@/lib/utils";

/** 단계 화면 오류 — 원문 오류는 보여 주지 않고 다시 시도만 안내한다 */
export default function StudioStepError({ reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <div className="mx-auto flex max-w-(--content-max) flex-col gap-4">
      <section
        role="alert"
        className="flex flex-col items-start gap-3 rounded-card border border-line bg-danger-bg p-6 text-danger-fg"
      >
        <p className="text-base font-bold">제작단계를 불러오지 못했습니다</p>
        <p className="text-sm">잠시 뒤 다시 시도해 주세요. 문제가 계속되면 프로젝트 관리에서 프로젝트를 다시 열어 주세요.</p>
        <button type="button" onClick={reset} className={cn(btnClass, btnPrimaryClass)}>
          다시 시도
        </button>
      </section>
    </div>
  );
}
