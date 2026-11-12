"use server";

import { pollRender, startRender } from "@/server/edit/edit";

/* 05 편집 서버 액션 진입점. 구현은 src/server/edit/edit.ts(소유권·단계 상태·편집 입력 원본을 서버에서 다시 검사) */

export async function startRenderAction(projectId: string, assignment: string[], idempotencyKey: string) {
  if (typeof projectId !== "string") return { ok: false as const, error: "잘못된 요청입니다." };
  return startRender(projectId, assignment, idempotencyKey);
}

export async function pollRenderAction(projectId: string, jobId: string) {
  if (typeof projectId !== "string") return { ok: false as const, error: "잘못된 요청입니다." };
  return pollRender(projectId, jobId);
}
