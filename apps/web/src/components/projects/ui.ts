/* 홈·새 프로젝트·프로젝트 관리·트렌드 공용 클래스 — 프로토타입 .card · .btn · .chip · .seg · .sbadge 를 토큰 유틸리티로 옮긴 것 */

export const cardClass = "rounded-card border border-line bg-white shadow-card";
export const sectClass = `${cardClass} p-4 tablet:p-5.5`;
export const btnClass =
  "inline-flex min-h-11 items-center justify-center gap-1.5 rounded-btn border border-line bg-white px-4 text-sm font-semibold whitespace-nowrap text-ink transition-colors hover:border-accent-line hover:bg-sub-hover disabled:cursor-not-allowed disabled:border-accent-line disabled:bg-accent-line disabled:text-muted";
export const btnPrimaryClass = "border-accent bg-accent text-white hover:border-accent hover:bg-nav-on-ink";
export const btnSmClass = "min-h-9 rounded-btn-sm px-3 text-xs";
export const btnGhostClass = "border-transparent bg-transparent px-2 text-accent hover:border-transparent hover:bg-transparent hover:underline";
export const chipClass =
  "inline-flex min-h-11 items-center rounded-btn border border-accent-line bg-sub-hover px-4 text-sm font-semibold text-nav-on-ink transition-colors hover:bg-accent-weak";
export const chipOnClass = "border-accent bg-accent text-white hover:bg-accent";
export const segClass = "inline-flex flex-wrap gap-1 rounded-btn bg-count-bg p-1";
export const segBtnClass =
  "inline-flex min-h-9 items-center rounded-btn-sm px-3.5 text-xs font-bold text-muted transition-colors hover:text-nav-on-ink disabled:cursor-not-allowed disabled:opacity-60 disabled:hover:text-muted";
export const segBtnOnClass = "bg-white text-nav-on-ink shadow-card";
export const badgeClass = "inline-flex rounded-pill px-2.5 py-0.5 text-xs font-bold whitespace-nowrap";
export const noteClass = "text-xs text-muted";
export const labelClass = "mb-2 block text-xs font-semibold text-muted";
export const fieldClass =
  "min-h-11 w-full rounded-btn border border-line bg-white px-3.5 text-sm text-ink focus:border-accent focus:outline-2 focus:outline-accent-line";
export const trackClass = "h-1.5 overflow-hidden rounded-pill bg-count-bg";
export const barClass = "block h-full rounded-pill bg-accent";
export const thClass = "border-b border-line px-2.5 py-2 text-left text-xs font-semibold whitespace-nowrap text-muted";
export const tdClass = "border-b border-line px-2.5 py-2.5 align-middle";
