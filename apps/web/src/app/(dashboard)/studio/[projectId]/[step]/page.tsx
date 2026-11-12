import Link from "next/link";
import { notFound } from "next/navigation";
import { PageHeader } from "@/components/page-header";
import { ProjectBar } from "@/components/studio/project-bar";
import { StudioStepView } from "@/components/studio/studio-step-view";
import { findStudioStep } from "@/lib/routes";
import { isProjectId } from "@/lib/steps/project-id";
import { type StepNumber, parseStepStatus } from "@/lib/steps/state";
import { createClient } from "@/lib/supabase/server";
import { ScriptStep } from "./script/script-step";
import { SourceStep } from "./source/source-step";
import { TopicStep } from "./topic/topic-step";
import { VoiceStep } from "./voice/voice-step";

type StudioStepPageProps = {
  params: Promise<{ projectId: string; step: string }>;
};

/** 단계별 본문 슬롯 — 단계 번호 → 서버 본문 로더. 본문이 없는 단계는 준비 중 안내 */
const STEP_BODIES: Partial<Record<StepNumber, (props: { projectId: string }) => Promise<React.ReactNode>>> = {
  1: TopicStep,
  2: SourceStep,
  3: ScriptStep,
  4: VoiceStep,
};

/** PostgREST 임베드는 관계에 따라 객체 또는 배열로 온다 */
function embeddedName(value: unknown, key: "name" | "channel_name"): string | null {
  const row = Array.isArray(value) ? value[0] : value;
  if (typeof row !== "object" || row === null) return null;
  const name = (row as Record<string, unknown>)[key];
  return typeof name === "string" ? name : null;
}

export default async function StudioStepPage({ params }: StudioStepPageProps) {
  const { projectId, step } = await params;
  const current = findStudioStep(step);
  if (!current) notFound();
  const stepNumber = current.num as StepNumber;
  const title = `${String(current.num).padStart(2, "0")} ${current.label}`;

  const supabase = await createClient();
  const { data: project, error } = isProjectId(projectId)
    ? await supabase
        .from("projects")
        .select("id, name, step_status, updated_at, accounts(channel_name), categories(name)")
        .eq("id", projectId)
        .maybeSingle()
    : { data: null, error: null };
  // 원문 오류는 화면에 내보내지 않는다. error.tsx가 다시 시도 버튼을 보여 준다.
  if (error) throw new Error("project_load_failed");

  if (!project) {
    return (
      <div className="mx-auto flex max-w-(--content-max) flex-col gap-4">
        <PageHeader eyebrow="PRODUCTION" title={title} />
        <section className="flex flex-col items-start gap-3 rounded-card border border-line bg-white p-6 shadow-card">
          <p className="text-base font-bold">프로젝트를 찾을 수 없습니다</p>
          <p className="text-sm text-muted">삭제되었거나 다른 계정의 프로젝트입니다. 프로젝트 관리에서 다시 골라 주세요.</p>
          <Link
            href="/projects"
            className="inline-flex min-h-11 items-center rounded-btn border border-accent bg-accent px-4 text-sm font-semibold text-white"
          >
            프로젝트 관리로 가기
          </Link>
        </section>
      </div>
    );
  }

  const status = parseStepStatus(project.step_status);
  if (!status) throw new Error("invalid_step_status");

  let runningStartedAt: string | null = null;
  if (status[stepNumber] === "running") {
    const { data: job } = await supabase
      .from("jobs")
      .select("started_at, created_at")
      .eq("project_id", projectId)
      .eq("step", stepNumber)
      .in("status", ["queued", "waiting_extension", "running"])
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    const started: unknown = job?.started_at ?? job?.created_at;
    runningStartedAt = typeof started === "string" ? started : null;
  }

  const StepBody = STEP_BODIES[stepNumber];

  return (
    <div className="mx-auto flex max-w-(--content-max) flex-col gap-4">
      <PageHeader eyebrow="PRODUCTION" title={title} />
      <ProjectBar
        name={String(project.name)}
        categoryName={embeddedName(project.categories, "name")}
        channelName={embeddedName(project.accounts, "channel_name")}
        updatedAt={String(project.updated_at)}
      />
      <StudioStepView
        key={stepNumber}
        projectId={projectId}
        step={stepNumber}
        initialStatus={status}
        runningStartedAt={runningStartedAt}
      >
        {StepBody ? (
          <StepBody projectId={projectId} />
        ) : (
          <section className="rounded-card border border-line bg-white p-6 shadow-card">
            <p className="text-sm text-muted">이 단계의 작업 화면은 준비 중입니다.</p>
          </section>
        )}
      </StudioStepView>
    </div>
  );
}
