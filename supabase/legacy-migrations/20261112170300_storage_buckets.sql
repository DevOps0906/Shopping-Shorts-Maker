-- task-011: 원본·음성·MP4 비공개 버킷 (docs/planning.md 17-8, docs/05_DATA_MODEL.md 3절)
-- - public = false. 브라우저는 서명 URL로만 받는다. 서명 URL은 웹 서버(SR)가 소유권을 검사한 뒤 발급한다.
-- - storage.objects 에 anon·authenticated 정책을 만들지 않는다 → 직접 목록·다운로드·업로드 전부 거부(RLS 기본 거부).
--   업로드(확장 수집·녹음)도 서버가 소유권을 재검사한 뒤 서버 키로 올린다.
-- - 객체 경로 규칙: <user_id>/<project_id>/<파일명>
-- - 크기 상한은 잠정값. URL 원본 상한은 task-017에서 확정한다.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('sources', 'sources', false, 524288000,             -- 500 MiB
   array['video/mp4', 'video/quicktime', 'video/webm']),
  ('voices', 'voices', false, 52428800,                -- 50 MiB
   array['audio/mpeg', 'audio/wav', 'audio/x-wav', 'audio/webm', 'audio/mp4', 'audio/ogg']),
  ('renders', 'renders', false, 209715200,             -- 200 MiB
   array['video/mp4'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;
