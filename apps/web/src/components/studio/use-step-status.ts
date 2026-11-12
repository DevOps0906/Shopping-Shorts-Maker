"use client";

import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { type StepStatusMap, parseStepStatus } from "@/lib/steps/state";

export type LiveState = "connecting" | "live" | "offline";

/**
 * projects.step_status 실시간 구독(planning.md 6장: 상태는 서버에 두고 실시간 구독으로 배너를 바꾼다).
 * 다른 탭·기기에서 승인·변경하거나 워커가 상태를 바꾸면 이 탭의 상태도 바뀐다.
 * 읽기 권한은 RLS(본인 프로젝트)가 거른다.
 */
export function useStepStatus(projectId: string, initial: StepStatusMap) {
  const [status, setStatus] = useState(initial);
  const [live, setLive] = useState<LiveState>("connecting");
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    const supabase = createClient();
    let active = true;
    // Realtime 이벤트를 받을 때마다 올린다. 재조회 응답이 그보다 먼저 시작된 요청이면 버린다.
    let eventSeq = 0;

    // 서버 렌더와 구독 시작 사이에 바뀐 값을 놓치지 않도록 구독이 붙으면 한 번 다시 읽는다.
    // 다시 읽기가 성공해야 실시간 연결로 본다.
    async function refetch() {
      const seqAtStart = eventSeq;
      const { data, error } = await supabase.from("projects").select("step_status").eq("id", projectId).maybeSingle();
      if (!active) return;
      const next = parseStepStatus(data?.step_status);
      if (error || !next) {
        setLive("offline");
        return;
      }
      if (seqAtStart === eventSeq) setStatus(next);
      setLive("live");
    }

    const channel = supabase
      .channel(`project-steps:${projectId}`)
      .on(
        "postgres_changes",
        { event: "UPDATE", schema: "public", table: "projects", filter: `id=eq.${projectId}` },
        (payload) => {
          const next = parseStepStatus((payload.new as { step_status?: unknown }).step_status);
          if (!active || !next) return;
          eventSeq += 1;
          setStatus(next);
        },
      )
      .subscribe((state) => {
        if (!active) return;
        if (state === "SUBSCRIBED") {
          void refetch();
        } else if (state === "CHANNEL_ERROR" || state === "TIMED_OUT" || state === "CLOSED") {
          setLive("offline");
        }
      });

    return () => {
      active = false;
      void supabase.removeChannel(channel);
    };
  }, [projectId, attempt]);

  /** 경고 배너의 다시 연결 버튼: 구독을 새로 붙이고 다시 읽는다 */
  const retry = useCallback(() => {
    setLive("connecting");
    setAttempt((n) => n + 1);
  }, []);

  return { status, setStatus, live, retry };
}
