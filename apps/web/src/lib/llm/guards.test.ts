import { describe, expect, it } from "vitest";
import { findBannedTerms } from "./banned";
import { createLlmLimiter } from "./rate-limit";
import { readTopicPrefill } from "./prefill";

describe("금지 표현 우회 표기", () => {
  const terms = ["무조건", "최저가 보장"];
  it.each([
    ["제로폭 공백", "무​조건 사세요"],
    ["BOM·단어 결합자", "무﻿조⁠건"],
    ["NFD 한글", "무조건".normalize("NFD") + " 사세요"],
    ["구두점 끼우기", "최저가-보장!"],
    ["공백 끼우기", "최 저 가 보 장"],
  ])("%s → 탐지", (_, line) => {
    expect(findBannedTerms([line], terms)).toHaveLength(1);
  });

  it("평범한 문장은 통과", () => {
    expect(findBannedTerms(["부피가 확 줄어요"], terms)).toEqual([]);
  });
});

describe("생성 호출 제한", () => {
  it("같은 프로젝트 동시 생성은 1개", () => {
    const limiter = createLlmLimiter();
    const first = limiter.acquire("p1", "u1", 0);
    expect(first.ok).toBe(true);
    expect(limiter.acquire("p1", "u1", 1)).toEqual({ ok: false, reason: "busy" });
    expect(limiter.acquire("p2", "u1", 1).ok).toBe(true);
    if (first.ok) first.release();
    expect(limiter.acquire("p1", "u1", 2).ok).toBe(true);
  });

  it("사용자별 분당 상한, 1분 뒤 풀림", () => {
    const limiter = createLlmLimiter(2);
    for (const t of [0, 1]) {
      const r = limiter.acquire(`p${t}`, "u1", t);
      if (r.ok) r.release();
    }
    expect(limiter.acquire("p9", "u1", 2)).toEqual({ ok: false, reason: "rate_limited" });
    expect(limiter.acquire("p9", "u2", 2).ok).toBe(true);
    expect(limiter.acquire("p8", "u1", 60_001).ok).toBe(true);
  });
});

describe("01 소재 미리 채우기(?product= · ?url=)", () => {
  it("제품명은 정리해 40자까지, 링크는 http(s)만", () => {
    expect(readTopicPrefill({ product: "  진공 압축팩 ", url: "https://shop.example.com/p/1" })).toEqual({
      product: "진공 압축팩",
      url: "https://shop.example.com/p/1",
    });
    expect(readTopicPrefill({ product: "가".repeat(50), url: "javascript:alert(1)" })).toEqual({
      product: "가".repeat(40),
      url: "",
    });
    expect(readTopicPrefill({ product: null, url: "ftp://x" })).toEqual({ product: "", url: "" });
  });
});
