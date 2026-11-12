/*
 * 06 발행 업로드 상태 → 화면 문구(task-024a). 상태 정본은 DB publications.status(20261112280000).
 * 결과 불명(needs_check)은 자동 재업로드를 하지 않으므로 YouTube Studio 확인을 먼저 안내한다.
 * 업로드 뒤 예약 취소·변경은 앱에서 할 수 없다(youtube.force-ssl 미요청, docs/04_API.md 2절) → Studio 안내.
 */

export type UploadStatusInput = {
  status: string;
  error: string | null;
  nextAttemptAt: string | null;
  retryCount: number;
  scheduledAt: string | null;
  videoId: string | null;
};

export type UploadStatusView = {
  /** info = 배너 없이 상태 줄(진행 중·자동 재시도 대기) */
  tone: "info" | "warning" | "error" | "success";
  message: string;
  retry: boolean;
  studioUrl: string | null;
  reconnect: boolean;
  /** needs_check: Studio 에 영상이 없음을 확인 → 새로 업로드(위험 확인 대화상자) */
  confirmAbsent: boolean;
};

const LIMIT_COPY: Record<string, string> = {
  "confirm:description_too_long": "설명란이 YouTube 한도(5000바이트)를 넘습니다. 본문을 줄여 다시 발행 준비해 주세요.",
  "confirm:title_too_long": "제목이 YouTube 한도(100자)를 넘습니다. 제목을 줄여 다시 발행 준비해 주세요.",
  "confirm:tags_too_long": "해시태그가 YouTube 태그 한도(500자)를 넘습니다. 해시태그를 줄여 다시 발행 준비해 주세요.",
};

/** YouTube 설명란 한도(UTF-8 바이트). 서버 검사는 DB prepare_publication·업로더가 다시 한다 */
export const DESCRIPTION_MAX_BYTES = 5000;

export function utf8Bytes(text: string) {
  return new TextEncoder().encode(text).byteLength;
}

export const STUDIO_URL = "https://studio.youtube.com/";

export function studioUrl(videoId: string | null) {
  return videoId ? `https://studio.youtube.com/video/${encodeURIComponent(videoId)}/edit` : STUDIO_URL;
}

function failedReason(error: string | null) {
  if (error?.startsWith("transient:")) return "일시 오류가 3번 이어졌습니다";
  if (error === "permanent:video_missing") return "영상 파일을 찾지 못했습니다. 05 편집에서 MP4를 다시 만들어 주세요";
  if (error === "permanent:channel_mismatch") return "프로젝트 채널이 연결된 YouTube 채널이 아닙니다";
  return "YouTube가 요청을 받지 않았습니다";
}

/** null = 업로드 상태 안내 없음(준비 전·준비 완료·일반 무효화는 기존 배너) */
export function uploadStatusView(p: UploadStatusInput, formatTime: (iso: string) => string): UploadStatusView | null {
  const base = { retry: false, studioUrl: null, reconnect: false, confirmAbsent: false };
  switch (p.status) {
    case "invalidated":
      if (p.error === "confirm:schedule_passed") {
        return {
          ...base,
          tone: "warning",
          message:
            "예약 시각이 지나 업로드하지 않았습니다(바로 공개하지 않습니다). 새 예약 시각을 고르거나 지금 올리기로 발행 준비를 다시 저장해 주세요.",
        };
      }
      if (p.error && LIMIT_COPY[p.error]) return { ...base, tone: "warning", message: LIMIT_COPY[p.error] };
      if (p.error === "confirm:policy_failed") {
        return {
          ...base,
          tone: "warning",
          message: "업로드 직전 점검에서 정책 6개 항목을 통과하지 못해 올리지 않았습니다. 점검 목록을 확인한 뒤 발행 준비를 다시 저장해 주세요.",
        };
      }
      return null;
    case "uploading":
      return { ...base, tone: "info", message: "YouTube에 올리는 중입니다…" };
    case "retry_wait": {
      const at = p.nextAttemptAt ? formatTime(p.nextAttemptAt) : null;
      if (p.error?.startsWith("quota:")) {
        return {
          ...base,
          tone: "info",
          message: `오늘 YouTube 업로드 한도에 닿아 ${at ? `${at} 이후` : "한도가 풀리면"} 자동으로 다시 올립니다. 재시도 횟수는 쓰지 않습니다.`,
        };
      }
      if (p.error) {
        return {
          ...base,
          tone: "info",
          message: `일시 오류로 올리지 못했습니다. ${at ? `${at}에 ` : ""}자동으로 다시 시도합니다(${p.retryCount}/3).`,
        };
      }
      return { ...base, tone: "info", message: "곧 업로드를 다시 시작합니다." };
    }
    case "reconnect_wait":
      return {
        ...base,
        tone: "warning",
        message: "YouTube 연결이 끊겨 업로드를 멈췄습니다. 채널을 다시 연결한 뒤 다시 시도를 눌러 주세요(재시도 횟수는 쓰지 않았습니다).",
        retry: true,
        reconnect: true,
      };
    case "needs_check":
      if (p.error?.startsWith("confirm:")) {
        return {
          ...base,
          tone: "error",
          message:
            p.error === "confirm:schedule_passed"
              ? "업로드를 이어 가는 사이 예약 시각이 지났습니다. 바로 공개되지 않도록 멈췄으니 YouTube Studio에서 영상 상태를 확인해 주세요."
              : "업로드 직전 점검을 통과하지 못해 멈췄습니다. YouTube Studio에서 영상 상태를 확인해 주세요.",
          studioUrl: STUDIO_URL,
          confirmAbsent: true,
        };
      }
      return {
        ...base,
        tone: "error",
        message:
          "업로드 결과를 확인하지 못했습니다. 중복 업로드를 막으려고 자동으로 다시 올리지 않습니다. YouTube Studio에서 이 영상이 올라갔는지 먼저 확인하고, 없을 때만 \"영상 없음 확인\"을 눌러 새로 올려 주세요.",
        studioUrl: STUDIO_URL,
        confirmAbsent: true,
      };
    case "failed":
      return {
        ...base,
        tone: "error",
        message: `업로드에 실패했습니다. ${failedReason(p.error)}.`,
        retry: p.error !== "permanent:video_missing" && p.error !== "permanent:channel_mismatch",
      };
    case "scheduled":
      return {
        ...base,
        tone: "success",
        message: `${p.scheduledAt ? `${formatTime(p.scheduledAt)}에 ` : ""}공개되도록 YouTube에 예약했습니다. 예약 취소·시각 변경은 앱에서 할 수 없습니다. YouTube Studio에서 해 주세요.`,
        studioUrl: studioUrl(p.videoId),
      };
    case "uploaded":
      return { ...base, tone: "success", message: "YouTube에 올렸습니다.", studioUrl: studioUrl(p.videoId) };
    default:
      return null;
  }
}
