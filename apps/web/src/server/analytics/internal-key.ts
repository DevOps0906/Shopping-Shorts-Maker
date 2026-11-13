import "server-only";
import { createHash, timingSafeEqual } from "node:crypto";

export const INTERNAL_KEY_MIN = 32;

/**
 * 내부 호출 키(INTERNAL_METRICS_KEY) 비교. 길이 차이도 드러내지 않도록 SHA-256 으로 맞춘 뒤 timingSafeEqual.
 * 서버 키가 없거나 32자 미만이면 설정 오류로 보고 항상 거부한다(키 값은 로그에 넣지 않는다).
 */
export function isInternalKey(given: string | null) {
  const expected = process.env.INTERNAL_METRICS_KEY?.trim();
  if (!expected || expected.length < INTERNAL_KEY_MIN) {
    console.error(`metrics_collect: INTERNAL_METRICS_KEY 가 없거나 ${INTERNAL_KEY_MIN}자 미만입니다`);
    return false;
  }
  if (!given) return false;
  const a = createHash("sha256").update(given).digest();
  const b = createHash("sha256").update(expected).digest();
  return timingSafeEqual(a, b);
}
