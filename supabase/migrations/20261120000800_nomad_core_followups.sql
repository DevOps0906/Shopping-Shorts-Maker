-- 코어 보완(P2 제품 이식 후속) 2건.
--   (1) nomad_core.mark_job_delivered: 제품 함수가 결과를 넘긴 뒤 "이후 실패해도 환불하지 않음"을 표시한다.
--       원본(docs finish_generation · trailer finish_run/finish_render · arch finish_ai_run)은 core.jobs.refund_on_failure를
--       직접 false로 바꿨다 → 제품 함수가 core 표를 직접 쓰지 않도록 전용 함수로 대체.
--       queued·running 행만 바꾸고(끝난 작업은 그대로), 반복 호출 안전. 어떤 API 역할에도 실행 권한 없음
--       — 소유자의 security definer 제품 함수만 호출한다(rate_limit_take·refund_credits_internal 패턴).
--   (2) nomad_core.revoke_provider_credential: 이미 폐기된 키는 forbidden 대신 no-op, 서버(is_service_caller) 호출 허용.
--       권한 검사는 그대로 먼저 한다(없는 키·권한 없는 사용자는 폐기 여부와 무관하게 forbidden).
-- 되돌림: drop function nomad_core.mark_job_delivered(uuid);
--   revoke execute on function nomad_core.revoke_provider_credential(uuid), public.nomad_revoke_provider_credential(uuid) from service_role;
--   revoke_provider_credential을 20261119000200 정의로 되돌린다.
begin;

-- ── (1) 결과 전달 표시 ───────────────────────────────────
create function nomad_core.mark_job_delivered(p_job uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  update nomad_core.jobs set refund_on_failure = false
  where id = p_job and status in ('queued', 'running') and refund_on_failure;
end;
$$;
revoke all on function nomad_core.mark_job_delivered(uuid) from public, anon, authenticated, service_role;
comment on function nomad_core.mark_job_delivered(uuid) is
  '결과 전달 후 환불 끄기(queued·running만, 반복 안전). execute grant 없음 — 소유자 definer 제품 함수만 호출.';

-- ── (2) 키 폐기: 재폐기 no-op · 서버 호출 허용 ─────────────
create or replace function nomad_core.revoke_provider_credential(credential_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare c nomad_core.provider_credentials;
begin
  select * into c from nomad_core.provider_credentials
  where id = credential_id for update;
  if not found
     or (not nomad_core.is_service_caller()
         and coalesce(nomad_core.organization_role(c.organization_id), '') not in ('owner', 'admin')) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if c.revoked_at is not null then
    return;
  end if;
  delete from vault.secrets where id = c.secret_id;
  update nomad_core.provider_credentials set revoked_at = now() where id = c.id;
end;
$$;
grant execute on function
  nomad_core.revoke_provider_credential(uuid),
  public.nomad_revoke_provider_credential(uuid)
to service_role;

commit;
