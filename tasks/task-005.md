# task-005 ADR: Supabase Queues·워커 언어·확장 통신·셀프 호스팅 구성

| 항목 | 내용 |
|---|---|
| 웨이브 | W1 |
| 선행 | task-004 |
| 위험도 | 높음 |
| 보안 영향 | 의존성, 노출 면(확장↔서버 통신) |
| 담당 | planner (+ challenger 착수 전 공격) |
| 근거 | `docs/planning.md#7`, `docs/planning.md#17-2`(D2·D4·D6), `docs/planning.md#17-5`, `docs/planning.md#17-8`, `docs/planning.md#17-10`, `AGENTS.md#2` |
| 쓰기 허용 | `docs/adr/0001-*.md`~`docs/adr/0004-*.md` |

## 할 것
- ADR 5건(각 25줄 이내): ① 큐 = Supabase Queues 1순위 vs 대안 ② Docker FFmpeg 워커 컨테이너 언어 ③ 확장↔서버 인증·통신 방식 ④ 셀프 호스팅 구성(Supabase 공식 compose·웹·워커·리버스 프록시, Studio 내부망 전용) ⑤ 설치형 앱 셸 방식(Tauri·Capacitor: 원격 URL vs 정적 번들, 인증 세션·딥링크·파일 업로드·마이크 권한, 웹 구현에서 미리 지킬 제약)(`docs/planning.md#17-2` D11)
- ④에 이미지 버전 고정(태그·digest) 방침, 셀프 호스팅 이미지에서 Queues(pgmq)·Vault 확장 동작 확인 결과(미확인이면 대안)
- 각 ADR에 최신 stable 버전, 라이선스(GPL·AGPL 거부), 위협 메모 표(확장 통신)
- `waiting_extension` 상태 전이 조건을 ③에 명시

## 하지 않을 것
- 코드·마이그레이션 작성
- 공급자 추가(Trigger.dev 등)는 대안 비교로만

## 완료 조건 (실행 가능한 확인)
- [ ] ADR 4개 파일 존재, 각 25줄 이하
- [ ] ④에 `select * from pg_extension where extname in ('pgmq','supabase_vault')` 결과(셀프 호스팅 이미지) 기록
- [ ] 다이어그램 필요 시 요청만 기록 → diagrammer 후 `mmd-check` 통과
