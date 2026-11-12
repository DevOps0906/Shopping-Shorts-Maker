import { describe, expect, it } from "vitest";
import { escapeLike, parseNewProject, parsePage, parseQuery, topicHref, trendsUrl } from "./input";

const ACCOUNT = "11111111-1111-4111-8111-111111111111";
const CATEGORY = "22222222-2222-4222-8222-222222222222";

function form(values: Record<string, string>) {
  const f = new FormData();
  for (const [k, v] of Object.entries(values)) f.set(k, v);
  return f;
}

describe("새 프로젝트 입력 검사", () => {
  it("제품명 직접 입력: 이름이 비면 제품명으로 만든다", () => {
    const r = parseNewProject(
      form({ accountId: ACCOUNT, categoryId: CATEGORY, start: "direct", product: " 의류 압축팩 ", targetSec: "20" }),
    );
    expect(r).toEqual({
      ok: true,
      start: "direct",
      accountId: ACCOUNT,
      categoryId: CATEGORY,
      targetSec: 20,
      name: "의류 압축팩",
      product: "의류 압축팩",
      url: "",
    });
  });

  it("필수 항목 누락은 항목별 안내와 입력값을 돌려준다", () => {
    const r = parseNewProject(form({ start: "direct", targetSec: "30" }));
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(Object.keys(r.state.fields ?? {}).sort()).toEqual(["accountId", "categoryId", "product", "targetSec"]);
    expect(r.state.values?.start).toBe("direct");
  });

  it("상품 링크는 http(s)만 받는다", () => {
    const bad = parseNewProject(form({ accountId: ACCOUNT, categoryId: CATEGORY, start: "link", url: "javascript:alert(1)", targetSec: "15" }));
    expect(bad.ok).toBe(false);
    const ok = parseNewProject(form({ accountId: ACCOUNT, categoryId: CATEGORY, start: "link", url: "https://www.coupang.com/vp/1", targetSec: "15" }));
    expect(ok).toMatchObject({ ok: true, name: "coupang.com", url: "https://www.coupang.com/vp/1", product: "" });
  });

  it("트렌드에서 고르기는 카테고리만 있으면 된다(채널 없음 허용)", () => {
    expect(parseNewProject(form({ categoryId: CATEGORY, start: "trend" }))).toEqual({
      ok: true,
      start: "trend",
      categoryId: CATEGORY,
      accountId: null,
    });
    expect(parseNewProject(form({ categoryId: CATEGORY, accountId: ACCOUNT, start: "trend" }))).toMatchObject({ accountId: ACCOUNT });
  });
});

describe("목록 URL 입력", () => {
  it("검색어 이스케이프·길이 제한, 페이지 정수", () => {
    expect(escapeLike("50%_off\\")).toBe("50\\%\\_off\\\\");
    expect(parseQuery("  a ".repeat(60)).length).toBeLessThanOrEqual(100);
    expect(parsePage("3")).toBe(3);
    expect(parsePage("-1")).toBe(1);
    expect(parsePage(undefined)).toBe(1);
  });
});

describe("이동 링크", () => {
  it("생성 직후 01 소재로 제품명·전체 URL을 넘긴다", () => {
    const href = topicHref("p1", "", "https://smartstore.naver.com/a/products/1?x=1&y=2");
    expect(new URL(href, "http://h").searchParams.get("url")).toBe("https://smartstore.naver.com/a/products/1?x=1&y=2");
    expect(topicHref("p1", "압축팩", "")).toBe("/studio/p1/topic?product=%EC%95%95%EC%B6%95%ED%8C%A9");
    expect(topicHref("p1", "", "")).toBe("/studio/p1/topic");
  });

  it("트렌드 링크는 선택 채널을 유지한다", () => {
    expect(trendsUrl({ period: "7d", categoryId: CATEGORY, accountId: ACCOUNT })).toBe(
      `/trends?period=7d&category=${CATEGORY}&account=${ACCOUNT}`,
    );
  });
});
