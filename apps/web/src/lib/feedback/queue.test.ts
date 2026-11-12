import { describe, expect, it } from "vitest";
import { dismiss, durationOf, emptyQueue, push, setMax } from "./queue";
import { type FeedbackItem, MAX_VISIBLE, TOAST_MS } from "./types";

let n = 0;
const toast = (message = "저장했습니다", key?: string): FeedbackItem => ({ id: `t${++n}`, kind: "toast", tone: "info", message, key, rev: 0 });
const errorBar = (message = "실패했습니다"): FeedbackItem => ({ id: `e${++n}`, kind: "snackbar", tone: "error", message, rev: 0 });

const pushAll = (max: number, items: FeedbackItem[]) => items.reduce(push, emptyQueue(max));

describe("동시 표시 상한", () => {
  it("모바일은 1개, 나머지는 FIFO 대기", () => {
    const [a, b, c] = [toast("a"), toast("b"), toast("c")];
    const s = pushAll(MAX_VISIBLE.mobile, [a, b, c]);
    expect(s.visible.map((i) => i.message)).toEqual(["a"]);
    expect(s.queue.map((i) => i.message)).toEqual(["b", "c"]);
  });

  it("태블릿·데스크톱은 3개, 새 것이 끝(아래)", () => {
    const s = pushAll(MAX_VISIBLE.wide, ["a", "b", "c", "d"].map((m) => toast(m)));
    expect(s.visible.map((i) => i.message)).toEqual(["a", "b", "c"]);
    expect(s.queue.map((i) => i.message)).toEqual(["d"]);
  });

  it("닫으면 대기열에서 채운다", () => {
    const [a, b] = [toast("a"), toast("b")];
    const s = dismiss(pushAll(1, [a, b]), a.id);
    expect(s.visible.map((i) => i.message)).toEqual(["b"]);
    expect(s.queue).toEqual([]);
  });

  it("모바일로 줄면 넘치는 것을 대기열 앞으로 돌린다", () => {
    const s = setMax(pushAll(3, ["a", "b", "c", "d"].map((m) => toast(m))), 1);
    expect(s.visible.map((i) => i.message)).toEqual(["a"]);
    expect(s.queue.map((i) => i.message)).toEqual(["b", "c", "d"]);
    expect(setMax(s, 3).visible.map((i) => i.message)).toEqual(["a", "b", "c"]);
  });
});

describe("오류 우선", () => {
  it("오류 스낵바는 대기열 맨 앞으로", () => {
    const s = pushAll(1, [toast("a"), toast("b"), errorBar("err")]);
    expect(s.queue.map((i) => i.message)).toEqual(["err", "b"]);
  });
});

describe("같은 key", () => {
  it("새로 띄우지 않고 내용을 바꾸고 rev를 올린다(id 유지)", () => {
    const first = toast("렌더 중", "render:1");
    let s = pushAll(3, [first]);
    s = push(s, { ...toast("렌더 완료", "render:1"), kind: "snackbar" });
    expect(s.visible).toHaveLength(1);
    expect(s.visible[0]).toMatchObject({ id: first.id, message: "렌더 완료", kind: "snackbar", rev: 1 });
  });

  it("대기열 안의 같은 key도 교체한다", () => {
    let s = pushAll(1, [toast("a"), toast("b", "k")]);
    s = push(s, toast("b2", "k"));
    expect(s.queue.map((i) => i.message)).toEqual(["b2"]);
  });

  it("key로 닫을 수 있다", () => {
    const s = dismiss(pushAll(3, [toast("a", "k")]), "k");
    expect(s.visible).toEqual([]);
  });
});

describe("지속 시간", () => {
  it("토스트 4초, 20자 넘으면 +1초", () => {
    expect(durationOf(toast("짧은 문구"))).toBe(TOAST_MS.info);
    expect(durationOf(toast("가".repeat(21)))).toBe(TOAST_MS.info + 1000);
  });

  it("스낵바 6초, 실행 취소 8초, 오류는 자동으로 닫지 않음", () => {
    const bar = (undo: boolean): FeedbackItem => ({ ...toast(), kind: "snackbar", action: { label: "x", onAction: () => {}, undo } });
    expect(durationOf(bar(false))).toBe(6000);
    expect(durationOf(bar(true))).toBe(8000);
    expect(durationOf(errorBar())).toBeNull();
  });
});
