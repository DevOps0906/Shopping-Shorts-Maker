import { NextResponse } from "next/server";
import { parseConfirmBody } from "@/lib/agent-tools/messages";
import { fail, readJson } from "@/server/chat/http";
import { confirmProposal } from "@/server/chat/service";

/*
 * 사전 확인 도구 실행: POST {proposalId}. 사용자가 확인 대화상자에서 실행을 누를 때만 화면이 부른다.
 * tool·args는 받지 않는다 — 서버가 저장한 제안(chat_proposals)을 1회 소비하고 그 값으로만 실행한다.
 */

export async function POST(request: Request) {
  const body = await readJson(request);
  if (body instanceof NextResponse) return body;
  const proposalId = parseConfirmBody(body);
  if (!proposalId) return fail("잘못된 요청입니다.", 400);
  const result = await confirmProposal(proposalId);
  return NextResponse.json(result, { status: result.ok ? 200 : 400 });
}
