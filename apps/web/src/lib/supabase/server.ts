import "server-only";
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { AUTH_COOKIE_OPTIONS, getSupabasePublicEnv, getSupabaseServerUrl } from "./env";

/** 서버 컴포넌트·서버 액션·Route Handler용. 요청마다 새로 만든다(anon 키 + 사용자 세션 쿠키). */
export async function createClient() {
  const cookieStore = await cookies();
  const { anonKey } = getSupabasePublicEnv();

  return createServerClient(getSupabaseServerUrl(), anonKey, {
    cookieOptions: AUTH_COOKIE_OPTIONS,
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        try {
          cookiesToSet.forEach(({ name, value, options }) => cookieStore.set(name, value, options));
        } catch {
          // 서버 컴포넌트에서는 쿠키를 쓸 수 없다. 토큰 갱신은 proxy가 맡는다.
        }
      },
    },
  });
}
