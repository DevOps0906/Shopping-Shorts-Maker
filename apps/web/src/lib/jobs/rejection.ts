import { TOO_MANY_JOBS_MESSAGE } from "./queue-status";

/*
 * 작업 시작이 대기 상한(JQ001)으로 거절됐음을 작업 현황 패널에 알린다(docs/design.md 작업 현황 패널 · JQ001 거절 안내).
 * 서버 액션이 돌려준 오류 문구가 거절 문구일 때만 이벤트를 보낸다. GNB 가 받아 패널 상단에 경고를 띄운다.
 */
export const JOB_REJECTED_EVENT = "jobs:rejected";

export function announceJobRejected(error: string) {
  if (error === TOO_MANY_JOBS_MESSAGE && typeof window !== "undefined") {
    window.dispatchEvent(new Event(JOB_REJECTED_EVENT));
  }
}
