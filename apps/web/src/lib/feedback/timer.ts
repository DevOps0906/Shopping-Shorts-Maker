/** 멈출 수 있는 타이머 — 포인터 올림·포커스 중에는 멈춘다(WCAG 2.2.1, docs/ui-feedback.md 3-3). */
export type PausableTimer = {
  pause: () => void;
  resume: () => void;
  clear: () => void;
};

export function createPausableTimer(onDone: () => void, ms: number): PausableTimer {
  let remaining = ms;
  let startedAt = 0;
  let handle: ReturnType<typeof setTimeout> | null = null;

  const resume = () => {
    if (handle !== null || remaining <= 0) return;
    startedAt = Date.now();
    handle = setTimeout(() => {
      handle = null;
      remaining = 0;
      onDone();
    }, remaining);
  };
  const pause = () => {
    if (handle === null) return;
    clearTimeout(handle);
    handle = null;
    remaining -= Date.now() - startedAt;
  };
  const clear = () => {
    if (handle !== null) clearTimeout(handle);
    handle = null;
    remaining = 0;
  };

  resume();
  return { pause, resume, clear };
}
