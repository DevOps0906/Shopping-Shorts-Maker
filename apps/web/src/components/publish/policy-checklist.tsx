"use client";

import { useId } from "react";
import { POLICY_ITEMS, type PolicyCheck, type PolicyResult, passedCount } from "@/lib/publish/rules";
import { cn } from "@/lib/utils";
import { switchClass } from "./affiliate-picker";

/*
 * 권리 · 정책 점검 6항목 — planning 15-4(정본) · design 5-7. "N / 6 통과" 진행 바.
 * 판정은 DB(publish_policy). 사용자 체크는 출처 표기·고지 확인만 여기서, 구매 경로의 사용자 체크는 링크인바이오 등록 완료 스위치.
 */

const MARK: Record<PolicyResult, { icon: string; label: string; className: string }> = {
  pass: { icon: "✓", label: "통과", className: "bg-success-bg text-success-fg" },
  pending: { icon: "…", label: "확인 필요", className: "bg-warning-bg text-warning-fg" },
  fail: { icon: "!", label: "미통과", className: "bg-danger-bg text-danger-fg" },
};

type PolicyChecklistProps = {
  items: PolicyCheck[];
  attributionChecked: boolean;
  credits: string;
  disabled: boolean;
  onAttribution: (on: boolean) => void;
};

export function PolicyChecklist({ items, attributionChecked, credits, disabled, onAttribution }: PolicyChecklistProps) {
  const checkId = useId();
  const passed = passedCount(items);
  const total = POLICY_ITEMS.length;

  return (
    <section aria-label="권리 · 정책 점검" className="flex flex-col gap-3 rounded-card border border-line bg-white p-4 shadow-card tablet:p-6">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <p className="text-sm font-semibold">권리 · 정책 점검</p>
        <p className="text-sm font-bold" aria-live="polite">
          {passed} / {total} 통과
        </p>
      </div>
      <div role="progressbar" aria-label="정책 점검 통과" aria-valuemin={0} aria-valuemax={total} aria-valuenow={passed} className="grid grid-cols-6 gap-1">
        {POLICY_ITEMS.map((p) => (
          <span key={p.id} className={cn("h-2 rounded-pill", items.find((i) => i.item === p.id)?.result === "pass" ? "bg-success-fg" : "bg-line")} />
        ))}
      </div>
      <ol className="flex flex-col gap-2">
        {POLICY_ITEMS.map((p, index) => {
          const check = items.find((i) => i.item === p.id);
          const mark = MARK[check?.result ?? "fail"];
          return (
            <li key={p.id} className="flex items-start gap-3 rounded-btn border border-line px-3 py-2">
              <span aria-hidden="true" className={cn("flex size-6 shrink-0 items-center justify-center rounded-pill text-xs font-bold", mark.className)}>
                {mark.icon}
              </span>
              <div className="flex min-w-0 flex-1 flex-col gap-1">
                <p className="flex flex-wrap items-baseline gap-x-2 text-sm">
                  <span className="font-semibold">
                    {index + 1}. {p.label}
                  </span>
                  <span className="text-xs text-muted">{p.kind}</span>
                  <span className="sr-only">{mark.label}</span>
                </p>
                <p className="text-xs text-muted">{check?.detail}</p>
                {p.id === "attribution_notice" ? (
                  <>
                    {credits ? <p className="text-xs">설명란 출처 문구: {credits}</p> : null}
                    <label htmlFor={checkId} className="flex min-h-11 items-center gap-2 text-sm">
                      <input
                        id={checkId}
                        type="checkbox"
                        checked={attributionChecked}
                        disabled={disabled}
                        onChange={(e) => onAttribution(e.target.checked)}
                        className={switchClass}
                      />
                      <span>쓴 원본의 출처가 영상과 설명란에 들어갔고, 02 소스의 고지를 확인했습니다</span>
                    </label>
                  </>
                ) : null}
              </div>
            </li>
          );
        })}
      </ol>
    </section>
  );
}
