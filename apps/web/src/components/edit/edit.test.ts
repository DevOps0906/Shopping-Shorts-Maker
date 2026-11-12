import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { FeedbackProvider } from "@/components/feedback";
import { StudioStepView } from "@/components/studio/studio-step-view";
import type { Candidate, RenderView } from "@/lib/edit/plan";
import type { StepStatusMap } from "@/lib/steps/state";
import type { EditStepData } from "@/server/edit/edit";
import { EditPanel } from "./edit-panel";

vi.mock("next/navigation", () => ({ useRouter: () => ({ refresh: () => {} }) }));
vi.mock("@/app/(dashboard)/studio/[projectId]/[step]/edit/actions", () => ({
  startRenderAction: vi.fn(),
  pollRenderAction: vi.fn(),
}));
vi.mock("@/app/(dashboard)/studio/actions", () => ({ approveStep: vi.fn(), requestStepChange: vi.fn() }));

/* spec S-10 05 편집: 컷 타임라인 · 연결표(컷·대사·원본·구간) · 스케일업/제거 비활성 · MP4 만들기 · 검토본(V·시각·9:16·다운로드) · 상태 4종 */

const html = (el: Parameters<typeof renderToStaticMarkup>[0]) => renderToStaticMarkup(el);
const approved4: StepStatusMap = { 1: "approved", 2: "approved", 3: "approved", 4: "approved", 5: "idle", 6: "idle" };
const lines = ["좁은 틈에도 쏙 들어가요.", "이거 하나면 정리 끝!", "지금 바로 확인해 보세요."];
const candidates: Candidate[] = [
  { id: "00000000-0000-4000-b000-00000000000a", rank: 1, author: "maker_a", platform: "tiktok", durationSec: 8, score: 90, rightsBasis: "attribution_notice" },
  { id: "00000000-0000-4000-b000-00000000000b", rank: 2, author: "maker_b", platform: "xiaohongshu", durationSec: 6, score: 80, rightsBasis: "own" },
];
const base: EditStepData = {
  targetSec: 15,
  lines,
  take: {
    id: "t1",
    source: "tts",
    durationSec: 11.5,
    sentences: [
      { i: 0, start: 0.1, end: 3.1 },
      { i: 1, start: 3.5, end: 7.5 },
      { i: 2, start: 7.9, end: 11.4 },
    ],
  },
  candidates,
  renders: [],
  job: null,
  lastError: null,
};
const v1: RenderView = {
  id: "r1",
  version: 1,
  createdAt: "2026-11-12T03:00:00Z",
  durationSec: 15,
  videoUrl: "https://example.test/signed-v1",
  cuts: [],
  credits: "영상 출처: @maker_a(TikTok)",
};

function panel(props: Partial<EditStepData>, status: StepStatusMap = approved4) {
  return html(
    createElement(
      FeedbackProvider,
      null,
      createElement(
        StudioStepView,
        { projectId: "00000000-0000-4000-a000-000000000002", step: 5, initialStatus: status, runningStartedAt: null },
        createElement(EditPanel, { ...base, ...props }),
      ),
    ),
  );
}

describe("S-10 05 편집 렌더", () => {
  it("빈 상태: 타임라인 · 연결표 · 교체 · 비활성 도구 · MP4 만들기 · 비용 · 검토본 없음", () => {
    const out = panel({});
    expect(out).toContain('aria-label="컷 타임라인"');
    expect(out).toContain("대사와 장면 연결표");
    for (const l of lines) expect(out).toContain(l);
    expect(out).toContain("①");
    expect(out).toContain("③");
    expect(out).toContain("1순위");
    expect(out).toContain("@maker_b");
    expect(out.match(/다음 순위로 교체/g)).toHaveLength(3);
    expect(out).toMatch(/<button[^>]*disabled=""[^>]*>스케일업<\/button>/);
    expect(out).toMatch(/<button[^>]*disabled=""[^>]*>자막 및 워터마크 제거<\/button>/);
    expect(out).toContain("출처 표기 원본에는 쓸 수 없습니다");
    expect(out).toContain("영상 출처: @maker_a(TikTok), @maker_b(小红书)");
    expect(out).toContain("좋은 컷을 골라 MP4 만들기");
    expect(out).toContain("예상 크레딧 30");
    expect(out).toContain("아직 검토본이 없습니다");
  });

  it("로딩: 자막과 음성 합치는 중 · 경과 초", () => {
    const out = panel({ job: { id: "j1", status: "running", error: null, startedAt: null } });
    expect(out).toContain("자막과 음성 합치는 중… 0초");
  });

  it("오류: 실패한 컷 번호 표시와 교체 안내", () => {
    const out = panel({ lastError: "컷 2번 원본을 쓸 수 없습니다(파일을 읽을 수 없음). 다음 순위 원본으로 바꿔 다시 만들어 주세요." });
    expect(out).toContain("실패한 컷: ②");
    expect(out).toContain(">실패</span>");
    expect(out).toContain("다시 시도");
  });

  it("성공: 검토본 V2 최신 · 생성 시각 · 9:16 미리보기 · 다운로드 · 버전 목록", () => {
    const v2: RenderView = { ...v1, id: "r2", version: 2, videoUrl: "https://example.test/signed-v2", createdAt: "2026-11-12T04:00:00Z" };
    const out = panel({ renders: [v2, v1] });
    expect(out).toContain("최신 수정본 · V2");
    expect(out).toContain("<video");
    expect(out).toContain("aspect-9/16");
    expect(out).toContain('download="V2.mp4"');
    expect(out).toContain("버전 목록");
    expect(out).toContain(">V1<");
  });

  it("편집 입력 원본이 없으면(미확인·격리만) 안내하고 만들기 막음", () => {
    const out = panel({ candidates: [] });
    expect(out).toContain("편집에 쓸 수 있는 원본이 없습니다");
    expect(out).toMatch(/<button[^>]*disabled=""[^>]*>좋은 컷을 골라 MP4 만들기<\/button>/);
  });

  it("04 미승인이면 안내", () => {
    const out = panel({}, { ...approved4, 4: "ready" });
    expect(out).toContain("04 목소리를 승인하면 컷을 맞출 수 있습니다");
  });
});
