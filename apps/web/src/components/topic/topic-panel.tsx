"use client";

import { useState, useTransition } from "react";
import { useSearchParams } from "next/navigation";
import { saveTopicAction, suggestTopicsAction } from "@/app/(dashboard)/studio/[projectId]/[step]/topic/actions";
import { InlineBanner, useFeedback } from "@/components/feedback";
import { btnClass, btnPrimaryClass } from "@/components/studio/step-actions";
import { useStudioStep } from "@/components/studio/studio-step-view";
import { readTopicPrefill } from "@/lib/llm/prefill";
import { cn } from "@/lib/utils";
import type { TopicView } from "@/server/llm/topics";
import { CostHint } from "./cost-hint";
import { useElapsed } from "./use-elapsed";

/*
 * S-06 01 소재 본문 — docs/planning.md 3장 01, docs/03_SCREENS_UX.md S-06(빈·로딩·오류·성공).
 * 후보 칩을 누르면 제품 칸이 채워지고 직접 고칠 수 있다. 저장하면 승인 필요(ready). 승인은 아래 StepActions만.
 */

type TopicPanelProps = { initialTopics: TopicView[]; categoryName: string | null };

export function TopicPanel({ initialTopics, categoryName }: TopicPanelProps) {
  const { projectId, status, setStatus } = useStudioStep();
  const feedback = useFeedback();
  const [topics, setTopics] = useState(initialTopics);
  const searchParams = useSearchParams();
  // S-02에서 넘어온 제품명·상품 링크는 입력칸만 채운다(생성 호출 없음). 저장된 소재가 있으면 그것이 우선
  const [prefill] = useState(() =>
    readTopicPrefill({ product: searchParams.get("product"), url: searchParams.get("url") }),
  );
  const [name, setName] = useState(initialTopics.find((t) => t.picked)?.name ?? prefill.product);
  const [productUrl, setProductUrl] = useState(initialTopics.find((t) => t.picked)?.productUrl ?? prefill.url);
  const [error, setError] = useState<string | null>(null);
  const [empty, setEmpty] = useState(false);
  const [suggesting, startSuggest] = useTransition();
  const [saving, startSave] = useTransition();
  const elapsed = useElapsed(suggesting);

  const locked = status[1] === "approved";
  const candidates = topics.filter((t) => t.reason !== null);
  const pickedName = topics.find((t) => t.picked)?.name ?? null;

  function suggest() {
    setError(null);
    startSuggest(async () => {
      const result = await suggestTopicsAction(projectId, name);
      if (!result.ok) {
        setError(result.error);
        return;
      }
      setEmpty(result.topics.length === 0);
      if (result.topics.length > 0) setTopics(result.topics);
      if (result.status) setStatus(result.status);
    });
  }

  function save() {
    setError(null);
    startSave(async () => {
      const result = await saveTopicAction(projectId, name, productUrl);
      if (!result.ok) {
        setError(result.error);
        return;
      }
      setTopics(result.topics);
      if (result.status) setStatus(result.status);
      feedback.toast({ message: "소재를 저장했습니다", tone: "success" });
    });
  }

  return (
    <section aria-label="소재 고르기" className="flex flex-col gap-4 rounded-card border border-line bg-white p-4 shadow-card tablet:p-6">
      <div className="flex flex-col gap-2">
        <div className="flex flex-wrap items-center gap-2">
          <button
            type="button"
            onClick={suggest}
            disabled={locked || suggesting}
            className={cn(btnClass, candidates.length === 0 && btnPrimaryClass)}
          >
            {suggesting ? `추천 중… ${elapsed}초` : candidates.length > 0 ? "다른 후보 추천" : "소재 추천받기"}
          </button>
          {categoryName ? <span className="text-xs text-muted">카테고리 · {categoryName}</span> : null}
        </div>
        <CostHint task="topics" />
        {candidates.length === 0 && !empty && !error ? (
          <p className="text-sm text-muted">소재 추천받기를 누르면 후보 3개를 제안합니다. 아래 칸에 적은 제품명은 힌트로 씁니다.</p>
        ) : null}
      </div>

      {error ? <InlineBanner tone="error">{error} 아래 칸에 제품명을 직접 입력해도 됩니다.</InlineBanner> : null}
      {empty ? (
        <InlineBanner tone="warning">추천할 후보를 찾지 못했습니다. 아래 칸에 제품명을 직접 입력해 주세요.</InlineBanner>
      ) : null}

      {candidates.length > 0 ? (
        <ul aria-label="추천 소재 후보" className="grid gap-2 desktop:grid-cols-3">
          {candidates.map((topic) => {
            const selected = topic.name === name;
            return (
              <li key={topic.id}>
                <button
                  type="button"
                  aria-pressed={selected}
                  disabled={locked}
                  onClick={() => setName(topic.name)}
                  className={cn(
                    "flex h-full w-full flex-col items-start gap-1 rounded-btn border px-4 py-3 text-left transition-colors disabled:cursor-not-allowed",
                    selected ? "border-accent bg-accent-weak" : "border-line bg-white hover:border-accent-line hover:bg-sub-hover",
                  )}
                >
                  <span className="text-base font-bold text-ink">{topic.name}</span>
                  {topic.reason ? <span className="text-sm text-muted">{topic.reason}</span> : null}
                </button>
                {topic.evidenceUrls.length > 0 ? (
                  <ul className="mt-1 flex flex-wrap gap-2 px-1">
                    {topic.evidenceUrls.slice(0, 3).map((url, i) => (
                      <li key={url}>
                        <a href={url} target="_blank" rel="noopener noreferrer" className="text-xs text-accent underline">
                          비슷한 영상 {i + 1}
                        </a>
                      </li>
                    ))}
                  </ul>
                ) : null}
              </li>
            );
          })}
        </ul>
      ) : null}

      <form
        className="flex flex-col gap-2"
        onSubmit={(event) => {
          event.preventDefault();
          save();
        }}
      >
        <label htmlFor="topic-name" className="text-sm font-semibold">
          이번 영상에서 다룰 제품<span className="text-danger-fg">*</span>
        </label>
        <div className="flex flex-col gap-2 tablet:flex-row">
          <input
            id="topic-name"
            value={name}
            onChange={(event) => setName(event.target.value)}
            maxLength={40}
            disabled={locked}
            placeholder="예: 진공 압축팩"
            className="min-h-11 flex-1 rounded-btn border border-line bg-white px-3 text-base text-ink disabled:bg-sub-hover"
          />
          <button type="submit" disabled={locked || saving || name.trim().length === 0} className={cn(btnClass, btnPrimaryClass)}>
            {saving ? "저장 중…" : "소재 저장"}
          </button>
        </div>
        <label htmlFor="topic-url" className="mt-2 text-sm font-semibold">
          상품 링크(선택)
        </label>
        <input
          id="topic-url"
          type="url"
          inputMode="url"
          value={productUrl}
          onChange={(event) => setProductUrl(event.target.value)}
          disabled={locked}
          placeholder="https://"
          className="min-h-11 rounded-btn border border-line bg-white px-3 text-base text-ink disabled:bg-sub-hover"
        />
        <p className="text-xs text-muted">
          {locked
            ? "승인된 소재입니다. 바꾸려면 아래 변경 필요를 눌러 주세요."
            : pickedName
              ? `저장된 소재 · ${pickedName}`
              : "후보를 누르면 칸이 채워지고, 직접 고쳐 쓸 수 있습니다."}
        </p>
      </form>
    </section>
  );
}
