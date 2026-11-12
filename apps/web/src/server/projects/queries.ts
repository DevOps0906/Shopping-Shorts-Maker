import "server-only";
import { createClient } from "@/lib/supabase/server";
import {
  type ProjectStatus,
  type StatusFilter,
  PROJECT_STATUSES,
  embeddedText,
  isProjectStatus,
  weekStartKst,
} from "@/components/projects/project-view";
import type { Tables } from "@/types/db";
import { escapeLike } from "./input";

/*
 * 홈·새 프로젝트·프로젝트 관리 조회. 사용자 세션(anon 키) + RLS로 본인 행만 읽는다.
 * accounts는 열 단위 GRANT라 select('*')를 쓰지 않고 열을 나열한다(oauth_token_ref 제외).
 * 원문 오류는 내보내지 않고 던져서 화면의 오류 상태로 보낸다.
 */

export type Channel = Pick<
  Tables<"accounts">,
  "id" | "platform" | "channel_name" | "category_id" | "tone" | "weekly_goal" | "is_default" | "status"
>;
const CHANNEL_COLUMNS = "id, platform, channel_name, category_id, tone, weekly_goal, is_default, status";

export type Category = Pick<Tables<"categories">, "id" | "name">;

export type ProjectRow = {
  id: string;
  name: string;
  status: ProjectStatus;
  currentStep: number;
  updatedAt: string;
  channelName: string | null;
  categoryName: string | null;
  version: number | null;
};

type RawProject = Pick<Tables<"projects">, "id" | "name" | "status" | "current_step" | "updated_at"> & {
  accounts?: unknown;
  categories?: unknown;
  renders?: unknown;
};

function toProjectRow(raw: RawProject): ProjectRow {
  const versions = Array.isArray(raw.renders)
    ? raw.renders.map((r) => (r as { version?: unknown }).version).filter((v): v is number => typeof v === "number")
    : [];
  return {
    id: raw.id,
    name: raw.name,
    status: isProjectStatus(raw.status) ? raw.status : "in_progress",
    currentStep: raw.current_step,
    updatedAt: raw.updated_at,
    channelName: embeddedText(raw.accounts, "channel_name"),
    categoryName: embeddedText(raw.categories, "name"),
    version: versions.length ? Math.max(...versions) : null,
  };
}

const PROJECT_COLUMNS = "id, name, status, current_step, updated_at, accounts(channel_name), categories(name)";

function fail(): never {
  throw new Error("load_failed");
}

export async function listChannels(): Promise<Channel[]> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("accounts")
    .select(CHANNEL_COLUMNS)
    .order("is_default", { ascending: false })
    .order("created_at", { ascending: true });
  if (error) fail();
  return (data ?? []) as Channel[];
}

export async function listCategories(): Promise<Category[]> {
  const supabase = await createClient();
  const { data, error } = await supabase.from("categories").select("id, name").order("name");
  if (error) fail();
  return (data ?? []) as Category[];
}

export const PAGE_SIZE = 20;

export type ProjectListQuery = { status: StatusFilter; q: string; page: number };

export async function listProjects({ status, q, page }: ProjectListQuery) {
  const supabase = await createClient();
  let query = supabase
    .from("projects")
    .select(`${PROJECT_COLUMNS}, renders(version)`, { count: "exact" })
    .order("updated_at", { ascending: false });
  if (status !== "all") query = query.eq("status", status);
  if (q) query = query.ilike("name", `%${escapeLike(q)}%`);
  const from = (page - 1) * PAGE_SIZE;
  const { data, error, count } = await query.range(from, from + PAGE_SIZE - 1);
  if (error) fail();

  // 상태 필터 칸의 개수 — 상태 열만 읽어 센다
  const { data: all, error: countError } = await supabase.from("projects").select("status");
  if (countError) fail();
  const counts = Object.fromEntries(PROJECT_STATUSES.map((s) => [s, 0])) as Record<ProjectStatus, number>;
  for (const row of (all ?? []) as { status: string }[]) if (isProjectStatus(row.status)) counts[row.status] += 1;

  return {
    rows: ((data ?? []) as RawProject[]).map(toProjectRow),
    total: count ?? 0,
    counts,
    all: (all ?? []).length,
  };
}

export type ChannelWeek = Channel & { uploaded: number };

export type HomeData = {
  profileName: string | null;
  inProgress: number;
  awaitingPublish: number;
  weekUploads: number;
  credits: number;
  continueList: ProjectRow[];
  channels: ChannelWeek[];
  loadedAt: string;
};

export async function getHomeData(now = new Date()): Promise<HomeData> {
  const supabase = await createClient();
  const weekStart = weekStartKst(now);

  const [profile, statuses, active, uploads, ledger, channels] = await Promise.all([
    supabase.from("user_profiles").select("name, email").maybeSingle(),
    supabase.from("projects").select("status"),
    supabase
      .from("projects")
      .select(PROJECT_COLUMNS)
      .in("status", ["in_progress", "awaiting_publish"])
      .order("updated_at", { ascending: false })
      .limit(3),
    supabase.from("publications").select("account_id").eq("status", "uploaded").gte("published_at", weekStart),
    supabase.from("credit_ledger").select("delta"),
    listChannels(),
  ]);
  if (profile.error || statuses.error || active.error || uploads.error || ledger.error) fail();

  const statusRows = (statuses.data ?? []) as { status: string }[];
  const uploadRows = (uploads.data ?? []) as { account_id: string }[];
  const perChannel = new Map<string, number>();
  for (const row of uploadRows) perChannel.set(row.account_id, (perChannel.get(row.account_id) ?? 0) + 1);

  const p = profile.data as { name: string | null; email: string | null } | null;
  return {
    profileName: p?.name || p?.email?.split("@")[0] || null,
    inProgress: statusRows.filter((r) => r.status === "in_progress").length,
    awaitingPublish: statusRows.filter((r) => r.status === "awaiting_publish").length,
    weekUploads: uploadRows.length,
    credits: ((ledger.data ?? []) as { delta: number }[]).reduce((sum, r) => sum + r.delta, 0),
    continueList: ((active.data ?? []) as RawProject[]).map(toProjectRow),
    channels: channels.map((c) => ({ ...c, uploaded: perChannel.get(c.id) ?? 0 })),
    loadedAt: now.toISOString(),
  };
}
