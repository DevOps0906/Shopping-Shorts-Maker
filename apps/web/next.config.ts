import path from "node:path";
import type { NextConfig } from "next";

// 개발·로컬 빌드: 루트 .env(docker/gen-secrets.sh 생성)를 읽는다. 이미 있는 환경 변수는 덮어쓰지 않는다.
// Docker 빌드에는 .env가 없어(.dockerignore) 건너뛰고, NEXT_PUBLIC_*는 빌드 인자로 들어온다.
// 이 값들은 서버 프로세스에만 남는다. 번들에는 아래 env의 공개 값(URL·anon 키)만 들어간다.
// 루트 .env.local(개발용 LLM 테스트 키: GEMINI_API_KEY 또는 GOOGLE_API_KEY)도 같은 방식으로 읽는다.
// 서버 코드(src/server/llm)만 이 값을 쓰며, env 블록에 넣지 않으므로 번들에 들어가지 않는다.
for (const file of ["../../.env", "../../.env.local"]) {
  try {
    process.loadEnvFile(path.resolve(process.cwd(), file));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
}

const nextConfig: NextConfig = {
  output: "standalone",
  poweredByHeader: false,
  env: {
    NEXT_PUBLIC_SUPABASE_URL:
      process.env.NEXT_PUBLIC_SUPABASE_URL ?? process.env.SUPABASE_PUBLIC_URL ?? "",
    NEXT_PUBLIC_SUPABASE_ANON_KEY:
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? process.env.ANON_KEY ?? "",
  },
};

export default nextConfig;
