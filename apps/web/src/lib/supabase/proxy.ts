import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { AUTH_COOKIE_OPTIONS, getSupabasePublicEnv, getSupabaseServerUrl } from "./env";
import { isPublicPath, LOGIN_PATH, safeNextPath } from "./paths";

const CACHE_HEADERS = ["cache-control", "expires", "pragma"];

/** 갱신된 세션 쿠키·캐시 금지 헤더를 다른 응답(리다이렉트)으로 옮긴다. */
function redirectWithSession(url: URL, from: NextResponse) {
  const response = NextResponse.redirect(url);
  from.cookies.getAll().forEach((cookie) => response.cookies.set(cookie));
  for (const header of CACHE_HEADERS) {
    const value = from.headers.get(header);
    if (value) response.headers.set(header, value);
  }
  return response;
}

/**
 * proxy에서 매 요청 호출: 세션 토큰을 갱신하고, 비로그인 사용자는 로그인 화면으로 보낸다.
 * 쿠키는 위조할 수 있으므로 getSession()이 아니라 서명을 검증하는 getClaims()로 판단한다.
 */
export async function updateSession(request: NextRequest) {
  let supabaseResponse = NextResponse.next({ request });
  const { anonKey } = getSupabasePublicEnv();

  const supabase = createServerClient(getSupabaseServerUrl(), anonKey, {
    cookieOptions: AUTH_COOKIE_OPTIONS,
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet, headers) {
        cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
        supabaseResponse = NextResponse.next({ request });
        cookiesToSet.forEach(({ name, value, options }) =>
          supabaseResponse.cookies.set(name, value, options),
        );
        Object.entries(headers ?? {}).forEach(([key, value]) =>
          supabaseResponse.headers.set(key, value),
        );
      },
    },
  });

  // createServerClient와 getClaims 사이에 다른 코드를 넣지 않는다(세션 갱신 순서 보장).
  const { data } = await supabase.auth.getClaims();
  const signedIn = Boolean(data?.claims?.sub);
  const { pathname, search } = request.nextUrl;

  if (!signedIn && !isPublicPath(pathname)) {
    const url = request.nextUrl.clone();
    url.pathname = LOGIN_PATH;
    url.search = "";
    url.searchParams.set("next", `${pathname}${search}`);
    return redirectWithSession(url, supabaseResponse);
  }

  if (signedIn && isPublicPath(pathname)) {
    const url = new URL(safeNextPath(request.nextUrl.searchParams.get("next")), request.url);
    return redirectWithSession(url, supabaseResponse);
  }

  return supabaseResponse;
}
