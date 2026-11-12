import "server-only";
import { createClient } from "@supabase/supabase-js";
import { getSupabaseServerUrl } from "@/lib/supabase/env";

/**
 * service_role 클라이언트 — RLS를 우회한다. 이 모듈은 src/server/** 에서만 import한다.
 * 키는 실행 환경 변수로만 받는다(루트 .env의 SERVICE_ROLE_KEY, 이미지·번들·로그 금지).
 * 사용자 요청 처리에는 쓰지 말고 lib/supabase/server.ts(사용자 세션)를 쓴다.
 */
export function createAdminClient() {
  const serviceRoleKey = process.env.SERVICE_ROLE_KEY;
  if (!serviceRoleKey) {
    throw new Error("SERVICE_ROLE_KEY가 서버 환경 변수에 없습니다.");
  }
  return createClient(getSupabaseServerUrl(), serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
}
