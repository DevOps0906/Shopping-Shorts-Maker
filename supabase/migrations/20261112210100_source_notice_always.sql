-- task-017 팀장 결정: 02 승인에는 출처 표기 고지 확인이 편수·원본 종류와 관계없이 항상 필요(docs/planning.md 3장 02 정본).
-- 20261112210000 의 source_approval_problem 만 교체(create or replace). approve_step(2)는 이 함수 결과로 거부하므로 그대로 따른다.

create or replace function private.source_approval_problem(p_project_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  with u as (
    select count(*) as n
    from public.sources s
    where s.project_id = p_project_id
      and s.used
      and s.rights_basis is not null
      and s.rights_confirmed_at is not null
      and s.file_path is not null
      and s.file_deleted_at is null
  )
  select case
    when u.n < 3 then 'too_few'
    when u.n < 5 and coalesce(btrim(p.sources_shortage_reason), '') = '' then 'reason_required'
    when p.sources_notice_ack_at is null then 'notice_required'
  end
  from u
  cross join public.projects p
  where p.id = p_project_id;
$$;
revoke execute on function private.source_approval_problem(uuid) from public, anon, authenticated;
