"use server";

import { chooseBioService, preparePublication, refreshPolicy, saveAffiliate, setUserCheck } from "@/server/publish/publish";

/* 06 발행 서버 액션 진입점. 구현은 src/server/publish/publish.ts(소유권·함수 전용 열·정책 6/6은 DB 함수가 다시 검사) */

export async function refreshPolicyAction(projectId: string, copy: unknown) {
  if (typeof projectId !== "string") return { ok: false as const, error: "잘못된 요청입니다." };
  return refreshPolicy(projectId, copy);
}

export async function saveAffiliateAction(projectId: string, input: unknown, copy: unknown) {
  if (typeof projectId !== "string") return { ok: false as const, error: "잘못된 요청입니다." };
  return saveAffiliate(projectId, input, copy);
}

export async function chooseBioServiceAction(projectId: string, service: unknown, copy: unknown) {
  if (typeof projectId !== "string") return { ok: false as const, error: "잘못된 요청입니다." };
  return chooseBioService(projectId, service, copy);
}

export async function setUserCheckAction(projectId: string, item: unknown, checked: unknown, copy: unknown) {
  if (typeof projectId !== "string") return { ok: false as const, error: "잘못된 요청입니다." };
  return setUserCheck(projectId, item, checked, copy);
}

export async function preparePublicationAction(projectId: string, input: unknown, copy: unknown) {
  if (typeof projectId !== "string") return { ok: false as const, error: "잘못된 요청입니다." };
  return preparePublication(projectId, input, copy);
}
