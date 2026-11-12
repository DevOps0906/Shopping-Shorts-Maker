"use client";

import { usePathname, useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { saveScriptAction } from "@/app/(dashboard)/studio/[projectId]/[step]/script/actions";
import { PARTNER_ID, ChatPopup } from "@/components/chat/chat-popup";
import { type ChatTarget, useChat } from "@/components/chat/use-chat";
import { useFeedback } from "@/components/feedback";
import type { PendingConfirm } from "@/lib/agent-tools/messages";
import { TOOL_LABEL, isAgentToolName } from "@/lib/agent-tools/tools";
import { STUDIO_STEPS } from "@/lib/routes";
import { isProjectId } from "@/lib/steps/project-id";
import { cn } from "@/lib/utils";

/**
 * 제작 파트너 FAB + 팝업(S-16, design.md 6장). 대시보드 레이아웃에 하나만 있어 화면을 옮겨도 대화·열림 상태가 유지된다.
 * - 열림 상태를 useFeedback().setPartnerOpen에 알려 토스트 위치를 옮긴다(ui-feedback 3-1).
 * - 닫혀 있을 때 온 AI 응답은 토스트 대신 FAB 숫자 배지 + 미리보기 3줄(ui-feedback 2장 #19).
 * - 확인이 필요한 도구는 공용 confirm()으로 묻고, 사용자가 실행을 누를 때만 /api/chat/confirm 을 부른다.
 * 모바일(~767)에서는 라벨을 숨기고 아이콘만, 열리면 FAB를 숨기고 바텀 시트로 연다.
 */

function targetFrom(pathname: string): ChatTarget {
  const m = /^\/studio\/([^/]+)\/([^/]+)/.exec(pathname);
  if (!m || !isProjectId(m[1])) return null;
  return { projectId: m[1], step: m[2] };
}

export function ChatFab() {
  const pathname = usePathname();
  const router = useRouter();
  const feedback = useFeedback();
  const target = targetFrom(pathname);
  const [open, setOpen] = useState(false);
  const [unread, setUnread] = useState(0);
  const [peek, setPeek] = useState<string | null>(null);
  const [applying, setApplying] = useState(false);
  const chat = useChat(target, open);
  const fabRef = useRef<HTMLButtonElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const openRef = useRef(open);
  const wasOpen = useRef(false);

  // 열면 입력칸에 포커스, 닫으면 FAB로 포커스를 돌린다(모바일은 열린 동안 FAB가 숨어 있어 다시 그린 뒤에 옮긴다)
  useEffect(() => {
    openRef.current = open;
    feedback.setPartnerOpen(open);
    if (open) inputRef.current?.focus();
    else if (wasOpen.current) fabRef.current?.focus();
    wasOpen.current = open;
  }, [open, feedback]);

  function show() {
    setOpen(true);
    setUnread(0);
    setPeek(null);
  }

  function close() {
    setOpen(false);
    setPeek(null);
  }

  /** 응답 도착: 닫혀 있으면 배지·미리보기, 데이터가 바뀌었으면 화면 새로고침 + 스낵바(#20) */
  function arrived(text: string | null, changed: string | null) {
    if (text && !openRef.current) {
      setUnread((n) => n + 1);
      setPeek(text);
    }
    if (changed && isAgentToolName(changed) && target) {
      router.refresh();
      const slug = STUDIO_STEPS[{ search_topics: 0, search_sources: 1, draft_script: 2, synthesize_voice: 3, replace_cut: 4, render_mp4: 4 }[changed]].slug;
      feedback.snackbar({
        message: `제작 파트너가 ${TOOL_LABEL[changed]} 작업을 시작했습니다`,
        key: `partner:${changed}`,
        action: { label: "보기", onAction: () => router.push(`/studio/${target.projectId}/${slug}`) },
      });
    }
  }

  async function confirmAndRun(pending: PendingConfirm) {
    // 다른 프로젝트의 제안은 묻지도 실행하지도 않는다
    if (!target || pending.projectId !== target.projectId) return;
    const yes = await feedback.confirm(pending.options);
    if (!yes) return;
    const r = await chat.runConfirm(pending);
    if (r.ok) arrived(r.ai?.text ?? null, r.changed);
  }

  async function onSend(text: string) {
    const r = await chat.send(text);
    if (!r.ok) return false;
    arrived(r.ai?.text ?? null, r.changed);
    if (r.confirm) void confirmAndRun(r.confirm);
    return true;
  }

  async function onApplyDraft(lines: string[]) {
    if (!target) return;
    setApplying(true);
    const result = await saveScriptAction(target.projectId, lines);
    setApplying(false);
    if (!result.ok) {
      chat.setError(result.error);
      return;
    }
    feedback.toast({ message: "추천 대본을 작업칸에 적용했습니다", tone: "success" });
    router.refresh();
  }

  return (
    <>
      {open ? (
        <ChatPopup
          context={chat.context}
          hasProject={target !== null}
          messages={chat.messages}
          loading={chat.loading}
          sending={chat.sending}
          error={chat.error}
          inputRef={inputRef}
          onClose={close}
          onSend={onSend}
          onConfirm={(p) => void confirmAndRun(p)}
          onApplyDraft={(lines) => void onApplyDraft(lines)}
          applying={applying}
        />
      ) : null}

      {!open && peek && unread > 0 ? (
        <div
          role="status"
          className="fixed right-(--fab-inset) bottom-[calc(var(--fab-inset)+var(--fab-size)+--spacing(3))] z-(--z-fab) flex w-75 max-w-[calc(100vw-var(--fab-inset)*2)] items-start gap-1 rounded-card border border-accent-line bg-white py-1.5 pr-1.5 pl-1 shadow-fab transition-[opacity,translate] duration-(--motion-fast) starting:translate-y-3 starting:opacity-0 motion-reduce:transition-none"
        >
          <button type="button" onClick={show} className="line-clamp-3 min-w-0 flex-1 rounded-btn px-2.5 py-2 text-left text-sm leading-normal text-ink hover:bg-sub-hover">
            <span className="mb-0.5 block text-xs font-bold text-accent">제작 파트너 · 새 메시지 {unread}개</span>
            {peek}
          </button>
          <button type="button" aria-label="알림 닫기" onClick={() => setPeek(null)} className="inline-flex size-8 shrink-0 items-center justify-center rounded-btn-sm text-muted hover:bg-sub-hover">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" aria-hidden="true" className="size-3.5">
              <path d="M6 6l12 12M18 6L6 18" />
            </svg>
          </button>
        </div>
      ) : null}

      <button
        ref={fabRef}
        type="button"
        aria-expanded={open}
        aria-controls={PARTNER_ID}
        aria-label={open ? "제작 파트너 닫기" : `제작 파트너 열기${unread > 0 ? ` (새 메시지 ${unread}개)` : ""}`}
        onClick={() => (open ? close() : show())}
        className={cn(
          "fixed right-(--fab-inset) bottom-(--fab-inset) z-(--z-fab) flex h-(--fab-size) min-w-(--fab-size) items-center justify-center gap-2 rounded-pill bg-accent px-3.5 text-sm font-bold text-white shadow-fab transition-transform duration-(--motion-fast) hover:-translate-y-0.5 active:scale-96 motion-reduce:transition-none",
          open ? "max-tablet:hidden tablet:px-0" : "tablet:pr-5 tablet:pl-4",
        )}
      >
        {!open && unread > 0 ? (
          <span aria-hidden="true" className="absolute inset-0 rounded-pill bg-accent opacity-50 motion-safe:animate-ping motion-safe:[animation-iteration-count:2]" />
        ) : null}
        {open ? (
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" aria-hidden="true" className="relative size-5.5">
            <path d="M6 6l12 12M18 6L6 18" />
          </svg>
        ) : (
          <>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className="relative size-6">
              <path d="M21 12a8 8 0 0 1-11.6 7.1L4 20.5l1.4-4.9A8 8 0 1 1 21 12z" />
              <path d="M8.5 11h.01M12 11h.01M15.5 11h.01" />
            </svg>
            <span className="relative hidden tablet:inline">제작 파트너</span>
          </>
        )}
        {!open && unread > 0 ? (
          <span aria-hidden="true" className="absolute -top-1 -right-1 flex h-5.5 min-w-5.5 items-center justify-center rounded-pill border-2 border-white bg-alert px-1.5 text-xs font-bold text-white tabular-nums">
            {unread}
          </span>
        ) : null}
      </button>
    </>
  );
}
