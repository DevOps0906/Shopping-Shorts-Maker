import { cleanText } from "./prompt";

/*
 * 01 소재 미리 채우기 — S-02 새로운 프로젝트(task-014)가 넘기는 ?product=(제품명) · ?url=(상품 링크).
 * 입력칸만 채우고 AI 생성은 호출하지 않는다. 링크는 http(s)만 받는다.
 */

export const MAX_PRODUCT_NAME = 40;
/** topics.product_url CHECK와 같은 상한 */
export const MAX_PRODUCT_URL = 2048;

export function readTopicPrefill(params: { product: string | null; url: string | null }) {
  const product = params.product ? cleanText(params.product, MAX_PRODUCT_NAME) : "";
  return { product, url: (params.url && toProductUrl(params.url)) || "" };
}

/** 상품 링크 검사(화면·서버 공통): http(s) 절대 URL만, 2048자 이하. 비었거나 형식이 틀리면 null */
export function toProductUrl(raw: string): string | null {
  const value = raw.trim();
  if (value.length === 0 || value.length > MAX_PRODUCT_URL) return null;
  try {
    const parsed = new URL(value);
    if (parsed.protocol !== "https:" && parsed.protocol !== "http:") return null;
    const url = parsed.toString();
    return url.length <= MAX_PRODUCT_URL ? url : null;
  } catch {
    return null;
  }
}
