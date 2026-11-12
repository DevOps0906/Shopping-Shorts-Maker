import { type ChannelPlatform, type PlacementBadge, linkPlacements } from "@/lib/publish/rules";
import { cn } from "@/lib/utils";

/* 링크 삽입 위치 — planning 16-1 · design 5-7: 채널 플랫폼별 사용 · 조건부 · 보조 · 클릭 안 됨 배지와 설명 */

const BADGE: Record<PlacementBadge, string> = {
  사용: "bg-success-bg text-success-fg",
  조건부: "bg-warning-bg text-warning-fg",
  보조: "bg-accent-weak text-nav-on-ink",
  "클릭 안 됨": "bg-danger-bg text-danger-fg",
};

const PLATFORM_LABEL: Record<ChannelPlatform, string> = {
  youtube: "YouTube 쇼츠",
  instagram: "Instagram 릴스",
  tiktok: "TikTok",
  xiaohongshu: "샤오홍슈(TikTok 기준 안내)",
};

export function LinkPlacement({ platform }: { platform: ChannelPlatform }) {
  return (
    <section aria-label="링크 삽입 위치" className="flex flex-col gap-3 rounded-card border border-line bg-white p-4 shadow-card tablet:p-6">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <p className="text-sm font-semibold">링크 삽입 위치</p>
        <p className="text-xs text-muted">{PLATFORM_LABEL[platform]}</p>
      </div>
      <ul className="flex flex-col gap-2">
        {linkPlacements(platform).map((p) => (
          <li key={p.place} className="flex flex-col gap-1 rounded-btn border border-line px-3 py-2 tablet:flex-row tablet:items-center tablet:gap-3">
            <span className={cn("w-fit shrink-0 rounded-pill px-2 py-0.5 text-xs font-bold", BADGE[p.badge])}>{p.badge}</span>
            <span className="text-sm font-semibold">{p.place}</span>
            <span className="text-xs text-muted">{p.note}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}
