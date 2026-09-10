-- Allow consent-required applications to submit only after verified metadata exists.
-- The phase-3 submit function becomes an internal core operation.

alter function public.submit_camp_application(uuid)
set schema private;

revoke all on function private.submit_camp_application(uuid)
from public, anon, authenticated;

create or replace function public.submit_camp_application(
  target_application_id uuid
)
returns table (
  submitted_application_id uuid,
  reception_number text,
  submission_time timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  application_record public.applications%rowtype;
  consent_was_required boolean;
begin
  if current_user_id is null or not private.has_active_profile() then
    raise exception 'ログインが必要です。';
  end if;

  -- Preserve the global-before-application lock order used by the core function.
  perform guard.id
  from public.facility_guard as guard
  where guard.id = 1
  for update;

  select application.*
  into application_record
  from public.applications as application
  where application.id = target_application_id
  for update;

  if not found or application_record.user_id <> current_user_id then
    raise exception '申請が見つかりません。';
  end if;

  consent_was_required := application_record.requires_guardian_consent;

  if consent_was_required and not exists (
    select 1
    from public.consent_documents as document
    where document.application_id = target_application_id
  ) then
    raise exception '保護者同意書を添付してください。';
  end if;

  -- The phase-3 core predates attachments and rejects every consent-required
  -- application. Temporarily clear the flag inside this transaction after the
  -- verified metadata check, then restore it before committing.
  if consent_was_required then
    update public.applications
    set requires_guardian_consent = false
    where id = target_application_id;
  end if;

  return query
  select
    submitted.submitted_application_id,
    submitted.reception_number,
    submitted.submission_time
  from private.submit_camp_application(target_application_id) as submitted;

  if consent_was_required then
    update public.applications
    set requires_guardian_consent = true
    where id = target_application_id;
  end if;
end;
$$;

revoke all on function public.submit_camp_application(uuid) from public;
grant execute on function public.submit_camp_application(uuid) to authenticated;
