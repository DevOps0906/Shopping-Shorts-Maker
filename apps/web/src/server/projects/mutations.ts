import "server-only";
import { createClient } from "@/lib/supabase/server";
import { isProjectId } from "@/lib/steps/project-id";
import { isUploadPlatform } from "@/components/projects/project-view";
import { type NewProjectState, parseNewProject, topicHref, trendsUrl } from "./input";

/*
 * 프로젝트 생성·복제·삭제. 사용자 세션 + RLS. current_step·step_status·status는 DB 트리거가 정한다
 * (INSERT 열 GRANT: user_id·account_id·category_id·name·target_sec). 원문 DB 오류는 화면에 내보내지 않는다.
 */

export type CreateResult =
  | { kind: "redirect"; href: string }
  | { kind: "invalid"; state: NewProjectState };

export async function createProjectFromForm(form: FormData): Promise<CreateResult> {
  const parsed = parseNewProject(form);
  if (!parsed.ok) return { kind: "invalid", state: parsed.state };
  // 트렌드에서 고르기: 프로젝트는 트렌드 화면에서 상품을 고른 뒤 만든다(S-02 → S-04)
  if (parsed.start === "trend") {
    return { kind: "redirect", href: trendsUrl({ categoryId: parsed.categoryId, accountId: parsed.accountId }) };
  }

  const supabase = await createClient();
  const { data: account, error: accountError } = await supabase
    .from("accounts")
    .select("id, platform")
    .eq("id", parsed.accountId)
    .maybeSingle();
  const channel = account as { id: string; platform: string } | null;
  if (accountError || !channel || !isUploadPlatform(channel.platform)) {
    return {
      kind: "invalid",
      state: { error: "필수 항목을 확인해 주세요.", fields: { accountId: "올릴 채널을 다시 골라 주세요." } },
    };
  }

  const { data, error } = await supabase
    .from("projects")
    .insert({
      account_id: parsed.accountId,
      category_id: parsed.categoryId,
      name: parsed.name,
      target_sec: parsed.targetSec,
    })
    .select("id")
    .single();
  if (error || !data) return { kind: "invalid", state: { error: "프로젝트를 만들지 못했습니다. 잠시 뒤 다시 시도해 주세요." } };
  return { kind: "redirect", href: topicHref((data as { id: string }).id, parsed.product, parsed.url) };
}

export type MutationResult = { ok: true; name: string } | { ok: false; error: string };

export async function duplicateProject(projectId: string): Promise<MutationResult> {
  if (!isProjectId(projectId)) return { ok: false, error: "잘못된 요청입니다." };
  const supabase = await createClient();
  const { data: source, error } = await supabase
    .from("projects")
    .select("account_id, category_id, name, target_sec")
    .eq("id", projectId)
    .maybeSingle();
  if (error || !source) return { ok: false, error: "프로젝트를 찾을 수 없습니다." };
  const s = source as { account_id: string; category_id: string | null; name: string; target_sec: number };
  const name = `${s.name} (복사본)`.slice(0, 120);
  const { error: insertError } = await supabase
    .from("projects")
    .insert({ account_id: s.account_id, category_id: s.category_id, name, target_sec: s.target_sec });
  if (insertError) return { ok: false, error: "복제하지 못했습니다. 잠시 뒤 다시 시도해 주세요." };
  return { ok: true, name: s.name };
}

export async function deleteProject(projectId: string): Promise<MutationResult> {
  if (!isProjectId(projectId)) return { ok: false, error: "잘못된 요청입니다." };
  const supabase = await createClient();
  const { data, error } = await supabase.from("projects").delete().eq("id", projectId).select("name");
  const rows = (data ?? []) as { name: string }[];
  if (error || rows.length === 0) return { ok: false, error: "삭제하지 못했습니다. 잠시 뒤 다시 시도해 주세요." };
  return { ok: true, name: rows[0].name };
}
