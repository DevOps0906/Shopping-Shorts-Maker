"use server";

import { saveTopic, suggestTopics } from "@/server/llm/topics";

/* 01 소재 서버 액션 진입점. 구현은 src/server/llm/topics.ts(소유권·단계 상태를 서버에서 다시 검사) */

export async function suggestTopicsAction(projectId: string, hint: string) {
  if (typeof projectId !== "string" || typeof hint !== "string") return { ok: false as const, error: "잘못된 요청입니다." };
  return suggestTopics(projectId, hint);
}

export async function saveTopicAction(projectId: string, name: string, productUrl: string) {
  if (typeof projectId !== "string" || typeof name !== "string" || typeof productUrl !== "string") return { ok: false as const, error: "잘못된 요청입니다." };
  return saveTopic(projectId, name, productUrl);
}
