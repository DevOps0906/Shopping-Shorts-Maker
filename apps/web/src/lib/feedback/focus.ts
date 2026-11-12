/** 대화상자 키 처리 (docs/ui-feedback.md 3-4): Esc로 닫기, Tab 순환(포커스 트랩). */

export const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

/** 첫 포커스 지정 표시. 알림 대화상자는 취소 버튼에 붙인다. */
export const AUTOFOCUS_ATTR = "data-autofocus";

export type DialogKeyResult = { type: "close" } | { type: "focus"; index: number } | null;

/**
 * @param index 현재 포커스가 focusables 안에서 몇 번째인지(밖이면 -1)
 * @param count focusables 개수
 */
export function dialogKeyAction(key: string, shiftKey: boolean, index: number, count: number): DialogKeyResult {
  if (key === "Escape") return { type: "close" };
  if (key !== "Tab" || count === 0) return null;
  if (shiftKey && index <= 0) return { type: "focus", index: count - 1 };
  if (!shiftKey && (index === -1 || index === count - 1)) return { type: "focus", index: 0 };
  return null;
}
