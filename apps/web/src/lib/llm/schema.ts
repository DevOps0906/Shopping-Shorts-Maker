/*
 * 모델 출력 검사 — 스키마를 벗어나면(모르는 키, 타입·길이 위반, 개수 초과) 통째로 거부한다.
 * 모델이 데이터 속 지시를 따라 다른 모양을 내놓아도 저장·상태 변경으로 이어지지 않게 하는 마지막 관문.
 */

export type TopicCandidate = { name: string; reason: string };

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasOnlyKeys(value: Record<string, unknown>, keys: readonly string[]) {
  return Object.keys(value).every((k) => keys.includes(k));
}

function boundedString(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 && trimmed.length <= max ? trimmed : null;
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

/** {"candidates":[{"name","reason"}]} 0~3개. 위반이면 null */
export function parseTopicOutput(text: string): TopicCandidate[] | null {
  const data = parseJson(text);
  if (!isPlainObject(data) || !hasOnlyKeys(data, ["candidates"]) || !Array.isArray(data.candidates)) return null;
  if (data.candidates.length > 3) return null;
  const out: TopicCandidate[] = [];
  for (const item of data.candidates) {
    if (!isPlainObject(item) || !hasOnlyKeys(item, ["name", "reason"])) return null;
    const name = boundedString(item.name, 40);
    const reason = boundedString(item.reason, 120);
    if (!name || !reason) return null;
    out.push({ name, reason });
  }
  return out;
}

/** {"lines":[문장]} 1~8개, 문장당 80자 이내. 위반이면 null */
export function parseScriptOutput(text: string): string[] | null {
  const data = parseJson(text);
  if (!isPlainObject(data) || !hasOnlyKeys(data, ["lines"]) || !Array.isArray(data.lines)) return null;
  if (data.lines.length === 0 || data.lines.length > 8) return null;
  const lines: string[] = [];
  for (const item of data.lines) {
    const line = boundedString(item, 80);
    if (!line || line.includes("\n")) return null;
    lines.push(line);
  }
  return lines;
}
