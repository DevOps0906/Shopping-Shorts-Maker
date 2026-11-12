"use client";

import { useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useFeedback } from "@/components/feedback";
import { btnClass, btnSmClass } from "@/components/projects/ui";
import { cn } from "@/lib/utils";

type MutationResult = { ok: true; name: string } | { ok: false; error: string };

type ProjectRowActionsProps = {
  projectId: string;
  name: string;
  openHref: string;
  onDuplicate: (projectId: string) => Promise<MutationResult>;
  onDelete: (projectId: string) => Promise<MutationResult>;
};

/**
 * 관리 칸: 열기 · 복제 · 삭제. 삭제는 되돌릴 수 없어 알림 대화상자로 확인받는다(docs/ui-feedback.md 2장 #16).
 * 결과는 토스트, 실패는 오류 스낵바(#4).
 */
export function ProjectRowActions({ projectId, name, openHref, onDuplicate, onDelete }: ProjectRowActionsProps) {
  const fb = useFeedback();
  const router = useRouter();
  const [pending, startTransition] = useTransition();

  function run(action: (id: string) => Promise<MutationResult>, done: (n: string) => string) {
    startTransition(async () => {
      const result = await action(projectId);
      if (result.ok) {
        fb.toast({ message: done(result.name), tone: "success" });
        router.refresh();
      } else {
        fb.snackbar({ message: result.error, tone: "error", key: `project:${projectId}` });
      }
    });
  }

  /** 영구 삭제 — 공용 알림 대화상자(취소 첫 포커스, 배경 클릭으로 안 닫힘), docs/ui-feedback.md 2장 #16 */
  async function confirmDelete() {
    const ok = await fb.confirm({
      title: `'${name}' 프로젝트를 영구 삭제할까요?`,
      description: "영상·원본·대본이 모두 지워지며 되돌릴 수 없습니다.",
      confirmLabel: "영구 삭제",
      cancelLabel: "취소",
      danger: true,
    });
    if (ok) run(onDelete, (n) => `'${n}' 프로젝트를 삭제했습니다`);
  }

  return (
    <div className="flex gap-1.5 whitespace-nowrap">
      <Link href={openHref} className={cn(btnClass, btnSmClass)}>
        열기
      </Link>
      <button
        type="button"
        className={cn(btnClass, btnSmClass)}
        disabled={pending}
        onClick={() => run(onDuplicate, (n) => `'${n}' 프로젝트를 복제했습니다`)}
        aria-label={`${name} 복제`}
      >
        복제
      </button>
      <button
        type="button"
        className={cn(btnClass, btnSmClass)}
        disabled={pending}
        onClick={confirmDelete}
        aria-label={`${name} 삭제`}
      >
        삭제
      </button>
    </div>
  );
}
