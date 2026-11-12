import type { NextRequest } from "next/server";
import { updateSession } from "@/lib/supabase/proxy";

// Next.js 16: middleware 파일 규칙이 proxy로 이름이 바뀌었다(nextjs.org/docs/app/api-reference/file-conventions/proxy).
export async function proxy(request: NextRequest) {
  return updateSession(request);
}

export const config = {
  // 정적 파일·이미지 최적화 경로는 건너뛴다.
  matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)"],
};
