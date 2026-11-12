"use client";

import { useActionState, useState } from "react";
import Link from "next/link";
import { InlineBanner } from "@/components/feedback";
import { AI_COST_NOTE, AI_COST_ROWS, formatWon } from "@/components/projects/ai-cost";
import { PLATFORM_LABEL, PLATFORM_TAG, UPLOAD_LABEL } from "@/components/projects/project-view";
import {
  btnClass,
  btnPrimaryClass,
  btnSmClass,
  chipClass,
  fieldClass,
  labelClass,
  noteClass,
  sectClass,
  segBtnClass,
  segClass,
} from "@/components/projects/ui";
import { cn } from "@/lib/utils";
import { type NewProjectState, type StartMode, START_OPTIONS } from "@/server/projects/input";

/*
 * S-02 새로운 프로젝트 — ① 채널(1 프로젝트 = 1 채널) ② 카테고리 ③ 시작 방식·제품명·상품 링크 ④ 영상 길이·올릴 플랫폼·
 * 프로젝트 이름, AI 예상 비용 표(D9), 만들기·취소. 시각 정본: design/prototype/Main.dc.html vNew.
 * 선택지는 라디오 입력(키보드·스크린리더)이고 카드 모양은 has-checked 로 표시한다.
 */

export type ChannelOption = {
  id: string;
  platform: string;
  name: string;
  categoryId: string | null;
  tone: string | null;
};

type NewProjectFormProps = {
  channels: ChannelOption[];
  categories: { id: string; name: string }[];
  initial: { accountId: string; categoryId: string; start: StartMode; product: string };
  action: (prev: NewProjectState, form: FormData) => Promise<NewProjectState>;
};

const optClass =
  "relative flex min-w-0 cursor-pointer flex-col gap-1.5 rounded-card border border-line bg-white p-4 text-left text-ink transition-colors hover:border-accent-line has-checked:border-accent has-checked:bg-sub-hover has-checked:ring-2 has-checked:ring-accent-weak has-focus-visible:outline-2 has-focus-visible:outline-accent";
const chipRadioClass = cn(
  chipClass,
  "relative cursor-pointer has-checked:border-accent has-checked:bg-accent has-checked:text-white has-focus-visible:outline-2 has-focus-visible:outline-offset-2 has-focus-visible:outline-accent",
);
const segRadioClass = cn(
  segBtnClass,
  "relative cursor-pointer has-checked:bg-white has-checked:text-nav-on-ink has-checked:shadow-card has-focus-visible:outline-2 has-focus-visible:outline-accent",
);

function Question({ num, id, children }: { num: number; id: string; children: React.ReactNode }) {
  return (
    <h3 id={id} className={cn("mb-3 flex items-center gap-2.5 text-base font-bold", num > 1 && "mt-6")}>
      <span className="flex size-6 shrink-0 items-center justify-center rounded-pill bg-accent text-xs text-white">{num}</span>
      {children}
    </h3>
  );
}

function FieldError({ id, message }: { id: string; message?: string }) {
  if (!message) return null;
  return (
    <p id={id} className="mt-1.5 text-xs font-semibold text-danger-fg">
      {message}
    </p>
  );
}

export function NewProjectForm({ channels, categories, initial, action }: NewProjectFormProps) {
  const [state, formAction, pending] = useActionState(action, {});
  const v = state.values;
  const [accountId, setAccountId] = useState(v?.accountId ?? initial.accountId);
  const [categoryId, setCategoryId] = useState(v?.categoryId ?? initial.categoryId);
  const [start, setStart] = useState<StartMode>(v?.start ?? initial.start);
  const fields = state.fields ?? {};
  const channel = channels.find((c) => c.id === accountId);
  const noChannel = channels.length === 0;
  const blocked = noChannel && start !== "trend";

  function pickChannel(c: ChannelOption) {
    setAccountId(c.id);
    if (c.categoryId) setCategoryId(c.categoryId);
  }

  return (
    <form action={formAction} className={sectClass} aria-describedby={state.error ? "np-error" : undefined} noValidate>
      {state.error ? (
        <div id="np-error" className="mb-4">
          <InlineBanner tone="error">
            <p className="font-bold">{state.error}</p>
            {Object.values(fields).length > 0 ? (
              <ul className="mt-1 list-disc pl-4">
                {Object.values(fields).map((m) => (
                  <li key={m}>{m}</li>
                ))}
              </ul>
            ) : null}
          </InlineBanner>
        </div>
      ) : null}

      <fieldset aria-describedby={fields.accountId ? "np-account-err" : undefined}>
        <legend className="contents">
          <Question num={1} id="np-q1">
            어느 채널에 올릴까요?
          </Question>
        </legend>
        {noChannel ? (
          <InlineBanner
            tone="warning"
            action={
              <Link href="/settings/accounts" className={cn(btnClass, btnSmClass)}>
                채널 연결하기
              </Link>
            }
          >
            <p className="font-bold">연결된 업로드 채널이 없습니다</p>
            <p>프로젝트는 채널 하나에 올립니다. 다중 계정에서 YouTube·Instagram·TikTok 채널을 먼저 연결해 주세요.</p>
          </InlineBanner>
        ) : (
          <div className="grid grid-cols-1 gap-3 tablet:grid-cols-2 desktop:grid-cols-4">
            {channels.map((c) => (
              <label key={c.id} className={optClass}>
                <input
                  type="radio"
                  name="accountId"
                  value={c.id}
                  checked={accountId === c.id}
                  onChange={() => pickChannel(c)}
                  className="sr-only"
                />
                <span className={cn("self-start rounded-chdot px-2 py-0.5 text-xs font-bold", PLATFORM_TAG[c.platform])}>
                  {PLATFORM_LABEL[c.platform] ?? c.platform}
                </span>
                <b className="truncate text-sm">{c.name}</b>
                <span className={noteClass}>
                  {categories.find((cat) => cat.id === c.categoryId)?.name ?? "카테고리 미정"}
                  {c.tone ? ` · ${c.tone}` : ""}
                </span>
              </label>
            ))}
          </div>
        )}
        <FieldError id="np-account-err" message={fields.accountId} />
      </fieldset>

      <fieldset aria-describedby={fields.categoryId ? "np-cat-err" : undefined}>
        <legend className="contents">
          <Question num={2} id="np-q2">
            카테고리
          </Question>
        </legend>
        <div className="flex flex-wrap gap-2">
          {categories.map((c) => (
            <label key={c.id} className={chipRadioClass}>
              <input
                type="radio"
                name="categoryId"
                value={c.id}
                checked={categoryId === c.id}
                onChange={() => setCategoryId(c.id)}
                className="sr-only"
              />
              {c.name}
            </label>
          ))}
        </div>
        <FieldError id="np-cat-err" message={fields.categoryId} />
      </fieldset>

      <fieldset>
        <legend className="contents">
          <Question num={3} id="np-q3">
            어떻게 시작할까요?
          </Question>
        </legend>
        <div className="grid grid-cols-1 gap-3 tablet:grid-cols-3">
          {START_OPTIONS.map((o) => (
            <label key={o.value} className={optClass}>
              <input
                type="radio"
                name="start"
                value={o.value}
                checked={start === o.value}
                onChange={() => setStart(o.value)}
                className="sr-only"
              />
              <b className="text-sm">{o.name}</b>
              <span className={noteClass}>{o.desc}</span>
            </label>
          ))}
        </div>
        {start === "direct" ? (
          <div className="mt-3.5">
            <label className={labelClass} htmlFor="np-prod">
              제품명 <span className="text-danger-fg">(필수)</span>
            </label>
            <input
              id="np-prod"
              name="product"
              className={fieldClass}
              defaultValue={v?.product ?? initial.product}
              placeholder="예: 무펌프 눌림식 밸브형 의류 압축팩"
              aria-invalid={fields.product ? true : undefined}
              aria-describedby={fields.product ? "np-prod-err" : undefined}
              required
            />
            <FieldError id="np-prod-err" message={fields.product} />
          </div>
        ) : null}
        {start === "link" ? (
          <div className="mt-3.5">
            <label className={labelClass} htmlFor="np-url">
              상품 링크 <span className="text-danger-fg">(필수)</span>
            </label>
            <input
              id="np-url"
              name="url"
              type="url"
              className={fieldClass}
              defaultValue={v?.url ?? ""}
              placeholder="쿠팡·스마트스토어·알리익스프레스·타오바오 상품 주소"
              aria-invalid={fields.url ? true : undefined}
              aria-describedby={fields.url ? "np-url-err" : undefined}
              required
            />
            <FieldError id="np-url-err" message={fields.url} />
          </div>
        ) : null}
      </fieldset>

      {start !== "trend" ? (
        <>
          <Question num={4} id="np-q4">
            영상 설정
          </Question>
          <div className="flex flex-wrap gap-x-8 gap-y-4">
            <fieldset>
              <legend className={labelClass}>영상 길이</legend>
              <div className={segClass}>
                {["15", "20"].map((sec) => (
                  <label key={sec} className={segRadioClass}>
                    <input
                      type="radio"
                      name="targetSec"
                      value={sec}
                      defaultChecked={(v?.targetSec ?? "15") === sec}
                      className="sr-only"
                    />
                    {sec}초
                  </label>
                ))}
              </div>
              <FieldError id="np-len-err" message={fields.targetSec} />
            </fieldset>
            <div>
              <span className={labelClass}>올릴 플랫폼</span>
              <p className="flex min-h-11 items-center text-sm font-semibold">
                {channel ? (UPLOAD_LABEL[channel.platform] ?? channel.platform) : "채널을 고르면 정해집니다"}
              </p>
              <p className={noteClass}>1 프로젝트 = 1 채널. 고른 채널의 플랫폼에만 올립니다.</p>
            </div>
          </div>
          <label className={cn(labelClass, "mt-4.5")} htmlFor="np-name">
            프로젝트 이름 (선택)
          </label>
          <input
            id="np-name"
            name="name"
            className={fieldClass}
            defaultValue={v?.name ?? ""}
            placeholder="비워 두면 제품명으로 만듭니다"
            aria-invalid={fields.name ? true : undefined}
            aria-describedby={fields.name ? "np-name-err" : undefined}
          />
          <FieldError id="np-name-err" message={fields.name} />
        </>
      ) : null}

      <AiCostTable />

      <div className="mt-5 flex flex-wrap gap-2">
        <button
          type="submit"
          className={cn(btnClass, btnPrimaryClass)}
          disabled={pending || blocked}
          aria-busy={pending || undefined}
        >
          {pending ? "만드는 중…" : start === "trend" ? "트렌드에서 상품 고르기 →" : "프로젝트 만들기"}
        </button>
        <Link href="/" className={btnClass}>
          취소
        </Link>
      </div>
    </form>
  );
}

/** D9 제작 전 AI 예상 비용(영상 1편 · 모델 조합별) */
export function AiCostTable() {
  return (
    <section
      className="mt-4.5 overflow-x-auto rounded-btn border border-accent-line bg-sub-hover p-3"
      aria-labelledby="np-cost"
    >
      <h3 id="np-cost" className={labelClass}>
        AI 예상 비용 (영상 1편 · 모델별)
      </h3>
      <table className="w-full border-collapse text-sm">
        <thead>
          <tr>
            {["조합", "대본·소재·채팅", "원본 분석 (썸네일 20장 + 영상 10편)", "예상 비용"].map((h) => (
              <th key={h} scope="col" className="border-b border-line px-2.5 py-2 text-left text-xs font-semibold text-muted">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {AI_COST_ROWS.map((row) => (
            <tr key={row.combo}>
              <th scope="row" className={cn("border-b border-line px-2.5 py-2.5 text-left", row.emphasis ? "font-bold" : "font-normal")}>
                {row.combo}
              </th>
              <td className="border-b border-line px-2.5 py-2.5">{row.scriptModel}</td>
              <td className="border-b border-line px-2.5 py-2.5">{row.analysisModel}</td>
              <td className={cn("border-b border-line px-2.5 py-2.5 whitespace-nowrap", row.emphasis && "font-bold")}>
                {formatWon(row.won)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className={cn(noteClass, "mt-1.5")}>{AI_COST_NOTE}</p>
    </section>
  );
}
