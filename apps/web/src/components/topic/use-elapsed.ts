"use client";

import { useEffect, useState } from "react";

/** 진행 중 경과 초(docs/03_SCREENS_UX.md 로딩 상태 "진행 중 · 경과 초") */
export function useElapsed(running: boolean) {
  const [elapsed, setElapsed] = useState(0);
  useEffect(() => {
    if (!running) return;
    const started = Date.now();
    const id = setInterval(() => setElapsed(Math.floor((Date.now() - started) / 1000)), 1000);
    return () => {
      clearInterval(id);
      setElapsed(0);
    };
  }, [running]);
  return elapsed;
}
