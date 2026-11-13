import { after } from "next/server";
import { collectMetrics } from "@/server/analytics/collect";
import { isInternalKey } from "@/server/analytics/internal-key";

/*
 * 성과 수집 내부 호출(pg_cron → pg_net, task-025). 로그인 세션이 아니라 x-internal-key 로만 인증한다(proxy matcher 제외).
 * 공개 도메인에서는 앞단 리버스 프록시가 /api/internal/* 를 막아야 한다(내부망·compose 네트워크에서만 호출).
 * 키가 맞으면 바로 202 를 돌려주고, 수집은 응답 뒤 after() 로 돌린다(시작·끝은 metrics_runs 에 기록).
 */

export const dynamic = "force-dynamic";

const NO_STORE = { "Cache-Control": "no-store" };

export async function POST(request: Request) {
  if (!isInternalKey(request.headers.get("x-internal-key"))) {
    return Response.json({ error: "unauthorized" }, { status: 401, headers: NO_STORE });
  }
  after(async () => {
    try {
      await collectMetrics();
    } catch (e) {
      // 실행 기록(metrics_runs)은 collectMetrics 가 남긴다. 원문 메시지 없이 오류 이름만, 다음 날 다시 시도한다
      console.error("metrics_collect: failed", e instanceof Error ? e.name : "unknown");
    }
  });
  return Response.json({ accepted: true }, { status: 202, headers: NO_STORE });
}
