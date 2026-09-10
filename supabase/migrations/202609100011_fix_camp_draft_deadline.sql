-- Fix the camp draft entry deadline check after a transaction has started.
-- Apply after 010. Keep the existing draft creation/reuse contract from 003.

begin;

create or replace function public.create_camp_application_draft(
  target_camp_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  current_email text := lower(auth.jwt() ->> 'email');
  camp_record public.camps%rowtype;
  existing_application_id uuid;
  new_application_id uuid;
  created_new_application boolean := false;
begin
  if current_user_id is null then
    raise exception 'ログインが必要です。';
  end if;

  if not private.has_active_profile() then
    raise exception 'このアカウントでは申請できません。';
  end if;

  select camp.*
  into camp_record
  from public.camps as camp
  where camp.id = target_camp_id
    and camp.deleted_at is null;

  if not found then
    raise exception '対象のキャンプが見つかりません。';
  end if;

  -- now() is fixed at transaction start, which may be before the deadline.
  -- Check the actual time before either returning or creating a draft.
  if clock_timestamp() >= camp_record.application_deadline then
    raise exception 'このキャンプの申請期限を過ぎています。';
  end if;

  if not exists (
    select 1
    from public.camp_eligible_users as eligible
    where eligible.camp_id = target_camp_id
      and eligible.disabled_at is null
      and eligible.email_normalized = current_email
  ) then
    raise exception 'このキャンプの申請対象者ではありません。';
  end if;

  select application.id
  into existing_application_id
  from public.applications as application
  where application.user_id = current_user_id
    and application.camp_id = target_camp_id
    and application.status not in ('rejected', 'cancelled')
  order by application.created_at desc
  limit 1;

  if existing_application_id is not null then
    return existing_application_id;
  end if;

  begin
    insert into public.applications (
      user_id,
      usage_type,
      camp_id,
      status,
      start_date,
      end_date
    )
    values (
      current_user_id,
      'camp',
      target_camp_id,
      'draft',
      camp_record.start_date,
      camp_record.end_date
    )
    returning id into new_application_id;

    created_new_application := true;
  exception
    when unique_violation then
      select application.id
      into new_application_id
      from public.applications as application
      where application.user_id = current_user_id
        and application.camp_id = target_camp_id
        and application.status not in ('rejected', 'cancelled')
      order by application.created_at desc
      limit 1;
  end;

  if new_application_id is null then
    raise exception '下書きを作成できませんでした。';
  end if;

  if created_new_application then
    insert into public.application_status_events (
      application_id,
      from_status,
      to_status,
      actor_user_id
    )
    values (
      new_application_id,
      null,
      'draft',
      current_user_id
    );
  end if;

  return new_application_id;
end;
$$;

revoke all on function public.create_camp_application_draft(uuid) from public, anon;
grant execute on function public.create_camp_application_draft(uuid) to authenticated;

commit;
