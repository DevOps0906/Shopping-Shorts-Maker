import "server-only";
import type { createClient } from "@/lib/supabase/server";

/*
 * 현재 업체(nomad_core.organizations). 앱 데이터는 업체 소유다(nomad_shorts org안).
 * 업체 선택 화면이 생기기 전까지는 사용자의 첫 업체(개인 업체가 먼저)를 쓴다.
 * public.nomad_my_organizations()는 세션 사용자(auth.uid())의 활성 멤버십만 돌려주므로 사용자 세션 클라이언트로 부른다.
 */
export async function currentOrganizationId(supabase: Awaited<ReturnType<typeof createClient>>): Promise<string | null> {
  const { data, error } = await supabase.schema("public").rpc("nomad_my_organizations");
  if (error || !Array.isArray(data)) return null;
  const id = (data[0] as { id?: unknown } | undefined)?.id;
  return typeof id === "string" ? id : null;
}
