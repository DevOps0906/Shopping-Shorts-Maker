import { describe, expect, it } from "vitest";
import {
  type SourceView,
  approvalProblem,
  defaultRightsBasis,
  directSourceError,
  editInputSources,
  platformFromUrl,
  listSources,
  recommendedIds,
  toUseEntries,
} from "./rules";

let seq = 0;
function src(over: Partial<SourceView> = {}): SourceView {
  seq += 1;
  return {
    id: `s${String(seq).padStart(3, "0")}`,
    platform: "tiktok",
    url: `https://www.tiktok.com/@a/video/${seq}`,
    author: "a",
    title: null,
    collectedAt: `2026-11-12T00:00:${String(seq % 60).padStart(2, "0")}Z`,
    width: 1080,
    height: 1920,
    durationSec: 12,
    score: null,
    downloaded: true,
    checked: true,
    used: false,
    excludeReason: null,
    quarantined: false,
    rightsBasis: null,
    rightsConfirmedAt: null,
    ...over,
  };
}
const used = (n: number, basis: SourceView["rightsBasis"] = "own") =>
  Array.from({ length: n }, () => src({ used: true, rightsBasis: basis, rightsConfirmedAt: "2026-11-12T01:00:00Z" }));

describe("02 소스 승인 규칙(3장 02, D8)", () => {
  it("2편이면 승인 불가", () => {
    expect(approvalProblem(used(2), true, "사유")).toBe("too_few");
  });
  it("3편 + 사유 없음이면 거부", () => {
    expect(approvalProblem(used(3), true, "  ")).toBe("reason_required");
    expect(approvalProblem(used(4), true, null)).toBe("reason_required");
  });
  it("3편 + 사유면 허용", () => {
    expect(approvalProblem(used(3), true, "같은 구조 영상이 3편뿐")).toBeNull();
  });
  it("5편이면 사유 없이 허용", () => {
    expect(approvalProblem(used(5), true, null)).toBeNull();
  });
  it("고지 미확인이면 원본 종류와 관계없이 거부", () => {
    expect(approvalProblem(used(5, "seller"), false, null)).toBe("notice_required");
    expect(approvalProblem(used(3, "own"), false, "사유")).toBe("notice_required");
  });
  it("출처 표기 원본이 있는데 고지 미확인이면 거부, 확인하면 허용", () => {
    const list = [...used(4), ...used(1, "attribution_notice")];
    expect(approvalProblem(list, false, null)).toBe("notice_required");
    expect(approvalProblem(list, true, null)).toBeNull();
  });
  it("권리 근거 없음·목록만 원본은 사용 편수에 넣지 않는다", () => {
    const list = [...used(4), src({ used: true }), src({ used: true, rightsBasis: "own", rightsConfirmedAt: "x", downloaded: false })];
    expect(approvalProblem(list, true, null)).toBe("reason_required");
  });
});

describe("편집 입력(D1)", () => {
  it("미확인 원본은 편집 입력에서 제외", () => {
    const confirmed = used(3);
    const unconfirmed = src({ used: true, rightsBasis: null });
    const notUsed = src({ rightsBasis: "own", rightsConfirmedAt: "x" });
    const out = editInputSources([...confirmed, unconfirmed, notUsed], true);
    expect(out.map((s) => s.id)).toEqual(confirmed.map((s) => s.id));
  });
  it("고지 미확인이면 출처 표기 원본도 제외", () => {
    const attribution = used(2, "attribution_notice");
    const own = used(1, "own");
    expect(editInputSources([...attribution, ...own], false)).toEqual(own);
    expect(editInputSources([...attribution, ...own], true)).toHaveLength(3);
  });
});

describe("목록·체크", () => {
  it("기본 권리 근거: 플랫폼 원본은 출처 표기, 직접 추가는 사용자가 고른다", () => {
    expect(defaultRightsBasis("tiktok")).toBe("attribution_notice");
    expect(defaultRightsBasis("direct")).toBeNull();
  });
  it("점수 순 상위 20편 + 직접 추가, 순위 밖 제외", () => {
    const auto = Array.from({ length: 25 }, (_, i) => src({ score: i, checked: false }));
    const out = [src({ score: 99, excludeReason: "일치도 순위 20위 밖" }), ...auto, src({ platform: "direct" })];
    const list = listSources(out);
    expect(list).toHaveLength(21);
    expect(list[0].score).toBe(24);
    expect(list[20].platform).toBe("direct");
  });
  it("추천은 점수 상위 10편 표시만(체크는 사용자)", () => {
    const auto = Array.from({ length: 15 }, (_, i) => src({ score: i, checked: false }));
    const ids = recommendedIds(auto);
    expect(ids.size).toBe(10);
    expect(ids.has(auto[14].id)).toBe(true);
    expect(ids.has(auto[0].id)).toBe(false);
    expect(auto.every((s) => !s.checked)).toBe(true);
  });
  it("저장 인자는 사용 + 권리 근거 있는 원본만", () => {
    const a = src({ used: true, rightsBasis: "seller" });
    const b = src({ used: true, rightsBasis: null });
    expect(toUseEntries([a, b, src()])).toEqual([{ id: a.id, rights_basis: "seller" }]);
  });
  it("격리 원본은 사용 편수·편집 입력·목록에서 빠진다(순위 밖과 구분)", () => {
    const q = src({ used: true, rightsBasis: "own", rightsConfirmedAt: "x", quarantined: true, excludeReason: "확장자와 실제 형식이 다름" });
    expect(editInputSources([...used(3), q], true)).toHaveLength(3);
    expect(approvalProblem([...used(4), q], true, null)).toBe("reason_required");
    expect(listSources([q, src({ score: 10 })])).toHaveLength(1);
  });
  it("userinfo(@) 위장 URL 거부, 호스트로 플랫폼 판별", () => {
    expect(directSourceError("https://www.tiktok.com@evil.example/v", "me", "")).not.toBeNull();
    expect(directSourceError("https://user:pw@example.com/v", "me", "")).not.toBeNull();
    expect(platformFromUrl("https://www.tiktok.com@evil.example/v")).toBe("direct");
    expect(platformFromUrl("https://m.tiktok.com:443/v/1")).toBe("tiktok");
    expect(platformFromUrl("https://www.xiaohongshu.com/explore/1")).toBe("xiaohongshu");
    expect(platformFromUrl("https://tiktok.com.evil.example/v")).toBe("direct");
  });
  it("작성자·제목 제어 문자·양방향 제어 문자 거부", () => {
    for (const bad of ["evil\u202Egpj", "line\nbreak", "iso\u2066x", "nul\u0000"]) {
      expect(directSourceError("https://example.com/v", bad, "")).not.toBeNull();
      expect(directSourceError("https://example.com/v", "me", bad)).not.toBeNull();
    }
    expect(directSourceError("https://example.com/v", "@판매자", "제품 시연")).toBeNull();
  });
  it("직접 추가: URL·작성자 필수", () => {
    expect(directSourceError("https://example.com/v", "판매자", "")).toBeNull();
    expect(directSourceError("javascript:alert(1)", "판매자", "")).not.toBeNull();
    expect(directSourceError("https://example.com/v", "  ", "")).not.toBeNull();
  });
});
