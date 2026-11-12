"use client";

import { useId, useState } from "react";
import { InlineBanner, useFeedback } from "@/components/feedback";
import { btnClass } from "@/components/studio/step-actions";
import { BIO_SERVICES, type BioService } from "@/lib/publish/rules";
import { cn } from "@/lib/utils";
import { switchClass } from "./affiliate-picker";

/*
 * 링크인바이오 등록 — planning 16-3 · 16-4 · design 5-7.
 * 서비스 선택 → 이번 영상 번호(채널마다 1번부터, 재사용 없음 — DB assign_bio_number) → 등록 내용·항목 내용 복사 →
 * 등록 완료 스위치(사용자 체크, 정책 점검 구매 경로) · "프로필 링크 N번" 설명 안내 스위치. 외부 서비스 API는 부르지 않는다(16-5 확장).
 */

type LinkInBioCardProps = {
  enabled: boolean;
  service: BioService | null;
  bioNo: number | null;
  registered: boolean;
  productName: string;
  url: string | null;
  disclosure: string;
  purchaseGuide: boolean;
  disabled: boolean;
  onService: (service: BioService | "none") => void;
  onRegistered: (on: boolean) => void;
  onPurchaseGuide: (on: boolean) => void;
};

/** 등록할 항목 내용(16-3 2번): 번호 + 상품명, 링크, 썸네일, 한 줄 공지 */
export function bioEntryText(no: number, productName: string, url: string, disclosure: string) {
  return [`${no}번 ${productName}`, url, "썸네일: 영상 첫 컷", disclosure ? `한 줄 공지: ${disclosure}` : ""].filter(Boolean).join("\n");
}

export function LinkInBioCard({
  enabled,
  service,
  bioNo,
  registered,
  productName,
  url,
  disclosure,
  purchaseGuide,
  disabled,
  onService,
  onRegistered,
  onPurchaseGuide,
}: LinkInBioCardProps) {
  const feedback = useFeedback();
  const ids = { registered: useId(), guide: useId() };
  const [copyFailed, setCopyFailed] = useState(false);
  const entry = bioNo !== null && url ? bioEntryText(bioNo, productName, url, disclosure) : null;

  async function copy() {
    if (!entry) return;
    try {
      await navigator.clipboard.writeText(entry);
      setCopyFailed(false);
      feedback.toast({ message: "항목 내용을 복사했습니다", tone: "success" });
    } catch {
      setCopyFailed(true);
    }
  }

  return (
    <section aria-label="링크인바이오 등록" className="flex flex-col gap-3 rounded-card border border-line bg-white p-4 shadow-card tablet:p-6">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <p className="text-sm font-semibold">링크인바이오 등록</p>
        <p className="text-xs text-muted">채널마다 1번부터 · 번호는 다시 쓰지 않음</p>
      </div>
      {!enabled ? (
        <p className="text-sm text-muted">링크형 제휴 프로그램을 고르고 상품 제휴 링크를 저장하면 번호를 받을 수 있습니다.</p>
      ) : null}
      <div role="radiogroup" aria-label="링크인바이오 서비스" className="flex flex-wrap gap-2">
        {BIO_SERVICES.map((s) => {
          const on = (service ?? "none") === s.id;
          return (
            <button
              key={s.id}
              type="button"
              role="radio"
              aria-checked={on}
              disabled={disabled || !enabled}
              onClick={() => onService(s.id)}
              className={cn(btnClass, on && "border-accent bg-accent-weak")}
            >
              {s.label}
            </button>
          );
        })}
      </div>

      <div className="flex flex-col gap-3 tablet:flex-row">
        <div className="flex shrink-0 flex-col items-center justify-center rounded-btn border border-line bg-sub-hover px-6 py-3">
          <span className="text-xs text-muted">이번 영상 번호</span>
          <span className="text-h font-bold" aria-label={bioNo !== null ? `${bioNo}번` : "번호 없음"}>
            {bioNo !== null ? `${bioNo}번` : "—"}
          </span>
        </div>
        <div className="flex min-w-0 flex-1 flex-col gap-2">
          <p className="text-xs text-muted">등록 내용</p>
          {entry ? (
            <pre className="overflow-x-auto rounded-btn border border-line bg-white px-3 py-2 font-sans text-sm whitespace-pre-wrap">{entry}</pre>
          ) : (
            <p className="text-sm text-muted">서비스를 고르면 번호와 등록할 내용을 보여 드립니다.</p>
          )}
          <div className="flex flex-wrap gap-2">
            <button type="button" onClick={copy} disabled={!entry} className={btnClass}>
              항목 내용 복사
            </button>
          </div>
          {copyFailed ? <InlineBanner tone="error">복사하지 못했습니다. 위 등록 내용을 직접 선택해 복사해 주세요.</InlineBanner> : null}
          <p className="text-xs text-muted">인포크링크·리틀리·링크트리에서 + 버튼 → 링크 붙여넣기 → 상품명·썸네일 입력 → 맨 위로 고정. 30일 지난 항목은 지우지 말고 아래로 내립니다.</p>
        </div>
      </div>

      <div className="flex flex-col gap-1 border-t border-line pt-3 text-sm">
        <label htmlFor={ids.registered} className="flex min-h-11 items-center gap-2">
          <input
            id={ids.registered}
            type="checkbox"
            role="switch"
            checked={registered}
            disabled={disabled || !entry}
            onChange={(e) => onRegistered(e.target.checked)}
            className={switchClass}
          />
          <span>등록 완료(링크인바이오에 {bioNo ?? "N"}번 항목을 올렸습니다)</span>
        </label>
        <label htmlFor={ids.guide} className="flex min-h-11 items-center gap-2">
          <input
            id={ids.guide}
            type="checkbox"
            role="switch"
            checked={purchaseGuide}
            disabled={disabled || !enabled}
            onChange={(e) => onPurchaseGuide(e.target.checked)}
            className={switchClass}
          />
          <span>설명란 첫 줄 “구매 정보: 프로필 링크 {bioNo ?? "N"}번” 안내</span>
        </label>
      </div>
    </section>
  );
}
