-- products/shorts/org/0002_storage.sql — 비공개 버킷 4개 (원본·음성·렌더·썸네일)
-- 근거: products/shorts/existing.md 버킷 절. 원본 마이그레이션 170300·240000 의 최종 값.
-- - public = false. storage.objects 에 anon·authenticated 정책을 만들지 않는다 → 직접 목록·다운로드·업로드 전부 거부.
--   서버(service_role)가 소유권을 검사한 뒤 서명 URL·업로드를 발급한다.
-- - 객체 경로 규칙: <organization_id>/<project_id>/<파일명>
-- - 버킷 id 는 프로젝트 전역이라 다른 제품과 겹치면 안 된다(existing.md 팀장 확인 항목).
begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('shorts-sources', 'shorts-sources', false, 209715200,             -- 200 MiB
   array['video/mp4', 'video/quicktime', 'video/webm']),
  ('shorts-voices', 'shorts-voices', false, 52428800,                -- 50 MiB
   array['audio/mpeg', 'audio/wav', 'audio/x-wav', 'audio/webm', 'audio/mp4', 'audio/ogg']),
  ('shorts-renders', 'shorts-renders', false, 209715200,             -- 200 MiB
   array['video/mp4']),
  ('shorts-thumbnails', 'shorts-thumbnails', false, 524288,          -- 512 KiB
   array['image/jpeg', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

commit;
