import type { NextRequest } from "next/server";
import { updateSession } from "@/lib/supabase/proxy";

// Next.js 16: middleware 파일 규칙이 proxy로 이름이 바뀌었다(nextjs.org/docs/app/api-reference/file-conventions/proxy).
export async function proxy(request: NextRequest) {
  return updateSession(request);
}

export const config = {
  // 정적 파일·이미지 최적화 경로는 건너뛴다.
  // 익명 경로도 건너뛴다: 단축 링크 /l/{코드}(task-025)·내부 호출 /api/internal/*(키 인증, 리버스 프록시가 외부 차단).
  matcher: ["/((?!_next/static|_next/image|favicon.ico|l/|api/internal/|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)"],
};
