import Link from "next/link";
import { RefreshButton } from "@/components/home/load-error";
import {
  PLATFORM_LABEL,
  PLATFORM_TAG,
  STATUS_BADGE,
  STATUS_LABEL,
  formatDateTime,
  progressPercent,
  stepLabel,
  studioHref,
} from "@/components/projects/project-view";
import {
  badgeClass,
  barClass,
  btnClass,
  btnGhostClass,
  btnPrimaryClass,
  btnSmClass,
  cardClass,
  noteClass,
  sectClass,
  trackClass,
} from "@/components/projects/ui";
import { type TrendRow, formatGrowth, formatScore, newProjectHref } from "@/components/trends/trend-view";
import { cn } from "@/lib/utils";
import type { HomeData } from "@/server/projects/queries";

/*
 * S-01 홈 — 구성: 인사·버튼 2개 / 지표 4개 / 이번 주(고정) / 이어서 만들기 / 오늘의 급상승 상품 5개 /
 * 채널별 이번 주 업로드 / 지표 기준 시각. 시각 정본: design/prototype/Main.dc.html vHome.
 */

type HomeViewProps = { data: HomeData; trends: TrendRow[]; categoryNames: Record<string, string> };

export function HomeView({ data, trends, categoryNames }: HomeViewProps) {
  const kpis = [
    { label: "진행 중", value: data.inProgress, sub: "이어서 만들기 →", href: "/projects?status=in_progress" },
    { label: "발행 대기", value: data.awaitingPublish, sub: "발행 단계에서 올리기 →", href: "/projects?status=awaiting_publish" },
    { label: "이번 주 업로드", value: data.weekUploads, sub: "업로드됨 →", href: "/projects?status=uploaded" },
    { label: "크레딧", value: data.credits, sub: "사용 방식 · API 키 →", href: "/settings/api-keys" },
  ];
  const first = data.channels[0];

  return (
    <>
      <section className={cn(cardClass, "flex flex-wrap items-center justify-between gap-4 p-4.5 tablet:p-6")}>
        <div>
          <h2 className="text-base font-bold">안녕하세요, {data.profileName ?? "운영자"} 님</h2>
          <p className={cn(noteClass, "mt-1")}>
            {first ? (
              <>
                오늘은 <b className="text-ink">{first.channel_name}</b> 채널
                {first.category_id && categoryNames[first.category_id] ? `(${categoryNames[first.category_id]})` : ""}에
                올릴 쇼핑 숏폼을 만들어 볼까요?
              </>
            ) : (
              "채널을 연결하고 첫 쇼핑 숏폼을 만들어 볼까요?"
            )}
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Link href="/new" className={cn(btnClass, btnPrimaryClass)}>
            + 새로운 프로젝트
          </Link>
          <Link href="/trends?period=today" className={btnClass}>
            오늘의 트렌드 보기
          </Link>
        </div>
      </section>

      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className={noteClass}>
          <span aria-hidden="true">📅 </span>기간: 이번 주(월요일부터, 고정)
        </p>
        <p className={cn(noteClass, "flex items-center gap-1")}>
          지표 기준 시각 {formatDateTime(data.loadedAt)}
          <RefreshButton />
        </p>
      </div>

      <div className="grid grid-cols-2 gap-3.5 desktop:grid-cols-4">
        {kpis.map((k) => (
          <Link
            key={k.label}
            href={k.href}
            className={cn(cardClass, "flex flex-col gap-1 px-5 py-4.5 transition-shadow hover:shadow-fab")}
          >
            <span className={noteClass}>{k.label}</span>
            <span className="text-app leading-tight font-bold tabular-nums">{k.value.toLocaleString("ko-KR")}</span>
            <span className={noteClass}>{k.sub}</span>
          </Link>
        ))}
      </div>

      <div className="grid grid-cols-1 gap-3.5 desktop:grid-cols-2">
        <section className={sectClass} aria-labelledby="home-continue">
          <div className="mb-2.5 flex flex-wrap items-center justify-between gap-2.5">
            <h3 id="home-continue" className="text-base font-bold">
              이어서 만들기
            </h3>
            <Link href="/projects" className={cn(btnClass, btnSmClass, btnGhostClass)}>
              전체 보기 →
            </Link>
          </div>
          {data.continueList.length === 0 ? (
            <p className={cn(noteClass, "border-t border-line py-3")}>
              진행 중인 프로젝트가 없습니다. 트렌드에서 상품을 골라 시작해 보세요.
            </p>
          ) : (
            <ul>
              {data.continueList.map((p) => (
                <li key={p.id} className="flex items-center gap-3 border-t border-line py-3">
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2">
                      <b className="truncate text-sm">{p.name}</b>
                      <span className={cn(badgeClass, STATUS_BADGE[p.status])}>{STATUS_LABEL[p.status]}</span>
                    </div>
                    <span className={noteClass}>
                      {p.channelName ?? "연결 해제된 채널"} · {stepLabel(p.status, p.currentStep)}
                    </span>
                    <div className={cn(trackClass, "mt-1.5")}>
                      <span className={barClass} style={{ width: `${progressPercent(p.status, p.currentStep)}%` }} />
                    </div>
                  </div>
                  <Link href={studioHref(p.id, p.currentStep)} className={cn(btnClass, btnSmClass)}>
                    이어서 하기
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </section>

        <section className={sectClass} aria-labelledby="home-trends">
          <div className="mb-2.5 flex flex-wrap items-center justify-between gap-2.5">
            <h3 id="home-trends" className="text-base font-bold">
              오늘의 급상승 상품
            </h3>
            <Link href="/trends?period=today" className={cn(btnClass, btnSmClass, btnGhostClass)}>
              트렌드 분석 →
            </Link>
          </div>
          {trends.length === 0 ? (
            <p className={cn(noteClass, "border-t border-line py-3")}>오늘 집계된 급상승 상품이 아직 없습니다.</p>
          ) : (
            <ol>
              {trends.map((t, i) => (
                <li key={t.id} className="flex items-center gap-3 border-t border-line py-3">
                  <span className="flex size-6.5 shrink-0 items-center justify-center rounded-btn-sm bg-nav-hover text-xs font-bold text-nav-on-ink">
                    {i + 1}
                  </span>
                  <div className="min-w-0 flex-1">
                    <b className="block truncate text-sm">{t.name}</b>
                    <span className={noteClass}>
                      {t.categoryName} · 해외 영상 {formatGrowth(t.overseasGrowth)}
                    </span>
                  </div>
                  <span className="font-bold text-nav-on-ink tabular-nums" aria-label={`기회 점수 ${formatScore(t.score)}`}>
                    {formatScore(t.score)}
                  </span>
                  <Link href={newProjectHref(t)} className={cn(btnClass, btnSmClass)}>
                    숏폼 제작
                  </Link>
                </li>
              ))}
            </ol>
          )}
        </section>
      </div>

      <section className={sectClass} aria-labelledby="home-channels">
        <div className="mb-2.5 flex flex-wrap items-center justify-between gap-2.5">
          <h3 id="home-channels" className="text-base font-bold">
            채널별 이번 주 업로드
          </h3>
          <Link href="/settings/accounts" className={cn(btnClass, btnSmClass, btnGhostClass)}>
            채널 관리 →
          </Link>
        </div>
        {data.channels.length === 0 ? (
          <p className={noteClass}>연결된 채널이 없습니다. 다중 계정에서 채널을 연결해 주세요.</p>
        ) : (
          <div className="grid grid-cols-1 gap-3 tablet:grid-cols-2 desktop:grid-cols-4">
            {data.channels.map((c) => {
              const percent = c.weekly_goal ? Math.min(100, Math.round((c.uploaded / c.weekly_goal) * 100)) : 0;
              return (
                <div key={c.id} className="flex min-w-0 flex-col gap-0.5 rounded-card border border-line bg-white p-3.5">
                  <span className={cn("self-start rounded-chdot px-2 py-0.5 text-xs font-bold", PLATFORM_TAG[c.platform])}>
                    {PLATFORM_LABEL[c.platform] ?? c.platform}
                  </span>
                  <b className="mt-2 truncate text-sm">{c.channel_name}</b>
                  <span className={noteClass}>
                    {(c.category_id && categoryNames[c.category_id]) || "카테고리 미정"}
                    {c.tone ? ` · ${c.tone}` : ""}
                  </span>
                  <div
                    className={cn(trackClass, "mt-1.5")}
                    role="progressbar"
                    aria-label={`${c.channel_name} 이번 주 업로드`}
                    aria-valuenow={c.uploaded}
                    aria-valuemin={0}
                    aria-valuemax={c.weekly_goal}
                  >
                    <span className={barClass} style={{ width: `${percent}%` }} />
                  </div>
                  <span className={noteClass}>
                    {c.uploaded} / {c.weekly_goal}편 · {c.status === "connected" ? "연결됨" : "재연결 필요"}
                  </span>
                </div>
              );
            })}
          </div>
        )}
      </section>
    </>
  );
}
