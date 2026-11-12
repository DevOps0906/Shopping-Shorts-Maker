import type { StepNumber, StepState } from "./state";

/*
 * 상태 배너 문구 — 근거: docs/planning.md 6장 표, docs/design.md 5-6 · 확정 결정 문구,
 * 시각 참고: design/prototype/Main.dc.html renderVals() 배너 분기.
 */

export type BannerTone = "idle" | "run" | "ready" | "ok";

export type BannerContent = {
  tone: BannerTone;
  title: string;
  description: string;
};

/** 02 소스 대기 배너(design.md 5-6 확정 결정 문구 D2) */
const SOURCE_IDLE_DESCRIPTION =
  "현재 0편 확보 · 목표: 10편 다운로드 · 5편 사용. 브라우저 확장 프로그램을 연결한 뒤 소스 찾기를 눌러 주세요.";

export function stepBanner(state: StepState, step: StepNumber, stepLabel: string): BannerContent {
  switch (state) {
    case "running":
      return { tone: "run", title: `${stepLabel} 진행 중`, description: "작업을 처리하고 있습니다. 창을 닫아도 이어서 진행됩니다." };
    case "suggested":
      return {
        tone: "ready",
        title: "AI 제안 도착 · 적용 필요",
        description: step === 1 ? "아래 추천 소재에서 제품을 골라 주세요." : "제작 파트너의 제안을 작업칸에 적용해 주세요.",
      };
    case "ready":
      return {
        tone: "ready",
        title: "결과 준비 완료 · 승인 필요",
        description: "현재 결과를 확인하고 그대로 진행 또는 변경 필요를 선택해 주세요.",
      };
    case "change":
      return {
        tone: "ready",
        title: "변경 요청됨 · 수정 내용 대기",
        description: "제작 파트너에게 바꿀 내용을 알려 주세요. 수정 후 다시 승인할 수 있습니다.",
      };
    case "approved":
      return {
        tone: "ok",
        title: `${stepLabel} 승인 완료`,
        description: step === 6 ? "발행을 마쳤습니다. 성과 분석에서 결과를 확인하세요." : "아래 다음 단계 버튼으로 진행하세요.",
      };
    case "idle":
      return step === 2
        ? { tone: "idle", title: "소스 확보 대기", description: SOURCE_IDLE_DESCRIPTION }
        : { tone: "idle", title: `${stepLabel} 준비 대기`, description: "아래에서 결과물을 준비하면 승인할 수 있습니다." };
  }
}

/** 단계 제목 옆 알약 문구 */
export const STEP_PILL: Record<StepState, string> = {
  idle: "준비 필요",
  suggested: "준비 필요",
  running: "진행 중",
  ready: "승인 필요",
  change: "변경 중",
  approved: "승인 완료",
};
