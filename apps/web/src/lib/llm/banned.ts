/*
 * 금지 표현 탐지 — 목록은 카테고리별 categories.banned_terms(docs/planning.md 11장, supabase/seed.sql)만 쓴다.
 * 우회 표기로 빠져나가지 않도록 비교 전에 둘 다 정규화한다:
 * NFC(분리된 한글 자모 합치기) → 제로폭 문자 제거 → 소문자 → 공백·구두점·기호 제거.
 */

export type BannedHit = { line: number; terms: string[] };

const ZERO_WIDTH = /[​-‍﻿⁠]/g;
const SPACE_PUNCT = /[\s\p{P}\p{S}]/gu;

export const normalizeForMatch = (value: string) =>
  value.normalize("NFC").replace(ZERO_WIDTH, "").toLowerCase().replace(SPACE_PUNCT, "");

/** 금지 표현이 들어간 문장(0부터 센 번호)과 그 표현 */
export function findBannedTerms(lines: readonly string[], terms: readonly string[]): BannedHit[] {
  const targets = terms.map((term) => ({ term, key: normalizeForMatch(term) })).filter((t) => t.key.length > 0);
  const hits: BannedHit[] = [];
  lines.forEach((line, index) => {
    const text = normalizeForMatch(line);
    const found = targets.filter((t) => text.includes(t.key)).map((t) => t.term);
    if (found.length > 0) hits.push({ line: index, terms: found });
  });
  return hits;
}
