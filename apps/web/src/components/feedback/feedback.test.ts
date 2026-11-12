import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { AlertDialog } from "./alert-dialog";
import { FeedbackProvider } from "./feedback-provider";
import { FeedbackRegion } from "./feedback-region";
import { InlineBanner } from "./inline-banner";

const noop = () => {};

describe("알림 영역", () => {
  it("처음부터 빈 컨테이너 2개(status polite · alert)가 DOM에 있다", () => {
    const html = renderToStaticMarkup(createElement(FeedbackProvider, null, "본문"));
    expect(html).toMatch(/<div role="alert"[^>]*><\/div>/);
    expect(html).toMatch(/<div role="status" aria-live="polite"[^>]*><\/div>/);
  });

  it("오류 스낵바는 alert, 나머지는 status 컨테이너에 들어간다", () => {
    const html = renderToStaticMarkup(
      createElement(FeedbackRegion, {
        partnerOpen: true,
        onDismiss: noop,
        items: [
          { id: "1", kind: "toast", tone: "success", message: "저장했습니다", rev: 0 },
          { id: "2", kind: "snackbar", tone: "error", message: "렌더에 실패했습니다", rev: 0 },
        ],
      }),
    );
    const alertPart = html.slice(html.indexOf('role="alert"'), html.indexOf('role="status"'));
    const statusPart = html.slice(html.indexOf('role="status"'));
    expect(alertPart).toContain("렌더에 실패했습니다");
    expect(alertPart).toContain('aria-label="알림 닫기"');
    expect(statusPart).toContain("저장했습니다");
    expect(html).toContain('data-partner="open"');
  });
});

describe("AlertDialog", () => {
  it("role=alertdialog, aria-describedby, 첫 포커스는 취소", () => {
    const html = renderToStaticMarkup(
      createElement(AlertDialog, {
        title: "삭제할까요?",
        description: "모두 지워집니다",
        confirmLabel: "삭제",
        danger: true,
        onConfirm: noop,
        onCancel: noop,
      }),
    );
    expect(html).toContain('role="alertdialog"');
    expect(html).toContain('aria-modal="true"');
    expect(html).toMatch(/aria-describedby="[^"]+"/);
    const buttons = html.match(/<button[^>]*>[^<]*<\/button>/g) ?? [];
    expect(buttons[0]).toContain("data-autofocus");
    expect(buttons[0]).toContain("취소");
    expect(buttons[1]).not.toContain("data-autofocus");
  });
});

describe("InlineBanner", () => {
  it("오류·경고는 alert, 성공은 status, 아이콘 + 텍스트", () => {
    const r = (tone: "error" | "warning" | "success") =>
      renderToStaticMarkup(InlineBanner({ tone, children: "문구" })); // 훅 없는 서버 컴포넌트
    expect(r("error")).toContain('role="alert"');
    expect(r("warning")).toContain('role="alert"');
    expect(r("success")).toContain('role="status"');
    expect(r("success")).toContain("✓");
  });
});
