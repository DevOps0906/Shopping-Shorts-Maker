import { describe, expect, it } from "vitest";
import {
  POLICY_ITEMS,
  type PolicyCheck,
  canPublish,
  checkAffiliateUrl,
  composeDescription,
  copyVariants,
  findPublishBanned,
  kstInputToIso,
  isoToKstInput,
  parseHashtags,
  parsePolicy,
  recommendedPrograms,
  recommendedSlots,
  withLocalBanned,
} from "./rules";

const allPass: PolicyCheck[] = POLICY_ITEMS.map((p) => ({ item: p.id, result: "pass", detail: "", checkedAt: null }));

describe("정책 점검 6항목(15-4)", () => {
  it("정본 6항목 순서·이름 — 2번은 출처 표기·고지 확인", () => {
    expect(POLICY_ITEMS.map((p) => p.label)).toEqual([
      "원본 출처 기록",
      "출처 표기·고지 확인",
      "새로 만든 요소",
      "금지·과장 표현",
      "제휴 고지",
      "구매 경로",
    ]);
  });

  it("6개 모두 통과해야 발행 가능, 1개라도 미통과·확인 필요면 불가", () => {
    expect(canPublish(allPass)).toBe(true);
    for (const p of POLICY_ITEMS) {
      for (const result of ["fail", "pending"] as const) {
        expect(canPublish(allPass.map((i) => (i.item === p.id ? { ...i, result } : i)))).toBe(false);
      }
    }
    expect(canPublish(allPass.slice(1))).toBe(false);
  });

  it("DB 결과 파싱: 빠진 항목은 미통과", () => {
    const view = parsePolicy({ items: [{ item: "source_record", result: "pass", detail: "ok" }], credits: "영상 출처: @a(TikTok)" });
    expect(view.items).toHaveLength(6);
    expect(view.items[0].result).toBe("pass");
    expect(view.items.slice(1).every((i) => i.result === "fail")).toBe(true);
    expect(view.credits).toBe("영상 출처: @a(TikTok)");
    expect(canPublish(view.items)).toBe(false);
  });

  it("금지·과장 표현: 공통 + 카테고리, 공백·제로폭 우회도 잡고 입력 중 판정을 덮어씀", () => {
    expect(findPublishBanned(["최 고의 압축팩"], [], [])).toBe("최고");
    expect(findPublishBanned(["압축팩", "최저가​ 보장"], [], ["최저가 보장"])).toBe("최저가 보장");
    expect(findPublishBanned(["압축팩"], ["무조건 사세요"], [])).toBe("무조건");
    expect(findPublishBanned(["압축팩 정리"], ["좁은 틈에도 쏙"], ["최저가 보장"])).toBeNull();
    expect(canPublish(withLocalBanned(allPass, "최고"))).toBe(false);
    expect(canPublish(withLocalBanned(allPass, null))).toBe(true);
  });
});

describe("설명란 순서 고정", () => {
  it("고지 → 구매 안내 → 본문 → 출처 → 해시태그, 빈 블록은 건너뜀", () => {
    const d = composeDescription({
      disclosure: "이 영상은 쿠팡 파트너스 활동의 일환으로, 이에 따른 일정액의 수수료를 제공받습니다.",
      purchase: "구매 정보: 프로필 링크 5번",
      body: "좁은 틈에도 쏙",
      credits: "영상 출처: @a(TikTok)",
      hashtags: ["수납", "압축팩"],
    });
    expect(d).toBe(
      "이 영상은 쿠팡 파트너스 활동의 일환으로, 이에 따른 일정액의 수수료를 제공받습니다.\n\n구매 정보: 프로필 링크 5번\n\n좁은 틈에도 쏙\n\n영상 출처: @a(TikTok)\n\n#수납 #압축팩",
    );
    expect(composeDescription({ disclosure: "", purchase: "", body: "본문", credits: "영상 출처: @a(TikTok)", hashtags: ["수납", "압축팩"] })).toBe(
      "본문\n\n영상 출처: @a(TikTok)\n\n#수납 #압축팩",
    );
  });

  it("입력 순서와 상관없이 같은 결과(호출 인자 객체 순서 무관)", () => {
    const parts = { hashtags: ["t"], credits: "c", body: "b", purchase: "p", disclosure: "d" };
    expect(composeDescription(parts)).toBe("d\n\np\n\nb\n\nc\n\n#t");
  });

  it("해시태그 정리: # 제거·중복 제거·순서 유지", () => {
    expect(parseHashtags("#수납  압축팩,#수납 ##정리")).toEqual(["수납", "압축팩", "정리"]);
  });
});

describe("제휴 링크·추천·문구·시간", () => {
  it("프로그램별 허용 도메인 https 만", () => {
    expect(checkAffiliateUrl("coupang_partners", "https://link.coupang.com/a/abc").ok).toBe(true);
    expect(checkAffiliateUrl("coupang_partners", "http://link.coupang.com/a/abc").ok).toBe(false);
    expect(checkAffiliateUrl("coupang_partners", "https://coupang.com.evil.example/a").ok).toBe(false);
    expect(checkAffiliateUrl("coupang_partners", "https://naver.me/x").ok).toBe(false);
    expect(checkAffiliateUrl("naver_shopping_connect", "https://naver.me/x").ok).toBe(true);
    expect(checkAffiliateUrl("youtube_shopping", "https://youtube.com/x").ok).toBe(false);
  });

  it("우회 거부: userinfo · 유니코드(키릴)·퓨니코드 · 포트 · 위장 호스트, 대문자는 소문자로 정규화", () => {
    for (const bad of [
      "https://coupang.com@evil.example/a",
      "https://user:pw@link.coupang.com/a",
      "https://user@link.coupang.com/a",
      "https://link.coupаng.com/a",
      "https://xn--coupng-4ve.com/a",
      "https://link.coupang.com:8443/a",
      "https://evilcoupang.com/a",
      "https://link.coupang.com/a b",
      "javascript://link.coupang.com/a",
    ]) {
      expect(checkAffiliateUrl("coupang_partners", bad).ok, bad).toBe(false);
    }
    const upper = checkAffiliateUrl("coupang_partners", "HTTPS://LINK.COUPANG.COM/a/X");
    expect(upper).toEqual({ ok: true, url: "https://link.coupang.com/a/X" });
  });

  it("추천: 쿠팡 기본 · 카테고리 맞춤 · YouTube 채널이면 유튜브 쇼핑 태그", () => {
    expect(recommendedPrograms("생활·수납", "youtube")).toEqual(["coupang_partners", "naver_shopping_connect", "ohouse_curator", "youtube_shopping"]);
    expect(recommendedPrograms("뷰티", "instagram")).toEqual(["coupang_partners", "oliveyoung_curator"]);
    expect(recommendedPrograms(null, "tiktok")).toEqual(["coupang_partners"]);
  });

  it("자동 작성 3가지 안은 금지어가 없고 제목 100자 이하", () => {
    const vs = copyVariants("진공 압축팩", "생활·수납", ["좁은 틈에도 쏙 들어가요.", "이거 하나면 정리 끝!"]);
    expect(vs).toHaveLength(3);
    for (const v of vs) {
      expect(findPublishBanned([v.title, v.body, v.hashtags.join("")], [], [])).toBeNull();
      expect([...v.title].length).toBeLessThanOrEqual(100);
    }
  });

  it("추천 시간 3개는 30분 뒤 이후의 KST 12·18·21시", () => {
    const now = new Date("2026-11-12T08:50:00Z"); // KST 17:50
    const slots = recommendedSlots(now).map((d) => d.toISOString());
    expect(slots).toEqual(["2026-11-12T12:00:00.000Z", "2026-11-13T03:00:00.000Z", "2026-11-13T09:00:00.000Z"]);
    expect(kstInputToIso(isoToKstInput(slots[0]))).toBe(slots[0]);
  });
});
