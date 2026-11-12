/** 토스트·스낵바·알림 대화상자 공용 타입 (docs/ui-feedback.md 3장) */

/** 표시 시간(ms). CSS가 아닌 TS 상수 — docs/ui-feedback.md 3-5 */
export const TOAST_MS = { info: 4000, action: 6000, undo: 8000 } as const;

/** 정보 토스트 문구가 이 글자 수를 넘으면 +1초 (3-3) */
export const TOAST_LONG_TEXT = 20;
export const TOAST_LONG_EXTRA_MS = 1000;

/** 동시 표시 개수 (3-2): 모바일 1, 태블릿·데스크톱 3 */
export const MAX_VISIBLE = { mobile: 1, wide: 3 } as const;

export type ToastTone = "info" | "success";
export type SnackbarTone = "info" | "error";

export type ToastOptions = {
  message: string;
  tone?: ToastTone;
  /** 같은 key는 새로 띄우지 않고 내용·타이머를 갱신한다(예: `render:{projectId}`). */
  key?: string;
};

export type SnackbarAction = {
  label: string;
  onAction: () => void;
  /** 실행 취소면 8초, 보기·이동이면 6초 */
  undo?: boolean;
};

export type SnackbarOptions = {
  message: string;
  /** 버튼은 1개만(4장). 오류 스낵바는 닫기(×)가 따로 붙는다. */
  action?: SnackbarAction;
  tone?: SnackbarTone;
  key?: string;
};

export type FeedbackItem = {
  id: string;
  kind: "toast" | "snackbar";
  tone: ToastTone | SnackbarTone;
  message: string;
  action?: SnackbarAction;
  key?: string;
  /** 같은 key로 갱신될 때마다 올라간다 → 타이머 다시 시작 */
  rev: number;
};

export type ConfirmOptions = {
  title: string;
  /** 결과 설명(aria-describedby) */
  description: string;
  confirmLabel: string;
  cancelLabel?: string;
  /** 되돌릴 수 없는 행동이면 위험 색 */
  danger?: boolean;
};
