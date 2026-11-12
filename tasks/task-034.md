# task-034 채널 수 한도: 요금제 포함 채널·연결 시 한도 검사·해제 시 슬롯 반환(D14)

| 항목 | 내용 |
|---|---|
| 웨이브 | W4 (결제 연동 부분은 로드맵 3단계 유료 전환, P1 결제 작업으로 넘김) |
| 선행 | task-022(022a YouTube OAuth), task-011 |
| 위험도 | 높음 |
| 보안 영향 | 노출 면(OAuth 콜백) · 키·권한(SECURITY DEFINER 함수) · 결제 정보(요금제) |
| 담당 | builder (변경 후 codex-reviewer code + reviewer security/contract) |
| 근거 | `docs/planning.md#12`(채널 수 한도와 추가 요금), `docs/planning.md#9`(수익 모델 표), `docs/planning.md#17-2` D14, `docs/05_DATA_MODEL.md#3`(accounts·projects), `supabase/migrations/20261112270000_youtube_oauth.sql`(oauth_state_create·youtube_save_connection·youtube_clear_token), `docs/ui-feedback.md#2`·`#4` |
| 쓰기 허용 | `supabase/migrations/<새 번호>_channel_slots.sql`, `supabase/tests/channel_slots.sql`, `apps/web/src/server/oauth/**`, `apps/web/src/types/db.ts`(재생성만), `docs/diagrams/erd.mmd`(sql2erd), `docs/05_DATA_MODEL.md`(새 테이블·열 표) |

## 할 것
- plans(읽기 전용, 시드: starter 1 · pro 3 — 가설)·subscriptions(서버만 씀)·accounts.connected_at·channel_slot_events(감사, 서버만 씀·본인 읽기) 신설. 새 테이블 RLS + 정책 + 인덱스 + 코멘트
- 한도 검사 함수(private 본체 + public 래퍼, service_role만 EXECUTE): 슬롯 = 업로드용 accounts 중 토큰 보유 행 수, 한도 = included_channels + extra_channels. 구독 행이 없으면 기본 한도 적용
- `oauth_state_create` 전 사전 검사(웹 서버), `youtube_save_connection`은 새 마이그레이션에서 `create or replace`로 사용자 단위 잠금 뒤 최종 검사 → 초과면 토큰 저장 없이 새 오류 코드로 거부. 이미 연결됨 상태인 계정의 재인증은 슬롯을 늘리지 않으므로 통과
- 초과 채널(다운그레이드·기존 초과): 연결 유지, projects 생성과 publications 새 예약만 DB에서 거부. 남길 순서 = is_default → connected_at
- 연결·해제·한도 거부를 channel_slot_events에 기록(토큰·이메일 원문 X)

## 하지 않을 것
- 결제·구독 변경·추가 요금 청구 흐름(P1 결제 작업). 금액 값 확정(9장 [미정] 유지)
- 1 프로젝트 = 1 채널, projects.account_id 변경 불가 트리거, 022a 전역 1계정 인덱스 변경
- 적용된 마이그레이션 파일 수정
- 화면 변경(S-14 다중 계정 카드의 "채널 N/M개" 표시·초과 배지, "+ 계정 추가" 비활성·안내 문구, 결제 후 추가 요금 알림 대화상자) → **사용자 승인 필요**, 03_SCREENS_UX·design 수정은 승인 뒤 별도 작업

## 위협 메모
| 항목 | 결정 |
|---|---|
| 노출 면 | OAuth 시작·콜백 라우트(로그인 필수). DB 함수는 service_role만 |
| 인가 | 한도는 서버·DB만 판단. 사용자는 plans 읽기만, subscriptions·channel_slot_events 쓰기 불가 |
| 데이터 | 요금제·채널 수. 토큰은 기존대로 Vault, 한도 거부 시 Vault에 넣지 않음 |
| 남용 | 동시 콜백 경쟁 → 사용자 단위 잠금. 연결·해제를 반복해 슬롯을 돌려 쓰는 것 → 월 교체 횟수 제한 여부 팀장 결정 필요 |
| 로그 | 감사 이벤트 O, 토큰·OAuth code·state 원문 X |

## 완료 조건 (실행 가능한 확인)
- [ ] `supabase db reset` 후 `supabase/tests/channel_slots.sql` 통과: 한도 1에서 두 번째 채널 `youtube_save_connection` 거부 + Vault secret 증가 0 + 거부 이벤트 1행
- [ ] 같은 파일: 연결 해제(`youtube_clear_token`) 뒤 슬롯 반환 → 다른 채널 연결 성공. 연결됨 상태 계정의 재인증(토큰 갱신)은 한도가 꽉 차도 통과, 해제했던 채널의 재연결은 한도 검사 대상
- [ ] 같은 파일: 프로젝트-채널 규칙 유지(첫 publication 뒤 account_id 변경 거부, 초과 채널로 projects 생성 거부, 기존 예약 publication 유지)
- [ ] 같은 파일: authenticated가 subscriptions·channel_slot_events에 쓰기 실패, plans 읽기만 성공
- [ ] `supabase/tests/youtube_oauth.sql` 회귀 통과, `pnpm typecheck` 통과, `sql2erd` 갱신
