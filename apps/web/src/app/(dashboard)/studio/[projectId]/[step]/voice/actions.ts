"use server";

import { pollTts, startTts } from "@/server/voice/voice";

/* 04 목소리 서버 액션 진입점. 구현은 src/server/voice/voice.ts(소유권·단계 상태를 서버에서 다시 검사) */

export async function startTtsAction(projectId: string, voiceId: string, idempotencyKey: string) {
  if (typeof projectId !== "string") return { ok: false as const, error: "잘못된 요청입니다." };
  return startTts(projectId, voiceId, idempotencyKey);
}

export async function pollTtsAction(projectId: string, jobId: string) {
  if (typeof projectId !== "string") return { ok: false as const, error: "잘못된 요청입니다." };
  return pollTts(projectId, jobId);
}
