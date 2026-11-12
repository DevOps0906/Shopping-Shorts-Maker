# 05 데이터 모델 · RLS

> 근거: [planning#6](./planning.md#6-상태-머신과-데이터-모델) · [#12](./planning.md#12-다중-계정과-채널-전략) · [#17-4](./planning.md#17-4-데이터-모델-보강) · [#17-5](./planning.md#17-5-작업-수명주기와-크레딧-정산) · [#17-8](./planning.md#17-8-보안과-개인정보) · [#17-2](./planning.md#17-2-확정된-결정)(D1·D5·D7·D8) · [ADR-0001](./adr/0001-job-queue-supabase-queues.md) · [ADR-0003](./adr/0003-extension-server-auth.md)
> ERD: 마이그레이션(task-010·011) 뒤 `sql2erd`로 `diagrams/erd.mmd` 생성. 현재는 초안 [erd-draft.mmd](./diagrams/erd-draft.mmd)만 있다. SQL은 이 문서에 쓰지 않는다.
> `channel_cards`는 폐기(accounts로 통합, 17-4).

## 1. 공통 규칙
| 규칙 | 내용 |
|---|---|
| RLS | 모든 테이블 RLS 켬. 정책 없는 테이블 = 아무도 못 읽음 |
| 소유자 판정 | `user_id = auth.uid()` 또는 `project_id → projects.user_id` / `account_id → accounts.user_id` 경로 |
| 금액·크레딧 | 정수(원·크레딧). 소수 금지 |
| 멱등 | `jobs.idempotency_key`·`credit_ledger.idempotency_key` unique, `credit_ledger` unique(job_id, kind) |
| 비밀 | API 키·OAuth 토큰은 Vault에만. 테이블에는 Vault secret id(`*_ref`)만, 브라우저로 원문 반환 금지 |
| 확장 토큰 | 해시만 저장(액세스 15분 · 갱신 30일, 갱신 시 회전) |
| 큐 | `pgmq` 스키마는 PostgREST 노출 금지. 브라우저는 jobs를 직접 만들지 않음(행 삽입 + `pgmq.send` 한 트랜잭션은 서버) |
| 서버 쓰기 주체 | 잠정(2026-11-12, 사용자 확인 전): "서버" = Next.js 서버 전용 코드의 service_role(RLS 우회, 클라이언트 번들·로그 금지). "워커" = ADR-0001 전용 DB 역할(service_role 아님). 2절에서 두 주체를 구분 표기 |
| 함수 전용 열 | 잠정(2026-11-12, 사용자 확인 전): 단계 승인·권리 확인·발행 열은 authenticated 역할의 열 단위 UPDATE를 REVOKE하고, 사용자가 직접 누른 요청을 받는 Route Handler만 호출하는 SECURITY DEFINER 함수로만 바꾼다. AI 제작 파트너 도구(17-7)에는 이 함수를 부르는 도구가 없어 바꿀 수 없다. 표에 **함수 전용**으로 표시 |
| INSERT 차단 | 함수 전용 열과 서버(SR) 전용 열(예: projects.step_status·current_step, scripts.approved_at, accounts.oauth_token_ref·status, sources 권리 열)은 authenticated의 열 단위 **INSERT·UPDATE GRANT를 모두 REVOKE**하고, BEFORE INSERT 트리거로 초기값(null·idle 등)을 강제 |
| SECURITY DEFINER 조건 | `set search_path = ''` · 함수 안에서 `auth.uid()` = 소유자 검사(Route Handler는 사용자 세션으로 호출, service_role 호출 금지) · PUBLIC·anon·authenticated EXECUTE REVOKE 후 필요한 역할만 GRANT · PostgREST 비노출 스키마(예: `private`)에 둠 · 호출 경로(잠정): 노출 스키마에 얇은 SECURITY INVOKER 래퍼(`api.*`)를 두고 authenticated에만 EXECUTE GRANT, 래퍼가 `private` 함수를 부른다(`private` 스키마 USAGE·함수 EXECUTE도 authenticated에만, anon 없음). AI 제작 파트너 도구 처리기는 래퍼를 부르지 않는다(17-7 도구 목록에 없음) |
| 열 제외 읽기 | "○○ 제외" 읽기는 열 단위 SELECT GRANT 또는 뷰로 구현. `vault` 스키마·`decrypted_secrets`는 PostgREST에 노출하지 않음 |
| 보관 | 잠정(2026-11-12, 사용자 확인 전): 원본 파일은 발행 + 30일, 미발행 원본은 collected_at + 30일. voice_takes·renders 파일은 발행 + 30일, 미발행이면 마지막 수정 + 30일. 행(출처 기록)은 남김 |

## 2. RLS 요약
주체: **본인** = 소유 사용자(로그인 세션) · **로그인** = 인증 사용자 전체 · **서버(SR)** = Next.js 서버 전용 코드의 service_role · **워커** = ADR-0001 워커 전용 DB 역할(BYPASSRLS 없음, service_role 미사용) · **함수 전용** = 사용자 조작 Route Handler → SECURITY DEFINER 함수만(1절) · **익명** = 비로그인.

| 테이블 | 소유자 경로 | 읽기 | 쓰기 | 워커 역할 |
|---|---|---|---|---|
| projects | user_id | 본인 | 본인(이름 등) · step_status 승인 전이는 **함수 전용** | — |
| topics | project_id | 본인 | 서버(SR, search_topics) · 본인(picked) | — |
| sources | project_id | 본인 | 서버(SR, 확장 업로드·URL 추가 시 소유권 재검사) · 권리 열은 **함수 전용** | — |
| scripts | project_id | 본인 | 본인 · 서버(SR, draft_script 제안) · approved_at은 **함수 전용** | — |
| voice_takes | project_id | 본인 | 서버(SR, 녹음 업로드) | 쓰기(TTS 결과, 확인 필요) |
| renders | project_id | 본인 | 서버(SR) | 쓰기(렌더 결과, 확인 필요) |
| chat_messages | project_id | 본인 | 본인(WITH CHECK role='user') · 서버(SR, AI 응답) | — |
| jobs | project_id | 본인 | 서버(SR)만(생성·취소·확장 claim) | **쓰기**(상태 조건부 갱신, ADR-0001) |
| credit_ledger | user_id | 본인 | 서버(SR)만 INSERT, 추가 전용(UPDATE·DELETE 없음) | **INSERT만**(settle·release, ADR-0001) |
| project_events | project_id | 본인 | 서버(SR)만(추가) | 쓰기(render_succeeded, 확인 필요) |
| accounts | user_id | 본인(oauth_token_ref 제외) | 본인(채널명·말투 등) · oauth_token_ref·status는 서버(SR)만 | — |
| categories | — (공용) | 로그인 | 서버(SR)만(읽기 전용 테이블) | — |
| trend_items | category_id (공용) | 로그인 | 서버(SR)만(읽기 전용 테이블) | — |
| affiliate_links | project_id | 본인 | 본인(program·disclosed·bio 열) · url·short_url은 서버(SR)만 | — |
| publications | project_id | 본인 | 발행 예약·실행은 **함수 전용**(정책 점검 6/6 확인) · 업로드 결과·재시도는 서버(SR) | — |
| video_metrics | publication_id → project | 본인 | 서버(SR)만(분석 API 수집) | — |
| policy_checks | project_id | 본인 | 서버(SR, 자동 항목) · 사용자 체크 항목은 **함수 전용** | — |
| bio_pages | account_id | 본인 | 본인 | — |
| bio_items | bio_page_id → account | 본인 | 본인 | — |
| link_clicks | affiliate_link_id → affiliate_links → projects.user_id | 본인(affiliate_links 경유) | **서버(SR)만**(익명 클릭을 서버가 기록) | — |
| api_keys | user_id | 본인(last4·status·tested_at만) | 서버(SR)만(원문은 Vault로) | — |
| user_profiles | user_id | 본인 | 본인 | — |
| extension_connections | user_id | 본인(해시 열 제외, 목록·폐기용) | 서버(SR)만(발급·회전·폐기·하트비트) | — |

## 3. 테이블
### projects
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id · user_id | uuid | user_id → auth.users |
| account_id | uuid not null | 복합 FK (account_id, user_id) → accounts(id, user_id). 첫 publication 뒤 변경 불가(트리거). 1 프로젝트 = 1 채널 |
| category_id | uuid → categories | |
| name | text | |
| current_step · step_status | smallint(1~6) · jsonb | 단계 6개 상태(idle·running·suggested·ready·change·approved). **함수 전용** |
| status | text | 진행 중·발행 대기·예약됨·업로드됨 |
| target_sec | smallint | 15·20만 |
| updated_at | timestamptz | |

### topics
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id · project_id | uuid | |
| round | int | 탐색 회차 |
| name · reason | text | 후보명·선정 근거 |
| evidence_urls | text[] | 비슷한 영상 3편 |
| picked | bool | |

### sources (원본)
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id · project_id | uuid | |
| platform | text not null | tiktok·xiaohongshu (직접 추가 값은 확인 필요) |
| url · author · title | text (url·author not null) | 출처 기록 필수, 정책 점검 ① |
| collected_at | timestamptz not null | 수집 시각 |
| width · height · duration_sec · score | int · int · numeric · numeric | |
| file_path | text null | 비공개 버킷. 목록만이면 null(D8) |
| checked · used · exclude_reason | bool · bool · text | checked = 다운로드 대상 10편, used = 편집 사용 5편(D8) |
| rights_basis | text null | `attribution_notice`(D7 출처 표기·고지 확인) · own · seller · licensed(D1). 워터마크 제거는 attribution_notice가 아닌 값만. **함수 전용** |
| rights_confirmed_by · rights_confirmed_at | uuid · timestamptz | 확인자·확인 시각. **함수 전용**(AI 불가) |
| purge_after · file_deleted_at | date · timestamptz | 삭제 예정일 = 발행일 + 30일(D5 가설), 미발행은 collected_at + 30일(1절 보관). 삭제 후 출처 기록만 남김 |

### scripts
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id · project_id | uuid | |
| version | int | |
| lines | jsonb | 문장 배열 |
| est_sec | numeric | 예상 초 |
| approved_at | timestamptz | **함수 전용** |

### voice_takes
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id · project_id | uuid | |
| voice_id | text | |
| source | text | tts·녹음 |
| audio_path | text | 비공개 버킷. 파일 보관은 1절 보관 |
| words · pauses | jsonb | 단어 타이밍·쉼 |
| duration_sec | numeric | |

### renders
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id · project_id | uuid | |
| version | int | V1, V2… |
| cut_map | jsonb | 대사·컷·원본 구간 |
| upscale_status · clean_status | text | clean(워터마크 제거) 작업 생성 함수(서버)가 대상 원본 전부의 rights_basis ∈ (own·seller·licensed)를 검사, attribution_notice(D7)면 거부. 워커가 실행 전 재확인 |
| mp4_path | text | 비공개 버킷, 서명 URL은 웹 서버만 발급. 파일 보관은 1절 보관 |
| created_at | timestamptz | |

### chat_messages
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id · project_id | uuid | |
| role · kind | text | kind = screen·text·ai |
| text · payload | text · jsonb | 외부 글은 데이터로만(17-7) |
| created_at | timestamptz | |

### jobs
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id · project_id | uuid | |
| step · type | smallint · text | 큐 종류 render·tts·analyze, 수집은 확장 |
| status | text | queued·waiting_extension(수집만)·running·succeeded·failed·canceled |
| idempotency_key | text unique | 같은 키면 기존 작업 반환 |
| attempts · max_attempts | int | 가설 최대 3 |
| payload | jsonb | |
| error | text | |
| started_at · finished_at | timestamptz | 배너 경과 시간 |
| extension_id | uuid null → extension_connections | 원자적 claim(ADR-0003). WHERE에 extension_connections.user_id = jobs 소유자 조건 |

### credit_ledger
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id · user_id | uuid | |
| project_id · job_id | uuid null | |
| kind | text | reserve·settle·release·charge. unique(job_id, kind) + kind in (settle, release) 부분 unique(job_id). reserve 시 사용자 단위 잠금(advisory lock 또는 사용자 행 FOR UPDATE) |
| delta | int | 정수 크레딧. MVP는 차감 기록만(D3) |
| reason | text | |
| idempotency_key | text unique | |
| created_at | timestamptz | |

### project_events
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id · project_id | uuid | |
| step | smallint | |
| event | text | step_started·step_approved·step_change_requested·render_succeeded(17-9) |
| created_at | timestamptz | |

### accounts
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id · user_id | uuid | |
| platform | text | youtube·instagram·tiktok(업로드)·xiaohongshu(수집) |
| channel_name | text | |
| category_id | uuid → categories | |
| tone · target | text | 말투·타깃(channel_cards 대체) |
| weekly_goal | int | |
| is_default | bool | 기본 채널(12장) |
| oauth_token_ref | uuid null | Vault secret id. 해제 시 Vault에서 삭제 |
| status | text | 연결됨·재연결 필요 |

### categories (읽기 전용)
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id | uuid | |
| name | text | 10개 |
| keywords_ko · keywords_en · keywords_zh | text[] | |
| banned_terms | text[] | 정책 점검 금지어 사전 |

### trend_items (읽기 전용)
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id · category_id | uuid | |
| name | text | |
| period | text | 오늘·7일·30일 |
| overseas_growth · kr_search_growth | numeric | |
| kr_competition · opportunity_score | 미확인 · numeric | |
| sellable | bool | |
| captured_at | timestamptz | |

### affiliate_links
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id · project_id | uuid | |
| program | text | 15-1의 8개 |
| url | text | 서버만 씀. 등록 제휴 도메인 CHECK(허용 목록 테이블 또는 상수), 리다이렉트 시 재검사 |
| short_url | text unique | 자체 단축 링크, 서버 생성 |
| partner_id_ref | text | 비밀 여부 확인 필요 |
| disclosed | bool | 꺼지면 정책 점검 실패 |
| bio_service · bio_no · bio_registered_at | text · int · timestamptz | |
| created_at | timestamptz | |

### publications
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id · project_id | uuid | unique(project_id) |
| account_id | uuid | = projects.account_id(다른 채널 재업로드 금지) |
| mode | text | 예약·지금. **함수 전용**(행 생성 포함) |
| scheduled_at · published_at | timestamptz | scheduled_at **함수 전용**. published_at이 sources.purge_after 기준 |
| platform_video_id | text | |
| status · error | text | |
| retry_count | int | 자동 재시도 3회 |

### video_metrics
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id · publication_id | uuid | |
| date | date | |
| views · link_clicks | int | |
| avg_view_pct | numeric | |
| est_revenue | int | 원(정수) |

### policy_checks
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id · project_id | uuid | |
| item | text | 15-4의 6항목 |
| result · detail | text | |
| checked_by | uuid null | 사용자 체크 항목만(출처 표기·고지, 구매 경로). **함수 전용** |
| checked_at | timestamptz | 사용자 체크 항목은 **함수 전용** |

### bio_pages · bio_items
| 컬럼 | 타입 | 비고 |
|---|---|---|
| bio_pages: id · account_id | uuid | |
| bio_pages: service · url | text | 인포크링크·리틀리 |
| bio_items: id · bio_page_id · project_id | uuid | |
| bio_items: no | int | 링크인바이오 번호 |
| bio_items: affiliate_link_id | uuid → affiliate_links | |
| bio_items: short_url · title · thumb_url | text | |
| bio_items: registered_at · archived_at | timestamptz | |

### link_clicks (서버 쓰기 전용)
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id | uuid | |
| affiliate_link_id | uuid → affiliate_links | 소유자 판정 경로 |
| short_url | text | |
| clicked_at | timestamptz | |
| referrer · platform | text | IP 원문 저장 금지 |

### api_keys
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id · user_id | uuid | unique(user_id, provider) |
| provider | text | anthropic·openai·fish_audio·elevenlabs·fal |
| secret_ref | uuid | Vault secret id |
| last4 | text | 화면 표시용 |
| status · tested_at | text · timestamptz | 미등록·등록됨·연결 확인됨 |

### user_profiles
| 컬럼 | 타입 | 비고 |
|---|---|---|
| user_id | uuid PK | |
| name · email | text | |
| default_tone · default_lang · subtitle_style | text | 채널 말투가 있으면 채널 우선 |
| default_len | smallint | 15·20 |
| notify_done · notify_weekly | bool | |

### extension_connections (ADR-0003, 이름 확인 필요)
| 컬럼 | 타입 | 비고 |
|---|---|---|
| id · user_id | uuid | |
| access_token_hash · access_expires_at | text · timestamptz | 15분, 원문 저장 금지 |
| refresh_token_hash · refresh_expires_at | text · timestamptz | 30일, 갱신 시 회전 |
| family_id | uuid | 재사용 감지 시 같은 계열 전체 폐기 |
| last_heartbeat_at | timestamptz | 30초 주기, 2분 끊김 판정 |
| revoked_at · created_at | timestamptz | |

## 4. 확인 필요
1. 서버 쓰기 주체 = service_role: 1절에 잠정 반영. 사용자 확인 필요.
2. 함수 전용 열(REVOKE + SECURITY DEFINER): 1절에 잠정 반영. 사용자 확인 필요.
3. 워커 쓰기 범위: ADR-0001은 jobs·credit_ledger만 명시. renders·voice_takes 결과 기록과 project_events(render_succeeded)를 워커가 쓰는지 서버가 쓰는지.
4. 출처 고지 확인(02 승인 조건)을 프로젝트 1건으로 저장할지, 사용 원본마다 rights_basis로 저장할지(현재 안은 원본마다).
5. rights_basis의 own·seller·licensed 값과 그 입력 화면(D1 문구 유래, D7 이후 쓰임 미확인).
6. 직접 추가(파일·URL) 원본의 platform·author 값 규칙(not null 유지 가능 여부).
7. 보관 기간(1절 보관)은 D5 가설 기반 잠정안. 사용자 확인 필요.
8. link_clicks 반복 클릭 판별용 값(IP 해시 등)과 집계 제외 표시 열 — 17-8 요구는 있으나 컬럼 미정.
9. affiliate_links.partner_id_ref가 비밀인지(Vault 대상인지), 채널별 파트너 ID 저장 위치(15-1 "다중 계정에서 등록").
10. trend_items.kr_competition 타입(등급 text vs 수치) 미확인.
11. video_metrics unique(publication_id, date) 여부(credit_ledger 추가 전용은 확정 반영).
12. extension_connections 테이블 이름·열은 ADR-0003에서 유도한 안(DB엔 해시만).
