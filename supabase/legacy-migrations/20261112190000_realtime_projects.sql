-- task-013: 단계 상태(projects.step_status) 변경을 Realtime으로 다른 탭·기기에 전달한다.
-- Realtime postgres_changes는 구독자의 RLS(본인 projects만 SELECT)를 그대로 적용한다.
alter publication supabase_realtime add table public.projects;
