"use server";

import { callStepFunction } from "@/server/steps/step-functions";

/* 단계 승인·변경 요청 서버 액션 진입점. 구현은 src/server/steps/step-functions.ts */

export async function approveStep(projectId: string, step: number) {
  return callStepFunction("approve_step", projectId, step);
}

export async function requestStepChange(projectId: string, step: number) {
  return callStepFunction("request_step_change", projectId, step);
}
