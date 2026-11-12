"use client";

import { useState } from "react";
import { InlineBanner } from "@/components/feedback";
import { btnClass, btnPrimaryClass } from "@/components/studio/step-actions";
import { directSourceError } from "@/lib/sources/rules";
import { cn } from "@/lib/utils";

/*
 * 원본 직접 추가 — URL·작성자 필수(15-4 ① 출처 기록). 권리 근거는 추가 뒤 카드에서 사용자가 고른다.
 * 파일 업로드는 형식·크기 한도가 정해진 뒤 붙인다(task-017 "하지 않을 것").
 */

type AddSourceFormProps = {
  pending: boolean;
  onSubmit: (url: string, author: string, title: string) => Promise<boolean>;
  onCancel: () => void;
};

const inputClass = "min-h-11 rounded-btn border border-line bg-white px-3 text-base text-ink";

export function AddSourceForm({ pending, onSubmit, onCancel }: AddSourceFormProps) {
  const [url, setUrl] = useState("");
  const [author, setAuthor] = useState("");
  const [title, setTitle] = useState("");
  const [error, setError] = useState<string | null>(null);

  return (
    <form
      aria-label="원본 영상 추가"
      className="flex flex-col gap-3 rounded-btn border border-line p-4"
      onSubmit={async (event) => {
        event.preventDefault();
        const invalid = directSourceError(url, author, title);
        setError(invalid);
        if (invalid) return;
        if (await onSubmit(url, author, title)) {
          setUrl("");
          setAuthor("");
          setTitle("");
        }
      }}
    >
      <div className="grid gap-3 tablet:grid-cols-2">
        <label className="flex flex-col gap-1 text-sm font-semibold tablet:col-span-2">
          <span>
            원본 URL<span className="text-danger-fg">*</span>
          </span>
          <input type="url" inputMode="url" value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://" maxLength={2000} className={inputClass} />
        </label>
        <label className="flex flex-col gap-1 text-sm font-semibold">
          <span>
            작성자<span className="text-danger-fg">*</span>
          </span>
          <input value={author} onChange={(e) => setAuthor(e.target.value)} placeholder="@작성자 또는 판매자명" maxLength={100} className={inputClass} />
        </label>
        <label className="flex flex-col gap-1 text-sm font-semibold">
          <span>제목(선택)</span>
          <input value={title} onChange={(e) => setTitle(e.target.value)} maxLength={200} className={inputClass} />
        </label>
      </div>
      <p className="text-xs text-muted">
        작성자는 영상과 설명란의 출처 표기에 씁니다. 추가한 원본은 내려받은 뒤 권리 근거를 골라 사용할 수 있습니다.
      </p>
      {error ? <InlineBanner tone="error">{error}</InlineBanner> : null}
      <div className="flex flex-wrap gap-2">
        <button type="submit" disabled={pending} className={cn(btnClass, btnPrimaryClass)}>
          {pending ? "추가 중…" : "추가"}
        </button>
        <button type="button" onClick={onCancel} className={btnClass}>
          닫기
        </button>
      </div>
    </form>
  );
}
