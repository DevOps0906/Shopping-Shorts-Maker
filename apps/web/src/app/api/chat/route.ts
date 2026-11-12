import { NextResponse } from "next/server";
import { readJson } from "@/server/chat/http";
import { loadChat, sendMessage } from "@/server/chat/service";

/*
 * 제작 파트너 대화(S-16). GET ?projectId=&step= : 맥락 줄 + 최근 대화 · POST {projectId, step, message} : 대화 1턴.
 * 인증·소유권은 사용자 세션(RLS)으로 서비스가 다시 검사한다. 확인이 필요한 도구는 /api/chat/confirm 으로만 실행된다.
 */

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const url = new URL(request.url);
  const result = await loadChat(url.searchParams.get("projectId"), url.searchParams.get("step"));
  return NextResponse.json(result, { status: result.ok ? 200 : 404, headers: { "Cache-Control": "no-store" } });
}

export async function POST(request: Request) {
  const body = await readJson(request);
  if (body instanceof NextResponse) return body;
  const result = await sendMessage(body.projectId, body.step, body.message);
  return NextResponse.json(result, { status: result.ok ? 200 : 400 });
}
