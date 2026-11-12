"use client";

import { useId, useMemo, useState, useTransition } from "react";
import {
  chooseBioServiceAction,
  preparePublicationAction,
  saveAffiliateAction,
  setUserCheckAction,
} from "@/app/(dashboard)/studio/[projectId]/[step]/publish/actions";
import { InlineBanner, useFeedback } from "@/components/feedback";
import { btnClass, btnPrimaryClass } from "@/components/studio/step-actions";
import { useStudioStep } from "@/components/studio/studio-step-view";
import {
  type BioService,
  type ProgramId,
  canPublish,
  composeDescription,
  findPublishBanned,
  formatSlot,
  isLinkProgram,
  isoToKstInput,
  kstInputToIso,
  parseHashtags,
  passedCount,
  recommendedPrograms,
  withLocalBanned,
} from "@/lib/publish/rules";
import { cn } from "@/lib/utils";
import type { CopyInput, PolicyActionResult, PublishStepData } from "@/server/publish/publish";
import { AffiliatePicker, inputClass } from "./affiliate-picker";
import { LinkInBioCard } from "./link-in-bio-card";
import { LinkPlacement } from "./link-placement";
import { PolicyChecklist } from "./policy-checklist";
import { PublishCopy } from "./publish-copy";

/*
 * S-11 06 발행 본문 — docs/planning.md 3장 06 · 15-1 · 15-4 · 16-3 · 16-4, docs/design.md 5-7.
 * 상태: 빈(정책 점검 미통과 → 발행 버튼 비활성 + 사라지지 않는 경고 배너) · 로딩(발행 버튼 회전 아이콘)
 * · 오류(같은 화면 배너) · 성공(발행 준비 완료 배너). 실제 업로드·예약은 task-024 — 버튼은 발행 준비 저장까지.
 * 버튼 활성은 UX일 뿐이고, DB(prepare_publication)가 6/6 통과를 다시 확인한다.
 */

const copyKey = (c: CopyInput) => JSON.stringify([c.title, c.body, c.hashtags]);

export function PublishPanel({
  productName,
  categoryName,
  channel,
  scriptLines,
  bannedTerms,
  link: initialLink,
  publication: initialPublication,
  variants,
  initialCopy,
  policy: initialPolicy,
  slots,
}: PublishStepData) {
  const { projectId, status } = useStudioStep();
  const feedback = useFeedback();
  const ids = { mode: useId(), at: useId() };
  const [link, setLink] = useState(initialLink);
  const [policy, setPolicy] = useState(initialPolicy);
  const [publication, setPublication] = useState(initialPublication);
  const [title, setTitle] = useState(initialCopy.title);
  const [body, setBody] = useState(initialCopy.body);
  const [hashtagText, setHashtagText] = useState(initialCopy.hashtags.join(" "));
  const [variantIdx, setVariantIdx] = useState(0);
  const [purchaseGuide, setPurchaseGuide] = useState(true);
  const [pinComment, setPinComment] = useState(initialPublication?.pinComment ?? false);
  const [mode, setMode] = useState<"scheduled" | "now">(initialPublication?.mode ?? "scheduled");
  const [scheduledAt, setScheduledAt] = useState<string | null>(initialPublication?.scheduledAt ?? slots[0] ?? null);
  const [error, setError] = useState<string | null>(null);
  // DB가 판정할 때 쓴 문구. 지금 문구와 같으면 DB의 금지어 미통과를 유지한다
  const [evaluatedKey, setEvaluatedKey] = useState(() => copyKey(initialCopy));
  const [pending, startTransition] = useTransition();
  const [publishing, startPublish] = useTransition();

  const hashtags = useMemo(() => parseHashtags(hashtagText), [hashtagText]);
  const copy: CopyInput = { title, body, hashtags };
  const banned = findPublishBanned([title, body, hashtags.join("")], scriptLines, bannedTerms);
  const items = withLocalBanned(policy.items, banned, evaluatedKey === copyKey(copy));
  const passed = passedCount(items);
  const description = composeDescription({
    disclosure: policy.disclosure,
    purchase: purchaseGuide ? policy.purchase : "",
    body,
    credits: policy.credits,
    hashtags,
  });

  const ready = status[5] === "approved";
  // 예약·업로드가 시작된 행은 잠근다. pending(준비 완료)·invalidated(정책 변화로 풀림)는 다시 저장할 수 있다
  const locked = publication !== null && publication.status !== "pending" && publication.status !== "invalidated";
  const prepared = publication?.status === "pending";
  const busy = pending || publishing;
  const program = link?.program ?? null;
  const allPassed = canPublish(items);
  const canSubmit = allPassed && ready && !locked && !busy && title.trim() !== "" && (mode === "now" || scheduledAt !== null);

  function run(action: () => Promise<PolicyActionResult>, done?: string) {
    setError(null);
    const key = copyKey(copy);
    startTransition(async () => {
      const result = await action();
      if (!result.ok) {
        setError(result.error);
        return;
      }
      setPolicy(result.policy);
      setEvaluatedKey(key);
      setLink(result.link);
      setPublication(result.publication);
      if (done) feedback.toast({ message: done, tone: "success" });
    });
  }

  const saveLink = (next: { program: ProgramId; url: string | null; disclosed: boolean }, done?: string) =>
    run(() => saveAffiliateAction(projectId, next, copy), done);

  function regenerate() {
    const next = (variantIdx + 1) % variants.length;
    setVariantIdx(next);
    setTitle(variants[next].title);
    setBody(variants[next].body);
    setHashtagText(variants[next].hashtags.join(" "));
  }

  function publish() {
    setError(null);
    const key = copyKey(copy);
    startPublish(async () => {
      const result = await preparePublicationAction(projectId, { mode, scheduledAt, purchaseGuide, pinComment }, copy);
      if (!result.ok) {
        setError(result.error);
        return;
      }
      setPublication(result.publication);
      setPolicy(result.policy);
      setEvaluatedKey(key);
      feedback.toast({ message: "발행 준비를 완료했습니다", tone: "success" });
    });
  }

  return (
    <div className="flex flex-col gap-4">
      {!ready ? <InlineBanner tone="warning">05 편집을 승인하면 발행할 수 있습니다. 지금은 내용을 미리 준비만 할 수 있습니다.</InlineBanner> : null}

      <div className="grid grid-cols-1 gap-4 desktop:grid-cols-2">
        <div className="flex min-w-0 flex-col gap-4">
          <AffiliatePicker
            program={program}
            url={link?.url ?? null}
            disclosed={link?.disclosed ?? true}
            pinComment={pinComment}
            recommended={recommendedPrograms(categoryName, channel.platform)}
            disabled={busy || locked}
            onProgram={(p) => saveLink({ program: p, url: p === program ? (link?.url ?? null) : null, disclosed: link?.disclosed ?? true })}
            onUrl={(url) => program && saveLink({ program, url, disclosed: link?.disclosed ?? true }, "제휴 링크를 저장했습니다")}
            onDisclosed={(on) => program && saveLink({ program, url: link?.url ?? null, disclosed: on })}
            onPinComment={setPinComment}
          />
          <LinkPlacement platform={channel.platform} />
          <LinkInBioCard
            enabled={isLinkProgram(program) && Boolean(link?.url)}
            service={link?.bioService ?? null}
            bioNo={link?.bioNo ?? null}
            registered={link?.bioRegistered ?? false}
            productName={productName}
            url={link?.url ?? null}
            disclosure={policy.disclosure}
            purchaseGuide={purchaseGuide}
            disabled={busy || locked}
            onService={(s: BioService | "none") => run(() => chooseBioServiceAction(projectId, s, copy))}
            onRegistered={(on) => run(() => setUserCheckAction(projectId, "purchase_path", on, copy), on ? "등록 완료로 표시했습니다" : undefined)}
            onPurchaseGuide={setPurchaseGuide}
          />
        </div>
        <div className="flex min-w-0 flex-col gap-4">
          <PublishCopy
            title={title}
            body={body}
            hashtagText={hashtagText}
            description={description}
            variantNo={variantIdx + 1}
            variantCount={variants.length}
            disabled={busy || locked}
            onTitle={setTitle}
            onBody={setBody}
            onHashtags={setHashtagText}
            onRegenerate={regenerate}
          />
          <PolicyChecklist
            items={items}
            attributionChecked={items.find((i) => i.item === "attribution_notice")?.checkedAt != null}
            credits={policy.credits}
            disabled={busy || locked}
            onAttribution={(on) => run(() => setUserCheckAction(projectId, "attribution_notice", on, copy))}
          />
        </div>
      </div>

      <section aria-label="발행 설정" className="flex flex-col gap-3 rounded-card border border-line bg-white p-4 shadow-card tablet:p-6">
        <div className="flex flex-wrap items-baseline justify-between gap-2">
          <p className="text-sm font-semibold">발행 설정</p>
          <p className="text-xs text-muted">
            채널: {channel.name || "프로젝트 채널"} (프로젝트당 1개 고정)
          </p>
        </div>
        <div role="radiogroup" aria-labelledby={ids.mode} className="flex flex-wrap gap-2">
          <span id={ids.mode} className="sr-only">
            발행 방식
          </span>
          {(
            [
              ["scheduled", "예약 발행"],
              ["now", "지금 올리기"],
            ] as const
          ).map(([value, label]) => (
            <button
              key={value}
              type="button"
              role="radio"
              aria-checked={mode === value}
              disabled={busy || locked}
              onClick={() => setMode(value)}
              className={cn(btnClass, mode === value && "border-accent bg-accent-weak")}
            >
              {label}
            </button>
          ))}
        </div>
        {mode === "scheduled" ? (
          <div className="flex flex-col gap-2">
            <p className="text-xs text-muted">추천 시간(조회가 몰리는 시간대 · 성과 데이터가 쌓이면 채널 기준으로 바뀝니다)</p>
            <div className="flex flex-wrap gap-2">
              {slots.map((slot) => (
                <button
                  key={slot}
                  type="button"
                  aria-pressed={scheduledAt === slot}
                  disabled={busy || locked}
                  onClick={() => setScheduledAt(slot)}
                  className={cn(btnClass, scheduledAt === slot && "border-accent bg-accent-weak")}
                >
                  {formatSlot(new Date(slot))}
                </button>
              ))}
            </div>
            <label htmlFor={ids.at} className="flex flex-col gap-1 text-xs text-muted tablet:max-w-80">
              직접 고르기(한국 시간)
              <input
                id={ids.at}
                type="datetime-local"
                value={scheduledAt ? isoToKstInput(scheduledAt) : ""}
                onChange={(e) => setScheduledAt(kstInputToIso(e.target.value))}
                disabled={busy || locked}
                className={inputClass}
              />
            </label>
          </div>
        ) : null}

        {!allPassed ? (
          <InlineBanner tone="warning">
            정책 점검 {items.length - passed}개 항목이 아직 통과하지 않아 발행 버튼이 꺼져 있습니다. 위 점검 목록의 안내를 따라 주세요.
          </InlineBanner>
        ) : null}
        {error ? <InlineBanner tone="error">{error}</InlineBanner> : null}
        {publication?.status === "invalidated" ? (
          <InlineBanner tone="warning">점검 내용이 바뀌어 발행 준비가 풀렸습니다. 6개 항목을 다시 확인한 뒤 발행 준비를 다시 저장해 주세요.</InlineBanner>
        ) : null}
        {publication && prepared ? (
          <InlineBanner tone="success">
            발행 준비 완료 · {publication.mode === "scheduled" && publication.scheduledAt ? `${formatSlot(new Date(publication.scheduledAt))} 예약` : "지금 올리기"}.
            실제 업로드는 YouTube 연결 기능이 열리면 이 설정으로 진행됩니다.
          </InlineBanner>
        ) : null}

        <div className="flex flex-wrap items-center gap-2">
          <button type="button" onClick={publish} disabled={!canSubmit} aria-busy={publishing} className={cn(btnClass, btnPrimaryClass)}>
            {publishing ? (
              <>
                <span aria-hidden="true" className="inline-block size-4 animate-spin rounded-pill border-2 border-white border-t-transparent" />
                저장하는 중…
              </>
            ) : prepared ? (
              "발행 준비 다시 저장"
            ) : (
              "발행"
            )}
          </button>
          <span className="text-xs text-muted">
            {passed} / {items.length} 통과 · 6개 모두 통과해야 켜집니다
          </span>
        </div>
      </section>
    </div>
  );
}
