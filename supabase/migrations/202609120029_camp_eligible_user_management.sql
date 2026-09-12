-- P06: safely change or disable camp eligibility without breaking an existing application.
begin;

create function public.update_camp_eligible_user(
  target_camp_id uuid,
  target_eligible_user_id uuid,
  new_email text,
  expected_updated_at timestamptz,
  change_reason text
)
returns table (result_id uuid, result_email text, result_updated_at timestamptz, result_disabled_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  eligible public.camp_eligible_users%rowtype;
  normalized_email text := lower(btrim(new_email));
  before_value jsonb;
begin
  perform private.lock_calendar_for_staff();
  perform 1 from public.camps where id = target_camp_id and deleted_at is null for update;
  if not found then raise exception using message = 'not-found'; end if;

  select * into eligible from public.camp_eligible_users
  where id = target_eligible_user_id and camp_id = target_camp_id for update;
  if not found then raise exception using message = 'not-found'; end if;
  perform private.check_calendar_version(eligible.updated_at, expected_updated_at);
  if eligible.disabled_at is not null then raise exception using message = 'invalid-status'; end if;
  if normalized_email = '' or normalized_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    then raise exception using message = 'invalid-email'; end if;
  if eligible.email_normalized = normalized_email then
    return query select eligible.id, eligible.email_normalized, eligible.updated_at, eligible.disabled_at;
    return;
  end if;
  perform private.check_calendar_reason(change_reason);
  if exists (
    select 1 from public.applications a
    where a.camp_id = target_camp_id
      and lower(btrim(coalesce(a.email_snapshot, ''))) = eligible.email_normalized
  ) then raise exception using message = 'eligible-has-application'; end if;
  if exists (
    select 1 from public.camp_eligible_users other
    where other.camp_id = target_camp_id and other.email_normalized = normalized_email
      and other.id <> eligible.id
  ) then raise exception using message = 'eligible-email-exists'; end if;

  before_value := jsonb_build_object('email', eligible.email_normalized, 'disabled_at', eligible.disabled_at);
  update public.camp_eligible_users set email_normalized = normalized_email
  where id = eligible.id returning * into eligible;
  insert into public.audit_logs(entity_type, entity_id, action, before_data, after_data,
    actor_kind, actor_user_id, reason)
  values ('camp_eligible_user', eligible.id, 'update_camp_eligible_user', before_value,
    jsonb_build_object('email', eligible.email_normalized, 'disabled_at', eligible.disabled_at),
    'staff', auth.uid(), btrim(change_reason));
  return query select eligible.id, eligible.email_normalized, eligible.updated_at, eligible.disabled_at;
end;
$$;

create function public.disable_camp_eligible_user(
  target_camp_id uuid,
  target_eligible_user_id uuid,
  expected_updated_at timestamptz,
  change_reason text
)
returns table (result_id uuid, result_email text, result_updated_at timestamptz, result_disabled_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare eligible public.camp_eligible_users%rowtype; before_value jsonb;
begin
  perform private.lock_calendar_for_staff();
  perform 1 from public.camps where id = target_camp_id and deleted_at is null for update;
  if not found then raise exception using message = 'not-found'; end if;
  select * into eligible from public.camp_eligible_users
  where id = target_eligible_user_id and camp_id = target_camp_id for update;
  if not found then raise exception using message = 'not-found'; end if;
  perform private.check_calendar_version(eligible.updated_at, expected_updated_at);
  if eligible.disabled_at is not null then raise exception using message = 'invalid-status'; end if;
  perform private.check_calendar_reason(change_reason);
  if exists (
    select 1 from public.applications a
    where a.camp_id = target_camp_id
      and lower(btrim(coalesce(a.email_snapshot, ''))) = eligible.email_normalized
  ) then raise exception using message = 'eligible-has-application'; end if;

  before_value := jsonb_build_object('email', eligible.email_normalized, 'disabled_at', eligible.disabled_at);
  update public.camp_eligible_users set disabled_at = clock_timestamp()
  where id = eligible.id returning * into eligible;
  insert into public.audit_logs(entity_type, entity_id, action, before_data, after_data,
    actor_kind, actor_user_id, reason)
  values ('camp_eligible_user', eligible.id, 'disable_camp_eligible_user', before_value,
    jsonb_build_object('email', eligible.email_normalized, 'disabled_at', eligible.disabled_at),
    'staff', auth.uid(), btrim(change_reason));
  return query select eligible.id, eligible.email_normalized, eligible.updated_at, eligible.disabled_at;
end;
$$;

revoke all on function public.update_camp_eligible_user(uuid, uuid, text, timestamptz, text)
from public, anon, authenticated;
grant execute on function public.update_camp_eligible_user(uuid, uuid, text, timestamptz, text) to authenticated;
revoke all on function public.disable_camp_eligible_user(uuid, uuid, timestamptz, text)
from public, anon, authenticated;
grant execute on function public.disable_camp_eligible_user(uuid, uuid, timestamptz, text) to authenticated;

commit;
