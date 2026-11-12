# task-015a 확장 수집 DB: 3단계 작업·전이 정본·claim·수집 입력 검증

| 항목 | 내용 |
|---|---|
| 웨이브 | W3 |
| 선행 | task-012, task-016 |
| 위험도 | 높음 |
| 보안 영향 | 노출 면(확장 입력이 DB에 닿는 경로), 키·권한(claim 소유권) |
| 담당 | builder → codex-reviewer(code) + reviewer(security) |
| 근거 | `docs/adr/0003-extension-server-auth.md#보강(2026-11-12)` ①②③⑤, `docs/planning.md#17-5`, 기존 `supabase/migrations/20261112180200_job_sweeper.sql`·`20261112210200_source_hardening.sql`(add_direct_source·has_unsafe_chars) |
| 쓰기 허용 | `supabase/migrations/<새 번호>_extension_collect.sql`, `supabase/tests/extension_collect.sql`, `docs/diagrams/erd.mmd`(sql2erd), `apps/web/src/types/db.ts`(재생성만) |

## 할 것
- 작업 종류: `collect`(목록·썸네일) 유지 + `collect_download`(체크 10편 파일) 추가 — 시간 상한·큐 매핑 함수에 행 추가
- `jobs.waiting_since timestamptz` 추가: `waiting_extension` 진입마다 now()
- `sweep_jobs` 교체(create or replace): 하트비트 2분 끊김 → `running`→`waiting_extension`(진행분 보존, `extension_id` null, `waiting_since`=now()) · 24시간은 `waiting_since` 기준 → `failed`. 수집 15분 상한 기준(최초 claim부터 누적 vs claim마다)은 `팀장 결정 필요`
- claim 함수: 원자적 갱신 + 조건 `확장.user_id = 프로젝트 소유자` · `revoked_at is null` · `status='waiting_extension'`
- 하트비트 함수: `last_heartbeat_at` 갱신 + 그 사용자의 대기 수집 job 1건(id·type·payload)을 응답으로 반환
- 수집 입력 함수(목록·다운로드 완료) — 위조 방지(🔴5):
  - platform은 **서버가 정규화한 URL의 호스트로 결정**(입력 platform 무시), 플랫폼 호스트가 아니면 거부(`direct` 불가)
  - URL 정규화: 소문자 호스트·쿼리·조각 제거·userinfo(@) 거부. 정규형 경로는 구현 시 실측 후 확정, 같은 프로젝트 중복 거부
  - `collected_at` = 서버 now()(입력 무시) · 틱톡은 URL의 `@handle` = author(대소문자 무시) 아니면 거부
  - add_direct_source와 같은 검사 재사용: `private.has_unsafe_chars`, author 1~100자, title ≤200자, URL ≤2000자, 프로젝트당 100편
  - 필드 허용 목록 밖 키가 있으면 거부(jsonb 키 검사). 한 번에 받는 행 수 상한 = 4장 회차당 60편 안팎(정확한 값 `팀장 결정 필요`)
- `sources.thumbnail_path` 추가, 다운로드 파일은 job의 체크된 행에만 `file_path` 기록
- 버킷: 수집 파일 상한을 ADR(200MB 가설)·`sources` 버킷(500MiB) 중 하나로 통일(`팀장 결정 필요`), 썸네일 버킷(image/jpeg·webp, 상한 `팀장 결정 필요`) 신설
- 미선정 원본의 썸네일 보존 기간 `팀장 결정 필요`(현재 purge_after = 수집 + 30일)

## 하지 않을 것
- 적용된 마이그레이션 수정(새 파일만), 권리 열(`rights_*`) 변경, 반응 지표 열 추가(점수표 반응 10% 저장 여부는 `팀장 결정 필요`)

## 완료 조건 (실행 가능한 확인)
- [x] `supabase db reset` 후 `supabase/tests/extension_collect.sql` 통과: 하트비트 끊김 → waiting_extension(진행분 행 유지) · waiting_since 24시간 → failed · 재claim → running
- [x] claim: 남의 job·폐기된 확장·이미 running → 0행
- [x] 수집 입력: 호스트 위장 platform·userinfo URL·handle 불일치·제어/양방향 문자·허용 외 키·과다 행 → 거부, collected_at은 서버 시각, 3필드(URL·작성자·수집 시각) 누락 0건
- [x] 모든 새 함수 anon·authenticated 실행 권한 없음, 새 테이블·열 RLS 유지, `sql2erd` 갱신


## 후속(2026-11-12 보안 재리뷰 🟡)
- 직접 추가(add_direct_source, 원문 URL 비교)와 수집 경로(정규화 URL 비교)의 중복 판정이 달라 같은 영상이 두 행으로 들어갈 수 있다 → 새 마이그레이션에서 두 경로 정규화 통일·기존 충돌 정리·프로젝트별 유일 인덱스(015b 착수 전)
