import { describe, expect, it } from "vitest";
import {
  INITIAL_STEP_STATUS,
  type StepStatusMap,
  applyApprove,
  applyChangeRequest,
  approvedCount,
  canApprove,
  canProceed,
  canRequestChange,
  parseStepStatus,
  stepsResetByChange,
} from "./state";

const allApprovedThrough = (last: number, rest: Partial<StepStatusMap> = {}): StepStatusMap => ({
  1: last >= 1 ? "approved" : "idle",
  2: last >= 2 ? "approved" : "idle",
  3: last >= 3 ? "approved" : "idle",
  4: last >= 4 ? "approved" : "idle",
  5: last >= 5 ? "approved" : "idle",
  6: last >= 6 ? "approved" : "idle",
  ...rest,
});

describe("parseStepStatus", () => {
  it("DB 기본값을 읽는다", () => {
    expect(parseStepStatus({ 1: "idle", 2: "idle", 3: "idle", 4: "idle", 5: "idle", 6: "idle" })).toEqual(
      INITIAL_STEP_STATUS,
    );
  });

  it("키가 빠지거나 모르는 상태·배열·null이면 null", () => {
    expect(parseStepStatus({ 1: "idle", 2: "idle", 3: "idle", 4: "idle", 5: "idle" })).toBeNull();
    expect(parseStepStatus({ ...INITIAL_STEP_STATUS, 3: "done" })).toBeNull();
    expect(parseStepStatus(["idle"])).toBeNull();
    expect(parseStepStatus(null)).toBeNull();
    expect(parseStepStatus("idle")).toBeNull();
  });
});

describe("승인(approve_step 규칙)", () => {
  it("1단계 ready면 승인할 수 있고 1단계만 approved가 된다", () => {
    const status = { ...INITIAL_STEP_STATUS, 1: "ready" } as const;
    expect(canApprove(status, 1)).toBe(true);
    expect(applyApprove(status, 1)).toEqual({ ...INITIAL_STEP_STATUS, 1: "approved" });
  });

  it("ready가 아니면 승인할 수 없다(change·running·suggested·idle·approved)", () => {
    for (const state of ["idle", "running", "suggested", "change", "approved"] as const) {
      const status = allApprovedThrough(1, { 2: state });
      expect(canApprove(status, 2)).toBe(false);
      expect(applyApprove(status, 2)).toBeNull();
    }
  });

  it("앞 단계가 하나라도 승인되지 않았으면 승인할 수 없다", () => {
    const status = allApprovedThrough(2, { 2: "ready", 3: "ready" });
    expect(canApprove(status, 3)).toBe(false);
    expect(canApprove(allApprovedThrough(2, { 3: "ready" }), 3)).toBe(true);
  });

  it("06 발행은 승인 버튼으로 승인하지 않는다", () => {
    expect(canApprove(allApprovedThrough(5, { 6: "ready" }), 6)).toBe(false);
  });

  it("다음 단계는 이 단계가 승인되어야 열린다", () => {
    expect(canProceed(allApprovedThrough(1), 1)).toBe(true);
    expect(canProceed(allApprovedThrough(1, { 2: "ready" }), 2)).toBe(false);
  });
});

describe("변경 요청(request_step_change 규칙)과 초기화 연쇄", () => {
  it("ready·approved에서만 요청할 수 있다", () => {
    expect(canRequestChange(allApprovedThrough(0, { 1: "ready" }), 1)).toBe(true);
    expect(canRequestChange(allApprovedThrough(1), 1)).toBe(true);
    for (const state of ["idle", "running", "suggested", "change"] as const) {
      const status = { ...INITIAL_STEP_STATUS, 1: state };
      expect(canRequestChange(status, 1)).toBe(false);
      expect(applyChangeRequest(status, 1)).toBeNull();
    }
  });

  it("승인된 앞 단계를 바꾸면 이 단계는 change, 뒤 단계는 모두 idle", () => {
    const status = allApprovedThrough(4, { 5: "running", 6: "suggested" });
    expect(applyChangeRequest(status, 2)).toEqual({
      1: "approved",
      2: "change",
      3: "idle",
      4: "idle",
      5: "idle",
      6: "idle",
    });
  });

  it("앞 단계는 그대로 둔다", () => {
    const next = applyChangeRequest(allApprovedThrough(5, { 6: "ready" }), 6);
    expect(next).toEqual(allApprovedThrough(5, { 6: "change" }));
  });

  it("초기화되는 진행 단계를 알려 준다", () => {
    expect(stepsResetByChange(allApprovedThrough(3, { 4: "running" }), 1)).toEqual([2, 3, 4]);
    expect(stepsResetByChange(allApprovedThrough(0, { 1: "ready" }), 1)).toEqual([]);
  });

  it("변경 후 다시 ready가 되면 재승인할 수 있고, 뒤 단계는 다시 처음부터 승인해야 한다", () => {
    const changed = applyChangeRequest(allApprovedThrough(3), 2);
    expect(changed).not.toBeNull();
    const readyAgain = { ...changed!, 2: "ready" } as const;
    const approved = applyApprove(readyAgain, 2);
    expect(approved).toEqual(allApprovedThrough(2));
    expect(canApprove({ ...approved!, 4: "ready" }, 4)).toBe(false);
    expect(approvedCount(approved!)).toBe(2);
  });
});
