"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import { pollTtsAction, startTtsAction } from "@/app/(dashboard)/studio/[projectId]/[step]/voice/actions";
import { InlineBanner, useFeedback } from "@/components/feedback";
import { btnClass, btnPrimaryClass } from "@/components/studio/step-actions";
import { useStudioStep } from "@/components/studio/studio-step-view";
import { useElapsed } from "@/components/topic/use-elapsed";
import { RECORDING_ACCEPT, RECORDING_MAX_SEC, checkRecording, sniffAudio } from "@/lib/voice/recording";
import { TTS_COST_LINE, TTS_TIME_LIMIT_SEC, type TakeView, type VoiceJobView, voiceLabel } from "@/lib/voice/voices";
import { cn } from "@/lib/utils";
import { VoicePicker } from "./voice-picker";

/*
 * S-09 04 목소리 본문 — docs/planning.md 3장 04 · 17-6, docs/ui-feedback.md 2장 #4(같은 화면 실패: 배너 오류 + 다시 시도).
 * 상태: 빈(목소리 선택 안내) · 로딩(음성 합성 중 · 경과 초) · 오류(공급자 오류·업로드 형식 오류 → 사용자 문구) · 성공(현재 음성).
 * 음성 생성은 tts 작업(워커)으로 돌고, 화면은 2초마다 작업 상태를 확인한다. 승인은 아래 StepActions만.
 */

type VoicePanelProps = {
  lines: string[];
  initialTake: TakeView | null;
  initialJob: VoiceJobView | null;
};

const ACTIVE = new Set(["queued", "running"]);
const POLL_MS = 2000;
const FAILED_PREFIX = "음성 생성에 실패했습니다.";

function formatSec(sec: number | null) {
  return sec === null ? "-" : `${sec.toFixed(1)}초`;
}

/** 브라우저가 읽은 음성 길이(초). 읽지 못하면 NaN */
function readDuration(file: Blob): Promise<number> {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(file);
    const audio = new Audio();
    const done = (sec: number) => {
      URL.revokeObjectURL(url);
      resolve(sec);
    };
    audio.preload = "metadata";
    audio.onloadedmetadata = () => done(audio.duration);
    audio.onerror = () => done(Number.NaN);
    audio.src = url;
  });
}

export function VoicePanel({ lines, initialTake, initialJob }: VoicePanelProps) {
  const { projectId, status, setStatus } = useStudioStep();
  const feedback = useFeedback();
  const [voiceId, setVoiceId] = useState<string | null>(initialTake?.voiceId ?? null);
  const [take, setTake] = useState(initialTake);
  const [job, setJob] = useState(initialJob);
  const [error, setError] = useState<string | null>(null);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [starting, startTransition] = useTransition();
  const [uploading, setUploading] = useState(false);
  const [recording, setRecording] = useState(false);
  const recorderRef = useRef<MediaRecorder | null>(null);
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const stopAtRef = useRef<number | null>(null);

  const running = job !== null && ACTIVE.has(job.status);
  const elapsed = useElapsed(running);
  const ready = status[3] === "approved";
  const locked = status[4] === "approved";
  const busy = running || starting || uploading || recording;

  // 작업 상태 확인(2초마다). 성공·실패면 멈춘다
  const jobId = running ? job.id : null;
  useEffect(() => {
    if (!jobId) return;
    let active = true;
    const timer = setInterval(async () => {
      const result = await pollTtsAction(projectId, jobId);
      if (!active || !result.ok) return; // 확인 실패는 다음 주기에 다시
      const next = result.job;
      if (next.status === "succeeded") {
        setJob(null);
        if (result.take) setTake(result.take);
        if (result.status) setStatus(result.status);
        feedback.toast({ message: "음성을 만들었습니다", tone: "success" });
      } else if (!ACTIVE.has(next.status)) {
        setJob(null);
        setError(`${FAILED_PREFIX} ${next.error ?? "잠시 뒤 다시 시도해 주세요."}`);
      } else {
        setJob(next);
      }
    }, POLL_MS);
    return () => {
      active = false;
      clearInterval(timer);
    };
  }, [jobId, projectId, setStatus, feedback]);

  function generate() {
    if (!voiceId) return;
    setError(null);
    const key = crypto.randomUUID();
    startTransition(async () => {
      const result = await startTtsAction(projectId, voiceId, key);
      if (!result.ok) {
        setError(result.error);
        return;
      }
      setJob({ id: result.jobId, status: "queued", error: null, startedAt: null });
    });
  }

  async function upload(file: Blob, durationSec: number) {
    setUploadError(null);
    const head = new Uint8Array(await file.slice(0, 64 * 1024).arrayBuffer());
    const checked = checkRecording(head, file.size, durationSec);
    // 큰 wav 는 앞부분만으로 길이를 못 잴 수 있어 서버가 전체로 다시 잰다
    const wavNeedsServer = sniffAudio(head)?.ext === "wav" && head.length < file.size;
    if (!checked.ok && !wavNeedsServer) {
      setUploadError(checked.error);
      return;
    }
    const form = new FormData();
    form.append("file", file);
    form.append("durationSec", String(durationSec));
    setUploading(true);
    try {
      const response = await fetch(`/studio/${projectId}/voice/voice`, { method: "POST", body: form });
      const result = (await response.json()) as
        | { ok: true; take: TakeView; status: typeof status | null }
        | { ok: false; error: string };
      if (!result.ok) {
        setUploadError(result.error);
        return;
      }
      setTake(result.take);
      if (result.status) setStatus(result.status);
      feedback.toast({ message: "녹음을 올렸습니다", tone: "success" });
    } catch {
      setUploadError("녹음 파일을 올리지 못했습니다. 연결을 확인한 뒤 다시 시도해 주세요.");
    } finally {
      setUploading(false);
    }
  }

  async function onFile(event: React.ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    await upload(file, await readDuration(file));
  }

  async function toggleRecord() {
    if (recorderRef.current) {
      recorderRef.current.stop();
      return;
    }
    setUploadError(null);
    let stream: MediaStream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch {
      setUploadError("마이크를 쓸 수 없습니다. 브라우저의 마이크 권한을 허용하거나 녹음 파일을 올려 주세요.");
      return;
    }
    const recorder = new MediaRecorder(stream);
    const chunks: Blob[] = [];
    const startedAt = Date.now();
    const limit = setTimeout(() => recorder.stop(), RECORDING_MAX_SEC * 1000);
    recorder.ondataavailable = (e) => chunks.push(e.data);
    recorder.onstop = () => {
      clearTimeout(limit);
      stream.getTracks().forEach((t) => t.stop());
      recorderRef.current = null;
      setRecording(false);
      const type = recorder.mimeType || "audio/webm";
      void upload(new Blob(chunks, { type }), (Date.now() - startedAt) / 1000);
    };
    recorderRef.current = recorder;
    recorder.start();
    setRecording(true);
  }

  function playRange(start: number, end: number) {
    const audio = audioRef.current;
    if (!audio) return;
    audio.currentTime = start;
    stopAtRef.current = end;
    void audio.play();
  }

  return (
    <div className="flex flex-col gap-4">
      <section aria-label="음성 생성" className="flex flex-col gap-3 rounded-card border border-line bg-white p-4 shadow-card tablet:p-6">
        <VoicePicker value={voiceId} onChange={setVoiceId} disabled={locked || !ready || busy} />
        <div className="flex flex-wrap items-center gap-2">
          <button
            type="button"
            onClick={generate}
            disabled={locked || !ready || busy || !voiceId || lines.length === 0}
            className={cn(btnClass, btnPrimaryClass)}
          >
            {running ? `음성 합성 중… ${elapsed}초` : starting ? "시작하는 중…" : take ? "다시 생성" : "음성 생성"}
          </button>
          <span className="text-xs text-muted">최대 {TTS_TIME_LIMIT_SEC / 60}분</span>
        </div>
        <p className="text-xs text-muted">호출 1회 · {TTS_COST_LINE}</p>
        {!ready ? <p className="text-sm text-muted">03 대본을 승인하면 음성을 만들 수 있습니다.</p> : null}
        {ready && !voiceId && !take && !running ? (
          <p className="text-sm text-muted">목소리를 하나 고른 뒤 음성 생성을 누르거나, 아래에서 직접 녹음을 올려 주세요.</p>
        ) : null}
        {error ? (
          <InlineBanner
            tone="error"
            action={
              voiceId && !locked ? (
                <button type="button" onClick={generate} disabled={busy} className={btnClass}>
                  다시 시도
                </button>
              ) : undefined
            }
          >
            {error}
            {error.startsWith(FAILED_PREFIX) ? " 다시 시도하면 크레딧은 한 번만 차감됩니다. 다른 목소리를 고르거나 직접 녹음할 수도 있습니다." : null}
          </InlineBanner>
        ) : null}
      </section>

      <section aria-label="직접 녹음 추가" className="flex flex-col gap-3 rounded-card border border-line bg-white p-4 shadow-card tablet:p-6">
        <p className="text-sm font-semibold">직접 녹음 추가</p>
        <div className="flex flex-wrap items-center gap-2">
          <button type="button" onClick={toggleRecord} disabled={locked || !ready || (busy && !recording)} className={btnClass}>
            {recording ? "녹음 멈추고 올리기" : "마이크로 녹음"}
          </button>
          <label className={cn(btnClass, (locked || !ready || busy) && "pointer-events-none opacity-60")}>
            {uploading ? "올리는 중…" : "녹음 파일 올리기"}
            <input type="file" accept={RECORDING_ACCEPT} onChange={onFile} disabled={locked || !ready || busy} className="sr-only" />
          </label>
        </div>
        <p className="text-xs text-muted">WAV·MP3·M4A·WebM·OGG, {RECORDING_MAX_SEC}초 이하. 녹음은 비공개로 저장됩니다.</p>
        {uploadError ? <InlineBanner tone="error">{uploadError}</InlineBanner> : null}
      </section>

      <section aria-label="현재 음성" className="flex flex-col gap-3 rounded-card border border-line bg-white p-4 shadow-card tablet:p-6">
        <p className="text-sm font-semibold">현재 음성</p>
        {take ? (
          <>
            <p className="text-xs text-muted">
              {take.source === "recording" ? "직접 녹음" : voiceLabel(take.voiceId)} · {formatSec(take.durationSec)}
            </p>
            {take.audioUrl ? (
              <audio
                ref={audioRef}
                controls
                preload="metadata"
                src={take.audioUrl}
                className="w-full"
                onTimeUpdate={(e) => {
                  const stopAt = stopAtRef.current;
                  if (stopAt !== null && e.currentTarget.currentTime >= stopAt) {
                    e.currentTarget.pause();
                    stopAtRef.current = null;
                  }
                }}
              />
            ) : (
              <p className="text-sm text-muted">음성 파일을 불러오지 못했습니다. 화면을 새로 고쳐 주세요.</p>
            )}
            {take.words.length > 0 ? (
              <div aria-label="단어별 다시 듣기" className="flex flex-col gap-2">
                {take.sentences.map((sentence) => (
                  <p key={sentence.i} className="flex flex-wrap gap-1">
                    {take.words
                      .filter((w) => w.s === sentence.i)
                      .map((w, k) => (
                        <button
                          key={k}
                          type="button"
                          onClick={() => playRange(w.start, w.end)}
                          className="min-h-11 rounded-btn-sm border border-line bg-white px-2 text-sm hover:border-accent-line hover:bg-sub-hover"
                        >
                          {w.w}
                        </button>
                      ))}
                  </p>
                ))}
              </div>
            ) : null}
          </>
        ) : (
          <p className="text-sm text-muted">아직 음성이 없습니다. 음성을 1개 이상 만들거나 올리면 승인할 수 있습니다.</p>
        )}
        <div className="flex flex-col gap-1">
          <p className="text-xs font-semibold text-muted">승인 대본</p>
          {lines.length > 0 ? (
            <ol className="flex list-decimal flex-col gap-1 pl-5 text-sm">
              {lines.map((line, i) => (
                <li key={i}>{line}</li>
              ))}
            </ol>
          ) : (
            <p className="text-sm text-muted">승인된 대본이 없습니다.</p>
          )}
        </div>
      </section>
    </div>
  );
}
