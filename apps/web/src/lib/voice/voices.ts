/*
 * 04 목소리 6종(docs/planning.md 3장 04). 지금은 Fish Audio 키·목소리 ID가 없어 테스트 공급자 Gemini TTS의
 * 기본 목소리를 쓴다(워커 apps/worker/worker/voice/voices.py 와 같은 ID). Fish Audio 연결 후 provider·id 를 바꾼다.
 */

export type VoiceGender = "여성" | "남성";
export type VoiceOption = { id: string; name: string; gender: VoiceGender; tone: string };

export const VOICE_PROVIDER_LABEL = "Gemini TTS(테스트 공급자)";

export const VOICES: readonly VoiceOption[] = [
  { id: "Leda", name: "레다", gender: "여성", tone: "밝고 젊은" },
  { id: "Zephyr", name: "제피르", gender: "여성", tone: "산뜻하고 경쾌한" },
  { id: "Kore", name: "코레", gender: "여성", tone: "또렷하고 단단한" },
  { id: "Sadachbia", name: "사다크비아", gender: "남성", tone: "활기찬" },
  { id: "Puck", name: "퍽", gender: "남성", tone: "명랑한" },
  { id: "Charon", name: "카론", gender: "남성", tone: "차분한 설명형" },
];

export function isVoiceId(value: unknown): value is string {
  return typeof value === "string" && VOICES.some((v) => v.id === value);
}

export function voiceLabel(id: string | null): string {
  const voice = VOICES.find((v) => v.id === id);
  return voice ? `${voice.name}(${voice.gender})` : "직접 녹음";
}

/** 예상 비용(호출 전 표시, D9). 크레딧은 DB private.job_cost('tts')와 같다. 테스트 공급자는 무료 키라 0원 */
export const TTS_CREDITS = 10;
export const TTS_COST_LINE = `예상 크레딧 ${TTS_CREDITS} · ${VOICE_PROVIDER_LABEL} 무료 키 기준 약 0원`;

/** 작업 시간 상한(17-5 가설: 음성 2분). 워커·DB 스위퍼와 같은 값 */
export const TTS_TIME_LIMIT_SEC = 120;

/** 단어 타이밍(voice_takes.words)·문장 타이밍(voice_takes.sentences) */
export type WordTiming = { s: number; w: string; start: number; end: number };
export type SentenceTiming = { i: number; text: string; start: number; end: number };

const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);

export function parseWords(value: unknown): WordTiming[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((x) => {
    const r = x as Record<string, unknown> | null;
    return r && isNum(r.s) && typeof r.w === "string" && isNum(r.start) && isNum(r.end)
      ? [{ s: r.s, w: r.w, start: r.start, end: r.end }]
      : [];
  });
}

export function parseSentences(value: unknown): SentenceTiming[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((x) => {
    const r = x as Record<string, unknown> | null;
    return r && isNum(r.i) && typeof r.text === "string" && isNum(r.start) && isNum(r.end)
      ? [{ i: r.i, text: r.text, start: r.start, end: r.end }]
      : [];
  });
}

/** 화면에 넘기는 음성 테이크·tts 작업(서버 src/server/voice 가 만든다) */
export type TakeView = {
  id: string;
  source: "tts" | "recording";
  voiceId: string | null;
  durationSec: number | null;
  /** 10분짜리 서명 다운로드 URL(공개 URL 아님) */
  audioUrl: string | null;
  sentences: SentenceTiming[];
  words: WordTiming[];
  createdAt: string;
};
export type VoiceJobView = { id: string; status: string; error: string | null; startedAt: string | null };
