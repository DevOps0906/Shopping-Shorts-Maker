# Shorts 운영 DB 전환 절차 (public → nomad_shorts, org안)

옛 `public`·`private` 스키마(legacy-migrations 59개)의 운영 데이터를 nomad 공용 DB 구조(`nomad_core` + `nomad_shorts`·`nomad_shorts_private`)로 옮기는 1회 절차다. 스키마는 `supabase/migrations/`로만 push하고, 데이터 복사는 사람이 `supabase/nomad-cutover/` 스크립트로 실행한다.
표별 대응·플랜 대응·제외 규칙의 정본: nomad-supabase-module `products/shorts/existing.md` "운영 데이터 이관".

## 파일
| 파일 | 내용 |
|---|---|
| `01_freeze.sql` / `01_freeze_undo.sql` | 옛 표 쓰기·옛 RPC 실행 회수, 옛 cron 3개 unschedule, 옛 가입 트리거 함수 무력화. 기록은 `nomad_cutover.freeze_state`, undo가 그대로 되돌리고 스키마를 지운다 |
| `01_queue_check.sql` | 옛 pgmq 큐(render·tts·analyze·sources)가 비었는지 확인(읽기만) |
| `02_copy.sql` | 한 트랜잭션 복사. 기본 dry-run(rollback), `-v apply=true`일 때만 commit |
| `03_storage.mjs` | 옛 버킷 → `shorts-*` 버킷 객체 복사(서버 측 copy)와 개수·크기 대조. 기본 dry-run |
| `check.sh` | 일회용 로컬 DB에서 전 과정 검증: `bash supabase/nomad-cutover/check.sh` |

모든 SQL은 `postgres` 역할로 실행한다: `psql "<DB 주소>" -v ON_ERROR_STOP=1 -f <파일>`.

## 순서
1. **백업**: 대시보드에서 PITR 또는 `npx supabase db dump --data-only -f backup_<날짜>.sql`(+ 스키마 dump). 백업 파일은 이 저장소에 넣지 않는다.
2. **노출 스키마 추가(앱 배포 전)**: 대시보드 Settings → API → Exposed schemas에 `nomad_shorts` 추가. `nomad_core`, `nomad_shorts_private`, `nomad_cutover`는 노출하지 않는다.
3. **점검 모드 + freeze**: 앱을 점검 모드로 전환(사용자 쓰기 중지 공지) → `01_freeze.sql`.
   - 워커는 계속 돌려 옛 큐를 비운다(freeze는 worker_role을 막지 않는다). `01_queue_check.sql`이 통과할 때까지 기다렸다가 다시 실행한다. 메시지는 옮기지 않는다(사용자 결정 3).
   - 통과하면 옛 워커를 멈춘다.
4. **마이그레이션 이력 정리**: 옛 버전 59개를 reverted로 표시한다(이력 표만 바뀐다. 표·데이터는 그대로).
   `npx supabase migration repair --status reverted $(ls supabase/legacy-migrations | cut -d_ -f1 | tr '\n' ' ')`
5. **스키마 push**: `npx supabase db push --dry-run`으로 새 파일 22개만 나오는지 확인 → `npx supabase db push`. 이때 기존 사용자에게 개인 조직이 백필된다.
6. **02 dry-run → apply**: `02_copy.sql` → 통과 메시지 확인 → `psql … -v apply=true -f supabase/nomad-cutover/02_copy.sql`.
   시작 검사(새 표 비어 있음, 옛 큐 비어 있음, 익명 소유 행 0, 개인 조직 없는 사용자 0, 경로 형식) 중 하나라도 어긋나면 아무것도 바꾸지 않고 중단한다. 익명 소유 행은 건수만 보고된다. 지우지 말고 팀장 판단을 받는다(사용자 결정 2).
7. **03 스토리지**: 대응표를 만든 뒤 dry-run → `--apply`(복사 후 대조까지 한다). 키는 환경 변수로만 넘긴다.
   ```
   psql "<DB 주소>" -c "\copy (select o.created_by, o.id from nomad_core.organizations o join nomad_core.memberships m on m.organization_id = o.id and m.user_id = o.created_by and m.role = 'owner' where o.kind = 'personal' order by 1) to 'user_org.csv' csv"
   SUPABASE_URL=… SUPABASE_SERVICE_ROLE_KEY=… node supabase/nomad-cutover/03_storage.mjs --map user_org.csv
   SUPABASE_URL=… SUPABASE_SERVICE_ROLE_KEY=… node supabase/nomad-cutover/03_storage.mjs --map user_org.csv --apply
   ```
   02가 DB 경로를 이미 `<organization_id>/<project_id>/…`로 바꿨으므로 **03이 끝나기 전에는 새 앱을 열지 않는다**. `user_org.csv`는 끝나면 지운다.
8. **새 앱·워커 배포와 확인**: 웹(스키마 `nomad_shorts`), 워커(`nomad_shorts_private.`, 큐 `shorts_*`), 버킷 `shorts-*`. 확인할 것: 로그인 → 내 프로젝트 목록·미리보기 재생, 다른 계정 데이터가 안 보임, 새 작업 1건 생성·완료, 크레딧 잔액이 옛 값과 같음.
9. **쓰기 재개(점검 해제) = 되돌릴 수 없는 지점.** 이후 새 표에 쓰인 데이터는 옛 표에 없으므로 아래 되돌리기를 쓸 수 없다. 재개 뒤 문제가 생기면 앞으로 고치는 수정으로 대응한다.
10. **정리(안정화 후)**: `drop schema nomad_cutover cascade;`(필요하면 먼저 dump). 옛 표·옛 버킷·옛 함수는 이 절차에서 지우지 않는다.

## 되돌리기 (9번 쓰기 재개 전까지만)
- **02 apply 전**: `01_freeze_undo.sql` → 옛 워커·앱 재개. push된 새 스키마는 남겨도 옛 앱에 영향이 없다(새 cron `shorts_*`는 빈 새 표만 다룬다).
- **02 apply 후**: 새 표를 먼저 비우고 undo한다. `profiles.display_name` 갱신과 `shorts-*` 버킷에 복사된 객체는 남아도 옛 앱에 영향이 없다.
  ```
  select format('truncate %s;', string_agg(format('%I.%I', schemaname, tablename), ', '))
  from pg_tables where schemaname in ('nomad_shorts', 'nomad_shorts_private') \gexec
  ```
  그 다음 `01_freeze_undo.sql`. undo는 권한·cron·가입 트리거 함수가 freeze 기록과 같아졌는지 확인하고 다르면 중단한다.
- 다시 시도할 때는 3번(freeze)부터 한다. 4·5번은 이미 끝났으므로 건너뛴다.

## 주의
- **Vault 비밀 공유**: `accounts.oauth_token_ref`·`api_keys.secret_ref`는 옛 행과 새 행이 같은 Vault 비밀을 가리킨다. 옛 표의 삭제 트리거(`accounts_vault_cleanup`·`api_keys_vault_cleanup`)가 비밀을 지우므로, 나중에 옛 표를 정리할 때는 옛 트리거를 먼저 없앤다. 사용자 탈퇴 시 옛 행이 cascade로 지워지면서 비밀도 지워지는 것은 새 행도 같이 사라지는 경우라 문제없다.
- **push와 02 사이**: 02는 새 표가 하나라도 비어 있지 않으면 중단한다. 새 cron `shorts_collect_metrics`(매일 00:30 UTC)가 `nomad_shorts_private.metrics_runs`에 행을 만들 수 있으므로 5~6번을 그 전에 끝낸다. 넘겼다면 그 행을 확인하고 지운 뒤 02를 실행한다.
- **가입 트리거**: `auth.users`의 소유자가 아니면 트리거를 disable할 수 없다. 그래서 freeze는 트리거 함수 `private.handle_new_user()`의 본문을 아무것도 하지 않는 본문으로 바꾸고, undo가 원래 정의로 되돌린다.
- **끝나지 않은 옛 작업**: `waiting_extension` 등은 상태 그대로 복사되고, 새 `sweep_jobs`가 시간 초과·환불을 처리한다. `jobs.payload` 같은 jsonb 안 값은 바꾸지 않는다.
- **옮기지 않는 값**: `user_profiles.email`(정본은 `auth.users.email`), 옛 pgmq 메시지, 옛 cron 정의(새 마이그레이션이 `shorts_*`로 만든다).
- **플랜**: 옛 스키마에는 플랜 열이 없다. `nomad_core.subscriptions` 행을 만들지 않으며, 구독이 없는 조직은 C 플랜으로 동작한다.
