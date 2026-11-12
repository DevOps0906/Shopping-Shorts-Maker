"use client";

import { type KeyboardEvent, type RefObject, useEffect, useId, useRef, useState } from "react";
import { InlineBanner } from "@/components/feedback";
import { btnClass, btnPrimaryClass, btnSmClass, chipClass } from "@/components/projects/ui";
import { chatCostLine } from "@/lib/agent-tools/cost";
import { type ChatContextView, type ChatMessageView, type PendingConfirm, QUICK_REQUESTS } from "@/lib/agent-tools/messages";
import { MAX_MESSAGE } from "@/lib/agent-tools/prompt";
import { cn } from "@/lib/utils";

/*
 * S-16 제작 파트너 팝업 — docs/design.md 6장, design/prototype/Main.dc.html .chat.
 * 데스크톱 --partner-w(400) · 태블릿 380 팝업, 모바일은 어두운 배경 위 바텀 시트(88%), 배경을 누르면 닫힘.
 * 상태: 빈(프로젝트 밖·대화 없음) · 로딩(점 3개 "제작 파트너가 입력 중") · 오류(InlineBanner) · 성공(적용 버튼).
 */

export const PARTNER_ID = "partner-chat";

const LABEL: Record<ChatMessageView["kind"], string> = { screen: "나 · 화면 선택", text: "나 · 직접 입력", ai: "제작 파트너" };

type ChatPopupProps = {
  context: ChatContextView | null;
  hasProject: boolean;
  messages: ChatMessageView[];
  loading: boolean;
  sending: boolean;
  error: string | null;
  inputRef: RefObject<HTMLTextAreaElement | null>;
  onClose: () => void;
  onSend: (text: string) => Promise<boolean>;
  onConfirm: (pending: PendingConfirm) => void;
  onApplyDraft: (lines: string[]) => void;
  applying: boolean;
};

function contextLine(context: ChatContextView | null, hasProject: boolean) {
  if (!hasProject) return "프로젝트 제작단계를 열면 단계 맥락이 표시됩니다";
  if (!context) return "맥락을 불러오는 중…";
  return [context.stepLabel, `채널 ${context.channelName ?? "미설정"}`, `카테고리 ${context.categoryName ?? "미설정"}`].join(" · ");
}

function Message({ m, busy, last, onConfirm, onApplyDraft }: { m: ChatMessageView; busy: boolean; last: boolean; onConfirm: ChatPopupProps["onConfirm"]; onApplyDraft: ChatPopupProps["onApplyDraft"] }) {
  const ai = m.role === "ai";
  return (
    <li
      className={cn(
        "max-w-[88%] rounded-card px-3.5 py-3 text-sm leading-relaxed break-words whitespace-pre-line text-ink",
        ai ? "self-start bg-nav-hover" : "self-end bg-accent-weak",
      )}
    >
      <span className="mb-1 block text-xs font-semibold text-muted">{LABEL[m.kind]}</span>
      {m.text}
      {m.draft ? (
        <>
          <ol className="mt-2 list-decimal pl-5">
            {m.draft.map((line, i) => (
              <li key={i}>{line}</li>
            ))}
          </ol>
          <button type="button" disabled={busy} onClick={() => onApplyDraft(m.draft ?? [])} className={cn(btnClass, btnPrimaryClass, btnSmClass, "mt-2.5")}>
            추천 대본을 작업칸에 적용
          </button>
        </>
      ) : null}
      {/* 확인 버튼은 마지막 메시지에만(이미 지난 확인 요청을 다시 실행하지 않게) */}
      {m.confirm && last ? (
        <button type="button" disabled={busy} onClick={() => m.confirm && onConfirm(m.confirm)} className={cn(btnClass, btnPrimaryClass, btnSmClass, "mt-2.5")}>
          확인하고 실행
        </button>
      ) : null}
    </li>
  );
}

export function ChatPopup(props: ChatPopupProps) {
  const { context, hasProject, messages, loading, sending, error, inputRef, onClose, onSend, onConfirm, onApplyDraft, applying } = props;
  const [input, setInput] = useState("");
  const listRef = useRef<HTMLDivElement>(null);
  const titleId = useId();
  const busy = sending || applying;
  const quick = QUICK_REQUESTS[context?.stepNumber ?? 0] ?? [];

  // 열 때·새 메시지가 올 때 맨 아래로
  useEffect(() => {
    const el = listRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [messages.length, sending, loading]);

  async function submit(text: string) {
    const value = text.trim();
    if (!value || busy || !hasProject) return;
    if (await onSend(value)) setInput("");
  }

  function onKeyDown(event: KeyboardEvent<HTMLTextAreaElement>) {
    // 한글 조합 중 Enter는 글자 확정이므로 보내지 않는다
    if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
      event.preventDefault();
      void submit(input);
    }
  }

  return (
    <>
      <div aria-hidden="true" onClick={onClose} className="fixed inset-0 z-(--z-popover) bg-(--scrim) tablet:hidden" />
      <aside
        id={PARTNER_ID}
        role="dialog"
        aria-modal="false"
        aria-labelledby={titleId}
        onKeyDown={(event) => {
          if (event.key === "Escape") {
            event.preventDefault();
            onClose();
          }
        }}
        className={cn(
          "fixed z-(--z-popover) flex flex-col overflow-hidden border border-line bg-white text-ink shadow-fab",
          "inset-x-0 bottom-0 h-[88dvh] rounded-t-card",
          "tablet:inset-x-auto tablet:right-(--fab-inset) tablet:bottom-[calc(var(--fab-inset)+var(--fab-size)+--spacing(4))] tablet:w-(--partner-w) tablet:rounded-card",
          "tablet:h-[min(--spacing(155),100dvh_-_--spacing(30))] desktop:h-[min(--spacing(170),100dvh_-_--spacing(32))]",
          "origin-bottom transition-[opacity,translate,scale] duration-(--motion-fast) starting:translate-y-3 starting:scale-97 starting:opacity-0 tablet:origin-bottom-right motion-reduce:transition-none",
        )}
      >
        <header className="flex items-center gap-2 border-b border-line px-4.5 pt-4 pb-3">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true" className="size-4.5 text-accent">
            <path d="M12 3v18M3 12h18M5.6 5.6l12.8 12.8M18.4 5.6L5.6 18.4" />
          </svg>
          <h2 id={titleId} className="text-sm font-bold">
            제작 파트너
          </h2>
          <span className="ml-auto text-xs font-semibold tracking-widest text-muted">AI CHAT</span>
          <button type="button" aria-label="제작 파트너 닫기" onClick={onClose} className="inline-flex size-9 items-center justify-center rounded-btn-sm text-muted hover:bg-sub-hover hover:text-ink">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" aria-hidden="true" className="size-4.5">
              <path d="M6 6l12 12M18 6L6 18" />
            </svg>
          </button>
        </header>
        <p className="border-b border-line bg-sub-hover px-4.5 py-2 text-xs text-muted">{contextLine(context, hasProject)}</p>

        <div ref={listRef} aria-live="polite" className="flex flex-1 flex-col gap-3 overflow-y-auto p-4">
          {!hasProject ? (
            <p className="m-auto max-w-[80%] text-center text-sm text-muted">프로젝트를 열고 제작단계에서 말로 수정을 요청할 수 있습니다. 예: “다른 소재 추천해줘”, “대본을 더 짧게”.</p>
          ) : loading ? (
            <div className="flex flex-col gap-2" aria-label="대화를 불러오는 중">
              <span className="h-10 w-3/5 animate-pulse rounded-card bg-count-bg" />
              <span className="ml-auto h-8 w-2/5 animate-pulse rounded-card bg-count-bg" />
            </div>
          ) : messages.length === 0 && !sending ? (
            <p className="m-auto max-w-[80%] text-center text-sm text-muted">아직 대화가 없습니다. 아래 빠른 요청을 누르거나 바꾸고 싶은 내용을 적어 주세요.</p>
          ) : (
            <ul className="flex flex-col gap-3">
              {messages.map((m, i) => (
                <Message key={m.id} m={m} busy={busy} last={i === messages.length - 1} onConfirm={onConfirm} onApplyDraft={onApplyDraft} />
              ))}
            </ul>
          )}
          {sending ? (
            <div role="status" aria-label="제작 파트너가 입력 중" className="flex gap-1 self-start rounded-card bg-nav-hover px-4 py-3.5">
              {[0, 1, 2].map((i) => (
                <i key={i} className="size-1.5 animate-bounce rounded-pill bg-muted motion-reduce:animate-none" style={{ animationDelay: `${i * 150}ms` }} />
              ))}
            </div>
          ) : null}
        </div>

        {error ? (
          <InlineBanner tone="error" className="mx-4 mb-2.5">
            {error}
          </InlineBanner>
        ) : null}

        {hasProject && quick.length > 0 ? (
          <div className="flex flex-wrap gap-1.5 px-4 pb-2.5">
            {quick.map((q) => (
              <button key={q} type="button" disabled={busy} onClick={() => void submit(q)} className={cn(chipClass, "min-h-9 rounded-pill px-2.5 text-xs disabled:cursor-not-allowed disabled:opacity-60")}>
                {q}
              </button>
            ))}
          </div>
        ) : null}

        <div className="mx-3.5 rounded-card border border-line bg-white px-3 py-2.5 focus-within:border-accent">
          <label htmlFor="chat-in" className="sr-only">
            제작 파트너에게 보낼 메시지
          </label>
          <textarea
            id="chat-in"
            ref={inputRef}
            value={input}
            maxLength={MAX_MESSAGE}
            disabled={!hasProject}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={onKeyDown}
            placeholder={hasProject ? "이 장면을 더 짧게 보여주세요…" : "프로젝트를 열면 입력할 수 있습니다"}
            className="min-h-16 w-full resize-none bg-transparent text-sm text-ink outline-none placeholder:text-muted disabled:cursor-not-allowed"
          />
          <div className="flex items-center gap-2">
            <button type="button" disabled aria-label="파일 첨부(준비 중)" className="inline-flex size-9 items-center justify-center rounded-btn-sm text-muted disabled:cursor-not-allowed disabled:opacity-60">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true" className="size-5">
                <path d="M12 5v14M5 12h14" />
              </svg>
            </button>
            <span className="text-xs text-muted">Enter 전송 · Shift+Enter 줄바꿈</span>
            <button
              type="button"
              aria-label="보내기"
              disabled={busy || !hasProject || input.trim() === ""}
              onClick={() => void submit(input)}
              className="ml-auto inline-flex size-9 items-center justify-center rounded-pill bg-accent text-white disabled:cursor-not-allowed disabled:bg-accent-line"
            >
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className="size-4.5">
                <path d="M12 19V5M5 12l7-7 7 7" />
              </svg>
            </button>
          </div>
        </div>
        <p className="px-4.5 pt-2 text-xs text-muted">요청할 때 AI 사용량에 따라 크레딧이 차감됩니다</p>
        <p className="px-4.5 pt-0.5 pb-3 text-xs text-muted">{chatCostLine()}</p>
      </aside>
    </>
  );
}
