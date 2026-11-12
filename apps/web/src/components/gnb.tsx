"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { signOut } from "@/app/(auth)/actions";
import { cn } from "@/lib/utils";
import { SETTINGS_TABS, STUDIO_STEPS } from "@/lib/routes";
import { createClient } from "@/lib/supabase/client";

/*
 * 좌측 GNB — 구조 정본: docs/design.md 4장, 시각 참고: design/prototype/Main.dc.html .gnb
 * 기본 클래스 = 모바일 아이콘 레일, tablet: 이상 = 라벨이 있는 세로 메뉴. 폭은 --gnb-w 토큰.
 * 프로젝트 개수·채널 목록·크레딧은 데이터 연동 작업에서 채운다. 프로필(이메일)·로그아웃은 task-009.
 */

const ICONS = {
  home: "M3 11l9-7 9 7M5 10v10h14V10",
  new: "M12 5v14M5 12h14",
  projects: "M3 6h6l2 2h10v11H3z",
  trends: "M3 17l6-6 4 4 8-8M15 7h6v6",
  studio: "M4 5h16v14H4zM4 9h16M9 5l-2 4M15 5l-2 4",
  analytics: "M4 20V10M10 20V4M16 20v-7M22 20H2",
  settings: "M4 7h10M18 7h2M4 17h2M10 17h10M16 5v4M8 15v4",
  logout: "M14 4h5v16h-5M10 8l-4 4 4 4M6 12h10",
} as const;

function Icon({ d, className = "size-5" }: { d: string; className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      className={cn("shrink-0", className)}
    >
      <path d={d} />
    </svg>
  );
}

const navItemClass =
  "flex min-h-13.5 w-full flex-col break-keep items-center justify-center gap-0.75 rounded-btn-sm px-0.5 py-1.5 text-center text-rail leading-tight font-semibold text-nav-ink transition-colors hover:bg-nav-hover hover:text-nav-on-ink tablet:min-h-11 tablet:flex-row tablet:justify-start tablet:gap-3 tablet:rounded-btn tablet:px-3 tablet:py-0 tablet:text-left tablet:text-sm";
const navItemOnClass = "bg-accent-weak text-nav-on-ink";

type NavLinkProps = {
  href: string;
  icon: string;
  label: string;
  active: boolean;
  /** 하위 메뉴가 현재 페이지를 가리킬 때는 상위 메뉴를 강조만 하고 aria-current는 하위에 둔다 */
  isCurrentPage?: boolean;
  badge?: string;
};

function NavLink({ href, icon, label, active, isCurrentPage = active, badge }: NavLinkProps) {
  return (
    <Link
      href={href}
      aria-current={isCurrentPage ? "page" : undefined}
      className={cn(navItemClass, active && navItemOnClass)}
    >
      <Icon d={icon} />
      <span className="tablet:flex-1">{label}</span>
      {badge ? (
        <span className="hidden min-w-5.5 rounded-pill bg-hot-bg px-1.75 py-0.5 text-center text-xs font-bold text-hot-fg tablet:inline-block">
          {badge}
        </span>
      ) : null}
    </Link>
  );
}

const subGroupClass =
  "mb-1.5 flex flex-col items-center gap-0.5 tablet:mt-0.5 tablet:mb-2 tablet:ml-5.75 tablet:items-stretch tablet:border-l-2 tablet:border-sub-line tablet:pl-2.5";
const subItemClass =
  "flex min-h-11 items-center justify-center gap-2.25 rounded-btn-sm text-xs font-semibold text-muted transition-colors tablet:justify-start tablet:px-2.5";
const subDotClass =
  "flex size-5 shrink-0 items-center justify-center rounded-full border-(length:--border-dot) border-step-dot-line bg-white text-rail font-bold text-step-dot-ink";
const subDotOnClass = "border-accent bg-accent text-white";

type SubItem = { key: string; num: number; label: string; href: string | null; active: boolean };

function SubMenu({ label, items }: { label: string; items: SubItem[] }) {
  return (
    <div role="group" aria-label={label} className={subGroupClass}>
      {items.map((item) => {
        const body = (
          <>
            <span className={cn(subDotClass, item.active && subDotOnClass)} aria-hidden="true">
              {item.num}
            </span>
            <span className="sr-only tablet:not-sr-only">{item.label}</span>
          </>
        );
        return item.href ? (
          <Link
            key={item.key}
            href={item.href}
            aria-current={item.active ? "page" : undefined}
            aria-label={`${item.num} ${item.label}`}
            className={cn(
              subItemClass,
              "hover:bg-sub-hover hover:text-nav-on-ink",
              item.active && navItemOnClass,
            )}
          >
            {body}
          </Link>
        ) : (
          <span
            key={item.key}
            aria-disabled="true"
            aria-label={`${item.num} ${item.label} (프로젝트를 먼저 고르세요)`}
            className={cn(subItemClass, "cursor-not-allowed")}
          >
            {body}
          </span>
        );
      })}
    </div>
  );
}

/** 프로필 영역 표시용 이메일. 접근 제어는 proxy가 하므로 여기서는 보여 주기만 한다. */
function useUserEmail() {
  const [email, setEmail] = useState<string | null>(null);
  useEffect(() => {
    let active = true;
    createClient()
      .auth.getUser()
      .then(({ data }) => {
        if (active) setEmail(data.user?.email ?? null);
      });
    return () => {
      active = false;
    };
  }, []);
  return email;
}

export function Gnb() {
  const pathname = usePathname();
  const email = useUserEmail();
  const segments = pathname.split("/").filter(Boolean);
  const startsWith = (prefix: string) => pathname === prefix || pathname.startsWith(`${prefix}/`);

  const inStudio = segments[0] === "studio";
  const projectId = inStudio ? segments[1] : undefined;
  const currentStep = inStudio ? segments[2] : undefined;
  const inSettings = segments[0] === "settings";

  const studioItems: SubItem[] = STUDIO_STEPS.map((step, index) => ({
    key: step.slug,
    num: index + 1,
    label: step.label,
    href: projectId ? `/studio/${projectId}/${step.slug}` : null,
    active: currentStep === step.slug,
  }));

  const settingsItems: SubItem[] = SETTINGS_TABS.map((tab, index) => ({
    key: tab.slug,
    num: index + 1,
    label: tab.label,
    href: `/settings/${tab.slug}`,
    active: inSettings && segments[1] === tab.slug,
  }));

  return (
    <nav
      aria-label="주 메뉴"
      className="fixed inset-y-0 left-0 z-40 flex w-(--gnb-w) flex-col gap-0.5 overflow-y-auto border-r border-line bg-gnb-bg px-1.5 py-3 tablet:px-3.5 tablet:py-5"
    >
      <div className="flex items-center justify-center gap-2.5 pt-1 pb-3 tablet:justify-start tablet:px-2 tablet:pb-4.5">
        <span
          className="flex size-9 shrink-0 items-center justify-center rounded-logo bg-accent text-white"
          aria-hidden="true"
        >
          <svg viewBox="0 0 24 24" fill="currentColor" className="size-4">
            <path d="M8 5v14l11-7z" />
          </svg>
        </span>
        <span className="hidden tablet:block">
          <b className="block text-base leading-snug">쇼핑 숏폼 스튜디오</b>
          <small className="block text-rail font-semibold tracking-widest text-muted">
            NOMAD AI FACTORY
          </small>
        </span>
      </div>

      <NavLink href="/" icon={ICONS.home} label="홈" active={pathname === "/"} />
      <NavLink href="/new" icon={ICONS.new} label="새로운 프로젝트" active={startsWith("/new")} />
      <NavLink
        href="/projects"
        icon={ICONS.projects}
        label="프로젝트 관리"
        active={startsWith("/projects")}
      />
      <NavLink
        href="/trends"
        icon={ICONS.trends}
        label="트렌드 분석"
        active={startsWith("/trends")}
        badge="HOT"
      />
      <NavLink
        href={projectId ? `/studio/${projectId}/topic` : "/projects"}
        icon={ICONS.studio}
        label="제작단계"
        active={inStudio}
        isCurrentPage={false}
      />
      <SubMenu label="제작단계 하위 메뉴" items={studioItems} />
      <NavLink
        href="/analytics"
        icon={ICONS.analytics}
        label="성과 분석"
        active={startsWith("/analytics")}
      />
      <NavLink
        href="/settings/profile"
        icon={ICONS.settings}
        label="환경설정"
        active={inSettings}
        isCurrentPage={false}
      />
      {inSettings ? <SubMenu label="환경설정 하위 메뉴" items={settingsItems} /> : null}

      <div className="flex justify-center px-0 pt-3 pb-1 text-rail font-bold tracking-wider text-muted tablet:justify-between tablet:px-3 tablet:pt-4 tablet:text-xs">
        <span>내 채널</span>
        <span className="hidden tablet:inline">0</span>
      </div>
      <Link href="/settings/accounts" className={cn(navItemClass, "text-muted")}>
        <span
          className="flex size-5.5 shrink-0 items-center justify-center rounded-chdot border-(length:--border-dot) border-dashed border-add-line text-xs font-bold text-muted"
          aria-hidden="true"
        >
          +
        </span>
        <span className="tablet:flex-1">채널 추가</span>
      </Link>

      <div className="mt-auto flex flex-col items-center gap-1.5 border-t border-line pt-3.5 tablet:flex-row tablet:gap-2.5">
        <span
          className="flex size-9.5 shrink-0 items-center justify-center rounded-full bg-avatar-bg text-sm font-bold text-nav-on-ink"
          aria-hidden="true"
        >
          {email ? email[0].toUpperCase() : "?"}
        </span>
        <span className="hidden min-w-0 flex-1 tablet:block">
          <b className="block text-sm">프로필</b>
          <span className="block truncate text-xs text-muted">{email ?? "불러오는 중…"}</span>
        </span>
        <form action={signOut}>
          <button
            type="submit"
            aria-label="로그아웃"
            title="로그아웃"
            className="flex size-11 items-center justify-center rounded-btn text-muted transition-colors hover:bg-nav-hover hover:text-nav-on-ink"
          >
            <Icon d={ICONS.logout} className="size-4.5" />
          </button>
        </form>
      </div>
    </nav>
  );
}
