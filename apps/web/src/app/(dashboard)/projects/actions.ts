"use server";

import { revalidatePath } from "next/cache";
import { type MutationResult, deleteProject, duplicateProject } from "@/server/projects/mutations";

/* 프로젝트 관리 서버 액션 진입점. 구현은 src/server/projects/mutations.ts (사용자 세션 + RLS) */

export async function duplicateProjectAction(projectId: string): Promise<MutationResult> {
  const result = await duplicateProject(projectId);
  if (result.ok) revalidatePath("/", "layout");
  return result;
}

export async function deleteProjectAction(projectId: string): Promise<MutationResult> {
  const result = await deleteProject(projectId);
  if (result.ok) revalidatePath("/", "layout");
  return result;
}
