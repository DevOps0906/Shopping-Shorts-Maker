import "server-only";
import { getAccessToken } from "@/server/oauth/access-token";
import { type RunResult, runOnce } from "./uploader";
import { createUploaderStore, createVideoLoader } from "./uploader-store";

/*
 * Compose 서비스 uploader 진입점(scripts/uploader.mjs 가 부른다). 대기 발행을 하나씩 선점해 올리고,
 * 할 일이 없으면 POLL_MS 쉰다. SIGTERM·SIGINT 면 지금 시도를 끝낸 뒤 멈춘다. `--once` 는 1건만.
 * 환경 변수(값은 루트 .env, 이름만): SERVICE_ROLE_KEY · SUPABASE_INTERNAL_URL · GOOGLE_OAUTH_CLIENT_ID ·
 *   GOOGLE_OAUTH_CLIENT_SECRET · OAUTH_REDIRECT_BASE_URL · UPLOAD_TEST_PRIVATE(1 = 비공개·예약 없음 테스트)
 */

const POLL_MS = 15_000;

export async function main(argv: string[]) {
  const once = argv.includes("--once");
  const testPrivate = process.env.UPLOAD_TEST_PRIVATE === "1";
  const deps = {
    store: createUploaderStore(),
    fetch: (input: string, init?: RequestInit) => fetch(input, init),
    getAccessToken,
    loadVideo: createVideoLoader(),
    testPrivate,
    log: (line: string) => console.log(line),
  };

  let stopped = false;
  let wake: (() => void) | null = null;
  const stop = () => {
    stopped = true;
    wake?.();
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);

  console.log(`[uploader] 시작${testPrivate ? " (테스트: 비공개·예약 없음)" : ""}`);
  while (!stopped) {
    const result: RunResult = await runOnce(deps);
    if (once) break;
    if (result.kind === "idle" || result.kind === "error") {
      await new Promise<void>((resolve) => {
        const t = setTimeout(resolve, POLL_MS);
        wake = () => {
          clearTimeout(t);
          resolve();
        };
      });
      wake = null;
    }
  }
  console.log("[uploader] 종료");
}
