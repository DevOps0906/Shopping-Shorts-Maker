"use client";

import { type KeyboardEvent, useEffect, useId, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { InlineBanner } from "@/components/feedback";
import { STUDIO_STEPS } from "@/lib/routes";
import { type JobRowView, type QueueStatus, TOO_MANY_JOBS_MESSAGE, limitNotice, postingRow, productionRow } from "@/lib/jobs/queue-status";
import { cn } from "@/lib/utils";

/*
 * S-17 작업 현황 패널 — docs/design.md 작업 현황 패널, 시각 참고: design/prototype/Main.dc.html .jp
 * 데스크톱·태블릿은 GNB 오른쪽 비모달 카드(--jp-w), 모바일은 전체 화면 시트.
 * 접근성: role=dialog(aria-modal=false), 열면 선택된 탭으로 포커스, Esc(문서 전체)·닫기로 닫고 GNB 아이콘으로 복귀,
 * 탭은 좌우 화살표(aria-controls·aria-labelledby).
 */

export const JOBS_PANEL_ID = "jobs-panel";

type TabKey = "make" | "post";
const TABS: { key: TabKey; label: string }[] = [
  { key: "make", label: "제작 중" },
  { key: "post", label: "포스팅 대기" },
];
const EMPTY_TEXT: Record<TabKey, string> = {
  make: "진행 중인 제작 작업이 없습니다.",
  post: "포스팅을 기다리는 영상이 없습니다.",
};

const chipTone: Record<JobRowView["tone"], string> = {
  run: "bg-accent-weak text-ink",
  wait: "bg-warning-bg text-warning-fg",
  ok: "bg-success-bg text-success-fg",
  bad: "bg-danger-bg text-danger-fg",
  none: "bg-line text-muted",
};

const focusRing =
  "focus-visible:outline-(length:--focus-ring-width) focus-visible:outline-offset-(--focus-ring-offset) focus-visible:outline-accent";

type JobsPanelProps = {
  status: QueueStatus;
  loaded: boolean;
  failed: boolean;
  /** 작업 시작이 대기 상한(JQ001)으로 거절됐을 때 상단 경고 */
  rejected?: boolean;
  onRetry: () => void;
  /** restoreFocus: GNB 아이콘으로 포커스를 돌릴지(행을 눌러 이동할 때는 false) */
  onClose: (restoreFocus: boolean) => void;
};

export function JobsPanel({ status, loaded, failed, rejected = false, onRetry, onClose }: JobsPanelProps) {
  const router = useRouter();
  const titleId = useId();
  const [tab, setTab] = useState<TabKey>("make");
  const [now, setNow] = useState(0);
  const tabRefs = useRef<Record<TabKey, HTMLButtonElement | null>>({ make: null, post: null });
  const closeRef = useRef(onClose);
  useEffect(() => {
    closeRef.current = onClose;
  }, [onClose]);

  // 열면 선택된 탭(제작 중)으로 포커스
  useEffect(() => {
    tabRefs.current.make?.focus();
  }, []);

  // Esc 는 문서 전체에서 닫는다
  useEffect(() => {
    const onKey = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") closeRef.current(true);
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  // 경과·예상 문구용 현재 시각(데이터가 바뀌거나 30초마다)
  useEffect(() => {
    const tick = () => setNow(Date.now());
    const first = setTimeout(tick, 0);
    const timer = setInterval(tick, 30_000);
    return () => {
      clearTimeout(first);
      clearInterval(timer);
    };
  }, [status]);

  const rows: Record<TabKey, JobRowView[]> = {
    make: status.production.map((item) => productionRow(item, now)),
    post: status.posting.map((item) => postingRow(item, now)),
  };
  const list = rows[tab];
  const notice = tab === "make" ? limitNotice(status.production) : null;

  function onTabKey(event: KeyboardEvent<HTMLDivElement>) {
    const dir = event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0;
    if (!dir) return;
    event.preventDefault();
    const next = TABS[(TABS.findIndex((t) => t.key === tab) + dir + TABS.length) % TABS.length].key;
    setTab(next);
    tabRefs.current[next]?.focus();
  }

  function go(row: JobRowView) {
    onClose(false);
    router.push(`/studio/${row.projectId}/${STUDIO_STEPS[row.step - 1].slug}`);
  }

  return (
    <aside
      id={JOBS_PANEL_ID}
      role="dialog"
      aria-modal="false"
      aria-labelledby={titleId}
      className={cn(
        "fixed z-(--z-jobs) flex flex-col overflow-hidden border border-line bg-white text-ink shadow-pop",
        "inset-0 rounded-none",
        "tablet:inset-auto tablet:top-(--jp-top) tablet:left-[calc(var(--gnb-w)+--spacing(2))] tablet:w-(--jp-w) tablet:max-h-[calc(100dvh-2*var(--jp-top))] tablet:rounded-card",
        "origin-bottom transition-[opacity,translate,scale] duration-(--motion-fast) starting:translate-y-3 starting:opacity-0 tablet:origin-top-left tablet:starting:translate-y-0 tablet:starting:scale-97 motion-reduce:transition-none",
      )}
    >
      <header className="flex items-center justify-between px-3 pt-4 tablet:px-4">
        <h2 id={titleId} className="text-base font-bold">
          작업 현황
        </h2>
        <button
          type="button"
          aria-label="작업 현황 닫기"
          onClick={() => onClose(true)}
          className={cn("inline-flex size-11 items-center justify-center rounded-btn-sm text-muted hover:bg-sub-hover hover:text-ink", focusRing)}
        >
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" aria-hidden="true" className="size-4.5">
            <path d="M6 6l12 12M18 6L6 18" />
          </svg>
        </button>
      </header>

      <div role="tablist" aria-label="작업 현황 구분" onKeyDown={onTabKey} className="flex gap-1 border-b border-line px-3 tablet:px-4">
        {TABS.map((t) => {
          const on = tab === t.key;
          return (
            <button
              key={t.key}
              ref={(el) => {
                tabRefs.current[t.key] = el;
              }}
              type="button"
              role="tab"
              id={`jobs-tab-${t.key}`}
              aria-selected={on}
              aria-controls="jobs-tabpanel"
              tabIndex={on ? 0 : -1}
              onClick={() => setTab(t.key)}
              className={cn(
                "inline-flex min-h-11 items-center border-b-2 px-3 text-sm font-bold transition-colors",
                focusRing,
                on ? "border-accent text-nav-on-ink" : "border-transparent text-muted hover:text-nav-on-ink",
              )}
            >
              {t.label}
              <span className="ml-1.5 rounded-pill bg-accent-weak px-1.5 py-0.5 text-xs font-bold text-ink tabular-nums">
                {rows[t.key].length}
              </span>
            </button>
          );
        })}
      </div>

      {rejected ? (
        <div role="alert" className="m-2 rounded-btn bg-warning-bg px-3.5 py-3 text-sm font-semibold text-warning-fg">
          {TOO_MANY_JOBS_MESSAGE}
        </div>
      ) : null}
      {notice ? (
        <div role="status" className="m-2 rounded-btn bg-warning-bg px-3.5 py-3 text-sm font-semibold text-warning-fg">
          {notice}
        </div>
      ) : null}
      {failed ? (
        <InlineBanner
          tone="error"
          className="m-2"
          action={
            <button type="button" onClick={onRetry} className="min-h-11 px-2 text-xs font-bold underline">
              다시 불러오기
            </button>
          }
        >
          작업 현황을 불러오지 못했습니다.
        </InlineBanner>
      ) : null}

      <div
        id="jobs-tabpanel"
        role="tabpanel"
        aria-labelledby={`jobs-tab-${tab}`}
        aria-live="polite"
        className="flex flex-1 flex-col gap-1 overflow-y-auto p-2"
      >
        {list.map((row) => (
          <button
            key={row.key}
            type="button"
            onClick={() => go(row)}
            className={cn(
              "grid min-h-(--jp-row-min) w-full grid-cols-[minmax(0,1fr)_auto] items-center gap-x-2 gap-y-0.5 rounded-btn border border-line bg-white px-3 py-2.5 text-left transition-colors hover:bg-accent-weak",
              focusRing,
            )}
          >
            <span className="truncate text-sm font-bold">{row.title}</span>
            <span className={cn("rounded-pill px-2.5 py-1 text-xs font-bold whitespace-nowrap", chipTone[row.tone])}>{row.chip}</span>
            <span className="col-span-full text-xs text-muted">{row.sub}</span>
            <span className="col-span-full text-xs font-semibold text-ink">{row.when}</span>
          </button>
        ))}
        {loaded && !failed && list.length === 0 ? (
          <p className="px-4 py-8 text-center text-sm text-muted">{EMPTY_TEXT[tab]}</p>
        ) : null}
        {!loaded && !failed ? <p className="px-4 py-8 text-center text-sm text-muted">불러오는 중…</p> : null}
      </div>
    </aside>
  );
}
