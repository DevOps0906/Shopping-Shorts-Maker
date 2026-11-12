-- task-011 보안 리뷰 반영: 승인된 대본 잠금
-- - approved_at 이 있는 대본은 lines·est_sec 를 바꿀 수 없다(본인·서버 모두).
-- - 프로젝트 03 단계가 approved 인 동안 새 대본 버전을 만들 수 없다.
-- 바꾸려면 request_step_change 로 승인을 해제한 뒤 수정한다(docs/planning.md 6장).

create function private.scripts_lock_after_approval()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if old.approved_at is not null
       and (new.lines, new.est_sec) is distinct from (old.lines, old.est_sec) then
      raise exception '승인된 대본은 바꿀 수 없습니다. 변경 요청으로 승인을 해제하세요'
        using errcode = '55000';
    end if;
  elsif exists (select 1 from public.projects p
                where p.id = new.project_id and p.step_status ->> '3' = 'approved') then
    raise exception '대본 단계가 승인된 동안 새 대본을 만들 수 없습니다. 변경 요청으로 승인을 해제하세요'
      using errcode = '55000';
  end if;
  return new;
end;
$$;
revoke execute on function private.scripts_lock_after_approval() from public, anon, authenticated;

create trigger scripts_lock_after_approval
  before insert or update on public.scripts
  for each row execute function private.scripts_lock_after_approval();
