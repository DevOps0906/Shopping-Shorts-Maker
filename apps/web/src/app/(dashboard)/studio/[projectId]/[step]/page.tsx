import { notFound } from "next/navigation";
import { EmptyPage } from "@/components/empty-page";
import { findStudioStep } from "@/lib/routes";

type StudioStepPageProps = {
  params: Promise<{ projectId: string; step: string }>;
};

export default async function StudioStepPage({ params }: StudioStepPageProps) {
  const { step } = await params;
  const current = findStudioStep(step);
  if (!current) notFound();

  return (
    <EmptyPage
      eyebrow="PRODUCTION"
      title={`${String(current.num).padStart(2, "0")} ${current.label}`}
    />
  );
}
