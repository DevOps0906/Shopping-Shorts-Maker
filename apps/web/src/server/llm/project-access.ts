import "server-only";
import { createClient } from "@/lib/supabase/server";
import { isProjectId } from "@/lib/steps/project-id";
import { type StepStatusMap, parseStepStatus } from "@/lib/steps/state";

/*
 * 사용자 세션으로 프로젝트를 읽는다. RLS가 본인 프로젝트만 돌려주므로 결과가 있으면 소유자다(17-7: 도구는 서버에서 소유권을 다시 검사).
 */

export type OwnedProject = {
  id: string;
  name: string;
  targetSec: number;
  status: StepStatusMap;
  categoryName: string | null;
  keywords: string[];
  bannedTerms: string[];
  userId: string;
};

function embedded(value: unknown): Record<string, unknown> | null {
  const row = Array.isArray(value) ? value[0] : value;
  return typeof row === "object" && row !== null ? (row as Record<string, unknown>) : null;
}

const strings = (value: unknown) => (Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : []);

export async function loadOwnedProject(projectId: string) {
  if (!isProjectId(projectId)) return { supabase: null, project: null };
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("projects")
    .select("id, user_id, name, target_sec, step_status, categories(name, keywords_ko, banned_terms)")
    .eq("id", projectId)
    .maybeSingle();
  if (error) throw new Error("project_load_failed");
  const status = parseStepStatus(data?.step_status);
  if (!data || !status) return { supabase, project: null };
  const category = embedded(data.categories);
  const project: OwnedProject = {
    id: String(data.id),
    name: String(data.name),
    targetSec: Number(data.target_sec) || 15,
    status,
    categoryName: typeof category?.name === "string" ? category.name : null,
    keywords: strings(category?.keywords_ko),
    bannedTerms: strings(category?.banned_terms),
    userId: String(data.user_id),
  };
  return { supabase, project };
}
