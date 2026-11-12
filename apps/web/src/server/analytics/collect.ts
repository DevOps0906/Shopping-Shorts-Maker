import "server-only";
import { getAccessToken } from "@/server/oauth/access-token";
import { type DailyMetric, fetchVideoDailyMetrics } from "@/server/oauth/google";
import { createAdminClient } from "@/server/supabase-admin";

/*
 * YouTube 성과 하루 1회 수집(task-025, docs/planning.md 15-3). pg_cron → POST /api/internal/metrics → 여기.
 * - 대상: public.metrics_targets()(업로드 완료·연결된 YouTube·발행 33일 이내·마지막 수집 20시간 지남).
 * - 최근 3일(Analytics day = America/Los_Angeles)을 다시 가져와 덮어쓴다. 클릭 집계·덮어쓰기는 DB 함수(save_video_metrics).
 * - 토큰은 계정별로 한 번만 발급한다. 토큰·원문 오류는 기록·로그에 넣지 않는다(오류 코드만).
 */

export const RECOLLECT_DAYS = 3;
const VIDEO_ID_RE = /^[A-Za-z0-9_-]{6,64}$/;
const LA_DATE = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Los_Angeles", year: "numeric", month: "2-digit", day: "2-digit" });

export type MetricsTarget = { publicationId: string; accountId: string; userId: string; videoId: string; publishedAt: string };

export type CollectDeps = {
  admin: ReturnType<typeof createAdminClient>;
  getToken: (userId: string, accountId: string) => Promise<string>;
  fetchDaily: (token: string, videoId: string, start: string, end: string) => Promise<DailyMetric[]>;
  now: () => Date;
};

/** Analytics day(LA) YYYY-MM-DD */
export function laDate(date: Date) {
  return LA_DATE.format(date);
}

export function addDays(day: string, delta: number) {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + delta)).toISOString().slice(0, 10);
}

/** 수집 범위: max(발행일, 오늘 - 3일) ~ 오늘(LA) */
export function collectRange(publishedAt: string, now: Date) {
  const end = laDate(now);
  const recent = addDays(end, -RECOLLECT_DAYS);
  const published = laDate(new Date(publishedAt));
  const start = published > recent ? (published > end ? end : published) : recent;
  return { start, end };
}

function toTargets(raw: unknown): MetricsTarget[] {
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((r: Record<string, unknown>) =>
    typeof r?.publication_id === "string" &&
    typeof r.account_id === "string" &&
    typeof r.user_id === "string" &&
    typeof r.platform_video_id === "string" &&
    typeof r.published_at === "string"
      ? [{ publicationId: r.publication_id, accountId: r.account_id, userId: r.user_id, videoId: r.platform_video_id, publishedAt: r.published_at }]
      : [],
  );
}

/** 기록용 오류 코드(GoogleOAuthError.code 또는 오류 이름). 원문 메시지·토큰은 넣지 않는다 */
const errorCode = (e: unknown) =>
  e instanceof Error && "code" in e && typeof e.code === "string" ? e.code : e instanceof Error ? e.name : "unknown";

/** 실행 기록 끝(finished_at). 실패하면 1회 다시 시도하고, 그래도 실패하면 코드만 로그로 남긴다 */
async function finishRun(admin: CollectDeps["admin"], args: { p_id: number; p_ok: number; p_skipped: number; p_error: string | null }) {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const { error } = await admin.rpc("metrics_run_finish", args);
      if (!error) return;
      if (attempt === 1) console.error("metrics_collect: run_finish_failed", error.code ?? "unknown");
    } catch (e) {
      if (attempt === 1) console.error("metrics_collect: run_finish_failed", errorCode(e));
    }
  }
}

/** 한 번 수집. 반환: 성공·건너뜀 건수(실행 기록 metrics_runs 에도 남는다) */
export async function collectMetrics(deps?: Partial<CollectDeps>) {
  const d: CollectDeps = {
    admin: deps?.admin ?? createAdminClient(),
    getToken: deps?.getToken ?? getAccessToken,
    fetchDaily: deps?.fetchDaily ?? fetchVideoDailyMetrics,
    now: deps?.now ?? (() => new Date()),
  };
  const run = await d.admin.rpc("metrics_run_start");
  const runId = !run.error && typeof run.data === "number" ? run.data : null;
  if (runId === null) {
    // 실행 기록을 못 남기면 수집하지 않는다(다음 날 다시 시도). 비밀 없는 코드만 남긴다
    console.error("metrics_collect: run_start_failed", run.error?.code ?? "no_id");
    return { ok: 0, skipped: 0, error: "run_start_failed" };
  }
  let ok = 0;
  let skipped = 0;
  let failure: string | null = null;

  try {
    const res = await d.admin.rpc("metrics_targets");
    if (res.error) throw new Error("metrics_targets_failed");
    const byAccount = new Map<string, MetricsTarget[]>();
    for (const t of toTargets(res.data)) byAccount.set(t.accountId, [...(byAccount.get(t.accountId) ?? []), t]);

    for (const targets of byAccount.values()) {
      let token: string;
      try {
        token = await d.getToken(targets[0].userId, targets[0].accountId);
      } catch (e) {
        skipped += targets.length;
        failure ??= `token:${errorCode(e)}`;
        continue;
      }
      for (const t of targets) {
        if (!VIDEO_ID_RE.test(t.videoId)) {
          skipped++;
          continue;
        }
        try {
          const { start, end } = collectRange(t.publishedAt, d.now());
          const rows = await d.fetchDaily(token, t.videoId, start, end);
          const saved = await d.admin.rpc("save_video_metrics", {
            p_publication_id: t.publicationId,
            p_start: start,
            p_end: end,
            p_rows: rows.map((r) => ({ date: r.date, views: r.views, avg_view_pct: r.avgViewPct })),
          });
          if (saved.error) throw new Error("save_failed");
          ok++;
        } catch (e) {
          skipped++;
          failure ??= `video:${errorCode(e)}`;
        }
      }
    }
  } catch {
    failure = "targets_failed";
  } finally {
    await finishRun(d.admin, { p_id: runId, p_ok: ok, p_skipped: skipped, p_error: failure });
  }
  return { ok, skipped, error: failure };
}
