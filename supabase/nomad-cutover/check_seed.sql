-- check.sh 전용 합성 데이터(옛 public·private 스키마). 실제 고객 데이터 아님. 사용자 2명(A·B), 익명 0명.
-- 가입은 평소처럼(옛 가입 트리거가 user_profiles 를 만든다), 나머지는 옛 트리거를 끄고 운영 중 상태를 흉내 낸다.
\set ON_ERROR_STOP on
\set A 'a0000000-0000-4000-8000-000000000001'
\set B 'b0000000-0000-4000-8000-000000000002'
begin;

insert into auth.users (id, aud, role, email, raw_user_meta_data, is_anonymous, created_at)
values (:'A', 'authenticated', 'authenticated', 'alice@example.test', '{}', false, '2026-10-01 09:00+09'),
       (:'B', 'authenticated', 'authenticated', 'bob@example.test', '{}', false, '2026-10-02 09:00+09');
update public.user_profiles set name = '합성 앨리스', default_tone = 'calm', default_lang = 'ko', subtitle_style = 'bold',
  default_len = 20, notify_weekly = true where user_id = :'A';
update public.user_profiles set name = null, default_lang = 'en' where user_id = :'B';

set local session_replication_role = replica;

insert into public.categories (id, name, keywords_ko, keywords_en, keywords_zh, banned_terms) values
  ('c0000000-0000-4000-8000-000000000001', '주방', '{냄비,칼}', '{pot}', '{锅}', '{최고}'),
  ('c0000000-0000-4000-8000-000000000002', '뷰티', '{립}', '{lip}', '{}', '{}');
insert into public.trend_items (category_id, name, period, overseas_growth, kr_search_growth, kr_competition, opportunity_score, sellable, captured_at) values
  ('c0000000-0000-4000-8000-000000000001', '접이식 도마', '7d', 12.5, 3.2, 40, 77.5, true, '2026-11-01'),
  ('c0000000-0000-4000-8000-000000000002', '틴트', 'today', 1, 2, 3, 4, false, '2026-11-02');

insert into public.accounts (id, user_id, platform, channel_name, category_id, weekly_goal, is_default, oauth_token_ref, status, created_at, last_bio_no, external_channel_id, first_connected_at) values
  ('aa000000-0000-4000-8000-000000000001', :'A', 'youtube', 'A 채널', 'c0000000-0000-4000-8000-000000000001', 3, true, gen_random_uuid(), 'connected', '2026-10-03', 2, 'UC_SYNTH_A', '2026-10-03'),
  ('aa000000-0000-4000-8000-000000000002', :'A', 'instagram', 'A 인스타', null, 0, false, null, 'reconnect_required', '2026-10-04', 0, null, null),
  ('bb000000-0000-4000-8000-000000000001', :'B', 'youtube', 'B 채널', 'c0000000-0000-4000-8000-000000000002', 1, true, gen_random_uuid(), 'connected', '2026-10-05', 1, 'UC_SYNTH_B', '2026-10-05');

-- 단계·상태·updated_at 이 원본대로 남는지(새 projects_force_initial_state·set_updated_at 트리거가 꺼졌는지) 확인용 값
insert into public.projects (id, user_id, account_id, category_id, name, current_step, step_status, status, target_sec, created_at, updated_at, sources_notice_ack_by, sources_notice_ack_at) values
  ('ab000000-0000-4000-8000-000000000001', :'A', 'aa000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001', 'A 도마 쇼츠', 6,
   '{"1":"approved","2":"approved","3":"approved","4":"approved","5":"approved","6":"approved"}', 'uploaded', 20, '2026-10-10 10:00+09', '2026-10-12 11:22:33+09', :'A', '2026-10-10 10:05+09'),
  ('ab000000-0000-4000-8000-000000000002', :'A', 'aa000000-0000-4000-8000-000000000002', null, 'A 두번째', 2,
   '{"1":"approved","2":"running","3":"idle","4":"idle","5":"idle","6":"idle"}', 'in_progress', 15, '2026-10-11', '2026-10-11 00:00:01+09', null, null),
  ('bc000000-0000-4000-8000-000000000001', :'B', 'bb000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000002', 'B 틴트', 4,
   '{"1":"approved","2":"approved","3":"approved","4":"ready","5":"idle","6":"idle"}', 'in_progress', 15, '2026-10-12', '2026-10-13', null, null);

insert into public.project_events (project_id, step, event, created_at) values
  ('ab000000-0000-4000-8000-000000000001', 1, 'step_approved', '2026-10-10'),
  ('bc000000-0000-4000-8000-000000000001', 4, 'step_started', '2026-10-12');
insert into public.topics (project_id, round, name, reason, evidence_urls, picked, product_url) values
  ('ab000000-0000-4000-8000-000000000001', 1, '도마 주제', '검색 증가', '{https://example.test/a}', true, 'https://example.test/p/1'),
  ('bc000000-0000-4000-8000-000000000001', 2, '틴트 주제', null, '{}', false, null);

insert into public.extension_connections (id, user_id, access_token_hash, access_expires_at, refresh_token_hash, refresh_expires_at, family_id, last_heartbeat_at, created_at, activated_at) values
  ('ae000000-0000-4000-8000-000000000001', :'A', 'hash-acc-a', '2026-12-01', 'hash-ref-a', '2026-12-31', gen_random_uuid(), '2026-11-01', '2026-10-20', '2026-10-20'),
  ('be000000-0000-4000-8000-000000000001', :'B', 'hash-acc-b', '2026-12-01', 'hash-ref-b', '2026-12-31', gen_random_uuid(), null, '2026-10-21', null);

-- 멱등 키 포함
insert into public.jobs (id, project_id, step, type, status, idempotency_key, attempts, max_attempts, payload, error, started_at, finished_at, extension_id, created_at, files_reported_at) values
  ('a1000000-0000-4000-8000-000000000001', 'ab000000-0000-4000-8000-000000000001', 5, 'render', 'succeeded', 'a0000000-0000-4000-8000-000000000001:render-1', 1, 3, '{"v":1}', null, '2026-10-11', '2026-10-11 00:05', null, '2026-10-11', null),
  ('a1000000-0000-4000-8000-000000000002', 'ab000000-0000-4000-8000-000000000001', 2, 'collect_download', 'succeeded', 'a0000000-0000-4000-8000-000000000001:dl-1', 1, 1, '{}', null, '2026-10-10', '2026-10-10 00:01', 'ae000000-0000-4000-8000-000000000001', '2026-10-10', '2026-10-10 00:01'),
  ('b1000000-0000-4000-8000-000000000001', 'bc000000-0000-4000-8000-000000000001', 4, 'tts', 'failed', 'b0000000-0000-4000-8000-000000000002:tts-1', 3, 3, '{}', 'E_TTS', '2026-10-13', '2026-10-13 00:02', null, '2026-10-13', null);

-- 저장 경로 <user_id>/<project_id>/… · 소프트 삭제(file_deleted_at)
insert into public.sources (project_id, platform, url, author, title, file_path, thumbnail_path, purge_after, file_deleted_at, used, checked, rights_basis, rights_confirmed_by, rights_confirmed_at) values
  ('ab000000-0000-4000-8000-000000000001', 'tiktok', 'https://example.test/v/1', 'author1', '원본1',
   'a0000000-0000-4000-8000-000000000001/ab000000-0000-4000-8000-000000000001/src-1.mp4',
   'a0000000-0000-4000-8000-000000000001/ab000000-0000-4000-8000-000000000001/thumb-1.jpg', '2026-11-30', null, true, true, 'own', :'A', '2026-10-10'),
  ('ab000000-0000-4000-8000-000000000002', 'direct', 'https://example.test/v/2', 'author2', null,
   'a0000000-0000-4000-8000-000000000001/ab000000-0000-4000-8000-000000000002/src-2.mp4', null, '2026-10-20', '2026-10-21', false, false, null, null, null),
  ('bc000000-0000-4000-8000-000000000001', 'xiaohongshu', 'https://example.test/v/3', 'author3', '원본3',
   'b0000000-0000-4000-8000-000000000002/bc000000-0000-4000-8000-000000000001/src-3.mp4', null, '2026-12-01', null, false, true, null, null, null);
insert into public.scripts (project_id, version, lines, est_sec, approved_at) values
  ('ab000000-0000-4000-8000-000000000001', 1, '[{"t":"안녕"}]', 18.5, '2026-10-10'),
  ('bc000000-0000-4000-8000-000000000001', 1, '[]', null, null);
insert into public.voice_takes (project_id, voice_id, source, audio_path, words, duration_sec, job_id, purge_after) values
  ('ab000000-0000-4000-8000-000000000001', 'v1', 'tts', 'a0000000-0000-4000-8000-000000000001/ab000000-0000-4000-8000-000000000001/voice-1.mp3', '[]', 19.2, null, '2026-12-01'),
  ('bc000000-0000-4000-8000-000000000001', null, 'recording', 'b0000000-0000-4000-8000-000000000002/bc000000-0000-4000-8000-000000000001/voice-2.webm', null, null, null, '2026-12-01');
insert into public.renders (project_id, version, cut_map, upscale_status, clean_status, mp4_path, job_id, duration_sec, purge_after, file_deleted_at) values
  ('ab000000-0000-4000-8000-000000000001', 1, '{"cuts":[]}', 'none', 'succeeded', 'a0000000-0000-4000-8000-000000000001/ab000000-0000-4000-8000-000000000001/render-1.mp4', 'a1000000-0000-4000-8000-000000000001', 20, '2026-12-10', null),
  ('ab000000-0000-4000-8000-000000000001', 2, null, 'none', 'none', 'a0000000-0000-4000-8000-000000000001/ab000000-0000-4000-8000-000000000001/render-2.mp4', null, null, '2026-10-01', '2026-10-02');
insert into public.chat_messages (project_id, role, kind, text, payload) values
  ('ab000000-0000-4000-8000-000000000001', 'user', 'text', '자막 바꿔줘', null),
  ('bc000000-0000-4000-8000-000000000001', 'ai', 'ai', '네', '{"k":1}');
insert into public.chat_proposals (user_id, project_id, tool, args, args_hash, input_version, expires_at, consumed_at) values
  (:'A', 'ab000000-0000-4000-8000-000000000001', 'draft_script', '{"x":1}', 'h1', '{"v":1}', '2026-10-11', '2026-10-10'),
  (:'B', 'bc000000-0000-4000-8000-000000000001', 'render_mp4', '{}', 'h2', '{}', '2026-10-14', null);
insert into public.credit_ledger (user_id, project_id, job_id, kind, delta, reason, idempotency_key, created_at) values
  (:'A', null, null, 'charge', 100, '합성 충전', 'charge:a:1', '2026-10-01'),
  (:'A', 'ab000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', 'reserve', -30, null, 'reserve:a:render-1', '2026-10-11'),
  (:'A', 'ab000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', 'settle', 0, null, 'settle:a:render-1', '2026-10-11'),
  (:'B', 'bc000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001', 'release', 10, null, 'release:b:tts-1', '2026-10-13');

insert into public.publications (id, project_id, account_id, mode, scheduled_at, published_at, platform_video_id, status, retry_count, title, description, hashtags, body) values
  ('a2000000-0000-4000-8000-000000000001', 'ab000000-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000001', 'now', null, '2026-10-12', 'yt-synth-1', 'uploaded', 0, '도마', '설명', '{#도마}', '본문'),
  ('b2000000-0000-4000-8000-000000000001', 'bc000000-0000-4000-8000-000000000001', 'bb000000-0000-4000-8000-000000000001', 'scheduled', '2026-12-01', null, null, 'scheduled', 1, '틴트', null, '{}', null);
insert into public.video_metrics (publication_id, date, views, link_clicks, avg_view_pct, est_revenue) values
  ('a2000000-0000-4000-8000-000000000001', '2026-10-13', 120, 4, 55.5, 300),
  ('a2000000-0000-4000-8000-000000000001', '2026-10-14', 80, 1, 40, 0);
insert into public.policy_checks (project_id, item, result, detail, checked_by, checked_at) values
  ('ab000000-0000-4000-8000-000000000001', 'affiliate_disclosure', 'pass', null, :'A', '2026-10-12'),
  ('bc000000-0000-4000-8000-000000000001', 'banned_terms', 'pending', null, null, null);
-- 공유 링크(short_url)
insert into public.affiliate_links (id, project_id, program, url, short_url, disclosed, bio_service, bio_no, bio_registered_at) values
  ('a3000000-0000-4000-8000-000000000001', 'ab000000-0000-4000-8000-000000000001', 'coupang_partners', 'https://link.coupang.com/a/synth', 'https://s.example.test/aA1', true, 'inpock', 2, '2026-10-12'),
  ('b3000000-0000-4000-8000-000000000001', 'bc000000-0000-4000-8000-000000000001', 'none', null, null, false, null, null, null);
insert into public.bio_pages (id, account_id, service, url) values
  ('a4000000-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000001', 'inpock', 'https://link.example.test/a'),
  ('b4000000-0000-4000-8000-000000000001', 'bb000000-0000-4000-8000-000000000001', 'litly', null);
insert into public.bio_items (bio_page_id, project_id, no, affiliate_link_id, short_url, title, registered_at, archived_at) values
  ('a4000000-0000-4000-8000-000000000001', 'ab000000-0000-4000-8000-000000000001', 2, 'a3000000-0000-4000-8000-000000000001', 'https://s.example.test/aA1', '도마', '2026-10-12', null),
  ('a4000000-0000-4000-8000-000000000001', null, 1, null, null, '보관된 항목', '2026-10-01', '2026-10-05');
insert into public.link_clicks (affiliate_link_id, short_url, clicked_at, referrer, platform, visitor_hash, counted) values
  ('a3000000-0000-4000-8000-000000000001', 'https://s.example.test/aA1', '2026-10-13', 'youtube', 'youtube', 'vh1', true),
  ('a3000000-0000-4000-8000-000000000001', 'https://s.example.test/aA1', '2026-10-13 00:00:01', null, null, 'vh1', false);
insert into public.api_keys (user_id, provider, secret_ref, last4, status, tested_at) values
  (:'A', 'anthropic', gen_random_uuid(), 'abcd', 'verified', '2026-10-05'),
  (:'B', 'openai', null, null, 'unregistered', null);
insert into public.oauth_states (state_hash, user_id, account_id, provider, code_verifier, expires_at, used_at) values
  (repeat('a', 64), :'A', 'aa000000-0000-4000-8000-000000000001', 'youtube', repeat('v', 43), '2026-10-03 00:10', '2026-10-03 00:01'),
  (repeat('b', 64), :'B', 'bb000000-0000-4000-8000-000000000001', 'youtube', repeat('w', 50), '2026-10-05 00:10', null);
insert into public.channel_slot_events (user_id, account_id, kind, slots, channel_limit) values
  (:'A', 'aa000000-0000-4000-8000-000000000001', 'connect', 1, 2),
  (:'B', null, 'reject_limit', 1, 1);
insert into public.publication_upload_sessions (publication_id, session_uri, total_bytes, restart_allowed, completed_at) values
  ('a2000000-0000-4000-8000-000000000001', 'https://www.googleapis.com/upload/youtube/v3/videos?upload_id=synth', 1048576, false, '2026-10-12'),
  ('b2000000-0000-4000-8000-000000000001', 'https://www.googleapis.com/upload/youtube/v3/videos?upload_id=synth2', 2048, false, null);
insert into public.youtube_upload_quota (day, used) values ('2026-10-12', 1600), ('2026-10-13', 0);

insert into private.channel_quotas (user_id, channel_limit) values (:'A', 2), (:'B', 1);
insert into private.click_salts (day, salt) values ('2026-10-13', '\x0102'), ('2026-10-14', '\x0304');
insert into private.metrics_runs (started_at, finished_at, ok, skipped) values ('2026-10-13', '2026-10-13 00:01', 2, 0), ('2026-10-14', null, 0, 0);
select setval('private.metrics_runs_id_seq', 7);  -- 원본 번호가 이어지는지 확인용
insert into private.rate_counters (key, window_start, hits) values ('user:synth-a', '2026-10-13', 3), ('ip:synth', '2026-10-13', 1);

commit;
