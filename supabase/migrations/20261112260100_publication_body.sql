-- task-023: 발행 본문(설명란의 "본문" 블록) 원문 저장 — 화면을 다시 열면 사용자가 고친 본문을 그대로 보여 준다.
-- publications.description 은 DB가 고정 순서로 만든 완성본, body 는 그중 본문 입력값(함수 전용, authenticated 는 SELECT 만).
-- prepare_publication 은 시그니처·권한·검사 그대로, body 를 함께 저장하도록만 바꾼다.

alter table public.publications add column body text check (char_length(body) <= 4000);
comment on column public.publications.body is '설명란 본문 입력값(고지·구매 안내·출처·해시태그 제외). prepare_publication 이 저장';

create or replace function private.prepare_publication(
  p_project_id uuid, p_mode text, p_scheduled_at timestamptz, p_title text, p_body text,
  p_hashtags text[], p_purchase_guide boolean, p_pin_comment boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status jsonb;
  v_account uuid;
  v_policy jsonb;
  v_tags text[] := private.publish_clean_hashtags(p_hashtags);
  v_title text := btrim(coalesce(p_title, ''));
  v_existing text;
  v_description text;
  v_row public.publications;
begin
  perform private.publish_owned(p_project_id, true);
  select step_status, account_id into v_status, v_account from public.projects where id = p_project_id;
  if v_status ->> '5' <> 'approved' then
    raise exception '05 편집을 먼저 승인해 주세요' using errcode = '55000';
  end if;
  if p_mode is null or p_mode not in ('scheduled', 'now') then
    raise exception '발행 방식이 올바르지 않습니다' using errcode = '22023';
  end if;
  if p_mode = 'scheduled' and (p_scheduled_at is null or p_scheduled_at <= now()) then
    raise exception '예약 시각은 지금보다 뒤여야 합니다' using errcode = '22023';
  end if;
  if char_length(v_title) not between 1 and 100 then
    raise exception '제목은 1~100자여야 합니다' using errcode = '22023';
  end if;
  if char_length(coalesce(p_body, '')) > 4000 or cardinality(v_tags) > 15
     or exists (select 1 from unnest(v_tags) t where t !~ '^[^[:space:]#]{1,30}$') then
    raise exception '설명·해시태그 형식이 올바르지 않습니다' using errcode = '22023';
  end if;

  select status into v_existing from public.publications where project_id = p_project_id;
  if v_existing is not null and v_existing <> 'pending' then
    raise exception '이미 예약·업로드가 시작된 발행입니다' using errcode = '55000';
  end if;

  v_policy := private.publish_evaluate(p_project_id, v_title, p_body, v_tags);
  if (v_policy ->> 'passed')::int <> 6 then
    raise exception '정책 점검 6개 항목을 모두 통과해야 발행할 수 있습니다' using errcode = 'PC001';
  end if;

  v_description := private.publish_description(
    v_policy ->> 'disclosure',
    case when coalesce(p_purchase_guide, true) then v_policy ->> 'purchase' else '' end,
    p_body, v_policy ->> 'credits', v_tags);

  insert into public.publications (project_id, account_id, mode, scheduled_at, title, body, description, hashtags,
                                   pin_comment, prepared_at, status)
  values (p_project_id, v_account, p_mode, case when p_mode = 'scheduled' then p_scheduled_at end, v_title,
          nullif(btrim(coalesce(p_body, '')), ''), v_description, v_tags, coalesce(p_pin_comment, false), now(), 'pending')
  on conflict (project_id) do update
    set mode = excluded.mode, scheduled_at = excluded.scheduled_at, title = excluded.title, body = excluded.body,
        description = excluded.description, hashtags = excluded.hashtags, pin_comment = excluded.pin_comment,
        prepared_at = excluded.prepared_at
  returning * into v_row;

  update public.projects set status = 'awaiting_publish' where id = p_project_id;

  return jsonb_build_object('id', v_row.id, 'mode', v_row.mode, 'scheduled_at', v_row.scheduled_at,
                            'title', v_row.title, 'description', v_row.description,
                            'prepared_at', v_row.prepared_at, 'status', v_row.status);
end;
$$;
