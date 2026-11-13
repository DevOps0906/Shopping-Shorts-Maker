# task-015c 확장 수집 워커: 썸네일 기준 점수·다운로드 파일 재검사

| 항목 | 내용 |
|---|---|
| 웨이브 | W3 |
| 선행 | task-015a, task-016 |
| 위험도 | 높음 |
| 보안 영향 | 외부 입력(확장이 올린 이미지·영상) 처리 |
| 담당 | builder → codex-reviewer(code) |
| 근거 | `docs/adr/0003-extension-server-auth.md#보강(2026-11-12)` ①, `docs/planning.md#4`(2차 거르기·점수표), `docs/planning.md#17-2`(D8), ADR-0002(샌드박스 ffprobe) |
| 쓰기 허용 | `apps/worker/worker/sources/**`, `apps/worker/tests/**` |

## 할 것
- `select_sources`가 `file_path`가 없으면 `thumbnail_path`(썸네일 버킷)를 일치도 입력으로 받게 함 — 현재 "목록만 행은 건너뜀"을 바꿈
- 썸네일 단계 점수: 일치도·화질(메타데이터 해상도)·깨끗함만 계산 가능. 동작 장면·첫 1~2초 프레임 항목 처리(가중치 재배분 또는 다운로드 후 재점수)는 `팀장 결정 필요`
- 이미지 입력 검사: 매직 바이트·크기·해상도 상한, 실패 시 격리(기존 quarantined 경로 재사용)
- `collect_download` 업로드 파일은 `succeeded` 전에 샌드박스 ffprobe 재검사(형식·길이·해상도), 실패 파일은 격리·사유 기록, 720p 미만이면 다음 순위 안내(4장 6번)

## 하지 않을 것
- 워터마크 제거·스케일업, worker_role에 sources 직접 쓰기 권한 추가(함수 경유 유지)

## 완료 조건 (실행 가능한 확인)
- [ ] `~/.claude/nomad/bin/q pytest apps/worker/tests` 통과
- [ ] 썸네일만 있는 후보 20편 이상 → 점수·상위 20편 저장 테스트
- [ ] 위장 이미지(확장자만 jpg)·초대형 이미지·위장 영상 → 격리 테스트, 다른 사용자 경로 → 거부

## 팀장 결정 (2026-11-14, challenger REVISE 반영)
- **분할**: 015c-1 썸네일 점수(지금) · 015c-2 다운로드 재검사(015b 완료 보고 경로가 생긴 뒤). 015c-2는 확장 완료 보고 → collect_download를 워커 큐로 넘겨 ffprobe 재검사 후 succeeded/failed(새 작업 종류 vs 큐 이관은 그때 비용 비교), 검사한 file_path 값에 결과를 묶고, 검증 전 원본은 승인 편수·편집 입력에서 제외
- **720p 미만(잠정, 사용자 확인)**: 자동 교체 안 함(D1 체크는 사용자만). 격리하지 않고 "사용 제외 + 다음 순위 안내"만
- **015c-1 쓰기 범위 확장**: `supabase/migrations/<새 번호>_*.sql`·`supabase/tests/**`·`apps/web/src/types/db.ts` 추가
- 썸네일 점수: 같은 공식(일치도 40·화질 20)/60. 파일 없는 후보의 화질은 0.7(720p 가정 — 1차 거르기 통과분, 실제 화질은 015c-2에서 재확인)
- 썸네일 입력: jpeg·webp만, 512KiB 상한(버킷과 같게), 해상도 상한 4096. 위장 형식만 `quarantined:true`, 썸네일 없음·삭제됨(thumbnail_deleted_at)·시간 초과·크기 초과는 `quarantined:false` 명시 + 사유
- 썸네일 루트는 원본과 다른 디렉터리(`WORKER_THUMB_DIR`), 같은 `<user>/<project>/` prefix·resolve 규칙
- **격리 기준 확정(리뷰 반영, 위 줄보다 우선)**: 격리(true) = 형식 위장·허용 외 형식·경로 오류·읽기 실패(손상)·해상도 4096 초과(기존 원본 격리 기준과 같음). 격리 아님(false) = 썸네일 없음·삭제됨·시간 초과·512KiB 초과. 워커는 항상 true/false를 명시. 저장 함수는 격리를 내리지 않는다(true → false 금지, 새 번호 마이그레이션)
- 015c-2 주의: Storage 내려받기는 임시 파일 → 원자적 rename(TOCTOU)
