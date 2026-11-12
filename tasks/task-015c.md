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
