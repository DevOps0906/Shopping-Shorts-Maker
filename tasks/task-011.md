# task-011 마이그레이션2 제작·jobs·credit_ledger·발행·성과·비공개 버킷

| 항목 | 내용 |
|---|---|
| 웨이브 | W2 |
| 선행 | task-010 |
| 위험도 | 높음 |
| 보안 영향 | 민감 데이터(원본·음성), 키·권한(RLS·버킷 정책) |
| 담당 | builder |
| 근거 | `docs/05_DATA_MODEL.md`, `docs/planning.md#6`, `docs/planning.md#17-4`, `docs/planning.md#17-5`, `docs/planning.md#17-8` |
| 쓰기 허용 | `supabase/migrations/**`, `apps/web/src/types/db.ts`, `docs/diagrams/erd.mmd` |

## 할 것
- 단계 산출물(소재·원본·대본·음성·렌더)·jobs(idempotency_key·attempts·max_attempts·payload)·credit_ledger(정수)·발행·성과·bio_items·link_clicks
- 원본 행: URL·작성자·수집 시각·권리 근거·확인자·삭제 예정일
- 원본·음성·MP4 버킷 비공개(서명 URL만), link_clicks 서버 쓰기 전용

## 하지 않을 것
- task-010 마이그레이션 파일 수정
- 결제 테이블(3단계 후보)

## 완료 조건 (실행 가능한 확인)
- [x] `supabase db reset` 성공(migrate.sh reset)
- [x] RLS·버킷 테스트: 타인 원본 객체 다운로드 거부, anon의 link_clicks 읽기 0행
- [x] `pnpm typecheck` 통과, ERD `mmd-check` 통과(db.ts·ERD는 task-012와 함께 커밋)
