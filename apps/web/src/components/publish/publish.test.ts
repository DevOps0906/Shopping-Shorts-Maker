import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { FeedbackProvider } from "@/components/feedback";
import { StudioStepView } from "@/components/studio/studio-step-view";
import { POLICY_ITEMS, type PolicyCheck, type PolicyView } from "@/lib/publish/rules";
import type { StepStatusMap } from "@/lib/steps/state";
import type { PublishStepData } from "@/server/publish/publish";
import { PublishPanel } from "./publish-panel";

vi.mock("next/navigation", () => ({ useRouter: () => ({ refresh: () => {} }) }));
vi.mock("@/app/(dashboard)/studio/[projectId]/[step]/publish/actions", () => ({
  refreshPolicyAction: vi.fn(),
  saveAffiliateAction: vi.fn(),
  chooseBioServiceAction: vi.fn(),
  setUserCheckAction: vi.fn(),
  preparePublicationAction: vi.fn(),
  retryUploadAction: vi.fn(),
  confirmUploadAbsentAction: vi.fn(),
}));
vi.mock("@/app/(dashboard)/studio/actions", () => ({ approveStep: vi.fn(), requestStepChange: vi.fn() }));

/* spec S-11 06 발행: 제휴 8개(추천) · 링크 삽입 위치 · 링크인바이오(번호·복사·등록 완료) · 제목 100자 · 설명 미리보기 순서 · 정책 6항목 N/6 · 발행 설정 · 버튼 비활성 */

const approved5: StepStatusMap = { 1: "approved", 2: "approved", 3: "approved", 4: "approved", 5: "approved", 6: "idle" };
const pass = (overrides: Partial<Record<PolicyCheck["item"], PolicyCheck["result"]>> = {}): PolicyCheck[] =>
  POLICY_ITEMS.map((p) => ({ item: p.id, result: overrides[p.id] ?? "pass", detail: `${p.label} 상세`, checkedAt: p.id === "attribution_notice" ? "2026-11-12T00:00:00Z" : null }));
const policy = (items: PolicyCheck[]): PolicyView => ({
  items,
  credits: "영상 출처: @maker_a(TikTok)",
  disclosure: "이 영상은 쿠팡 파트너스 활동의 일환으로, 이에 따른 일정액의 수수료를 제공받습니다.",
  purchase: "구매 정보: 프로필 링크 5번",
});
const base: PublishStepData = {
  productName: "진공 압축팩",
  categoryName: "생활·수납",
  channel: { platform: "youtube", name: "E2E 채널" },
  scriptLines: ["좁은 틈에도 쏙 들어가요."],
  bannedTerms: ["최저가 보장"],
  link: { program: "coupang_partners", url: "https://link.coupang.com/a/test", disclosed: true, bioService: "inpock", bioNo: 5, bioRegistered: true },
  publication: null,
  variants: [
    { title: "진공 압축팩 써 보니 이렇게 편해요", body: "본문 하나", hashtags: ["수납"] },
    { title: "두 번째 안", body: "본문 둘", hashtags: ["압축팩"] },
    { title: "세 번째 안", body: "본문 셋", hashtags: ["정리"] },
  ],
  initialCopy: { title: "진공 압축팩 써 보니 이렇게 편해요", body: "본문 하나", hashtags: ["수납", "압축팩"] },
  policy: policy(pass()),
  slots: ["2026-11-12T12:00:00.000Z", "2026-11-13T03:00:00.000Z", "2026-11-13T09:00:00.000Z"],
};

function panel(props: Partial<PublishStepData>, status: StepStatusMap = approved5) {
  return renderToStaticMarkup(
    createElement(
      FeedbackProvider,
      null,
      createElement(
        StudioStepView,
        { projectId: "00000000-0000-4000-a000-000000000002", step: 6, initialStatus: status, runningStartedAt: null },
        createElement(PublishPanel, { ...base, ...props }),
      ),
    ),
  );
}

const publishButton = /<button[^>]*>발행<\/button>/;
const isDisabled = (out: string) => /disabled=""/.test(out.match(publishButton)?.[0] ?? "");

describe("S-11 06 발행 렌더", () => {
  it("카드 구성: 제휴 8개·추천 · 링크 삽입 위치 · 링크인바이오 번호 · 제목 카운터 · 미리보기 · 정책 6항목 · 발행 설정", () => {
    const out = panel({});
    for (const label of ["쿠팡 파트너스", "네이버 쇼핑 커넥트", "오늘의집 큐레이터", "무신사 큐레이터", "올리브영 쇼핑 큐레이터", "유튜브 쇼핑 상품 태그", "알리익스프레스", "사용 안 함"]) {
      expect(out).toContain(label);
    }
    expect(out.match(/role="radio"/g)?.length).toBeGreaterThanOrEqual(8 + 4 + 2);
    expect(out).toContain(">추천<");
    expect(out).toContain("자동 찾기");
    expect(out).toContain("고지 문구 자동 삽입");
    expect(out).toContain("고정 댓글 구매 안내");
    expect(out).toContain("클릭 안 됨");
    expect(out).toContain("조건부");
    expect(out).toContain("5번");
    expect(out).toContain("항목 내용 복사");
    expect(out).toContain("등록 완료");
    expect(out).toContain("/ 100");
    expect(out).toContain("다시 만들기 (1/3안)");
    expect(out).toContain("6 / 6 통과");
    for (const p of POLICY_ITEMS) expect(out).toContain(p.label);
    expect(out).toContain("예약 발행");
    expect(out).toContain("지금 올리기");
    expect(out).toContain("추천 시간");
  });

  it("설명란 미리보기 순서: 고지 → 구매 안내 → 본문 → 출처 → 해시태그", () => {
    const out = panel({});
    const preview = out.slice(out.indexOf('aria-label="설명란 미리보기"'));
    const at = (s: string) => preview.indexOf(s);
    expect(at("쿠팡 파트너스 활동")).toBeGreaterThan(-1);
    expect(at("쿠팡 파트너스 활동")).toBeLessThan(at("구매 정보: 프로필 링크 5번"));
    expect(at("구매 정보: 프로필 링크 5번")).toBeLessThan(at("본문 하나"));
    expect(at("본문 하나")).toBeLessThan(at("영상 출처: @maker_a"));
    expect(at("영상 출처: @maker_a")).toBeLessThan(at("#수납 #압축팩"));
  });

  it("6/6 통과 · 05 승인이면 발행 버튼 활성", () => {
    const out = panel({});
    expect(out).toMatch(publishButton);
    expect(isDisabled(out)).toBe(false);
    expect(out).not.toContain("발행 버튼이 꺼져 있습니다");
  });

  it("6항목 중 1개라도 미통과·확인 필요면 발행 버튼 비활성 + 사라지지 않는 경고 배너", () => {
    for (const p of POLICY_ITEMS) {
      for (const result of ["fail", "pending"] as const) {
        const out = panel({ policy: policy(pass({ [p.id]: result })) });
        expect(isDisabled(out), `${p.label} ${result}`).toBe(true);
        expect(out).toContain("5 / 6 통과");
        expect(out).toContain("발행 버튼이 꺼져 있습니다");
        expect(out).toMatch(/role="alert"[^>]*>[\s\S]*정책 점검 1개 항목/);
      }
    }
  });

  it("DB가 통과로 줘도 입력 중 문구에 금지어가 있으면 비활성", () => {
    const out = panel({ initialCopy: { title: "최고의 압축팩", body: "본문", hashtags: [] } });
    expect(isDisabled(out)).toBe(true);
    expect(out).toContain("금지·과장 표현 &quot;최고&quot;");
  });

  it("05 편집 미승인이면 안내하고 비활성", () => {
    const out = panel({}, { ...approved5, 5: "ready" });
    expect(out).toContain("05 편집을 승인하면 발행할 수 있습니다");
    expect(isDisabled(out)).toBe(true);
  });

  it("발행 준비 완료 상태(성공) 배너", () => {
    const out = panel({
      publication: {
        mode: "now",
        scheduledAt: null,
        title: "t",
        body: "본문 하나",
        description: "d",
        hashtags: [],
        pinComment: false,
        preparedAt: "2026-11-12T00:00:00Z",
        status: "pending",
        error: null,
        nextAttemptAt: null,
        retryCount: 0,
        videoId: null,
      },
    });
    expect(out).toContain("발행 준비 완료 · 지금 올리기");
    expect(out).toContain("발행 준비 다시 저장");
  });

  it("정책 변화로 발행 준비가 풀리면(invalidated) 경고 배너, 성공 배너 없음", () => {
    const out = panel({
      publication: {
        mode: "now",
        scheduledAt: null,
        title: "t",
        body: "본문 하나",
        description: "d",
        hashtags: [],
        pinComment: false,
        preparedAt: "2026-11-12T00:00:00Z",
        status: "invalidated",
        error: null,
        nextAttemptAt: null,
        retryCount: 0,
        videoId: null,
      },
    });
    expect(out).toContain("발행 준비가 풀렸습니다");
    expect(out).not.toContain("발행 준비 완료 ·");
    expect(isDisabled(out)).toBe(false);
  });

  it("제휴를 쓰지 않으면 링크인바이오는 번호를 받을 수 없다는 안내", () => {
    const out = panel({ link: { program: "none", url: null, disclosed: true, bioService: null, bioNo: null, bioRegistered: false } });
    expect(out).toContain("링크형 제휴 프로그램을 고르고");
  });

  it("업로드 상태: 예약 완료는 Studio 취소 안내, 결과 불명은 Studio 확인 뒤 다시 시도, 지난 예약은 다시 저장 안내", () => {
    const pub = {
      mode: "scheduled" as const,
      scheduledAt: "2026-11-20T10:00:00Z",
      title: "t",
      body: "본문 하나",
      description: "d",
      hashtags: [],
      pinComment: false,
      preparedAt: "2026-11-12T00:00:00Z",
      error: null,
      nextAttemptAt: null,
      retryCount: 0,
      videoId: "dQw4w9WgXcQ",
    };
    const scheduled = panel({ publication: { ...pub, status: "scheduled" } });
    expect(scheduled).toContain("YouTube Studio에서 해 주세요");
    expect(scheduled).toContain("https://studio.youtube.com/video/dQw4w9WgXcQ/edit");
    expect(isDisabled(scheduled)).toBe(true);

    const unknown = panel({ publication: { ...pub, status: "needs_check", error: "unknown:response_lost", videoId: null } });
    expect(unknown).toContain("YouTube Studio에서 이 영상이 올라갔는지 먼저 확인");
    expect(unknown).toContain("영상 없음 확인 · 새로 업로드");
    expect(unknown).not.toContain(">다시 시도<");

    const reconnect = panel({ publication: { ...pub, status: "reconnect_wait", error: "reconnect:invalid_grant", videoId: null } });
    expect(reconnect).toContain("채널 다시 연결");

    const passed = panel({ publication: { ...pub, status: "invalidated", error: "confirm:schedule_passed", videoId: null } });
    expect(passed).toContain("예약 시각이 지나 업로드하지 않았습니다");
    expect(passed).not.toContain("발행 준비가 풀렸습니다");
    expect(isDisabled(passed)).toBe(false);
  });

  it("설명란 바이트 수 표시, 5000바이트 초과면 발행 버튼 꺼짐 · needs_check 는 영상 없음 확인 버튼", () => {
    const long = panel({ initialCopy: { title: "압축팩 정리 꿀팁", body: "가".repeat(4000), hashtags: [] } });
    expect(long).toContain("YouTube 한도를 넘어 발행할 수 없습니다");
    expect(isDisabled(long)).toBe(true);
    const short = panel({ initialCopy: { title: "압축팩 정리 꿀팁", body: "가".repeat(100), hashtags: [] } });
    expect(short).toMatch(/설명란 [\d,]+ \/ 5,000바이트/);

    const unknown = panel({
      publication: {
        mode: "now",
        scheduledAt: null,
        title: "t",
        body: "본문 하나",
        description: "d",
        hashtags: [],
        pinComment: false,
        preparedAt: "2026-11-12T00:00:00Z",
        status: "needs_check",
        error: "unknown:response_lost",
        nextAttemptAt: null,
        retryCount: 0,
        videoId: null,
      },
    });
    expect(unknown).toContain("영상 없음 확인 · 새로 업로드");
  });
});
