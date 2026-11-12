import { describe, expect, it } from "vitest";
import {
  type Candidate,
  boundaries,
  creditsText,
  defaultAssignment,
  failedCutNumbers,
  nextCandidate,
  parseCutMap,
  planCuts,
  reconcileAssignment,
} from "./plan";

/* 워커 apps/worker/tests/test_render.py test_plan_rules 와 같은 규칙 */

const LINES = ["좁은 틈에도 쏙 들어가요.", "이거 하나면 정리 끝!", "지금 바로 확인해 보세요."];
const SENTENCES = [
  { i: 0, start: 0.1, end: 3.1 },
  { i: 1, start: 3.5, end: 7.5 },
  { i: 2, start: 7.9, end: 11.4 },
];
const cand = (id: string, rank: number, durationSec: number | null = 8, rightsBasis = "own"): Candidate => ({
  id,
  rank,
  author: `maker_${id}`,
  platform: rank % 2 ? "tiktok" : "xiaohongshu",
  durationSec,
  score: 100 - rank,
  rightsBasis,
});

describe("컷 경계", () => {
  it("문장 사이 쉼 가운데, 1/30초 단위, 마지막은 목표 길이", () => {
    const r = boundaries(LINES, SENTENCES, 11.5, 15);
    expect(r).toEqual({ ok: true, bounds: [0, Math.round(3.3 * 30) / 30, Math.round(7.7 * 30) / 30, 15], tempo: 1, method: "sentences" });
  });

  it("음성이 목표보다 길면 최대 1.15배로 줄이고, 더 길면 거부", () => {
    const r = boundaries(LINES, SENTENCES, 16.5, 15);
    expect(r.ok && r.tempo).toBeCloseTo(1.1);
    expect(r.ok && r.bounds[1]).toBe(Math.round((3.3 / 1.1) * 30) / 30);
    expect(boundaries(LINES, SENTENCES, 18, 15).ok).toBe(false);
  });

  it("문장 타이밍이 없으면(직접 녹음) 글자 수 비율", () => {
    const r = boundaries(LINES, [], 10, 15);
    expect(r.ok && r.method).toBe("char_ratio");
    expect(r.ok && r.bounds.at(-1)).toBe(15);
  });
});

describe("매칭·교체", () => {
  const cands = [cand("a", 1, 20), cand("b", 2), cand("c", 3)];

  it("기본 매칭은 점수 순으로 돌려 쓴다", () => {
    expect(defaultAssignment(5, cands.slice(0, 2))).toEqual(["a", "b", "a", "b", "a"]);
    expect(defaultAssignment(3, [])).toEqual([]);
  });

  it("교체 = 다음 순위 원본(마지막이면 1순위), 후보 1편이면 교체 없음", () => {
    expect(nextCandidate(cands, "a")?.id).toBe("b");
    expect(nextCandidate(cands, "c")?.id).toBe("a");
    expect(nextCandidate([cands[0]], "a")).toBeNull();
  });

  it("저장된 매칭에 후보가 아닌 원본(미확인·격리로 빠짐)이 있으면 기본 매칭으로", () => {
    expect(reconcileAssignment(3, cands, ["c", "b", "a"])).toEqual(["c", "b", "a"]);
    expect(reconcileAssignment(3, cands, ["c", "unconfirmed", "a"])).toEqual(["a", "b", "c"]);
  });

  it("컷 표: 같은 원본 이어 쓰기, 후보가 아닌 원본은 그 컷 번호로 거부", () => {
    const r = planCuts(LINES, SENTENCES, 11.5, 15, ["a", "b", "a"], cands);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.cuts.map((c) => c.no)).toEqual([1, 2, 3]);
    expect(r.cuts[2].srcStart).toBeCloseTo(r.cuts[0].outEnd, 3);
    expect(r.cuts.at(-1)?.outEnd).toBe(15);
    const bad = planCuts(LINES, SENTENCES, 11.5, 15, ["a", "quarantined", "a"], cands);
    expect(bad).toEqual({ ok: false, error: "컷 2번 원본을 편집에 쓸 수 없습니다. 다음 순위 원본으로 바꿔 주세요." });
    expect(planCuts(LINES, SENTENCES, 11.5, 15, ["a", "b", "c"], []).ok).toBe(false);
  });
});

describe("출처·실패 컷·cut_map", () => {
  it("설명란 출처 문구(중복 제거)", () => {
    expect(
      creditsText([
        { author: "@kim", platform: "tiktok" },
        { author: "lee", platform: "xiaohongshu" },
        { author: "kim", platform: "tiktok" },
      ]),
    ).toBe("영상 출처: @kim(TikTok), @lee(小红书)");
    expect(creditsText([{ author: " ", platform: "tiktok" }])).toBe("");
  });

  it("워커 실패 문구에서 컷 번호", () => {
    expect(failedCutNumbers("컷 1번·3번 원본을 쓸 수 없습니다(파일을 읽을 수 없음).")).toEqual([1, 3]);
    expect(failedCutNumbers("MP4 만들기에 실패했습니다. 컷 2번 원본을 쓸 수 없습니다")).toEqual([2]);
    expect(failedCutNumbers("영상 합치기에 실패했습니다.")).toEqual([]);
    expect(failedCutNumbers(null)).toEqual([]);
  });

  it("cut_map 파싱은 모양이 맞는 컷만", () => {
    const map = parseCutMap({
      cuts: [{ no: 1, line: "a", source_id: "s1", author: "x", platform: "tiktok", src_start: 0, src_end: 3, out_start: 0, out_end: 3 }, { no: "x" }],
      credits: "영상 출처: @x(TikTok)",
    });
    expect(map?.cuts).toHaveLength(1);
    expect(map?.credits).toBe("영상 출처: @x(TikTok)");
    expect(parseCutMap(null)).toBeNull();
    expect(parseCutMap({ cuts: [] })).toBeNull();
  });
});
