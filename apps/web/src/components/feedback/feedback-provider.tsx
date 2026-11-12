"use client";

import {
  type ReactNode,
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { type ConfirmRequest, createConfirmController } from "@/lib/feedback/confirm";
import { FOCUSABLE } from "@/lib/feedback/focus";
import { type QueueState, dismiss, emptyQueue, push, setMax } from "@/lib/feedback/queue";
import {
  type ConfirmOptions,
  type FeedbackItem,
  MAX_VISIBLE,
  type SnackbarOptions,
  type ToastOptions,
} from "@/lib/feedback/types";
import { AlertDialog } from "./alert-dialog";
import { FeedbackRegion } from "./feedback-region";

export type FeedbackApi = {
  /** 정보 토스트(액션 없음, 4초). 반환값은 id */
  toast: (options: ToastOptions) => string;
  /** 스낵바(버튼 1개, 6초 / 실행 취소 8초 / 오류는 수동 닫기). 반환값은 id */
  snackbar: (options: SnackbarOptions) => string;
  /** id 또는 key로 닫는다 */
  dismiss: (idOrKey: string) => void;
  /** 알림 대화상자. 확인 = true, 취소·Esc = false */
  confirm: (options: ConfirmOptions) => Promise<boolean>;
  /** 제작 파트너 팝업 열림 상태를 알려 알림 영역 위치를 옮긴다(3-1) */
  setPartnerOpen: (open: boolean) => void;
};

const FeedbackContext = createContext<FeedbackApi | null>(null);

export function useFeedback(): FeedbackApi {
  const api = useContext(FeedbackContext);
  if (!api) throw new Error("useFeedback은 FeedbackProvider 안에서만 쓸 수 있습니다.");
  return api;
}

type Action = { type: "push"; item: FeedbackItem } | { type: "dismiss"; idOrKey: string } | { type: "max"; max: number };

function reducer(state: QueueState, action: Action): QueueState {
  if (action.type === "push") return push(state, action.item);
  if (action.type === "dismiss") return dismiss(state, action.idOrKey);
  return setMax(state, action.max);
}

// 768 = tokens.css @theme --breakpoint-tablet (JS matchMedia는 CSS 변수를 못 쓰므로 같은 값을 둔다)
const MOBILE_QUERY = "(width < 768px)";
const subscribeMobile = (onChange: () => void) => {
  const mq = window.matchMedia(MOBILE_QUERY);
  mq.addEventListener("change", onChange);
  return () => mq.removeEventListener("change", onChange);
};
const isMobile = () => window.matchMedia(MOBILE_QUERY).matches;

export function FeedbackProvider({ children, partnerOpen: initialPartnerOpen = false }: { children: ReactNode; partnerOpen?: boolean }) {
  const [state, dispatch] = useReducer(reducer, MAX_VISIBLE.wide, emptyQueue);
  const [partnerOpen, setPartnerOpen] = useState(initialPartnerOpen);
  const [pending, setPending] = useState<ConfirmRequest | null>(null);
  const [controller] = useState(() => createConfirmController(setPending));
  const seq = useRef(0);
  const regionRef = useRef<HTMLDivElement>(null);
  const mobile = useSyncExternalStore(subscribeMobile, isMobile, () => false);

  useEffect(() => {
    dispatch({ type: "max", max: mobile ? MAX_VISIBLE.mobile : MAX_VISIBLE.wide });
  }, [mobile]);

  // Alt+N: 최신 알림의 버튼으로 포커스(3-4, 제안)
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (!event.altKey || event.code !== "KeyN") return;
      const items = regionRef.current?.querySelectorAll<HTMLElement>("[data-feedback-item]");
      const target = items?.[items.length - 1]?.querySelector<HTMLElement>(FOCUSABLE);
      if (!target) return;
      event.preventDefault();
      target.focus();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const onDismiss = useCallback((idOrKey: string) => dispatch({ type: "dismiss", idOrKey }), []);

  const api = useMemo<FeedbackApi>(() => {
    const nextId = () => `fb-${++seq.current}`;
    return {
      toast: ({ message, tone = "info", key }) => {
        const id = nextId();
        dispatch({ type: "push", item: { id, kind: "toast", tone, message, key, rev: 0 } });
        return id;
      },
      snackbar: ({ message, tone = "info", action, key }) => {
        const id = nextId();
        dispatch({ type: "push", item: { id, kind: "snackbar", tone, message, action, key, rev: 0 } });
        return id;
      },
      dismiss: onDismiss,
      confirm: controller.confirm,
      setPartnerOpen,
    };
  }, [controller, onDismiss]);

  return (
    <FeedbackContext value={api}>
      {children}
      <FeedbackRegion items={state.visible} partnerOpen={partnerOpen} onDismiss={onDismiss} regionRef={regionRef} />
      {pending ? (
        <AlertDialog
          key={pending.id}
          {...pending}
          onConfirm={() => controller.settle(true)}
          onCancel={() => controller.settle(false)}
        />
      ) : null}
    </FeedbackContext>
  );
}
