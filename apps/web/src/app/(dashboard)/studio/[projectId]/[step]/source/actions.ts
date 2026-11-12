"use server";

import { addDirectSource, saveSourceUse, setDownloadChecks, startSourceSelection } from "@/server/sources/sources";

/* 02 소스 서버 액션 진입점. 구현은 src/server/sources/sources.ts(소유권·단계 상태·승인 조건은 DB 함수가 다시 검사) */

const BAD = { ok: false as const, error: "잘못된 요청입니다." };

export async function setDownloadChecksAction(projectId: string, sourceIds: string[]) {
  if (typeof projectId !== "string") return BAD;
  return setDownloadChecks(projectId, sourceIds);
}

export async function saveSourceUseAction(
  projectId: string,
  uses: { id: string; rights_basis: string }[],
  noticeAck: boolean,
  reason: string | null,
) {
  if (typeof projectId !== "string") return BAD;
  return saveSourceUse(projectId, uses, noticeAck, reason);
}

export async function addDirectSourceAction(projectId: string, url: string, author: string, title: string) {
  if (typeof projectId !== "string") return BAD;
  return addDirectSource(projectId, url, author, title);
}

export async function startSourceSelectionAction(projectId: string, idempotencyKey: string) {
  if (typeof projectId !== "string") return { ...BAD, retryable: false };
  return startSourceSelection(projectId, idempotencyKey);
}
