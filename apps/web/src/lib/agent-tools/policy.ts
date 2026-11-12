import type { ConfirmOptions } from "@/lib/feedback/types";
import { RENDER_CREDITS } from "@/lib/edit/plan";
import type { StepStatusMap } from "@/lib/steps/state";
import { TTS_CREDITS } from "@/lib/voice/voices";
import type { ParsedCall } from "./tools";

/*
 * 사전 확인 정책(docs/planning.md 5장 설계 규칙 · 17-7 "사전 확인" 열). 서버가 정하고 모델 판단으로 건너뛰지 않는다.
 * - search_topics: 01 소재가 이미 승인돼 있으면 다시 열고 뒤 단계를 초기화하므로 확인
 * - search_sources: 탐색 회차(최대 MAX_COLLECT_ROUNDS)를 하나 쓰므로 확인, 남은 회차가 없으면 거부
 * - synthesize_voice · replace_cut · render_mp4: 크레딧이 CONFIRM_CREDITS 이상이면 확인
 * - draft_script: 확인 없음(제안만, 적용은 사용자)
 * 확인은 화면의 공용 confirm()으로 사용자에게 묻고, 사용자가 누른 요청(confirmed)만 실행한다.
 */

export const MAX_COLLECT_ROUNDS = 3; // planning 4장 7 "회차 판단 최대 3회"
export const CONFIRM_CREDITS = 10;

export type PolicyProject = { status: StepStatusMap; collectRounds: number };

export type Gate = { kind: "run" } | { kind: "confirm"; confirm: ConfirmOptions } | { kind: "deny"; error: string };

const creditConfirm = (title: string, credits: number, what: string): Gate =>
  credits >= CONFIRM_CREDITS
    ? {
        kind: "confirm",
        confirm: {
          title,
          description: `${what} 예상 크레딧 ${credits}을 씁니다. 결과는 새 버전으로 쌓이고 승인은 직접 눌러야 합니다.`,
          confirmLabel: "실행",
        },
      }
    : { kind: "run" };

export function gateFor(call: ParsedCall, project: PolicyProject): Gate {
  switch (call.name) {
    case "search_topics":
      return project.status[1] === "approved"
        ? {
            kind: "confirm",
            confirm: {
              title: "01 소재를 다시 열까요?",
              description: "새 소재를 찾으려면 승인을 풀어야 합니다. 02 소스~06 발행 결과가 초기화됩니다.",
              confirmLabel: "다시 열고 검색",
              danger: true,
            },
          }
        : { kind: "run" };
    case "search_sources": {
      const left = MAX_COLLECT_ROUNDS - project.collectRounds;
      if (left <= 0) return { kind: "deny", error: `탐색 회차 ${MAX_COLLECT_ROUNDS}회를 모두 썼습니다. 02 소스에서 원본을 직접 추가해 주세요.` };
      const platform = call.args.platform === "tiktok" ? "TikTok" : "小红书";
      return {
        kind: "confirm",
        confirm: {
          title: `${platform} 원본을 한 회차 더 찾을까요?`,
          description: `탐색 회차가 ${left}회 남았고, 실행하면 ${left - 1}회가 남습니다. 브라우저 확장이 열린 탭에서 수집합니다.`,
          confirmLabel: "검색",
        },
      };
    }
    case "draft_script":
      return { kind: "run" };
    case "synthesize_voice":
      return creditConfirm("음성을 다시 합성할까요?", TTS_CREDITS, "음성 합성에");
    case "replace_cut":
      return creditConfirm(`${call.args.cut_no}번 컷을 바꿔 새 버전을 만들까요?`, RENDER_CREDITS, "MP4 만들기에");
    case "render_mp4":
      return creditConfirm("MP4를 새 버전으로 만들까요?", RENDER_CREDITS, "MP4 만들기에");
  }
}
