"use client";

import { useActionState } from "react";
import { authenticate, type AuthFormState } from "../actions";

const inputClass =
  "min-h-11 w-full rounded-btn border border-line bg-white px-3 text-base text-ink placeholder:text-muted focus-visible:border-accent";
const buttonClass =
  "flex min-h-11 w-full items-center justify-center rounded-btn px-4 text-sm font-bold transition-colors disabled:cursor-not-allowed disabled:opacity-60";

export function LoginForm({ next }: { next: string }) {
  const [state, formAction, pending] = useActionState<AuthFormState, FormData>(authenticate, {});

  return (
    <form action={formAction} className="flex flex-col gap-4" noValidate>
      <input type="hidden" name="next" value={next} />
      <label className="flex flex-col gap-1.5 text-sm font-semibold">
        이메일
        <input
          className={inputClass}
          type="email"
          name="email"
          autoComplete="email"
          required
          defaultValue={state.email}
          aria-invalid={state.error ? true : undefined}
          aria-describedby={state.error ? "auth-message" : undefined}
        />
      </label>
      <label className="flex flex-col gap-1.5 text-sm font-semibold">
        비밀번호
        <input
          className={inputClass}
          type="password"
          name="password"
          autoComplete="current-password"
          required
          minLength={8}
          aria-invalid={state.error ? true : undefined}
          aria-describedby="password-hint"
        />
        <span id="password-hint" className="text-xs font-normal text-muted">
          8자 이상
        </span>
      </label>

      {state.error ? (
        <p id="auth-message" role="alert" className="rounded-btn bg-danger-bg px-3 py-2 text-sm text-danger-fg">
          {state.error}
        </p>
      ) : null}
      {state.notice ? (
        <p role="status" className="rounded-btn bg-success-bg px-3 py-2 text-sm text-success-fg">
          {state.notice}
        </p>
      ) : null}

      <div className="mt-2 flex flex-col gap-2 tablet:flex-row">
        <button
          type="submit"
          name="intent"
          value="signin"
          disabled={pending}
          className={`${buttonClass} bg-accent text-white hover:opacity-90`}
        >
          {pending ? "처리 중…" : "로그인"}
        </button>
        <button
          type="submit"
          name="intent"
          value="signup"
          disabled={pending}
          className={`${buttonClass} border border-accent-line bg-accent-weak text-nav-on-ink hover:bg-nav-hover`}
        >
          가입하기
        </button>
      </div>
    </form>
  );
}
