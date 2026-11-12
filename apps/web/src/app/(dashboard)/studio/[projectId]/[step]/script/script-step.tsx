import { ScriptEditor } from "@/components/script/script-editor";
import { loadOwnedProject } from "@/server/llm/project-access";

/** S-08 03 대본 본문 로더(서버). 최신 대본 버전·체크된 원본 수·카테고리 금지 표현을 사용자 세션으로 읽는다 */
export async function ScriptStep({ projectId }: { projectId: string }) {
  const { supabase, project } = await loadOwnedProject(projectId);
  if (!project || !supabase) return null;

  const [{ data: script, error: scriptError }, { count, error: countError }] = await Promise.all([
    supabase
      .from("scripts")
      .select("lines")
      .eq("project_id", project.id)
      .order("version", { ascending: false })
      .limit(1)
      .maybeSingle(),
    supabase.from("sources").select("id", { count: "exact", head: true }).eq("project_id", project.id).eq("checked", true),
  ]);
  if (scriptError || countError) throw new Error("script_load_failed");

  const lines = Array.isArray(script?.lines) ? script.lines.filter((l): l is string => typeof l === "string") : [];
  return (
    <ScriptEditor
      initialLines={lines}
      targetSec={project.targetSec}
      bannedTerms={project.bannedTerms}
      checkedCount={count ?? 0}
    />
  );
}
