/**
 * confirm({...}) → Promise<boolean> 제어기.
 * 알림 대화상자는 한 번에 1개(docs/ui-feedback.md 3-2): 열린 동안 들어온 요청은 차례로 기다린다.
 */
import type { ConfirmOptions } from "./types";

export type ConfirmRequest = ConfirmOptions & { id: number };

export type ConfirmController = {
  confirm: (options: ConfirmOptions) => Promise<boolean>;
  /** 열린 대화상자에 답한다. 확인 = true, 취소·Esc = false */
  settle: (result: boolean) => void;
  current: () => ConfirmRequest | null;
};

export function createConfirmController(onChange: (current: ConfirmRequest | null) => void): ConfirmController {
  const pending: { request: ConfirmRequest; resolve: (v: boolean) => void }[] = [];
  let seq = 0;

  const current = () => pending[0]?.request ?? null;

  return {
    confirm(options) {
      return new Promise<boolean>((resolve) => {
        pending.push({ request: { ...options, id: ++seq }, resolve });
        if (pending.length === 1) onChange(current());
      });
    },
    settle(result) {
      const head = pending.shift();
      if (!head) return;
      head.resolve(result);
      onChange(current());
    },
    current,
  };
}
