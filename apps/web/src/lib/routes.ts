/** 제작단계 6개 — URL 조각은 docs/03_SCREENS_UX.md 화면 표 기준 */
export const STUDIO_STEPS = [
  { slug: "topic", label: "소재" },
  { slug: "source", label: "소스" },
  { slug: "script", label: "대본" },
  { slug: "voice", label: "목소리" },
  { slug: "edit", label: "편집" },
  { slug: "publish", label: "발행" },
] as const;

/** 환경설정 하위 3개 */
export const SETTINGS_TABS = [
  { slug: "profile", label: "프로필 설정" },
  { slug: "accounts", label: "다중 계정" },
  { slug: "api-keys", label: "모델 API 키" },
] as const;

export type StudioStepSlug = (typeof STUDIO_STEPS)[number]["slug"];
export type SettingsTabSlug = (typeof SETTINGS_TABS)[number]["slug"];

export function findStudioStep(slug: string) {
  const index = STUDIO_STEPS.findIndex((step) => step.slug === slug);
  return index === -1 ? null : { ...STUDIO_STEPS[index], num: index + 1 };
}

export function findSettingsTab(slug: string) {
  const index = SETTINGS_TABS.findIndex((tab) => tab.slug === slug);
  return index === -1 ? null : { ...SETTINGS_TABS[index], num: index + 1 };
}
