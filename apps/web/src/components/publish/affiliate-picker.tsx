"use client";

import { useId, useState } from "react";
import { btnClass, btnPrimaryClass } from "@/components/studio/step-actions";
import { PROGRAMS, type ProgramId, isLinkProgram } from "@/lib/publish/rules";
import { cn } from "@/lib/utils";

/*
 * 제휴 프로그램 카드 — docs/design.md 5-7 · planning 15-1 · 16-2.
 * 8개 선택 카드(추천 배지) · 상품 제휴 링크 입력 · 자동 찾기(준비 중) · 고지 문구 자동 삽입 스위치 · 고정 댓글 구매 안내 스위치.
 * 링크 저장은 서버가 프로그램별 허용 도메인을 검사하고 서버(SR)만 url 을 쓴다.
 */

export const inputClass = "min-h-11 w-full rounded-btn border border-line bg-white px-3 text-base text-ink disabled:bg-sub-hover disabled:text-muted";
export const switchClass = "size-4 shrink-0 accent-accent";

type AffiliatePickerProps = {
  program: ProgramId | null;
  url: string | null;
  disclosed: boolean;
  pinComment: boolean;
  recommended: ProgramId[];
  disabled: boolean;
  onProgram: (program: ProgramId) => void;
  onUrl: (url: string) => void;
  onDisclosed: (on: boolean) => void;
  onPinComment: (on: boolean) => void;
};

export function AffiliatePicker({
  program,
  url,
  disclosed,
  pinComment,
  recommended,
  disabled,
  onProgram,
  onUrl,
  onDisclosed,
  onPinComment,
}: AffiliatePickerProps) {
  const ids = { url: useId(), disclosed: useId(), pin: useId(), find: useId() };
  const [draft, setDraft] = useState(url ?? "");
  const linkType = isLinkProgram(program);
  const usesAffiliate = program !== null && program !== "none";

  return (
    <section aria-label="제휴 프로그램" className="flex flex-col gap-3 rounded-card border border-line bg-white p-4 shadow-card tablet:p-6">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <p className="text-sm font-semibold">제휴 프로그램</p>
        <p className="text-xs text-muted">채널 카테고리·플랫폼에 맞는 곳에 추천 표시</p>
      </div>
      <div role="radiogroup" aria-label="제휴 프로그램 8개" className="grid grid-cols-2 gap-2 tablet:grid-cols-4">
        {PROGRAMS.map((p) => {
          const on = program === p.id;
          return (
            <button
              key={p.id}
              type="button"
              role="radio"
              aria-checked={on}
              disabled={disabled}
              onClick={() => onProgram(p.id)}
              className={cn(
                "flex min-h-11 flex-col items-start gap-1 rounded-btn border px-3 py-2 text-left text-sm disabled:cursor-not-allowed",
                on ? "border-accent bg-accent-weak" : "border-line bg-white hover:border-accent-line",
              )}
            >
              <span className="flex flex-wrap items-center gap-1.5 font-semibold">
                {p.label}
                {recommended.includes(p.id) ? (
                  <span className="rounded-pill bg-success-bg px-2 py-0.5 text-xs font-bold text-success-fg">추천</span>
                ) : null}
              </span>
              <span className="text-xs text-muted">{p.hint}</span>
            </button>
          );
        })}
      </div>

      {linkType ? (
        <div className="flex flex-col gap-1">
          <label htmlFor={ids.url} className="text-xs text-muted">
            상품 제휴 링크
          </label>
          <div className="flex flex-col gap-2 tablet:flex-row">
            <input
              id={ids.url}
              type="url"
              inputMode="url"
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              placeholder="https://"
              maxLength={2048}
              disabled={disabled}
              className={inputClass}
            />
            <div className="flex gap-2">
              <button type="button" disabled={disabled || draft.trim() === (url ?? "")} onClick={() => onUrl(draft)} className={cn(btnClass, btnPrimaryClass)}>
                링크 저장
              </button>
              <button type="button" disabled aria-describedby={ids.find} className={cn(btnClass, "opacity-60")}>
                자동 찾기
              </button>
            </div>
          </div>
          <p id={ids.find} className="text-xs text-muted">
            자동 찾기: 준비 중. 제휴 프로그램에서 만든 상품 링크를 붙여 넣어 주세요. {url ? "저장됨" : "아직 저장된 링크가 없습니다."}
          </p>
        </div>
      ) : null}
      {program === "youtube_shopping" ? (
        <p className="text-sm text-muted">YouTube Studio에서 영상에 쇼핑 상품 태그를 붙입니다. 링크 입력은 필요 없습니다.</p>
      ) : null}

      <div className="flex flex-col gap-1 border-t border-line pt-3 text-sm">
        <label htmlFor={ids.disclosed} className="flex min-h-11 items-center gap-2">
          <input
            id={ids.disclosed}
            type="checkbox"
            role="switch"
            checked={disclosed}
            disabled={disabled || !usesAffiliate}
            onChange={(e) => onDisclosed(e.target.checked)}
            className={switchClass}
          />
          <span>고지 문구 자동 삽입(설명란 첫머리 · 링크인바이오 한 줄 공지)</span>
        </label>
        {usesAffiliate && !disclosed ? <p className="text-xs text-danger-fg">고지 문구를 끄면 정책 점검(제휴 고지)을 통과하지 못해 발행할 수 없습니다.</p> : null}
        <label htmlFor={ids.pin} className="flex min-h-11 items-center gap-2">
          <input
            id={ids.pin}
            type="checkbox"
            role="switch"
            checked={pinComment}
            disabled={disabled || !usesAffiliate}
            onChange={(e) => onPinComment(e.target.checked)}
            className={switchClass}
          />
          <span>고정 댓글 구매 안내(“구매 정보는 프로필 링크 N번” 문구, 링크는 달지 않음)</span>
        </label>
      </div>
    </section>
  );
}
