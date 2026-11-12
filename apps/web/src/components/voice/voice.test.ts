import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { FeedbackProvider } from "@/components/feedback";
import { StudioStepView } from "@/components/studio/studio-step-view";
import type { StepStatusMap } from "@/lib/steps/state";
import { RECORDING_ERRORS, checkRecording, sniffAudio, wavDurationSec } from "@/lib/voice/recording";
import { type TakeView, VOICES, isVoiceId, parseWords } from "@/lib/voice/voices";
import { VoicePanel } from "./voice-panel";
import { VoicePicker } from "./voice-picker";

vi.mock("next/navigation", () => ({ useRouter: () => ({ refresh: () => {} }) }));
vi.mock("@/app/(dashboard)/studio/[projectId]/[step]/voice/actions", () => ({
  startTtsAction: vi.fn(),
  pollTtsAction: vi.fn(),
}));
vi.mock("@/app/(dashboard)/studio/actions", () => ({ approveStep: vi.fn(), requestStepChange: vi.fn() }));

/* spec S-09 04 목소리: 목소리 6종 · 음성 생성 · 직접 녹음 · 현재 음성(플레이어·승인 대본·단어) · 상태(빈·로딩·오류·성공) */

const html = (el: Parameters<typeof renderToStaticMarkup>[0]) => renderToStaticMarkup(el);

function wav(seconds: number, rate = 8000): Uint8Array {
  const data = Math.round(seconds * rate) * 2;
  const b = new Uint8Array(44 + data);
  const v = new DataView(b.buffer);
  const put = (at: number, s: string) => [...s].forEach((c, i) => (b[at + i] = c.charCodeAt(0)));
  put(0, "RIFF");
  v.setUint32(4, 36 + data, true);
  put(8, "WAVE");
  put(12, "fmt ");
  v.setUint32(16, 16, true);
  v.setUint16(20, 1, true);
  v.setUint16(22, 1, true);
  v.setUint32(24, rate, true);
  v.setUint32(28, rate * 2, true);
  v.setUint16(32, 2, true);
  v.setUint16(34, 16, true);
  put(36, "data");
  v.setUint32(40, data, true);
  return b;
}

describe("목소리 목록", () => {
  it("한국어 목소리 6종, 워커와 같은 ID", () => {
    expect(VOICES.map((v) => v.id)).toEqual(["Leda", "Zephyr", "Kore", "Sadachbia", "Puck", "Charon"]);
    expect(isVoiceId("Leda")).toBe(true);
    expect(isVoiceId("EvilVoice")).toBe(false);
  });

  it("단어 타이밍 파싱은 모양이 맞는 항목만", () => {
    expect(parseWords([{ s: 0, w: "첫", start: 0, end: 0.3 }, { s: "x" }, null])).toEqual([{ s: 0, w: "첫", start: 0, end: 0.3 }]);
    expect(parseWords("nope")).toEqual([]);
  });
});

describe("녹음 업로드 검사", () => {
  it("wav 길이는 헤더로 잰다", () => {
    expect(wavDurationSec(wav(2.5))).toBeCloseTo(2.5, 3);
    const ok = checkRecording(wav(2.5), wav(2.5).byteLength, 999);
    expect(ok).toMatchObject({ ok: true, kind: { mime: "audio/wav" }, durationSec: 2.5 });
  });

  it("잘린 WAV(data 청크가 헤더보다 짧음)는 거부", () => {
    const cut = wav(5).slice(0, 44 + 8000);
    expect(wavDurationSec(cut)).toBeNull();
    expect(checkRecording(cut, cut.byteLength, 5)).toEqual({ ok: false, error: RECORDING_ERRORS.unreadable });
  });

  it("형식 오류는 사용자 문구로 안내", () => {
    const text = new TextEncoder().encode("<html>not audio</html>");
    expect(checkRecording(text, text.byteLength, 3)).toEqual({ ok: false, error: RECORDING_ERRORS.format });
    // MIME·확장자를 속인 영상(mp4 = ftyp 도 m4a 로 보지만 길이 범위는 확인), PNG
    const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    expect(checkRecording(png, png.byteLength, 3)).toEqual({ ok: false, error: RECORDING_ERRORS.format });
  });

  it("크기·길이 범위", () => {
    expect(checkRecording(wav(0.5), wav(0.5).byteLength, 0)).toEqual({ ok: false, error: RECORDING_ERRORS.tooShort });
    expect(checkRecording(wav(61), wav(61).byteLength, 0)).toEqual({ ok: false, error: RECORDING_ERRORS.tooLong });
    expect(checkRecording(wav(2), 30 * 1024 * 1024, 0)).toEqual({ ok: false, error: RECORDING_ERRORS.tooBig });
    expect(checkRecording(new Uint8Array(0), 0, 0)).toEqual({ ok: false, error: RECORDING_ERRORS.empty });
    const webm = new Uint8Array([0x1a, 0x45, 0xdf, 0xa3, 0, 0, 0, 0]);
    expect(sniffAudio(webm)?.mime).toBe("audio/webm");
    expect(checkRecording(webm, 1000, Number.POSITIVE_INFINITY)).toEqual({ ok: false, error: RECORDING_ERRORS.unreadable });
    expect(checkRecording(webm, 1000, 12.3)).toMatchObject({ ok: true, durationSec: 12.3 });
  });
});

const approved3: StepStatusMap = { 1: "approved", 2: "approved", 3: "approved", 4: "idle", 5: "idle", 6: "idle" };
const lines = ["좁은 틈에도 쏙 들어가요.", "이거 하나면 정리 끝!"];

function panel(props: Partial<Parameters<typeof VoicePanel>[0]>, status: StepStatusMap = approved3) {
  return html(
    createElement(
      FeedbackProvider,
      null,
      createElement(
        StudioStepView,
        { projectId: "00000000-0000-4000-a000-000000000002", step: 4, initialStatus: status, runningStartedAt: null },
        createElement(VoicePanel, { lines, initialTake: null, initialJob: null, ...props }),
      ),
    ),
  );
}

describe("S-09 04 목소리 렌더", () => {
  it("목소리 카드 6개(이름·성별)와 라디오", () => {
    const out = html(createElement(VoicePicker, { value: "Kore", onChange: () => {} }));
    expect(out.match(/type="radio"/g)).toHaveLength(6);
    for (const v of VOICES) expect(out).toContain(v.name);
    expect(out).toContain("여성");
    expect(out).toContain("남성");
    expect(out).toContain("전체 목소리 100개 보기");
  });

  it("빈 상태: 목소리 선택 안내 · 음성 생성 · 직접 녹음 · 승인 대본 · 비용", () => {
    const out = panel({});
    expect(out).toContain("목소리를 하나 고른 뒤 음성 생성");
    expect(out).toContain("음성 생성");
    expect(out).toContain("직접 녹음 추가");
    expect(out).toContain("녹음 파일 올리기");
    expect(out).toContain("아직 음성이 없습니다");
    expect(out).toContain(lines[1]);
    expect(out).toContain("예상 크레딧 10");
  });

  it("로딩: 음성 합성 중 · 경과 초", () => {
    const out = panel({ initialJob: { id: "j1", status: "running", error: null, startedAt: null } });
    expect(out).toContain("음성 합성 중… 0초");
  });

  it("성공: 플레이어 · 단어 칩", () => {
    const take: TakeView = {
      id: "t1",
      source: "tts",
      voiceId: "Leda",
      durationSec: 3.2,
      audioUrl: "https://example.test/signed",
      sentences: [{ i: 0, text: lines[0], start: 0, end: 1.5 }],
      words: lines[0].split(" ").map((w, k) => ({ s: 0, w, start: k * 0.5, end: k * 0.5 + 0.5 })),
      createdAt: "2026-11-12T00:00:00Z",
    };
    const out = panel({ initialTake: take });
    expect(out).toContain("<audio");
    expect(out).toContain("레다(여성)");
    expect(out.match(/aria-label="단어별 다시 듣기"/g)).toHaveLength(1);
    for (const w of lines[0].split(" ")) expect(out).toContain(`>${w}</button>`);
    expect(out).toContain("다시 생성");
  });

  it("03 미승인이면 생성 막고 안내", () => {
    const out = panel({}, { ...approved3, 3: "ready" });
    expect(out).toContain("03 대본을 승인하면 음성을 만들 수 있습니다");
  });
});
