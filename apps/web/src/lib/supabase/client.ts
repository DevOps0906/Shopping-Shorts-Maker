import { createBrowserClient } from "@supabase/ssr";
import { AUTH_COOKIE_OPTIONS, getSupabasePublicEnv } from "./env";

/** 클라이언트 컴포넌트용. 화면 표시용으로만 쓰고 권한 판단은 서버(proxy·RLS)가 한다. */
export function createClient() {
  const { url, anonKey } = getSupabasePublicEnv();
  return createBrowserClient(url, anonKey, { cookieOptions: AUTH_COOKIE_OPTIONS });
}
