export const LOGIN_PATH = "/login";

/** 로그인 없이 열 수 있는 경로. 나머지((dashboard) 전체)는 로그인 필요. */
export function isPublicPath(pathname: string) {
  return pathname === LOGIN_PATH || pathname.startsWith(`${LOGIN_PATH}/`);
}

/**
 * 로그인 후 돌아갈 경로. 같은 사이트의 상대 경로만 허용해 열린 리다이렉트를 막는다.
 * "//evil.com"·"/\evil.com"처럼 다른 호스트로 해석되는 값과 로그인 화면 자신은 홈으로 돌린다.
 */
export function safeNextPath(raw: string | null | undefined) {
  if (!raw || !raw.startsWith("/") || raw.startsWith("//") || /[\u0000-\u001f\u007f\\]/.test(raw)) return "/";
  // 브라우저는 탭·개행을 지우고 \를 /로 바꿔 "//evil.com"이 될 수 있으므로 제어문자·백슬래시는 모두 거부한다.
  if (isPublicPath(raw.split(/[?#]/)[0])) return "/";
  return raw;
}
