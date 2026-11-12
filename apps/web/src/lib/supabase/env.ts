/*
 * Supabase 접속 값. 공개 값(NEXT_PUBLIC_*)만 다룬다. service_role 키는 src/server/** 전용.
 * - 개발: next.config.ts가 루트 .env의 SUPABASE_PUBLIC_URL·ANON_KEY를 NEXT_PUBLIC_*로 연결한다.
 * - Docker: 빌드 인자로 NEXT_PUBLIC_*가 들어오고, 서버는 내부망 주소(SUPABASE_INTERNAL_URL)를 쓴다.
 */

/** 브라우저·서버가 같은 세션 쿠키를 보도록 이름을 고정한다(기본값은 접속 주소마다 달라진다). */
export const AUTH_COOKIE_NAME = "sb-shorts-auth-token";

/** 운영(HTTPS)에서는 Secure 쿠키로만 보낸다. */
export const AUTH_COOKIE_OPTIONS = {
  name: AUTH_COOKIE_NAME,
  secure: process.env.NODE_ENV === "production",
  sameSite: "lax" as const,
};

export function getSupabasePublicEnv() {
  // NEXT_PUBLIC_* 는 빌드 때 문자 그대로 치환되므로 구조 분해 없이 직접 참조한다.
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !anonKey) {
    throw new Error("NEXT_PUBLIC_SUPABASE_URL·NEXT_PUBLIC_SUPABASE_ANON_KEY가 설정되지 않았습니다.");
  }
  return { url, anonKey };
}

/** 서버 코드(proxy·서버 컴포넌트·서버 액션)가 붙을 주소. 컨테이너 안에서는 내부망 게이트웨이. */
export function getSupabaseServerUrl() {
  return process.env.SUPABASE_INTERNAL_URL || getSupabasePublicEnv().url;
}
