"use client";

import { useEffect, useState } from "react";
import { cn } from "@/lib/utils";
import type { BannerContent } from "@/lib/steps/banner";

/*
 * 상태 배너 — docs/design.md 5-6 ③: 대기 · 진행 중(초 단위 경과) · AI 제안 · 준비 완료 · 변경 요청 · 승인
 * 시각 참고: design/prototype/Main.dc.html .banner(.run · .ready · .ok)
 */

const toneClass: Record<BannerContent["tone"], string> = {
  idle: "bg-white border-l-accent-line",
  run: "bg-accent-weak border-accent-line border-l-accent",
  ready: "bg-warning-bg border-l-warning-fg",
  ok: "bg-success-bg border-l-success-line",
};

function BannerIcon({ tone }: { tone: BannerContent["tone"] }) {
  switch (tone) {
    case "run":
      return (
        <span
          aria-hidden="true"
          className="inline-block size-3.5 shrink-0 animate-spin rounded-full border-2 border-accent-line border-t-accent"
        />
      );
    case "ready":
      return <span aria-hidden="true" className="inline-block size-2.25 shrink-0 rounded-full bg-accent" />;
    case "ok":
      return (
        <svg
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2.4"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
          className="size-4 shrink-0 text-success-line"
        >
          <path d="M5 12l5 5 9-10" />
        </svg>
      );
    case "idle":
      return <span aria-hidden="true" className="inline-block size-3.5 shrink-0 rounded-full border-2 border-add-line" />;
  }
}

type StatusBannerProps = {
  content: BannerContent;
  /** 진행 중일 때 경과 초의 기준(jobs.started_at). 없으면 배너가 진행 중으로 바뀐 시각부터 센다. */
  startedAt?: string | null;
};

export function StatusBanner({ content, startedAt }: StatusBannerProps) {
  const isRun = content.tone === "run";
  const [elapsed, setElapsed] = useState<number | null>(null);

  useEffect(() => {
    if (!isRun) return;
    const parsed = startedAt ? Date.parse(startedAt) : Number.NaN;
    const base = Number.isNaN(parsed) ? Date.now() : parsed;
    const tick = () => setElapsed(Math.max(0, Math.floor((Date.now() - base) / 1000)));
    const first = setTimeout(tick, 0);
    const timer = setInterval(tick, 1000);
    return () => {
      clearTimeout(first);
      clearInterval(timer);
    };
  }, [isRun, startedAt]);

  return (
    <div
      className={cn(
        "relative flex items-start justify-between gap-3 overflow-hidden rounded-card border border-line border-l-4 px-4 py-3.5 transition-colors tablet:px-5 tablet:py-4",
        toneClass[content.tone],
      )}
    >
      {/* 상태 전이만 읽어 준다. 매초 바뀌는 경과 시간은 이 영역 밖에 둔다. */}
      <div role="status" aria-live="polite" className="min-w-0">
        <p className="flex items-center gap-2 text-base font-bold">
          <BannerIcon tone={content.tone} />
          {content.title}
        </p>
        <p className="mt-0.5 text-sm text-muted">{content.description}</p>
      </div>
      {isRun ? (
        <>
          <span className="text-xs whitespace-nowrap text-muted">{elapsed === null ? "" : `${elapsed}초 경과`}</span>
          <span aria-hidden="true" className="absolute inset-x-0 bottom-0 h-0.75 overflow-hidden bg-accent-line">
            <span className="absolute inset-y-0 left-0 w-1/3 animate-pulse rounded-pill bg-accent" />
          </span>
        </>
      ) : null}
    </div>
  );
}
