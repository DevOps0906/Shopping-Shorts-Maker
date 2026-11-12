"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { LOGIN_PATH, safeNextPath } from "@/lib/supabase/paths";

export type AuthFormState = { error?: string; notice?: string; email?: string };

// 잠정 정책(팀장 결정 전): 최소 8자. 72바이트 초과는 bcrypt가 잘라 내므로 막는다.
const PASSWORD_MIN = 8;
const PASSWORD_MAX = 72;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/** Auth 오류 코드를 화면 문구로 바꾼다. 원문 메시지는 화면·로그에 내보내지 않는다. */
function toMessage(code: string | undefined) {
  switch (code) {
    case "invalid_credentials":
      return "이메일 또는 비밀번호가 맞지 않습니다.";
    case "email_not_confirmed":
      return "이메일 확인이 아직 끝나지 않았습니다. 받은 메일의 확인 링크를 눌러 주세요.";
    case "user_already_exists":
    case "email_exists":
      return "이미 가입된 이메일입니다. 로그인해 주세요.";
    case "weak_password":
      return `비밀번호는 ${PASSWORD_MIN}자 이상이어야 합니다.`;
    case "signup_disabled":
      return "지금은 새 가입을 받지 않습니다.";
    case "over_request_rate_limit":
    case "over_email_send_rate_limit":
      return "요청이 너무 많습니다. 잠시 뒤 다시 시도해 주세요.";
    default:
      return "로그인 서버에 연결하지 못했습니다. 잠시 뒤 다시 시도해 주세요.";
  }
}

export async function authenticate(
  _prev: AuthFormState,
  formData: FormData,
): Promise<AuthFormState> {
  const intent = formData.get("intent") === "signup" ? "signup" : "signin";
  const email = String(formData.get("email") ?? "").trim();
  const password = String(formData.get("password") ?? "");
  const next = safeNextPath(String(formData.get("next") ?? ""));

  if (!EMAIL_PATTERN.test(email)) return { error: "이메일 형식을 확인해 주세요.", email };
  if (password.length < PASSWORD_MIN || new TextEncoder().encode(password).length > PASSWORD_MAX) {
    return { error: `비밀번호는 ${PASSWORD_MIN}자 이상 ${PASSWORD_MAX}바이트 이하로 입력해 주세요.`, email };
  }

  const supabase = await createClient();

  if (intent === "signup") {
    const { data, error } = await supabase.auth.signUp({ email, password });
    if (error) return { error: toMessage(error.code), email };
    // 메일 자동 확인이 꺼져 있으면 세션 없이 사용자만 생긴다.
    if (!data.session) {
      return { notice: "가입 확인 메일을 보냈습니다. 메일의 링크를 누른 뒤 로그인해 주세요.", email };
    }
  } else {
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) return { error: toMessage(error.code), email };
  }

  redirect(next);
}

export async function signOut() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect(LOGIN_PATH);
}
