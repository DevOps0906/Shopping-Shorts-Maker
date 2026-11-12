import { describe, expect, it, vi } from "vitest";
import { createConfirmController } from "./confirm";
import { dialogKeyAction } from "./focus";

const opts = { title: "삭제할까요?", description: "되돌릴 수 없습니다", confirmLabel: "삭제" };

describe("confirm → Promise<boolean>", () => {
  it("확인이면 true, 취소면 false", async () => {
    const c = createConfirmController(() => {});
    const yes = c.confirm(opts);
    c.settle(true);
    await expect(yes).resolves.toBe(true);
    const no = c.confirm(opts);
    c.settle(false);
    await expect(no).resolves.toBe(false);
  });

  it("한 번에 1개만 열고 다음 요청은 차례로", async () => {
    const onChange = vi.fn();
    const c = createConfirmController(onChange);
    const a = c.confirm({ ...opts, title: "A" });
    const b = c.confirm({ ...opts, title: "B" });
    expect(c.current()?.title).toBe("A");
    c.settle(false);
    await expect(a).resolves.toBe(false);
    expect(c.current()?.title).toBe("B");
    c.settle(true);
    await expect(b).resolves.toBe(true);
    expect(c.current()).toBeNull();
    expect(onChange).toHaveBeenLastCalledWith(null);
  });
});

describe("dialogKeyAction", () => {
  it("Esc는 닫기(=취소)", () => {
    expect(dialogKeyAction("Escape", false, 0, 2)).toEqual({ type: "close" });
  });

  it("Tab은 끝에서 처음으로, Shift+Tab은 처음에서 끝으로 순환", () => {
    expect(dialogKeyAction("Tab", false, 1, 2)).toEqual({ type: "focus", index: 0 });
    expect(dialogKeyAction("Tab", true, 0, 2)).toEqual({ type: "focus", index: 1 });
    expect(dialogKeyAction("Tab", false, 0, 2)).toBeNull();
    expect(dialogKeyAction("Tab", false, -1, 2)).toEqual({ type: "focus", index: 0 });
  });

  it("다른 키는 무시", () => {
    expect(dialogKeyAction("Enter", false, 0, 2)).toBeNull();
  });
});
