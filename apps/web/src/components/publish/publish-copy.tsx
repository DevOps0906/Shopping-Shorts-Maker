"use client";

import { useId } from "react";
import { btnClass } from "@/components/studio/step-actions";
import { BODY_MAX, TITLE_MAX } from "@/lib/publish/rules";
import { cn } from "@/lib/utils";
import { inputClass } from "./affiliate-picker";
import { DESCRIPTION_MAX_BYTES, utf8Bytes } from "./upload-status-copy";

/*
 * 제목 · 설명 · 해시태그 — planning 3장 06 · design 5-7.
 * 제목 100자 카운터 · 다시 만들기(3가지 안 순환) · 설명 미리보기(고지 → 구매 안내 → 본문 → 해시태그, 출처 문구는 본문 뒤).
 * 미리보기는 DB가 만든 고지·구매 안내·출처 조각을 같은 순서로 이은 것이고, 저장되는 설명란은 DB가 다시 만든다.
 */

type PublishCopyProps = {
  title: string;
  body: string;
  hashtagText: string;
  description: string;
  variantNo: number;
  variantCount: number;
  disabled: boolean;
  onTitle: (v: string) => void;
  onBody: (v: string) => void;
  onHashtags: (v: string) => void;
  onRegenerate: () => void;
};

export function PublishCopy({
  title,
  body,
  hashtagText,
  description,
  variantNo,
  variantCount,
  disabled,
  onTitle,
  onBody,
  onHashtags,
  onRegenerate,
}: PublishCopyProps) {
  const descriptionBytes = utf8Bytes(description);
  const ids = { title: useId(), count: useId(), body: useId(), tags: useId() };
  const length = [...title].length;

  return (
    <section aria-label="제목 · 설명 · 해시태그" className="flex flex-col gap-3 rounded-card border border-line bg-white p-4 shadow-card tablet:p-6">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm font-semibold">제목 · 설명 · 해시태그</p>
        <button type="button" onClick={onRegenerate} disabled={disabled} className={btnClass}>
          다시 만들기 ({variantNo}/{variantCount}안)
        </button>
      </div>
      <div className="flex flex-col gap-1">
        <div className="flex items-baseline justify-between gap-2">
          <label htmlFor={ids.title} className="text-xs text-muted">
            제목
          </label>
          <span id={ids.count} className={cn("text-xs", length > TITLE_MAX ? "font-bold text-danger-fg" : "text-muted")}>
            {length} / {TITLE_MAX}
          </span>
        </div>
        <input
          id={ids.title}
          value={title}
          onChange={(e) => onTitle(e.target.value)}
          maxLength={TITLE_MAX}
          aria-describedby={ids.count}
          disabled={disabled}
          className={inputClass}
        />
      </div>
      <div className="flex flex-col gap-1">
        <label htmlFor={ids.body} className="text-xs text-muted">
          설명(본문)
        </label>
        <textarea
          id={ids.body}
          value={body}
          onChange={(e) => onBody(e.target.value)}
          maxLength={BODY_MAX}
          rows={4}
          disabled={disabled}
          className={cn(inputClass, "py-2")}
        />
      </div>
      <div className="flex flex-col gap-1">
        <label htmlFor={ids.tags} className="text-xs text-muted">
          해시태그(띄어쓰기로 구분)
        </label>
        <input id={ids.tags} value={hashtagText} onChange={(e) => onHashtags(e.target.value)} disabled={disabled} className={inputClass} />
      </div>
      <div className="flex flex-col gap-1">
        <p className="text-xs text-muted">설명란 미리보기 · 고지 → 구매 안내 → 본문 → 해시태그</p>
        <pre aria-label="설명란 미리보기" className="max-h-80 overflow-y-auto rounded-btn border border-line bg-sub-hover px-3 py-2 font-sans text-sm whitespace-pre-wrap">
          {description || "본문을 입력하면 미리보기가 보입니다."}
        </pre>
        <p className={cn("text-xs", descriptionBytes > DESCRIPTION_MAX_BYTES ? "text-danger-fg" : "text-muted")}>
          설명란 {descriptionBytes.toLocaleString("ko-KR")} / {DESCRIPTION_MAX_BYTES.toLocaleString("ko-KR")}바이트
          {descriptionBytes > DESCRIPTION_MAX_BYTES ? " · YouTube 한도를 넘어 발행할 수 없습니다. 본문을 줄여 주세요" : " (YouTube 한도, 한글 1자 = 3바이트)"}
        </p>
      </div>
    </section>
  );
}
