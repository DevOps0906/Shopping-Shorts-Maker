# syntax=docker/dockerfile:1
# 웹 (Next.js standalone). 빌드 컨텍스트는 저장소 루트(pnpm 워크스페이스):
#   docker build -f apps/web/Dockerfile .
# 전제: apps/web/next.config.ts에 `output: "standalone"`.
# NEXT_PUBLIC_*만 빌드 인자로 받는다. 서버 비밀은 실행 시 환경 변수로만(이미지에 넣지 않는다).

ARG NODE_IMAGE=node:26-trixie-slim@sha256:e6bedef217677b276c591795e169840edd9096dbf13f29df8ef8d1856b8820bc

############################ 의존성 ############################
FROM ${NODE_IMAGE} AS deps
WORKDIR /repo
RUN corepack enable
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml ./
COPY apps/web/package.json apps/web/package.json
RUN pnpm install --frozen-lockfile --filter web...

############################ 빌드 ############################
FROM deps AS build
ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY
ENV NEXT_PUBLIC_SUPABASE_URL=${NEXT_PUBLIC_SUPABASE_URL} \
    NEXT_PUBLIC_SUPABASE_ANON_KEY=${NEXT_PUBLIC_SUPABASE_ANON_KEY} \
    NEXT_TELEMETRY_DISABLED=1
COPY apps/web apps/web
RUN pnpm --filter web build

############################ 실행 ############################
FROM ${NODE_IMAGE}
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    HOSTNAME=0.0.0.0 \
    PORT=3000
WORKDIR /app

COPY --from=build --chown=node:node /repo/apps/web/.next/standalone ./
COPY --from=build --chown=node:node /repo/apps/web/.next/static ./apps/web/.next/static
COPY --from=build --chown=node:node /repo/apps/web/public ./apps/web/public

USER node
EXPOSE 3000
CMD ["node", "apps/web/server.js"]
