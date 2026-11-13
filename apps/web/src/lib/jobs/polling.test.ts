import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { type VisibilityDoc, startQueuePolling } from "./polling";

function fakeDoc(hidden = false) {
  let listener: (() => void) | null = null;
  const doc: VisibilityDoc = {
    hidden,
    addEventListener: (_t, l) => {
      listener = l;
    },
    removeEventListener: () => {
      listener = null;
    },
  };
  return { doc, fire: () => listener?.(), hasListener: () => listener !== null };
}

describe("startQueuePolling", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("시작 즉시 1회 조회하고 간격마다 반복", () => {
    const load = vi.fn();
    const { doc } = fakeDoc();
    startQueuePolling(load, 1000, doc);
    expect(load).toHaveBeenCalledTimes(1);
    vi.advanceTimersByTime(2000);
    expect(load).toHaveBeenCalledTimes(3);
  });

  it("숨기면 중단, 복귀하면 1회 조회 후 재개", () => {
    const load = vi.fn();
    const { doc, fire } = fakeDoc();
    startQueuePolling(load, 1000, doc);
    doc.hidden = true;
    fire();
    vi.advanceTimersByTime(5000);
    expect(load).toHaveBeenCalledTimes(1);
    doc.hidden = false;
    fire();
    expect(load).toHaveBeenCalledTimes(2);
    vi.advanceTimersByTime(1000);
    expect(load).toHaveBeenCalledTimes(3);
  });

  it("숨겨진 채 시작하면 조회하지 않고, 정리하면 모두 멈춤", () => {
    const load = vi.fn();
    const { doc, hasListener } = fakeDoc(true);
    const stop = startQueuePolling(load, 1000, doc);
    expect(load).not.toHaveBeenCalled();
    stop();
    expect(hasListener()).toBe(false);
  });
});
