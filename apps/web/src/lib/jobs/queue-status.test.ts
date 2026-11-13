import { describe, expect, it } from "vitest";
import {
  type ProductionItem,
  activeCount,
  badgeLabel,
  badgeText,
  limitNotice,
  parseQueueStatus,
  postingRow,
  productionRow,
  queueBanner,
  waitPhrase,
} from "./queue-status";

const NOW = Date.parse("2026-11-13T10:00:00+09:00");

const job = (over: Partial<ProductionItem> = {}): ProductionItem => ({
  jobId: "j1",
  projectId: "p1",
  projectName: "압축팩",
  step: 5,
  queue: "render",
  state: "queued",
  startedAt: null,
  position: 3,
  etaSeconds: 360,
  ...over,
});

describe("parseQueueStatus", () => {
  it("모르는 값·잘못된 행은 버린다", () => {
    const status = parseQueueStatus({
      production: [
        { job_id: "a", project_id: "p", project_name: "x", step: 5, queue: "render", state: "queued", position: 2, eta_seconds: 300 },
        { job_id: "b", project_id: "p", step: 5, queue: "weird", state: "queued" },
        "bad",
      ],
      posting: [
        { publication_id: "u", project_id: "p", state: "pending", position: 1, est_start_at: "2026-11-13T01:03:00Z", retry_count: 0 },
        { publication_id: "v", project_id: "p", state: "uploaded" },
      ],
    });
    expect(status.production).toHaveLength(1);
    expect(status.production[0]).toMatchObject({ position: 2, etaSeconds: 300 });
    expect(status.posting).toHaveLength(1);
  });

  it("객체가 아니면 빈 상태", () => {
    expect(parseQueueStatus(null)).toEqual({ production: [], posting: [] });
    expect(parseQueueStatus([1])).toEqual({ production: [], posting: [] });
  });
});

describe("배지", () => {
  it("제작 전체 + 업로드 대기·재시도 대기·업로드 중만 센다", () => {
    const base = { publicationId: "x", projectId: "p", projectName: "", rawStatus: "pending", startedAt: null, scheduledAt: null, position: null, estStartAt: null, retryCount: 0, error: null };
    const status = {
      production: [job(), job({ jobId: "j2", state: "running" })],
      posting: [
        { ...base, state: "pending" as const },
        { ...base, state: "retry_wait" as const },
        { ...base, state: "uploading" as const },
        { ...base, state: "scheduled" as const },
        { ...base, state: "failed" as const },
        { ...base, state: "reconnect_wait" as const },
      ],
    };
    expect(activeCount(status)).toBe(5);
  });

  it("9 초과는 9+, 접근성 이름", () => {
    expect(badgeText(9)).toBe("9");
    expect(badgeText(10)).toBe("9+");
    expect(badgeLabel(3)).toBe("작업 현황, 진행·대기 중 3건");
  });
});

describe("문구", () => {
  it("예상 대기는 1분 미만 곧, 그 외 올림한 분", () => {
    expect(waitPhrase(30)).toBe("곧");
    expect(waitPhrase(360)).toBe("약 6분 뒤");
    expect(waitPhrase(361)).toBe("약 7분 뒤");
  });

  it("제작 행: 대기·미룸·진행 중", () => {
    expect(productionRow(job(), NOW)).toMatchObject({ chip: "대기 3번째", tone: "wait", when: "약 6분 뒤 시작", title: "압축팩 · 05 편집" });
    expect(productionRow(job({ state: "deferred", position: null, etaSeconds: null }), NOW)).toMatchObject({
      chip: "미룸",
      when: "앞 작업이 끝나면 시작",
    });
    expect(productionRow(job({ state: "running", startedAt: new Date(NOW - 125_000).toISOString() }), NOW)).toMatchObject({
      chip: "진행 중",
      when: "2분 경과",
    });
  });

  it("포스팅 행: 순번·재시도·예약·재연결", () => {
    const base = { publicationId: "u", projectId: "p", projectName: "압축팩", rawStatus: "pending", startedAt: null, scheduledAt: null, position: null, estStartAt: null, retryCount: 1, error: null };
    expect(postingRow({ ...base, state: "pending", position: 2, estStartAt: new Date(NOW + 240_000).toISOString() }, NOW)).toMatchObject({
      chip: "순번 2번째",
      when: "예상 시작 약 4분 뒤",
    });
    expect(postingRow({ ...base, state: "retry_wait", estStartAt: new Date(NOW + 180_000).toISOString() }, NOW)).toMatchObject({
      chip: "재시도 대기",
      when: "약 3분 뒤 다시 시도(자동 3회까지)",
    });
    expect(postingRow({ ...base, state: "scheduled", scheduledAt: new Date(NOW + 9 * 3_600_000).toISOString() }, NOW)).toMatchObject({
      chip: "예약됨",
      tone: "ok",
    });
    expect(postingRow({ ...base, state: "reconnect_wait", rawStatus: "reconnect_wait", error: "reconnect:reconnect_required" }, NOW)).toMatchObject({
      chip: "재연결 필요",
      tone: "bad",
    });
  });

  it("실패·재연결 필요 사유는 사용자 문구로, 원문 코드는 노출하지 않는다", () => {
    const base = { publicationId: "u", projectId: "p", projectName: "압축팩", startedAt: null, scheduledAt: null, position: null, estStartAt: null, retryCount: 3 };
    const failed = postingRow({ ...base, state: "failed", rawStatus: "failed", error: "transient:http_503" }, NOW);
    expect(failed.sub).toContain("일시 오류가 3번");
    expect(failed.sub).not.toContain("transient");
    const missing = postingRow({ ...base, state: "failed", rawStatus: "failed", error: "permanent:video_missing" }, NOW);
    expect(missing.sub).toContain("MP4를 다시 만들어");
    const check = postingRow({ ...base, state: "failed", rawStatus: "needs_check", error: "unknown:stale_attempt" }, NOW);
    expect(check.sub).toContain("YouTube Studio");
    expect(check.sub).not.toContain("unknown:");
    const reconnect = postingRow({ ...base, state: "reconnect_wait", rawStatus: "reconnect_wait", error: "reconnect:reconnect_required" }, NOW);
    expect(reconnect.sub).toContain("다시 연결");
    const odd = postingRow({ ...base, state: "reconnect_wait", rawStatus: "weird", error: "x:y" }, NOW);
    expect(odd.sub).toBe("업로드 상태를 확인해 주세요.");
  });
});

describe("상태 배너 대기 문구", () => {
  it("대기: 종류·순번·예상 시간과 순번 칩", () => {
    expect(queueBanner([job()], "p1", 5)).toMatchObject({ title: "렌더링 대기 3번째 · 약 6분 뒤 시작", chip: "3번째" });
  });

  it("미룸·실행 중·다른 프로젝트", () => {
    expect(queueBanner([job({ state: "deferred", position: null, etaSeconds: null })], "p1", 5)).toMatchObject({
      title: "앞 작업이 끝나면 시작",
      chip: "미룸",
    });
    expect(queueBanner([job({ state: "running" })], "p1", 5)).toBeNull();
    expect(queueBanner([job()], "p2", 5)).toBeNull();
    expect(queueBanner([job()], "p1", 4)).toBeNull();
  });
});

describe("대기 상한 안내", () => {
  it("상한에 이른 종류가 있으면 안내", () => {
    const three = [job({ jobId: "1" }), job({ jobId: "2" }), job({ jobId: "3" })];
    expect(limitNotice(three)).toContain("렌더링 작업이 이미 3개");
    expect(limitNotice(three.slice(0, 2))).toBeNull();
  });
});
