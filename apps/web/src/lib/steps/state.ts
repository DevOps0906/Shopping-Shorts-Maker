/*
 * 6단계 상태 머신 — 근거: docs/planning.md 6장, 전이 규칙 정본은
 * supabase/migrations/20261112170400_step_approval_functions.sql (approve_step · request_step_change).
 * 이 파일은 DB 규칙과 같은 판단을 하는 순수 함수만 둔다. 화면의 버튼 활성 여부에 쓰고,
 * 실제 변경은 항상 DB 함수가 다시 검사한다.
 */

export const STEP_STATES = ["idle", "running", "suggested", "ready", "change", "approved"] as const;
export type StepState = (typeof STEP_STATES)[number];

export const STEP_NUMBERS = [1, 2, 3, 4, 5, 6] as const;
export type StepNumber = (typeof STEP_NUMBERS)[number];

/** projects.step_status(jsonb) 모양: {"1":"idle", …, "6":"idle"} */
export type StepStatusMap = Readonly<Record<StepNumber, StepState>>;

/** 06 발행은 발행 버튼이 승인을 대신하므로 approve_step은 1~5단계만 받는다 */
export const LAST_APPROVABLE_STEP = 5;

export const INITIAL_STEP_STATUS: StepStatusMap = {
  1: "idle",
  2: "idle",
  3: "idle",
  4: "idle",
  5: "idle",
  6: "idle",
};

export function isStepNumber(value: unknown): value is StepNumber {
  return typeof value === "number" && Number.isInteger(value) && value >= 1 && value <= 6;
}

function isStepState(value: unknown): value is StepState {
  return typeof value === "string" && (STEP_STATES as readonly string[]).includes(value);
}

/** DB·Realtime에서 받은 jsonb를 검사한다. 키 6개가 모두 있고 값이 상태 6개 중 하나여야 한다. */
export function parseStepStatus(raw: unknown): StepStatusMap | null {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return null;
  const record = raw as Record<string, unknown>;
  const parsed = {} as Record<StepNumber, StepState>;
  for (const step of STEP_NUMBERS) {
    const value = record[String(step)];
    if (!isStepState(value)) return null;
    parsed[step] = value;
  }
  return parsed;
}

function previousApproved(status: StepStatusMap, step: StepNumber) {
  return STEP_NUMBERS.every((n) => n >= step || status[n] === "approved");
}

/** approve_step 규칙: 1~5단계, 앞 단계 모두 approved, 이 단계 ready */
export function canApprove(status: StepStatusMap, step: StepNumber) {
  return step <= LAST_APPROVABLE_STEP && previousApproved(status, step) && status[step] === "ready";
}

/** request_step_change 규칙: 이 단계가 ready 또는 approved */
export function canRequestChange(status: StepStatusMap, step: StepNumber) {
  return status[step] === "ready" || status[step] === "approved";
}

/** 다음 단계 버튼: 이 단계가 승인되어야 열린다 */
export function canProceed(status: StepStatusMap, step: StepNumber) {
  return status[step] === "approved";
}

/** approve_step과 같은 결과. 규칙을 어기면 null */
export function applyApprove(status: StepStatusMap, step: StepNumber): StepStatusMap | null {
  if (!canApprove(status, step)) return null;
  return { ...status, [step]: "approved" };
}

/** request_step_change와 같은 결과: 이 단계는 change, 뒤 단계는 모두 idle(초기화 연쇄). 규칙을 어기면 null */
export function applyChangeRequest(status: StepStatusMap, step: StepNumber): StepStatusMap | null {
  if (!canRequestChange(status, step)) return null;
  const next = { ...status } as Record<StepNumber, StepState>;
  for (const n of STEP_NUMBERS) {
    if (n === step) next[n] = "change";
    else if (n > step) next[n] = "idle";
  }
  return next;
}

/** 변경 요청 시 초기화되는 뒤 단계 중 이미 진행된(idle이 아닌) 단계 — 확인 문구에 쓴다 */
export function stepsResetByChange(status: StepStatusMap, step: StepNumber): StepNumber[] {
  return STEP_NUMBERS.filter((n) => n > step && status[n] !== "idle");
}

export function approvedCount(status: StepStatusMap) {
  return STEP_NUMBERS.filter((n) => status[n] === "approved").length;
}
