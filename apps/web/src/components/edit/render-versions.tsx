"use client";

import { useState } from "react";
import { formatDateTime } from "@/components/projects/project-view";
import { btnClass } from "@/components/studio/step-actions";
import type { RenderView } from "@/lib/edit/plan";
import { cn } from "@/lib/utils";

/*
 * S-10 검토본 카드 + 버전 목록(docs/planning.md 3장 05): "최신 수정본 · V1", 생성 시각, 9:16 미리보기, 다운로드.
 * 수정할 때마다 V2, V3로 쌓인다. 영상 주소는 10분짜리 서명 URL(공개 URL 아님).
 */

export function RenderVersions({ renders }: { renders: RenderView[] }) {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const latest = renders[0] ?? null;
  const shown = renders.find((r) => r.id === selectedId) ?? latest;

  return (
    <section aria-label="검토본" className="flex flex-col gap-3 rounded-card border border-line bg-white p-4 shadow-card tablet:p-6">
      <p className="text-sm font-semibold">검토본</p>
      {!shown ? (
        <p className="text-sm text-muted">아직 검토본이 없습니다. 위에서 MP4를 만들면 V1이 생기고, 검토본이 1개 이상이면 승인할 수 있습니다.</p>
      ) : (
        <div className="flex flex-col gap-4 tablet:flex-row">
          <div className="w-full max-w-90 shrink-0 self-center tablet:w-60 tablet:self-start desktop:w-72">
            {shown.videoUrl ? (
              <video
                key={shown.id}
                controls
                preload="metadata"
                playsInline
                src={shown.videoUrl}
                aria-label={`검토본 V${shown.version} 9:16 미리보기`}
                className="aspect-9/16 w-full rounded-btn bg-ink"
              />
            ) : (
              <div className="flex aspect-9/16 w-full items-center justify-center rounded-btn border border-dashed border-line p-4 text-center text-sm text-muted">
                영상을 불러오지 못했습니다. 화면을 새로 고쳐 주세요.
              </div>
            )}
          </div>
          <div className="flex min-w-0 flex-1 flex-col gap-3">
            <div className="flex flex-col gap-1">
              <p className="text-base font-bold">
                {shown.id === latest?.id ? "최신 수정본" : "이전 수정본"} · V{shown.version}
              </p>
              <p className="text-xs text-muted">
                생성 {formatDateTime(shown.createdAt)}
                {shown.durationSec !== null ? ` · ${shown.durationSec.toFixed(1)}초` : null} · 9:16
              </p>
              {shown.credits ? <p className="text-xs text-muted">{shown.credits}</p> : null}
            </div>
            {shown.videoUrl ? (
              <a href={shown.videoUrl} download={`V${shown.version}.mp4`} className={cn(btnClass, "self-start")}>
                다운로드
              </a>
            ) : null}
            {renders.length > 1 ? (
              <div className="flex flex-col gap-2">
                <p className="text-xs font-semibold text-muted">버전 목록</p>
                <ul className="flex flex-wrap gap-2">
                  {renders.map((r) => (
                    <li key={r.id}>
                      <button
                        type="button"
                        onClick={() => setSelectedId(r.id)}
                        aria-pressed={r.id === shown.id}
                        className={cn(btnClass, r.id === shown.id && "border-accent bg-accent-weak")}
                      >
                        V{r.version}
                        <span className="text-xs font-normal text-muted">{formatDateTime(r.createdAt)}</span>
                      </button>
                    </li>
                  ))}
                </ul>
              </div>
            ) : null}
          </div>
        </div>
      )}
    </section>
  );
}
