# task-010 마이그레이션1 사용자·채널·프로젝트·카테고리·trend_items·이벤트

| 항목 | 내용 |
|---|---|
| 웨이브 | W2 |
| 선행 | task-006, task-009, task-030 |
| 위험도 | 높음 |
| 보안 영향 | 민감 데이터, 키·권한(RLS) |
| 담당 | builder (+ intern: 카테고리·트렌드 시드) |
| 근거 | `docs/05_DATA_MODEL.md`, `docs/planning.md#11`, `docs/planning.md#12`, `docs/planning.md#17-4` |
| 쓰기 허용 | `supabase/migrations/**`, `supabase/seed.sql`, `apps/web/src/types/db.ts`, `docs/diagrams/erd.mmd` |

## 할 것
- 프로필·accounts(target 포함)·projects(account_id·category_id·status·target_sec)·categories·trend_items·project_events
- 모든 테이블 RLS, categories·trend_items는 로그인 읽기 전용
- 카테고리(11장)·트렌드 시드

## 하지 않을 것
- 제작·jobs·발행 테이블(task-011)
- 적용된 마이그레이션 수정(새 번호 파일로만)

## 완료 조건 (실행 가능한 확인)
- [x] `supabase db reset` 성공(셀프 호스팅이라 `MIGRATE_ALLOW_RESET=1 sh docker/migrate.sh reset`으로 대체)
- [x] RLS 테스트: 다른 사용자의 projects 읽기·쓰기 0행
- [x] `supabase gen types` 후 `pnpm typecheck` 통과, `sql2erd` 갱신 후 `mmd-check` 통과
