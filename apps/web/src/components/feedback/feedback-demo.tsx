"use client";

import { useEffect, useState } from "react";
import { InlineBanner } from "./inline-banner";
import { Modal } from "./modal";
import { useFeedback } from "./feedback-provider";

const btn = "rounded-btn border border-line bg-white px-3 py-2 text-sm font-bold text-ink hover:bg-nav-hover";

/** 개발용 데모(/dev/feedback). preview=1이면 스낵바·오류 스낵바를 미리 띄워 캡처한다. */
export function FeedbackDemo({ preview }: { preview: boolean }) {
  const fb = useFeedback();
  const [modalOpen, setModalOpen] = useState(false);
  const [partner, setPartner] = useState(false);
  const [result, setResult] = useState("—");

  useEffect(() => {
    if (!preview) return;
    fb.snackbar({ message: "음성 생성에 실패했습니다. 다시 시도하면 크레딧은 한 번만 차감됩니다", tone: "error", key: "demo:error", action: { label: "다시 시도", onAction: () => {} } });
    fb.snackbar({ message: "'무선 선풍기' 영상 출력이 끝났습니다", action: { label: "보기", onAction: () => {} }, key: "render:demo" });
    fb.snackbar({ message: "문장을 삭제했습니다", action: { label: "실행 취소", onAction: () => {}, undo: true }, key: "demo:undo" });
  }, [preview, fb]);

  return (
    <div className="flex flex-col gap-6">
      <h1 className="text-h font-bold">피드백 컴포넌트 (개발용)</h1>

      <section className="flex flex-wrap gap-2">
        <button type="button" className={btn} onClick={() => fb.toast({ message: "03 대본을 승인했습니다", tone: "success" })}>
          토스트
        </button>
        <button type="button" className={btn} onClick={() => fb.snackbar({ message: "문장을 삭제했습니다", action: { label: "실행 취소", onAction: () => fb.toast({ message: "되돌렸습니다" }), undo: true } })}>
          스낵바(실행 취소)
        </button>
        <button type="button" className={btn} onClick={() => fb.snackbar({ message: "'무선 선풍기' 영상 출력이 끝났습니다", key: "render:demo", action: { label: "보기", onAction: () => {} } })}>
          스낵바(같은 key)
        </button>
        <button type="button" className={btn} onClick={() => fb.snackbar({ message: "렌더에 실패했습니다", tone: "error", action: { label: "다시 시도", onAction: () => {} } })}>
          오류 스낵바
        </button>
        <button
          type="button"
          className={btn}
          onClick={async () => {
            const ok = await fb.confirm({ title: "'무선 선풍기' 프로젝트를 삭제할까요?", description: "영상·원본·대본이 모두 지워집니다.", confirmLabel: "삭제", danger: true });
            setResult(ok ? "삭제" : "취소");
          }}
        >
          알림 대화상자
        </button>
        <button type="button" className={btn} onClick={() => setModalOpen(true)}>
          모달
        </button>
        <label className="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={partner}
            onChange={(e) => {
              setPartner(e.target.checked);
              fb.setPartnerOpen(e.target.checked);
            }}
          />
          제작 파트너 팝업 열림
        </label>
      </section>
      <p className="text-sm text-muted">confirm 결과: {result}</p>

      <section className="flex flex-col gap-3">
        <InlineBanner tone="error" action={<button type="button" className={btn}>다시 시도</button>}>
          음성 생성에 실패했습니다. 다시 시도하면 크레딧은 한 번만 차감됩니다
        </InlineBanner>
        <InlineBanner tone="warning">권리를 확인한 원본에만 워터마크 제거를 쓸 수 있습니다</InlineBanner>
        <InlineBanner tone="success">준비 완료</InlineBanner>
      </section>

      <Modal open={modalOpen} title="이 작업은 약 3 크레딧을 씁니다" onClose={() => setModalOpen(false)}>
        <label className="flex flex-col gap-1">
          메모
          <input className="rounded-btn-sm border border-line px-3 py-2" />
        </label>
        <div className="mt-6 flex justify-end gap-2">
          <button type="button" className={btn} onClick={() => setModalOpen(false)}>
            취소
          </button>
          <button type="button" className="rounded-btn bg-accent px-3 py-2 text-sm font-bold text-white" onClick={() => setModalOpen(false)}>
            생성
          </button>
        </div>
      </Modal>
    </div>
  );
}
