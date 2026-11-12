"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createProjectFromForm } from "@/server/projects/mutations";
import type { NewProjectState } from "@/server/projects/input";

/* 새 프로젝트 서버 액션 진입점. 검사·저장은 src/server/projects/*. */

export async function createProject(_prev: NewProjectState, form: FormData): Promise<NewProjectState> {
  const result = await createProjectFromForm(form);
  if (result.kind === "invalid") return result.state;
  revalidatePath("/", "layout");
  redirect(result.href);
}
