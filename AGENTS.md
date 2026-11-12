# AGENTS.md — Shopping-Shorts-Maker

> 모든 AI 코딩 도구(Claude Code · ChatGPT Codex · Gemini CLI · OpenCode · Cursor)가 읽는 **단일 정본**. 80줄 이내로 유지한다.
> 영역별 상세 규칙은 `.claude/rules/*.md`(7장 표), 기획 근거는 `docs/`.

## 1. 무엇인가
쇼핑 숏폼 운영자가 제품명 하나로 틱톡·샤오홍슈 원본을 모아 15·20초 숏폼을 만들고 제휴 링크와 함께 발행하는 6단계 승인형 대시보드. 기획 정본: `docs/planning.md` · 구조도: `docs/diagrams/`. 현재 기획·디자인 단계이며 앱 코드는 아직 없다.

## 2. 스택 (작업 시 최신 stable 확인 후 버전 고정)
| 영역 | 선택 | 위치 |
|---|---|---|
| 웹·AI 호출 | Next.js 16.4 (App Router) · React 19.3 · TypeScript · Tailwind CSS v4.3 · shadcn/ui (LLM 키는 서버 전용 코드에만) | `apps/web` |
| DB·인증·파일 | Supabase 셀프 호스팅 (Postgres · RLS · Auth · Storage · Realtime · Vault · Queues) | `supabase/` |
| 영상 워커 | FFmpeg 워커 컨테이너 (언어는 `docs/planning.md#17-2` D4 ADR에서 확정) | `apps/worker` |
| 인프라 | Docker Compose, 개발·운영 동일 구성 (`docs/planning.md#17-10`) | `docker/` |
| 수집 | 사용자 로그인 브라우저 확장 | `apps/extension` |
| 설치형 앱 (웹 완성 후) | Tauri(데스크톱) · Capacitor(모바일), 운영 웹을 여는 셸 (`docs/planning.md#17-2` D11) | `apps/desktop` · `apps/mobile` |

## 3. 명령 (앱 생성 후 유효)
| 목적 | 명령 |
|---|---|
| 설치 | `pnpm install` |
| 개발 서버 | `pnpm dev` |
| 린트 · 타입 | `pnpm lint` · `pnpm typecheck` |
| 테스트 | `pnpm test` |
| DB 초기화 · 타입 | `supabase db reset` · `supabase gen types typescript --local > apps/web/src/types/db.ts` |
| ERD 갱신 | `~/.claude/nomad/bin/sql2erd supabase/migrations -o docs/diagrams/erd.mmd` |
긴 출력 명령은 `~/.claude/nomad/bin/q <명령>`으로 실행한다.

## 4. 절대 규칙 (위반 = 리뷰 🔴)
- 비밀(API 키 · service_role · 결제 키)은 저장소·클라이언트 번들·로그에 넣지 않는다. `.env.example`에 이름만.
- 모든 테이블 RLS. 적용된 마이그레이션 파일은 수정하지 않고 새 번호 파일로 추가한다.
- 금액은 정수(원). 결제·차감 요청에는 멱등 키.
- UI는 반응형 3구간(~767 / 768~1199 / 1200~), 색·크기는 토큰만(hex·px 직접 금지).
- 문서·커밋·화면 문구는 한국어, 코드 식별자는 영어.
- 새 의존성은 `secscan license`로 확인(GPL·AGPL 거부). 보안 레벨 `docs/planning.md#17-8`.
- 화면 구조(GNB · 제작단계 · 제작 파트너 팝업)와 토큰은 `docs/design.md`와 `design/prototype/`가 정본이다. 사용자 승인 없이 바꾸지 않는다.
- 단계는 승인해야 다음으로 넘어간다. 승인 · 발행 · 권리 확인은 사용자만 할 수 있고, AI는 도구 호출로만 데이터를 바꾼다.
- 1 프로젝트 = 1 채널. 같은 영상을 다른 채널에 다시 올리는 기능은 만들지 않는다.
- 원본마다 URL · 작성자 · 수집 시각을 기록한다. 정책 점검 6항목을 통과하기 전에는 발행할 수 없고, 워터마크 제거는 권리를 확인한 원본에만 허용한다.
- 플랫폼 연결은 공식 OAuth만 쓰고 비밀번호는 저장하지 않는다. 사용자 API 키 · OAuth 토큰은 Vault에 두고 원문을 브라우저로 돌려주지 않는다.

## 5. 문서 지도 (필요한 장만 읽는다)
| 문서 | 내용 |
|---|---|
| `docs/00_LEAN.md` | 린 검증 게이트 (통과 전 W1~W6 보류) |
| `docs/planning.md` | 기능 · 데이터 · 리스크 · 로드맵 (17장: 구현 전 보강 명세 · 확정 결정) |
| `docs/03_SCREENS_UX.md` · `design/spec.json` | 화면 표 S-01~S-16 · 화면별 사양(`spec <ID>`로 조회) |
| `docs/diagrams/*.mmd` | 구조도 · 흐름도 · ERD (Mermaid) |
| `docs/design.md` · `design/prototype/` | 디자인 시안 · 토큰 (`apps/web` 생성 후 토큰 파일이 정답) |
| `docs/ui-feedback.md` | 토스트·스낵바·대화상자 등 피드백 패턴 사용 기준 |
| `tasks/README.md` · `tasks/NOW.md` | 작업 표 · 현재 상태 |

## 6. 작업 방식
작업은 `tasks/README.md`의 순서대로 하나씩. 작업 파일의 "근거"와 "하지 않을 것"을 지키고, 완료 조건을 실행으로 확인한 뒤 커밋한다.
커밋: `[task-NNN] 요약` + 본문(무엇을 · 확인 방법).

## 7. 영역 규칙 · 도구별 로드 (규칙 정본은 `.claude/rules/` 한 곳)
아래 경로의 파일을 만들거나 고치기 **전에** 해당 규칙 파일을 읽는다. Claude Code는 `paths:` 조건으로 자동 로드하므로 다시 읽지 않는다.
| 작업 경로 | 규칙 파일 |
|---|---|
| `apps/web/**` | `.claude/rules/web.md` |
| `supabase/**` | `.claude/rules/db.md` |
| `docs/**` | `.claude/rules/docs.md` |
- 읽지 않는 파일: `.env*` · lock 파일 · `node_modules/` · `.next/` · `dist/` · `build/` · `coverage/` (Claude는 `.claude/settings.json`, Gemini는 `.geminiignore`가 강제, ChatGPT Codex는 이 줄로 지킨다).
- 도구별 설정: Claude Code `CLAUDE.md`·`.claude/` · ChatGPT Codex `.codex/config.toml` · Gemini CLI `.gemini/settings.json`·`.geminiignore`.
- 새 규칙 파일을 추가하면 이 표에도 한 줄 추가한다.

## 8. Codex 네이티브 팀
- 주 모델은 gpt-6.1-sol, 부 모델은 사용자가 확인한 지원 ID로만 지정한다. 초기 설정은 비활성이다.
- `nomad-os codex init . --worker-model <ID>` 적용 후 새 세션에서 시작하고 `nomad-os codex check .`로 검사한다.
- nomad_scout/designer/builder/tester/reviewer, 부 작업 최대 3개·깊이 1. 소유 파일을 명시하고 타인의 변경을 되돌리지 않는다.
- 설정 검사와 실제 모델 실행은 별개다. 운영 지침: NOMAD `global/nomad/CODEX_TEAM.md`.
