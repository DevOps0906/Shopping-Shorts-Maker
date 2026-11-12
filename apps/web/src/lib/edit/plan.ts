/*
 * 05 편집 컷 계획 — 워커 apps/worker/worker/render/plan.py 와 같은 규칙(화면 미리보기용. 실제 값은 워커가 다시 계산해 renders.cut_map 에 남긴다).
 * - 컷 = 대본 한 줄. 경계는 음성 문장 사이 쉼의 가운데(문장 타이밍이 없으면 글자 수 비율), 1/30초 단위. 마지막 컷은 목표 길이까지.
 * - 음성이 목표보다 길면 최대 1.15배 빠르게(atempo). 더 길면 렌더하지 않는다.
 * - 기본 매칭: 점수 순 편집 입력 원본을 차례로 돌려 쓴다(컷 i → 순위 i % 원본 수). 교체 = 다음 순위 원본.
 * - 편집 입력 원본은 DB 함수 edit_input_sources(권리 근거 있음 · 격리 아님 · 고지 확인)만 쓴다.
 */

export const FPS = 30;
export const MAX_TEMPO = 1.15;
export const MIN_CUT_SEC = 0.5;

/** 예상 비용(D9: 호출 전 표시). 크레딧은 DB private.job_cost('render')와 같다. 렌더는 자체 서버 FFmpeg라 외부 API 비용 0원 */
export const RENDER_CREDITS = 30;
export const RENDER_COST_LINE = `예상 크레딧 ${RENDER_CREDITS} · 자체 서버 렌더(외부 AI 호출 없음) 약 0원`;
/** 작업 시간 상한(17-5 가설: 렌더 10분). 워커·DB 스위퍼와 같은 값 */
export const RENDER_TIME_LIMIT_SEC = 600;

export const PLATFORM_LABEL: Record<string, string> = { tiktok: "TikTok", xiaohongshu: "小红书", direct: "직접 추가" };

export type Candidate = {
  id: string;
  rank: number;
  author: string;
  platform: string;
  durationSec: number | null;
  score: number | null;
  rightsBasis: string;
};

export type SentenceSpan = { i: number; start: number; end: number };

export type CutRow = {
  no: number;
  line: string;
  sourceId: string;
  author: string;
  platform: string;
  srcStart: number;
  srcEnd: number;
  outStart: number;
  outEnd: number;
};

export type PlanResult = { ok: true; cuts: CutRow[]; tempo: number; method: "sentences" | "char_ratio" } | { ok: false; error: string };

const toFrame = (sec: number) => Math.round(sec * FPS) / FPS;
const r3 = (x: number) => Math.round(x * 1000) / 1000;

function charRatio(lines: string[], target: number): number[] {
  const weights = lines.map((x) => Math.max(1, x.replace(/\s/g, "").length));
  const total = weights.reduce((a, b) => a + b, 0);
  const out = [0];
  let acc = 0;
  for (const w of weights.slice(0, -1)) {
    acc += w;
    out.push(toFrame((target * acc) / total));
  }
  return [...out, target];
}

const tooShort = (b: number[]) => b.slice(1).some((x, i) => x - b[i] < MIN_CUT_SEC);

export function boundaries(
  lines: string[],
  sentences: SentenceSpan[],
  voiceSec: number,
  target: number,
): { ok: true; bounds: number[]; tempo: number; method: "sentences" | "char_ratio" } | { ok: false; error: string } {
  if (lines.length === 0) return { ok: false, error: "승인된 대본이 없습니다." };
  const tempo = voiceSec <= target ? 1 : voiceSec / target;
  if (tempo > MAX_TEMPO) {
    return { ok: false, error: `음성(${voiceSec.toFixed(1)}초)이 목표 길이 ${target}초보다 너무 깁니다. 04 목소리에서 다시 만들어 주세요.` };
  }
  const n = lines.length;
  const ordered = [...sentences].sort((a, b) => a.i - b.i);
  if (ordered.length === n) {
    const b = [0];
    for (let i = 1; i < n; i++) b.push(toFrame((ordered[i - 1].end + ordered[i].start) / 2 / tempo));
    b.push(target);
    if (!tooShort(b)) return { ok: true, bounds: b, tempo, method: "sentences" };
  }
  const b = charRatio(lines, target);
  if (tooShort(b)) return { ok: false, error: "대사 줄이 너무 많아 컷을 나눌 수 없습니다. 03 대본을 줄여 주세요." };
  return { ok: true, bounds: b, tempo, method: "char_ratio" };
}

/** 기본 매칭: 컷 i → 점수 순위 i % 원본 수 */
export function defaultAssignment(n: number, candidates: Candidate[]): string[] {
  if (candidates.length === 0) return [];
  return Array.from({ length: n }, (_, i) => candidates[i % candidates.length].id);
}

/** 저장된 매칭이 지금 후보와 맞으면 그대로, 아니면(후보가 바뀜) 기본 매칭 */
export function reconcileAssignment(n: number, candidates: Candidate[], saved: string[] | null): string[] {
  const ids = new Set(candidates.map((c) => c.id));
  if (saved && saved.length === n && saved.every((id) => ids.has(id))) return saved;
  return defaultAssignment(n, candidates);
}

/** 컷 교체: 지금 원본의 다음 순위 원본(마지막이면 1순위로). 후보가 1편이면 null */
export function nextCandidate(candidates: Candidate[], currentId: string): Candidate | null {
  if (candidates.length < 2) return null;
  const at = candidates.findIndex((c) => c.id === currentId);
  return candidates[(at + 1) % candidates.length];
}

export function planCuts(
  lines: string[],
  sentences: SentenceSpan[],
  voiceSec: number,
  target: number,
  assignment: string[],
  candidates: Candidate[],
): PlanResult {
  if (candidates.length === 0) return { ok: false, error: "편집에 쓸 수 있는 원본이 없습니다. 02 소스에서 권리 근거를 확인한 원본을 고르세요." };
  const result = boundaries(lines, sentences, voiceSec, target);
  if (!result.ok) return result;
  const byId = new Map(candidates.map((c) => [c.id, c]));
  const used = new Map<string, number>();
  const cuts: CutRow[] = [];
  for (let i = 0; i < lines.length; i++) {
    const src = byId.get(assignment[i]);
    if (!src) return { ok: false, error: `컷 ${i + 1}번 원본을 편집에 쓸 수 없습니다. 다음 순위 원본으로 바꿔 주세요.` };
    const a = result.bounds[i];
    const b = result.bounds[i + 1];
    const dur = b - a;
    let start = used.get(src.id) ?? 0;
    if (src.durationSec !== null && start + dur > src.durationSec) start = 0;
    used.set(src.id, r3(start + dur));
    cuts.push({
      no: i + 1,
      line: lines[i],
      sourceId: src.id,
      author: src.author,
      platform: src.platform,
      srcStart: r3(start),
      srcEnd: r3(start + dur),
      outStart: r3(a),
      outEnd: r3(b),
    });
  }
  return { ok: true, cuts, tempo: result.tempo, method: result.method };
}

export function creditLabel(author: string): string {
  const a = author.trim().replace(/^@+/, "");
  return a ? `@${a}` : "";
}

/** 설명란용 출처 문구: '영상 출처: @a(TikTok), @b(小红书)' (중복 제거, 컷 순서) */
export function creditsText(cuts: Pick<CutRow, "author" | "platform">[]): string {
  const seen: string[] = [];
  for (const c of cuts) {
    const label = creditLabel(c.author);
    if (!label) continue;
    const item = c.platform ? `${label}(${PLATFORM_LABEL[c.platform] ?? c.platform})` : label;
    if (!seen.includes(item)) seen.push(item);
  }
  return seen.length ? `영상 출처: ${seen.join(", ")}` : "";
}

/** 렌더 실패 문구의 '컷 1번·3번' → [1, 3] (워커 render.cut_error 형식) */
export function failedCutNumbers(error: string | null): number[] {
  const m = error?.match(/컷 ((?:\d+번·?)+)/);
  return m ? [...m[1].matchAll(/(\d+)번/g)].map((x) => Number(x[1])) : [];
}

const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const str = (v: unknown) => (typeof v === "string" ? v : "");

/** renders.cut_map 파싱(워커가 쓴 값). 모양이 다르면 null */
export function parseCutMap(value: unknown): { cuts: CutRow[]; credits: string } | null {
  const obj = value as Record<string, unknown> | null;
  if (!obj || typeof obj !== "object" || !Array.isArray(obj.cuts)) return null;
  const cuts = obj.cuts.flatMap((x): CutRow[] => {
    const c = x as Record<string, unknown> | null;
    if (!c || !isNum(c.no) || !isNum(c.out_start) || !isNum(c.out_end) || typeof c.source_id !== "string") return [];
    return [
      {
        no: c.no,
        line: str(c.line),
        sourceId: c.source_id,
        author: str(c.author),
        platform: str(c.platform),
        srcStart: isNum(c.src_start) ? c.src_start : 0,
        srcEnd: isNum(c.src_end) ? c.src_end : 0,
        outStart: c.out_start,
        outEnd: c.out_end,
      },
    ];
  });
  return cuts.length ? { cuts, credits: str(obj.credits) } : null;
}

/** 화면에 넘기는 렌더 버전·작업(서버 src/server/edit 가 만든다) */
export type RenderView = {
  id: string;
  version: number;
  createdAt: string;
  durationSec: number | null;
  /** 10분짜리 서명 다운로드 URL(공개 URL 아님) */
  videoUrl: string | null;
  cuts: CutRow[];
  credits: string;
};
export type RenderJobView = { id: string; status: string; error: string | null; startedAt: string | null };
