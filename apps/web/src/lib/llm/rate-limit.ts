/*
 * LLM 생성 호출 제한 — 같은 프로젝트 동시 생성 1개 + 사용자별 분당 상한.
 * 상태는 이 객체(서버 프로세스 메모리)에만 있어 서버가 여러 대면 인스턴스마다 따로 센다.
 * TODO(DB 이전): 짧은 TTL의 DB advisory lock·호출 기록 함수가 생기면 그쪽으로 옮긴다.
 */

export const USER_CALLS_PER_MINUTE = 6;
const WINDOW_MS = 60_000;

export type AcquireResult = { ok: true; release: () => void } | { ok: false; reason: "busy" | "rate_limited" };

export const RATE_LIMIT_MESSAGE: Record<"busy" | "rate_limited", string> = {
  busy: "이 프로젝트에서 이미 AI 생성이 진행 중입니다. 끝난 뒤 다시 시도해 주세요.",
  rate_limited: `AI 생성은 1분에 ${USER_CALLS_PER_MINUTE}번까지 할 수 있습니다. 잠시 뒤 다시 시도해 주세요.`,
};

export function createLlmLimiter(limit = USER_CALLS_PER_MINUTE) {
  const inFlight = new Set<string>();
  const calls = new Map<string, number[]>();

  return {
    /** 동기 함수라 확인과 선점 사이에 다른 요청이 끼어들 수 없다(같은 프로세스 안에서 원자적) */
    acquire(projectId: string, userId: string, now = Date.now()): AcquireResult {
      if (inFlight.has(projectId)) return { ok: false, reason: "busy" };
      const recent = (calls.get(userId) ?? []).filter((t) => now - t < WINDOW_MS);
      if (recent.length >= limit) {
        calls.set(userId, recent);
        return { ok: false, reason: "rate_limited" };
      }
      recent.push(now);
      calls.set(userId, recent);
      inFlight.add(projectId);
      let released = false;
      return {
        ok: true,
        release: () => {
          if (released) return;
          released = true;
          inFlight.delete(projectId);
        },
      };
    },
  };
}
