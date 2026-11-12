import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { HomeView } from "@/components/home/home-view";
import { NewProjectForm } from "@/components/projects/new-project-form";
import { ProjectsView } from "@/components/projects/projects-view";
import { TrendBoard } from "@/components/trends/trend-board";
import type { TrendRow } from "@/components/trends/trend-view";

vi.mock("next/navigation", () => ({ useRouter: () => ({ refresh: () => {} }) }));

/* spec S-01~S-04 구성 블록이 모두 렌더되는지(docs/03_SCREENS_UX.md 화면 표) */

const trend: TrendRow = {
  id: "t1",
  name: "의류 압축팩",
  categoryId: "c1",
  categoryName: "생활·수납",
  overseasGrowth: 92,
  krSearchGrowth: 64,
  krCompetition: 28,
  score: 65.2,
  sellable: true,
  capturedAt: "2026-11-12T00:00:00Z",
};

const project = {
  id: "p1",
  name: "무선 선풍기",
  status: "in_progress" as const,
  currentStep: 3,
  updatedAt: "2026-11-12T05:00:00Z",
  channelName: "@살림",
  categoryName: "생활가전",
  version: 2,
};

const channel = {
  id: "a1",
  platform: "youtube",
  channel_name: "@살림",
  category_id: "c1",
  tone: "친근",
  weekly_goal: 5,
  is_default: true,
  status: "connected",
  uploaded: 2,
};

const html = (el: Parameters<typeof renderToStaticMarkup>[0]) => renderToStaticMarkup(el);

describe("S-01 홈", () => {
  const data = {
    profileName: "운영자",
    inProgress: 1,
    awaitingPublish: 0,
    weekUploads: 2,
    credits: 30,
    continueList: [project],
    channels: [channel],
    loadedAt: "2026-11-12T05:00:00Z",
  };

  it("인사·버튼 2개·지표 4개·이번 주·이어서 만들기·급상승 5·채널 진행 바·기준 시각", () => {
    const out = html(createElement(HomeView, { data, trends: [trend], categoryNames: { c1: "생활·수납" } }));
    for (const text of [
      "안녕하세요, 운영자 님",
      "+ 새로운 프로젝트",
      "오늘의 트렌드 보기",
      "진행 중",
      "발행 대기",
      "이번 주 업로드",
      "크레딧",
      "이번 주(월요일부터, 고정)",
      "이어서 만들기",
      "이어서 하기",
      "오늘의 급상승 상품",
      "숏폼 제작",
      "채널별 이번 주 업로드",
      "2 / 5편",
      "지표 기준 시각",
    ]) {
      expect(out).toContain(text);
    }
    expect(out).toContain('role="progressbar"');
  });

  it("빈 상태 문구", () => {
    const out = html(createElement(HomeView, { data: { ...data, continueList: [] }, trends: [], categoryNames: {} }));
    expect(out).toContain("진행 중인 프로젝트가 없습니다. 트렌드에서 상품을 골라 시작해 보세요.");
  });
});

describe("S-02 새로운 프로젝트", () => {
  const props = {
    channels: [{ id: "a1", platform: "youtube", name: "@살림", categoryId: "c1", tone: "친근" }],
    categories: [{ id: "c1", name: "생활·수납" }],
    initial: { accountId: "a1", categoryId: "c1", start: "direct" as const, product: "의류 압축팩" },
    action: async () => ({}),
  };

  it("① 채널 ② 카테고리 ③ 시작 방식 ④ 영상 설정 · 비용 표 · 만들기·취소", () => {
    const out = html(createElement(NewProjectForm, props));
    for (const text of [
      "어느 채널에 올릴까요?",
      "카테고리",
      "어떻게 시작할까요?",
      "트렌드에서 고르기",
      "제품명 직접 입력",
      "상품 링크로 시작",
      "제품명",
      "영상 길이",
      "15초",
      "20초",
      "올릴 플랫폼",
      "YouTube Shorts",
      "프로젝트 이름 (선택)",
      "AI 예상 비용 (영상 1편 · 모델별)",
      "약 27원",
      "약 102원",
      "약 653원",
      "프로젝트 만들기",
      "취소",
    ]) {
      expect(out).toContain(text);
    }
    expect(out).toContain('value="의류 압축팩"');
  });

  it("채널이 0개면 연결 안내와 비활성 버튼", () => {
    const out = html(createElement(NewProjectForm, { ...props, channels: [], initial: { ...props.initial, accountId: "" } }));
    expect(out).toContain("연결된 업로드 채널이 없습니다");
    expect(out).toContain('href="/settings/accounts"');
    expect(out).toMatch(/<button type="submit"[^>]*disabled/);
  });
});

describe("S-03 프로젝트 관리", () => {
  const props = {
    rows: [project],
    status: "all" as const,
    q: "",
    page: 1,
    pageCount: 2,
    counts: { in_progress: 1, awaiting_publish: 0, scheduled: 0, uploaded: 0 },
    all: 1,
    renderActions: () => createElement("span", null, "관리칸"),
  };

  it("상태 필터 5개·검색·새 프로젝트·표 머리 8칸·페이지", () => {
    const out = html(createElement(ProjectsView, props));
    for (const text of ["전체 1", "진행 중 1", "발행 대기 0", "예약됨 0", "업로드됨 0", "프로젝트·제품 검색", "+ 새로운 프로젝트"]) {
      expect(out).toContain(text);
    }
    for (const th of ["프로젝트", "채널", "카테고리", "진행", "버전", "수정", "상태", "관리"]) expect(out).toContain(th);
    expect(out).toContain("03 대본");
    expect(out).toContain("V2");
    expect(out).toContain("관리칸");
    expect(out).toContain('aria-label="페이지"');
  });

  it("빈 상태 문구", () => {
    const out = html(createElement(ProjectsView, { ...props, rows: [], pageCount: 1 }));
    expect(out).toContain("조건에 맞는 프로젝트가 없습니다.");
  });
});

describe("S-04 트렌드 분석", () => {
  const props = {
    rows: [trend],
    categories: [{ id: "c1", name: "생활·수납" }],
    period: "7d" as const,
    categoryId: null,
    channelName: "@살림",
    accountId: "a1",
  };

  it("필터 3종·인사이트 3개·TOP 표·상위 3개 선택·제작 버튼·막대·산식·수집 시각", () => {
    const out = html(createElement(TrendBoard, props));
    for (const text of [
      "카테고리",
      "오늘",
      "7일",
      "30일",
      "틱톡",
      "샤오홍슈",
      "가장 기회가 큰 카테고리",
      "해외 선행 상품",
      "평균 해외 영상 증가",
      "급상승 상품 TOP 1",
      "상위 3개 선택",
      "숏폼 제작하기",
      "카테고리별 기회 점수",
      "기회 점수 = 해외 영상 증가(40%)",
      "수집 시각",
    ]) {
      expect(out).toContain(text);
    }
    for (const th of ["순위", "상품", "7일 추이", "해외 영상", "국내 검색", "국내 경쟁", "기회 점수"]) expect(out).toContain(th);
    expect(out).toContain("+92%");
    expect(out).toContain("낮음");
    expect(out).toContain("account=a1");
  });

  it("빈 상태 문구", () => {
    const out = html(createElement(TrendBoard, { ...props, rows: [] }));
    expect(out).toContain("이 카테고리의 급상승 상품이 아직 없습니다.");
  });
});
