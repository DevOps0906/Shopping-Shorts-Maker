import { clientIp, refererHost, resolveShortLink } from "@/server/analytics/short-link";

/*
 * 단축 링크 /l/{코드} (익명, proxy matcher 에서 제외). 등록된 제휴 도메인으로만 302.
 * 없는 코드·허용되지 않은 도메인·naver.me 는 모두 같은 404(코드 존재 여부를 드러내지 않는다). 응답은 캐시하지 않는다.
 */

export const dynamic = "force-dynamic";

const NO_STORE = { "Cache-Control": "no-store" };

export async function GET(request: Request, { params }: { params: Promise<{ code: string }> }) {
  const { code } = await params;
  let target: string | null = null;
  try {
    target = await resolveShortLink(code, {
      ip: clientIp(request.headers),
      refHost: refererHost(request.headers.get("referer")),
    });
  } catch {
    target = null;
  }
  if (!target) {
    return new Response("링크를 찾을 수 없습니다.", {
      status: 404,
      headers: { ...NO_STORE, "Content-Type": "text/plain; charset=utf-8" },
    });
  }
  return new Response(null, { status: 302, headers: { ...NO_STORE, Location: target } });
}
