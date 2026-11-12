/**
 * 제작 파트너 FAB 자리 (design.md 6장). 팝업·대화 연결은 별도 작업에서 붙인다.
 * 모바일(~767)에서는 라벨을 숨기고 아이콘만 보인다.
 */
export function ChatFab() {
  return (
    <button
      type="button"
      aria-label="제작 파트너 (준비 중)"
      aria-disabled="true"
      className="fixed right-(--fab-inset) bottom-(--fab-inset) z-(--z-fab) flex h-(--fab-size) min-w-(--fab-size) cursor-not-allowed items-center justify-center gap-2 rounded-pill bg-accent px-3.5 text-sm font-bold text-white shadow-fab tablet:pr-5 tablet:pl-4"
    >
      <svg
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
        className="size-6"
      >
        <path d="M21 12a8 8 0 0 1-11.6 7.1L4 20.5l1.4-4.9A8 8 0 1 1 21 12z" />
        <path d="M8.5 11h.01M12 11h.01M15.5 11h.01" />
      </svg>
      <span className="hidden tablet:inline">제작 파트너</span>
    </button>
  );
}
