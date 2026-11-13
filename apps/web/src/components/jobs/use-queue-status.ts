"use client";

import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { startQueuePolling } from "@/lib/jobs/polling";
import { EMPTY_QUEUE_STATUS, type QueueStatus, parseQueueStatus } from "@/lib/jobs/queue-status";

/** 작업 현황 갱신 간격. jobs·publications 는 Realtime 발행 대상이 아니라 열려 있는 동안 폴링한다(planning 17-5-1) */
export const QUEUE_POLL_MS = 15_000;

type Options = {
  /** true 인 동안만 불러온다 */
  active: boolean;
  /** true 인 동안 `QUEUE_POLL_MS` 간격으로 다시 읽는다(패널 열림·진행 중 배너) */
  poll: boolean;
  /** 값이 바뀌면 한 번 다시 읽는다(경로 이동 등) */
  refreshKey?: string;
};

/** 본인 작업의 순번·예상 시간. RLS가 아니라 DB 함수가 본인 행만 돌려준다. */
export function useQueueStatus({ active, poll, refreshKey }: Options) {
  const [status, setStatus] = useState<QueueStatus>(EMPTY_QUEUE_STATUS);
  const [failed, setFailed] = useState(false);
  const [loaded, setLoaded] = useState(false);

  const load = useCallback(async () => {
    const { data, error } = await createClient().rpc("job_queue_status");
    if (error) {
      setFailed(true);
      return;
    }
    setFailed(false);
    setLoaded(true);
    setStatus(parseQueueStatus(data));
  }, []);

  useEffect(() => {
    if (!active) return;
    const first = setTimeout(() => void load(), 0);
    return () => clearTimeout(first);
  }, [active, load, refreshKey]);

  useEffect(() => {
    if (!active || !poll) return;
    // 열림 전환 즉시 1회 조회, 탭이 숨겨지면 중단·복귀 시 1회 조회
    return startQueuePolling(() => void load(), QUEUE_POLL_MS, document);
  }, [active, poll, load]);

  return { status, failed, loaded, reload: load };
}
