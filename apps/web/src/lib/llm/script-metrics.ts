/*
 * 03 대본 예상 길이 — docs/planning.md 3장 03(문장별 예상 초 · 예상 길이 미터 · 목표 15~20초).
 * 말하기 속도는 가정값(한국어 내레이션 초당 6.5음절 + 문장 사이 쉼 0.3초). 04 목소리 실측 후 고친다.
 * 합계 오차를 막으려고 내부 계산은 0.1초 단위 정수로 한다.
 */

export const SYLLABLES_PER_SEC = 6.5;
export const PAUSE_TENTHS = 3;
export const MAX_SCRIPT_LINES = 12;
export const MAX_LINE_CHARS = 120;

/** 발음되는 글자(한글·영문·숫자)만 센다 */
const SPOKEN = /[가-힣A-Za-z0-9]/g;

/** 작업칸 글 → 문장 배열(한 줄에 한 문장, 빈 줄 제외) */
export function splitScript(text: string): string[] {
  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

/** 문장 하나의 예상 길이(0.1초 단위 정수) */
export function lineTenths(line: string): number {
  const spoken = line.match(SPOKEN)?.length ?? 0;
  if (spoken === 0) return 0;
  return Math.ceil((spoken * 10) / SYLLABLES_PER_SEC) + PAUSE_TENTHS;
}

export function totalTenths(lines: readonly string[]): number {
  return lines.reduce((sum, line) => sum + lineTenths(line), 0);
}

export const formatSec = (tenths: number) => `${(tenths / 10).toFixed(1)}초`;

export type MeterState = "empty" | "short" | "fit" | "long";

/** 목표 길이 대비 상태: 목표의 85% 이상 ~ 목표 이하면 적정 */
export function meterState(tenths: number, targetSec: number): MeterState {
  if (tenths === 0) return "empty";
  const target = targetSec * 10;
  if (tenths > target) return "long";
  if (tenths < Math.ceil(target * 0.85)) return "short";
  return "fit";
}

/** 저장 전 검사(서버·화면 공통). 문제가 없으면 null */
export function validateLines(lines: readonly string[]): string | null {
  if (lines.length === 0) return "작업칸에 1문장 이상 적어 주세요.";
  if (lines.length > MAX_SCRIPT_LINES) return `문장은 ${MAX_SCRIPT_LINES}개까지 적을 수 있습니다.`;
  if (lines.some((line) => line.length > MAX_LINE_CHARS)) return `한 문장은 ${MAX_LINE_CHARS}자까지 적을 수 있습니다.`;
  return null;
}
