import { notFound } from "next/navigation";
import { EmptyPage } from "@/components/empty-page";
import { findSettingsTab } from "@/lib/routes";

type SettingsTabPageProps = {
  params: Promise<{ tab: string }>;
};

export default async function SettingsTabPage({ params }: SettingsTabPageProps) {
  const { tab } = await params;
  const current = findSettingsTab(tab);
  if (!current) notFound();

  return <EmptyPage eyebrow="SETTINGS" title={current.label} />;
}
