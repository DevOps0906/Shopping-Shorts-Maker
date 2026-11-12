"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { ChatContextView, ChatLoadResponse, ChatMessageView, ChatSendResponse, PendingConfirm } from "@/lib/agent-tools/messages";

/*
 * 제작 파트너 대화 상태 — /api/chat(GET 불러오기 · POST 1턴) · /api/chat/confirm(사용자가 확인한 도구 실행).
 * 확인이 필요한 도구는 서버가 실행하지 않고 confirm을 돌려준다 → 호출한 쪽이 공용 confirm()으로 묻고 runConfirm을 부른다.
 */

export type ChatTarget = { projectId: string; step: string } | null;
type Sent = { ok: true; confirm: PendingConfirm | null; changed: string | null; ai: ChatMessageView | null } | { ok: false };

const NETWORK_ERROR = "서버에 연결하지 못했습니다. 잠시 뒤 다시 시도해 주세요.";

async function postJson(url: string, body: unknown): Promise<ChatSendResponse> {
  try {
    const res = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    return (await res.json()) as ChatSendResponse;
  } catch {
    return { ok: false, error: NETWORK_ERROR };
  }
}

export function useChat(target: ChatTarget, active: boolean) {
  const [context, setContext] = useState<ChatContextView | null>(null);
  const [messages, setMessages] = useState<ChatMessageView[]>([]);
  const [loading, setLoading] = useState(false);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const projectId = target?.projectId ?? null;
  const step = target?.step ?? null;
  const loadedFor = useRef<string | null>(null);
  // 응답이 왔을 때 사용자가 다른 프로젝트로 옮겼으면 그 응답·제안은 버린다
  const currentProject = useRef(projectId);
  useEffect(() => {
    currentProject.current = projectId;
  }, [projectId]);

  // 열려 있을 때 프로젝트·단계가 바뀌면(또는 처음 열면) 다시 불러온다
  useEffect(() => {
    if (!active || !projectId) return;
    const key = `${projectId}:${step}`;
    if (loadedFor.current === key) return;
    loadedFor.current = key;
    let cancelled = false;
    setLoading(true);
    setError(null);
    fetch(`/api/chat?projectId=${encodeURIComponent(projectId)}&step=${encodeURIComponent(step ?? "")}`, { cache: "no-store" })
      .then((res) => res.json() as Promise<ChatLoadResponse>)
      .catch((): ChatLoadResponse => ({ ok: false, error: NETWORK_ERROR }))
      .then((data) => {
        if (cancelled) return;
        if (data.ok) {
          setContext(data.context);
          setMessages(data.messages);
        } else {
          setError(data.error);
          loadedFor.current = null;
        }
        setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [active, projectId, step]);

  const apply = useCallback((res: ChatSendResponse, requestedFor: string): Sent => {
    if (currentProject.current !== requestedFor) return { ok: false };
    if (!res.ok) {
      setError(res.error);
      return { ok: false };
    }
    const mine = res.messages.filter((m) => m.projectId === requestedFor);
    setMessages((prev) => [...prev, ...mine.filter((m) => !prev.some((p) => p.id === m.id))]);
    const ai = mine.findLast((m) => m.role === "ai") ?? null;
    const confirm = res.confirm && res.confirm.projectId === requestedFor ? res.confirm : null;
    return { ok: true, confirm, changed: res.changed, ai };
  }, []);

  const send = useCallback(
    async (text: string): Promise<Sent> => {
      if (!projectId) return { ok: false };
      setSending(true);
      setError(null);
      const res = await postJson("/api/chat", { projectId, step, message: text });
      setSending(false);
      return apply(res, projectId);
    },
    [projectId, step, apply],
  );

  const runConfirm = useCallback(
    async (pending: PendingConfirm): Promise<Sent> => {
      if (!projectId || pending.projectId !== projectId) return { ok: false };
      setSending(true);
      setError(null);
      // tool·args·멱등 키는 보내지 않는다 — 서버가 저장한 제안을 소비하고 키를 proposal id로 파생한다
      const res = await postJson("/api/chat/confirm", { proposalId: pending.proposalId });
      setSending(false);
      return apply(res, pending.projectId);
    },
    [projectId, apply],
  );

  return { context: projectId ? context : null, messages: projectId ? messages : [], loading, sending, error, setError, send, runConfirm };
}
