# task-019 04 목소리: Fish Audio·VoicePicker·녹음·단어 타이밍

| 항목 | 내용 |
|---|---|
| 웨이브 | W3 |
| 선행 | task-012, task-013 |
| 위험도 | 높음 |
| 보안 영향 | 키·권한(Fish Audio 키), 민감 데이터(사용자 목소리 녹음) |
| 담당 | builder |
| 근거 | spec S-09, `docs/planning.md#3`(04 목소리), `docs/planning.md#7`, `docs/planning.md#17-5`, `docs/planning.md#17-6` |
| 쓰기 허용 | `apps/web/src/app/(dashboard)/studio/[projectId]/[step]/voice/**`, `apps/web/src/components/voice/**`, `apps/worker/src/voice/**` |

## 할 것
- VoicePicker: task-003에서 확정한 한국어 목소리 6종, 승인 대본 → voice_takes job
- 직접 녹음·업로드(비공개 버킷), 형식 오류 안내
- 자막용 단어 타이밍 저장
- 공급자 오류를 사용자 문구로 변환, 시간 제한(가설 2분)

## 하지 않을 것
- 목소리 복제·새 공급자 추가
- 녹음 파일 공개 URL

## 완료 조건 (실행 가능한 확인)
- [ ] 공급자 목(mock) 테스트: 성공 시 settle, 오류 시 release + 사용자 문구
- [ ] 단어 타이밍이 대본 단어 수와 맞는지 테스트
- [ ] `spec S-09` 렌더 테스트, `pnpm typecheck` 통과
