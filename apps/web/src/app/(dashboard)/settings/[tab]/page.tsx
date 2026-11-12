import { notFound } from "next/navigation";
import { EmptyPage } from "@/components/empty-page";
import { PageHeader } from "@/components/page-header";
import { YoutubeConnections, type YoutubeAccountRow } from "@/components/settings/youtube-connections";
import { findSettingsTab } from "@/lib/routes";
import { createClient } from "@/lib/supabase/server";
import { isGoogleOAuthConfigured } from "@/server/oauth/config";

type SettingsTabPageProps = {
  params: Promise<{ tab: string }>;
  searchParams: Promise<{ oauth?: string | string[] }>;
};

export default async function SettingsTabPage({ params, searchParams }: SettingsTabPageProps) {
  const { tab } = await params;
  const current = findSettingsTab(tab);
  if (!current) notFound();
  if (current.slug !== "accounts") return <EmptyPage eyebrow="SETTINGS" title={current.label} />;

  // 다중 계정: YouTube 연결 버튼만(task-022a). 계정 카드·채널 화면은 022b. 토큰·채널 id 열은 읽지 않는다(권한도 없음).
  const { oauth } = await searchParams;
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("accounts")
    .select("id, channel_name, status")
    .eq("platform", "youtube")
    .order("created_at", { ascending: true });

  return (
    <div className="mx-auto flex max-w-(--content-max) flex-col gap-4">
      <PageHeader eyebrow="SETTINGS" title={current.label} />
      <YoutubeConnections
        accounts={(data ?? []) as YoutubeAccountRow[]}
        configured={isGoogleOAuthConfigured()}
        result={error ? "failed" : typeof oauth === "string" ? oauth : null}
      />
    </div>
  );
}
