/*
 * 작업 현황 폴링 — 시작 즉시 1회 조회, 문서가 숨겨지면 중단, 다시 보이면 1회 조회 후 재개한다.
 * 훅(use-queue-status)에서 분리해 DOM 없이 테스트한다.
 */
export type VisibilityDoc = {
  hidden: boolean;
  addEventListener: (type: "visibilitychange", listener: () => void) => void;
  removeEventListener: (type: "visibilitychange", listener: () => void) => void;
};

export function startQueuePolling(load: () => void, intervalMs: number, doc: VisibilityDoc): () => void {
  let timer: ReturnType<typeof setInterval> | null = null;
  const stop = () => {
    if (timer !== null) clearInterval(timer);
    timer = null;
  };
  const start = () => {
    stop();
    load();
    timer = setInterval(load, intervalMs);
  };
  const onVisibility = () => {
    if (doc.hidden) stop();
    else start();
  };
  if (!doc.hidden) start();
  doc.addEventListener("visibilitychange", onVisibility);
  return () => {
    stop();
    doc.removeEventListener("visibilitychange", onVisibility);
  };
}
