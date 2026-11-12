"use server";

import { draftScript, saveScript } from "@/server/llm/script";

/* 03 대본 서버 액션 진입점. 구현은 src/server/llm/script.ts(소유권·단계 상태·금지 표현을 서버에서 다시 검사) */

export async function draftScriptAction(projectId: string) {
  if (typeof projectId !== "string") return { ok: false as const, error: "잘못된 요청입니다." };
  return draftScript(projectId);
}

export async function saveScriptAction(projectId: string, lines: string[]) {
  if (typeof projectId !== "string") return { ok: false as const, error: "잘못된 요청입니다." };
  return saveScript(projectId, lines);
}
