import { describe, expect, it } from "vitest";
import { costSummary, formatWon } from "./ai-cost";
import { parseStatusFilter, progressPercent, stepLabel, studioHref, weekStartKst } from "./project-view";

describe("프로젝트 표시", () => {
  it("진행 문구: 진행 중은 현재 단계, 발행 이후는 상태 문구", () => {
    expect(stepLabel("in_progress", 3)).toBe("03 대본");
    expect(stepLabel("awaiting_publish", 6)).toBe("06 발행 대기");
    expect(stepLabel("uploaded", 6)).toBe("발행 완료");
  });

  it("진행 바: 진행 중은 단계 절반까지, 발행 이후는 100", () => {
    expect(progressPercent("in_progress", 1)).toBe(8);
    expect(progressPercent("in_progress", 6)).toBe(92);
    expect(progressPercent("scheduled", 6)).toBe(100);
  });

  it("상태 필터는 모르는 값을 전체로 본다", () => {
    expect(parseStatusFilter("scheduled")).toBe("scheduled");
    expect(parseStatusFilter("drop table")).toBe("all");
    expect(parseStatusFilter(undefined)).toBe("all");
  });

  it("열기 링크는 현재 단계 화면", () => {
    expect(studioHref("abc", 2)).toBe("/studio/abc/source");
    expect(studioHref("abc", 99)).toBe("/studio/abc/publish");
  });

  it("이번 주 시작 = 한국 시간 월요일 0시", () => {
    // 2026-11-12(목) 10:00 KST
    expect(weekStartKst(new Date("2026-11-12T01:00:00Z"))).toBe("2026-11-08T15:00:00.000Z");
    // 2026-11-16(월) 00:30 KST = 일요일 UTC
    expect(weekStartKst(new Date("2026-11-15T15:30:00Z"))).toBe("2026-11-15T15:00:00.000Z");
  });
});

describe("AI 예상 비용(D9)", () => {
  it("프로토타입 값 27·102·653원을 정수로 보여 준다", () => {
    expect(formatWon(653)).toBe("약 653원");
    expect(costSummary(3)).toBe("AI 예상 비용 · 편당 최저 약 27원 · 추천 약 102원 · Claude만 약 653원 (음성 별도) × 3편");
  });
});
