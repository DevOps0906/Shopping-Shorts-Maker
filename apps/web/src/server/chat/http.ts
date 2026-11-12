import "server-only";
import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";

/*
 * /api/chat 공통 요청 검사(순서가 규칙):
 * 1) 로그인 세션 확인(없으면 본문을 읽지 않고 401)
 * 2) 다른 사이트에서 보낸 요청(CSRF) 차단: JSON 본문만 받고(단순 폼 요청 불가), Origin 이 있으면 같은 호스트여야 한다
 * 3) 본문은 스트림으로 읽으며 누적 바이트(UTF-8)가 BODY_LIMIT 을 넘으면 즉시 413
 */

const BODY_LIMIT = 8 * 1024;

export const fail = (error: string, status: number) => NextResponse.json({ ok: false, error }, { status });

function sameOrigin(request: Request): boolean {
  const origin = request.headers.get("origin");
  if (origin === null) return request.headers.get("sec-fetch-site") !== "cross-site";
  const host = request.headers.get("x-forwarded-host") ?? request.headers.get("host");
  try {
    return host !== null && new URL(origin).host === host;
  } catch {
    return false;
  }
}

async function readLimited(body: ReadableStream<Uint8Array>): Promise<string | null> {
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > BODY_LIMIT) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(out);
}

export async function readJson(request: Request): Promise<Record<string, unknown> | NextResponse> {
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  if (!data?.claims) return fail("로그인이 필요합니다.", 401);

  const type = request.headers.get("content-type") ?? "";
  if (!type.toLowerCase().startsWith("application/json")) return fail("잘못된 요청입니다.", 415);
  if (!sameOrigin(request)) return fail("허용되지 않은 요청입니다.", 403);
  if (Number(request.headers.get("content-length") ?? 0) > BODY_LIMIT) return fail("요청이 너무 깁니다.", 413);
  if (!request.body) return fail("잘못된 요청입니다.", 400);

  const text = await readLimited(request.body);
  if (text === null) return fail("요청이 너무 깁니다.", 413);
  try {
    const body: unknown = JSON.parse(text);
    if (typeof body !== "object" || body === null || Array.isArray(body)) return fail("잘못된 요청입니다.", 400);
    return body as Record<string, unknown>;
  } catch {
    return fail("잘못된 요청입니다.", 400);
  }
}
