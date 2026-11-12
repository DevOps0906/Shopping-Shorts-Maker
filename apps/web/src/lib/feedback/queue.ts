/**
 * 알림 큐 (docs/ui-feedback.md 3-2, 3-3). 순수 함수만 두어 테스트한다.
 * - visible: 화면에 보이는 것(앞 = 위, 끝 = 아래·최신)
 * - queue: 대기열 FIFO, 오류 스낵바는 맨 앞
 */
import {
  type FeedbackItem,
  TOAST_LONG_EXTRA_MS,
  TOAST_LONG_TEXT,
  TOAST_MS,
} from "./types";

export type QueueState = {
  visible: FeedbackItem[];
  queue: FeedbackItem[];
  max: number;
};

export const emptyQueue = (max: number): QueueState => ({ visible: [], queue: [], max });

export const isError = (item: FeedbackItem) => item.kind === "snackbar" && item.tone === "error";

/** 자동 닫힘까지의 시간. null이면 자동으로 닫지 않는다(오류 스낵바). */
export function durationOf(item: FeedbackItem): number | null {
  if (item.kind === "toast") {
    return TOAST_MS.info + (item.message.length > TOAST_LONG_TEXT ? TOAST_LONG_EXTRA_MS : 0);
  }
  if (item.tone === "error") return null;
  return item.action?.undo ? TOAST_MS.undo : TOAST_MS.action;
}

function fill(state: QueueState): QueueState {
  if (state.visible.length >= state.max || state.queue.length === 0) return state;
  const room = state.max - state.visible.length;
  return {
    ...state,
    visible: [...state.visible, ...state.queue.slice(0, room)],
    queue: state.queue.slice(room),
  };
}

const replaceIn = (list: FeedbackItem[], next: FeedbackItem) =>
  list.map((it) => (it.key === next.key ? { ...next, id: it.id, rev: it.rev + 1 } : it));

export function push(state: QueueState, item: FeedbackItem): QueueState {
  if (item.key !== undefined) {
    if (state.visible.some((it) => it.key === item.key)) {
      return { ...state, visible: replaceIn(state.visible, item) };
    }
    if (state.queue.some((it) => it.key === item.key)) {
      return { ...state, queue: replaceIn(state.queue, item) };
    }
  }
  const queue = isError(item) ? [item, ...state.queue] : [...state.queue, item];
  return fill({ ...state, queue });
}

/** id 또는 key로 닫는다. */
export function dismiss(state: QueueState, idOrKey: string): QueueState {
  const keep = (it: FeedbackItem) => it.id !== idOrKey && it.key !== idOrKey;
  return fill({
    ...state,
    visible: state.visible.filter(keep),
    queue: state.queue.filter(keep),
  });
}

/** 화면 구간이 바뀌면 상한을 바꾼다. 넘치는 것은 순서를 지켜 대기열 앞으로 돌린다. */
export function setMax(state: QueueState, max: number): QueueState {
  if (max === state.max) return state;
  if (state.visible.length <= max) return fill({ ...state, max });
  return {
    max,
    visible: state.visible.slice(0, max),
    queue: [...state.visible.slice(max), ...state.queue],
  };
}
