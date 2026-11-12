/**
 * task-024b 보관 기간 지난 파일 삭제(출처 행은 남긴다). 근거: docs/planning.md 17-2 D5, docs/05_DATA_MODEL.md 1절 보관.
 *
 * 순서(한 묶음): 목록(public.retention_due, 키셋 페이지) → 삭제 예약(public.retention_reserve: 행 잠금·기준일·발행 재판정,
 * 통과한 행만 토큰) → 객체마다 삭제 직전 확인(public.retention_confirm: 토큰·예약 30분·기준일 재판정, 5분 "삭제 중")
 * → Storage 삭제(요청 60초 제한, 재시도마다 다시 확인) → 성공한 것만 public.retention_mark_deleted(같은 토큰 행만 표시).
 * 실패·건너뜀은 표시하지 않고 다음 회차에서 다시 시도한다.
 * - service_role 키로만 돈다(워커는 Storage 삭제 권한이 없다). 키·경로는 로그에 남기지 않는다.
 * - 이 파일은 Node가 직접 실행한다(타입 제거 실행): 상대 경로·@ 별칭 값 import 금지, 타입은 `import type`만.
 *
 * 실행: `pnpm --filter web retention -- --once`(한 번) · 인자 없으면 RETENTION_INTERVAL_HOURS(기본 24)마다 반복.
 */
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { pathToFileURL } from "node:url";
import type { Database } from "@/types/db";

export type RetentionKind = "source" | "thumbnail" | "voice" | "render";

export type DueItem = Database["public"]["Functions"]["retention_due"]["Returns"][number];
type ReservedItem = Database["public"]["Functions"]["retention_reserve"]["Returns"][number];

type Client = SupabaseClient<Database>;

export type RetentionOptions = {
  /** 한 번에 가져올 대상 수(DB 상한 1000) */
  pageSize?: number;
  /** Storage 삭제 시도 횟수(일시 오류 대비) */
  maxAttempts?: number;
  /** 한 회차에서 가져올 최대 페이지 수 */
  maxPages?: number;
  sleep?: (ms: number) => Promise<void>;
  log?: (message: string) => void;
};

export type RetentionResult = {
  deleted: number;
  failed: number;
  skipped: number;
  markFailed: number;
};

const BUCKET_OF: Record<RetentionKind, string> = {
  source: "sources",
  thumbnail: "thumbnails",
  voice: "voices",
  render: "renders",
};

/** 예약 한 번에 보낼 행 수 */
const CHUNK = 100;
/** Storage·DB 요청 제한(DB 삭제 중 창 5분보다 충분히 짧게) */
const FETCH_TIMEOUT_MS = 60_000;

/** 경로 조각: 영문·숫자·. _ - 만(인코딩 %, 역슬래시, 공백 등 거부). ".", ".." 은 따로 거부 */
const SEGMENT = /^[A-Za-z0-9._-]+$/;

const defaultSleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

function isKind(kind: string): kind is RetentionKind {
  return Object.hasOwn(BUCKET_OF, kind);
}

/** 경로가 이 프로젝트 폴더(<user_id>/<project_id>/) 안의 평범한 파일 이름인지. 남의 객체를 지우지 않게 서버에서 다시 확인한다. */
export function isSafePath(path: string, userId: string, projectId: string): boolean {
  const prefix = `${userId}/${projectId}/`;
  if (!path.startsWith(prefix)) return false;
  const segments = path.slice(prefix.length).split("/");
  return segments.every((seg) => SEGMENT.test(seg) && seg !== "." && seg !== "..");
}

/** 버킷이 종류와 맞고 경로가 안전한지 */
export function isSafeItem(item: DueItem): item is DueItem & { kind: RetentionKind } {
  return isKind(item.kind) && item.bucket === BUCKET_OF[item.kind] && isSafePath(item.path, item.user_id, item.project_id);
}

/** 한 종류의 묶음: 예약 → 삭제 → 표시 */
async function processChunk(
  client: Client,
  kind: RetentionKind,
  items: DueItem[],
  result: RetentionResult,
  maxAttempts: number,
  sleep: (ms: number) => Promise<void>,
  log: (message: string) => void,
) {
  const { data: reservedData, error: reserveError } = await client.rpc("retention_reserve", {
    p_kind: kind,
    p_ids: items.map((item) => item.id),
  });
  if (reserveError) {
    result.failed += items.length;
    log(`삭제 예약 실패: ${kind} ${items.length}건 (${reserveError.message})`);
    return;
  }
  const reserved: ReservedItem[] = reservedData ?? [];
  // 예약 단계에서 빠진 것(그사이 발행·활동으로 연장)은 건너뜀으로 센다
  result.skipped += items.length - reserved.length;
  const safe = reserved.filter((r) => isSafePath(r.path, r.user_id, r.project_id));
  result.skipped += reserved.length - safe.length;
  if (safe.length === 0) return;
  for (const r of safe) {
    await processObject(client, kind, r, result, maxAttempts, sleep, log);
  }
}

/** 삭제 직전 확인(행 잠금·토큰·예약 30분·기준일 재판정, 통과하면 5분 "삭제 중") → 성공 시 true */
async function confirm(client: Client, kind: RetentionKind, r: ReservedItem): Promise<boolean> {
  const { data, error } = await client.rpc("retention_confirm", { p_kind: kind, p_ids: [r.id], p_token: r.token });
  if (error) throw new Error(error.message);
  return (data ?? []).includes(r.id);
}

/** 객체 하나: 시도마다 삭제 직전 확인 → Storage 삭제(60초 제한) → 같은 토큰으로 표시 */
async function processObject(
  client: Client,
  kind: RetentionKind,
  r: ReservedItem,
  result: RetentionResult,
  maxAttempts: number,
  sleep: (ms: number) => Promise<void>,
  log: (message: string) => void,
) {
  let removed = false;
  for (let attempt = 1; attempt <= maxAttempts && !removed; attempt += 1) {
    let confirmed: boolean;
    try {
      confirmed = await confirm(client, kind, r);
    } catch (error) {
      result.failed += 1;
      log(`삭제 직전 확인 실패: ${kind} ${r.id} (${error instanceof Error ? error.message : String(error)})`);
      return;
    }
    if (!confirmed) {
      // 예약 만료(정지 뒤 재개)·발행 연장·활동 연장 → 지우지 않는다
      result.skipped += 1;
      return;
    }
    try {
      const { error } = await client.storage.from(BUCKET_OF[kind]).remove([r.path]);
      removed = !error;
    } catch {
      // 네트워크 오류·60초 제한 초과도 일시 오류로 보고 다시 확인 후 시도한다
    }
    if (!removed && attempt < maxAttempts) await sleep(1000 * 2 ** (attempt - 1));
  }
  if (!removed) {
    result.failed += 1;
    log(`Storage 삭제 실패(${maxAttempts}회): ${kind} ${r.id}, 다음 회차에 재시도`);
    return;
  }
  const { data: marked, error: markError } = await client.rpc("retention_mark_deleted", {
    p_kind: kind,
    p_ids: [r.id],
    p_token: r.token,
  });
  if (markError || marked !== 1) {
    // 객체는 지워졌다. 다음 회차가 다시 예약·확인·삭제(없는 객체는 성공)·표시한다.
    result.markFailed += 1;
    log(`삭제 표시 실패: ${kind} ${r.id}${markError ? ` (${markError.message})` : ""}`);
    return;
  }
  result.deleted += 1;
}

/** 한 회차: 키셋 커서로 전체 대상을 돌며 기준일 지난 객체를 지우고 성공분만 DB에 표시한다. */
export async function runRetentionOnce(client: Client, options: RetentionOptions = {}): Promise<RetentionResult> {
  const pageSize = options.pageSize ?? 500;
  const maxAttempts = options.maxAttempts ?? 3;
  const maxPages = options.maxPages ?? 1000;
  const sleep = options.sleep ?? defaultSleep;
  const log = options.log ?? ((message: string) => console.log(`[retention] ${message}`));
  const result: RetentionResult = { deleted: 0, failed: 0, skipped: 0, markFailed: 0 };
  let cursor: { p_after_due: string; p_after_kind: string; p_after_id: string } | null = null;

  for (let page = 0; page < maxPages; page += 1) {
    const { data, error } = await client.rpc("retention_due", { p_limit: pageSize, ...(cursor ?? {}) });
    if (error) throw new Error(`대상 목록 조회 실패: ${error.message}`);
    const rows: DueItem[] = data ?? [];
    if (rows.length === 0) break;
    const last: DueItem = rows[rows.length - 1];
    cursor = { p_after_due: last.due_on, p_after_kind: last.kind, p_after_id: last.id };

    const groups = new Map<RetentionKind, DueItem[]>();
    for (const item of rows) {
      if (!isSafeItem(item)) {
        result.skipped += 1;
        log(`경로·버킷이 맞지 않아 건너뜀: ${item.kind} ${item.id}`);
        continue;
      }
      const list = groups.get(item.kind) ?? [];
      list.push(item);
      groups.set(item.kind, list);
    }
    for (const [kind, items] of groups) {
      for (let i = 0; i < items.length; i += CHUNK) {
        await processChunk(client, kind, items.slice(i, i + CHUNK), result, maxAttempts, sleep, log);
      }
    }
    if (rows.length < pageSize) break;
  }
  log(`완료: 삭제 ${result.deleted} · 실패 ${result.failed} · 건너뜀 ${result.skipped} · 표시 실패 ${result.markFailed}`);
  return result;
}

function createRetentionClient(): Client {
  const url =
    process.env.SUPABASE_INTERNAL_URL || process.env.NEXT_PUBLIC_SUPABASE_URL || process.env.SUPABASE_PUBLIC_URL;
  const serviceRoleKey = process.env.SERVICE_ROLE_KEY;
  if (!url || !serviceRoleKey) {
    throw new Error("SUPABASE_INTERNAL_URL(또는 SUPABASE_PUBLIC_URL)·SERVICE_ROLE_KEY가 서버 환경 변수에 없습니다.");
  }
  return createClient<Database>(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    // 삭제 중 창(5분) 안에서 끝나도록 요청마다 60초 제한
    global: {
      fetch: (input, init) => {
        const timeout = AbortSignal.timeout(FETCH_TIMEOUT_MS);
        return fetch(input, { ...init, signal: init?.signal ? AbortSignal.any([init.signal, timeout]) : timeout });
      },
    },
  });
}

async function main(argv: string[]) {
  const client = createRetentionClient();
  if (argv.includes("--once")) {
    const result = await runRetentionOnce(client);
    process.exitCode = result.failed + result.markFailed > 0 ? 1 : 0;
    return;
  }
  const hours = Number(process.env.RETENTION_INTERVAL_HOURS ?? "24");
  const intervalMs = (Number.isFinite(hours) && hours > 0 ? hours : 24) * 3_600_000;
  for (;;) {
    try {
      await runRetentionOnce(client);
    } catch (error) {
      console.error(`[retention] 회차 실패: ${error instanceof Error ? error.message : String(error)}`);
    }
    await defaultSleep(intervalMs);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch((error: unknown) => {
    console.error(`[retention] 시작 실패: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  });
}
