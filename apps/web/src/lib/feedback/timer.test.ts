import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createPausableTimer } from "./timer";

describe("createPausableTimer", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("시간이 지나면 닫는다", () => {
    const done = vi.fn();
    createPausableTimer(done, 4000);
    vi.advanceTimersByTime(3999);
    expect(done).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1);
    expect(done).toHaveBeenCalledOnce();
  });

  it("멈춘 동안은 닫지 않고, 재개하면 남은 시간만 기다린다", () => {
    const done = vi.fn();
    const t = createPausableTimer(done, 6000);
    vi.advanceTimersByTime(2000);
    t.pause();
    vi.advanceTimersByTime(60000);
    expect(done).not.toHaveBeenCalled();
    t.resume();
    vi.advanceTimersByTime(3999);
    expect(done).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1);
    expect(done).toHaveBeenCalledOnce();
  });

  it("clear 후에는 호출하지 않는다", () => {
    const done = vi.fn();
    const t = createPausableTimer(done, 1000);
    t.clear();
    t.resume();
    vi.advanceTimersByTime(5000);
    expect(done).not.toHaveBeenCalled();
  });
});
