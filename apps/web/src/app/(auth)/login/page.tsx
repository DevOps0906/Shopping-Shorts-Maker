import type { Metadata } from "next";
import { safeNextPath } from "@/lib/supabase/paths";
import { LoginForm } from "./login-form";

export const metadata: Metadata = { title: "로그인 · 쇼핑 숏폼 스튜디오" };

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ next?: string | string[] }>;
}) {
  const { next } = await searchParams;
  const nextPath = safeNextPath(Array.isArray(next) ? next[0] : next);

  return (
    <section
      aria-labelledby="login-title"
      className="w-full max-w-md rounded-card border border-line bg-white p-5 shadow-card tablet:p-7 desktop:p-8"
    >
      <div className="mb-6 flex items-center gap-2.5">
        <span
          className="flex size-9 shrink-0 items-center justify-center rounded-logo bg-accent text-white"
          aria-hidden="true"
        >
          <svg viewBox="0 0 24 24" fill="currentColor" className="size-4">
            <path d="M8 5v14l11-7z" />
          </svg>
        </span>
        <span>
          <b className="block text-base leading-snug">쇼핑 숏폼 스튜디오</b>
          <small className="block text-rail font-semibold tracking-widest text-muted">
            NOMAD AI FACTORY
          </small>
        </span>
      </div>
      <h1 id="login-title" className="text-app font-bold">
        로그인
      </h1>
      <p className="mt-1 mb-6 text-sm text-muted">이메일과 비밀번호로 로그인하거나 새로 가입하세요.</p>
      <LoginForm next={nextPath} />
    </section>
  );
}
