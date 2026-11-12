# task-018 01 소재·03 대본: LLM·ScriptEditor·금지 표현

| 항목 | 내용 |
|---|---|
| 웨이브 | W3 |
| 선행 | task-013 |
| 위험도 | 높음 |
| 보안 영향 | 키·권한(LLM 키 서버 전용), 노출 면(외부 글 프롬프트 주입) |
| 담당 | builder |
| 근거 | spec S-06, S-08, `docs/planning.md#3`(01 소재·03 대본), `docs/planning.md#7`, `docs/planning.md#17-6`, `docs/planning.md#17-7` |
| 쓰기 허용 | `apps/web/src/app/(dashboard)/studio/[projectId]/[step]/{topic,script}/**`, `apps/web/src/components/{topic,script}/**`, `apps/web/src/lib/llm/**` |

## 할 것
- 01 소재: 제품 힌트·카테고리 → 후보 3개, 0개·사진 인식 실패 시 "제품명 직접 입력"
- 03 대본: 체크된 원본 기반 초안, ScriptEditor 직접 수정, 금지 표현 문장 표시
- 외부 글(영상 제목·작성자명)은 데이터로만 넣고 지시로 실행하지 않음
- LLM 호출은 서버 코드에서만

## 하지 않을 것
- 금지 표현 목록 새로 정의(기획 문서 목록만, 없으면 팀장 결정 필요)
- 승인 자동화

## 완료 조건 (실행 가능한 확인)
- [x] 테스트: 금지 표현 포함 대본 → 해당 문장 표시
- [x] 테스트: 제목에 지시문 주입 시 도구 호출·상태 변경 0건
- [x] `pnpm build` 클라이언트 번들 LLM 키 이름 0건, `pnpm typecheck` 통과
