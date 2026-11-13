import "server-only";
import {
  type AnalyticsSummary,
  type ChannelOption,
  type MetricRow,
  type VideoInput,
  periodDays,
  summarize,
} from "@/components/analytics/metrics";
import { createClient } from "@/lib/supabase/server";

/*
 * S-12 성과 분석 조회(task-025). 사용자 세션(anon 키) + RLS 로 본인 발행·지표만 읽는다(service_role 금지).
 * accounts 는 열 단위 GRANT 라 열을 나열한다. 원문 오류는 던져서 화면의 오류 상태로 보낸다.
 */

export type AnalyticsData = {
  channels: ChannelOption[];
  channelId: string | null;
  hasVideos: boolean;
  summary: AnalyticsSummary;
  /** 최신 지표 수집 시각(ISO). 아직 없으면 null */
  collectedAt: string | null;
};

const one = (raw: unknown) => (Array.isArray(raw) ? raw[0] : raw) as Record<string, unknown> | null | undefined;
const text = (v: unknown) => (typeof v === "string" ? v : null);

export async function getAnalytics(channelId: string | null, now = new Date()): Promise<AnalyticsData> {
  const supabase = await createClient();
  const days = periodDays(now);

  const accountsRes = await supabase.from("accounts").select("id, platform, channel_name").order("created_at");
  if (accountsRes.error) throw new Error("analytics_channels_failed");
  const channels: ChannelOption[] = accountsRes.data.map((a) => ({ id: a.id, name: a.channel_name, platform: a.platform }));
  const selected = channelId && channels.some((c) => c.id === channelId) ? channelId : null;

  let pubQuery = supabase
    .from("publications")
    .select("id, account_id, title, published_at, projects(name, categories(name))")
    .eq("status", "uploaded")
    .order("published_at", { ascending: false });
  if (selected) pubQuery = pubQuery.eq("account_id", selected);
  const pubRes = await pubQuery;
  if (pubRes.error) throw new Error("analytics_publications_failed");

  const channelName = new Map(channels.map((c) => [c.id, c.name]));
  const videos: VideoInput[] = pubRes.data.map((p) => {
    const project = one(p.projects);
    const category = one(project?.categories);
    return {
      publicationId: p.id,
      title: text(p.title)?.trim() || text(project?.name) || "제목 없음",
      channelName: channelName.get(p.account_id) ?? "연결 해제된 채널",
      categoryName: text(category?.name),
      publishedAt: text(p.published_at),
    };
  });

  let metrics: MetricRow[] = [];
  let collectedAt: string | null = null;
  if (videos.length > 0) {
    const ids = videos.map((v) => v.publicationId);
    const [metricRes, latestRes] = await Promise.all([
      supabase
        .from("video_metrics")
        .select("publication_id, date, views, link_clicks, avg_view_pct")
        .in("publication_id", ids)
        .gte("date", days[0])
        .lte("date", days[days.length - 1]),
      supabase
        .from("video_metrics")
        .select("collected_at")
        .in("publication_id", ids)
        .order("collected_at", { ascending: false })
        .limit(1)
        .maybeSingle(),
    ]);
    if (metricRes.error || latestRes.error) throw new Error("analytics_metrics_failed");
    metrics = metricRes.data.map((m) => ({
      publicationId: m.publication_id,
      date: m.date,
      views: m.views,
      linkClicks: m.link_clicks,
      avgViewPct: m.avg_view_pct === null ? null : Number(m.avg_view_pct),
    }));
    collectedAt = text((latestRes.data as Record<string, unknown> | null)?.collected_at);
  }

  return { channels, channelId: selected, hasVideos: videos.length > 0, summary: summarize(videos, metrics, days), collectedAt };
}
