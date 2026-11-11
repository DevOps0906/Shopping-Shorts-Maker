# task-009 Supabase Auth·로그인·세션

| 항목 | 내용 |
|---|---|
| 웨이브 | W2 |
| 선행 | task-008, task-030 |
| 위험도 | 높음 |
| 보안 영향 | 노출 면(로그인), 키·권한(세션·service_role) |
| 담당 | builder |
| 근거 | `docs/planning.md#13`, `docs/planning.md#17-8`, `AGENTS.md#4` |
| 쓰기 허용 | `apps/web/src/app/(auth)/**`, `apps/web/src/lib/supabase/**`, `apps/web/src/middleware.ts`, `supabase/config.toml`, `.env.example` |

## 할 것
- Supabase Auth 로그인·로그아웃, 서버 컴포넌트용·브라우저용 클라이언트 분리
- `(dashboard)` 라우트 비로그인 접근 시 로그인으로 이동
- service_role 키는 서버 전용 모듈에서만 import

## 하지 않을 것
- 플랫폼 계정 OAuth(task-022), 테이블 생성(task-010)
- 비밀번호 정책·소셜 로그인 공급자 추가(팀장 결정 필요)

## 완료 조건 (실행 가능한 확인)
- [ ] `pnpm typecheck` · `pnpm test` 통과(비로그인 리다이렉트 테스트 포함)
- [ ] `pnpm build` 후 클라이언트 번들에서 service_role 키 이름 검색 0건
- [ ] 위협 메모 표(로그인 노출 면) 작업 보고에 첨부
