/*
 * 직접 녹음·업로드 검사(docs/planning.md 17-6: 업로드 형식 오류 → 사용자 문구). 화면과 서버가 같은 규칙을 쓴다.
 * - 형식은 선언된 MIME이 아니라 파일 앞부분(매직 바이트)으로 판단한다. voices 버킷 허용 형식만.
 * - 길이: wav 는 헤더로 정확히 계산하고, 그 밖의 형식은 브라우저가 읽은 길이를 받아 범위만 확인한다(서버에 디코더 없음).
 */

// Next proxy 가 요청 본문을 10MB까지만 넘긴다(middlewareClientMaxBodySize 기본값, 15MB 실측 시 잘림).
// 폼 여유(64KB)를 더해도 10MB 아래가 되도록 9MB. 60초 기준 wav 48kHz 모노(약 5.8MB)·webm·m4a 는 충분하다.
export const RECORDING_MAX_BYTES = 9 * 1024 * 1024;
export const RECORDING_MIN_SEC = 1;
export const RECORDING_MAX_SEC = 60;
export const RECORDING_ACCEPT = "audio/wav,audio/x-wav,audio/mpeg,audio/mp4,audio/x-m4a,audio/webm,audio/ogg,.wav,.mp3,.m4a,.webm,.ogg";

export type AudioKind = { mime: string; ext: string; label: string };

const KINDS = {
  wav: { mime: "audio/wav", ext: "wav", label: "WAV" },
  mp3: { mime: "audio/mpeg", ext: "mp3", label: "MP3" },
  m4a: { mime: "audio/mp4", ext: "m4a", label: "M4A" },
  webm: { mime: "audio/webm", ext: "webm", label: "WebM" },
  ogg: { mime: "audio/ogg", ext: "ogg", label: "OGG" },
} as const satisfies Record<string, AudioKind>;

const ascii = (b: Uint8Array, start: number, text: string) =>
  b.length >= start + text.length && [...text].every((ch, i) => b[start + i] === ch.charCodeAt(0));

export function sniffAudio(b: Uint8Array): AudioKind | null {
  if (ascii(b, 0, "RIFF") && ascii(b, 8, "WAVE")) return KINDS.wav;
  if (ascii(b, 0, "ID3") || (b.length >= 2 && b[0] === 0xff && (b[1] & 0xe0) === 0xe0)) return KINDS.mp3;
  if (ascii(b, 4, "ftyp")) return KINDS.m4a;
  if (b.length >= 4 && b[0] === 0x1a && b[1] === 0x45 && b[2] === 0xdf && b[3] === 0xa3) return KINDS.webm;
  if (ascii(b, 0, "OggS")) return KINDS.ogg;
  return null;
}

/** RIFF/WAVE 헤더로 길이(초). fmt·data 청크를 못 찾거나 data 가 헤더보다 짧으면(잘린 파일) null */
export function wavDurationSec(b: Uint8Array): number | null {
  const view = new DataView(b.buffer, b.byteOffset, b.byteLength);
  let pos = 12;
  let byteRate = 0;
  while (pos + 8 <= b.length) {
    const size = view.getUint32(pos + 4, true);
    if (ascii(b, pos, "fmt ") && pos + 16 <= b.length) byteRate = view.getUint32(pos + 16, true);
    if (ascii(b, pos, "data")) {
      if (!byteRate) return null;
      if (size > b.length - pos - 8) return null;
      return size / byteRate;
    }
    pos += 8 + size + (size % 2);
  }
  return null;
}

export const RECORDING_ERRORS = {
  empty: "녹음 파일을 골라 주세요.",
  tooBig: `파일이 너무 큽니다. ${RECORDING_MAX_BYTES / 1024 / 1024}MB 이하로 올려 주세요.`,
  format: "지원하지 않는 형식입니다. WAV·MP3·M4A·WebM·OGG 음성 파일을 올려 주세요.",
  unreadable: "음성 길이를 읽지 못했습니다. 파일이 손상되지 않았는지 확인해 주세요.",
  tooShort: `녹음이 너무 짧습니다. ${RECORDING_MIN_SEC}초 이상으로 올려 주세요.`,
  tooLong: `녹음이 너무 깁니다. ${RECORDING_MAX_SEC}초 이하로 올려 주세요.`,
} as const;

export type RecordingCheck = { ok: true; kind: AudioKind; durationSec: number } | { ok: false; error: string };

/** head = 파일 앞부분(전체여도 됨). declaredSec = 브라우저가 읽은 길이(wav 가 아니면 이것으로 범위 확인) */
export function checkRecording(bytes: Uint8Array, size: number, declaredSec: unknown): RecordingCheck {
  if (size <= 0) return { ok: false, error: RECORDING_ERRORS.empty };
  if (size > RECORDING_MAX_BYTES) return { ok: false, error: RECORDING_ERRORS.tooBig };
  const kind = sniffAudio(bytes);
  if (!kind) return { ok: false, error: RECORDING_ERRORS.format };
  const sec = kind.ext === "wav" ? wavDurationSec(bytes) : typeof declaredSec === "number" ? declaredSec : Number(declaredSec);
  if (sec === null || !Number.isFinite(sec) || sec <= 0) return { ok: false, error: RECORDING_ERRORS.unreadable };
  if (sec < RECORDING_MIN_SEC) return { ok: false, error: RECORDING_ERRORS.tooShort };
  if (sec > RECORDING_MAX_SEC) return { ok: false, error: RECORDING_ERRORS.tooLong };
  return { ok: true, kind, durationSec: Math.round(sec * 1000) / 1000 };
}
