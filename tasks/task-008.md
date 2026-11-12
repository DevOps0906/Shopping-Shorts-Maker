# task-008 프로젝트 생성·토큰·3구간·대시보드 셸·라우트(+ /secure setup)

| 항목 | 내용 |
|---|---|
| 웨이브 | W2 |
| 선행 | task-005 |
| 위험도 | 높음 |
| 보안 영향 | 의존성(새 앱·패키지 일괄 도입) |
| 담당 | builder |
| 근거 | `AGENTS.md#2`, `AGENTS.md#4`, `docs/design.md#2`~`#4`, `docs/design.md#8`, spec S-01~S-16 공통 셸 |
| 쓰기 허용 | `apps/web/**`, `package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `.env.example`, `.github/**` |

## 할 것
- pnpm 워크스페이스 + `apps/web`(AGENTS.md 2장 스택, 작업 시점 최신 stable 확인 후 고정)
- 토큰을 Tailwind `@theme`로, 폰트 3구간 `--fs-*` 미디어 쿼리
- `(dashboard)/layout.tsx`에 고정 GNB + `ChatFab` 자리, 라우트 8개(design.md 8장) 빈 페이지
- `/secure setup`(보안 레벨 L1: lockfile·비밀 스캔·의존성 점검)

## 하지 않을 것
- 화면 내용·데이터 연동, 인증(task-009)
- Dockerfile·compose 등 Docker 관련 일체(task-030)
- 토큰 값·GNB 구조 변경

## 완료 조건 (실행 가능한 확인)
- [x] `pnpm lint` · `pnpm typecheck` 통과
- [x] `secscan license` GPL·AGPL 0건(secscan 판정 불가 → pnpm licenses로 확인, LGPL-3.0 sharp 1건), `token-audit` hex·px 직접 사용 0건(tokens.css 제외)
- [x] 375·767·768·1024·1440 `shot`으로 GNB 3구간 확인(경계 767/768 포함)
