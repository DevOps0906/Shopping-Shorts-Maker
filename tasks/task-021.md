# task-021 제작 파트너: ChatFab·도구 6종(승인·발행·권리 도구 없음)

| 항목 | 내용 |
|---|---|
| 웨이브 | W3 |
| 선행 | task-016, task-018, task-019, task-020 |
| 위험도 | 높음 |
| 보안 영향 | 노출 면(LLM 도구 호출·프롬프트 주입), 키·권한(서버 재검사) |
| 담당 | builder |
| 근거 | spec S-16, `docs/planning.md#5`, `docs/planning.md#17-7`, `docs/design.md#6` |
| 쓰기 허용 | `apps/web/src/components/chat/**`, `apps/web/src/app/api/chat/**`, `apps/web/src/lib/agent-tools/**` |

## 할 것
- ChatFab·ChatPopup(전역), 도구 6종: search_topics·search_sources·draft_script·synthesize_voice·replace_cut·render_mp4
- 도구마다 서버에서 소유권·단계 상태 재검사, 사전 확인(초기화·회차·큰 크레딧)
- draft_script는 제안 + 적용 버튼(적용은 사용자)

## 하지 않을 것
- 승인·발행·권리 확인 도구 추가
- 외부 글 속 지시 실행

## 완료 조건 (실행 가능한 확인)
- [x] 테스트: 도구 목록이 정확히 6개, 승인·발행·권리 이름 0개
- [x] 테스트: 타인 프로젝트 ID로 도구 호출 시 거부
- [x] 위협 메모 표 첨부, `spec S-16` 3구간 `shot` 확인
