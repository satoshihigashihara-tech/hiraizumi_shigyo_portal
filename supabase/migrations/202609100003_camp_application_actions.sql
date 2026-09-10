-- MVP phase 3: safe draft, save, and submit operations for camp users.

create table public.facility_guard (
  id smallint primary key check (id = 1)
);

insert into public.facility_guard (id) values (1);

alter table public.facility_guard enable row level security;
revoke all on public.facility_guard from anon, authenticated;

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

  if now() >= camp_record.application_deadline then
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

create or replace function public.save_camp_application_draft(
  target_application_id uuid,
  applicant_name text,
  applicant_address text,
  applicant_phone text,
  emergency_contact_name text,
  emergency_contact_address text,
  emergency_contact_phone text,
  usage_purpose text,
  notes text,
  guardian_consent_required boolean,
  requested_room_preference text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  current_email text := lower(auth.jwt() ->> 'email');
  application_record public.applications%rowtype;
begin
  if current_user_id is null or not private.has_active_profile() then
    raise exception 'ログインが必要です。';
  end if;

  select application.*
  into application_record
  from public.applications as application
  where application.id = target_application_id
  for update;

  if not found or application_record.user_id <> current_user_id then
    raise exception '申請が見つかりません。';
  end if;

  if application_record.status not in ('draft', 'revision_requested') then
    raise exception '現在の状態では申請を編集できません。';
  end if;

  if application_record.status = 'revision_requested'
    and application_record.revision_due_at is not null
    and now() >= application_record.revision_due_at then
    raise exception '修正期限を過ぎています。';
  end if;

  if requested_room_preference is not null
    and requested_room_preference not in ('shared_ok', 'private_requested') then
    raise exception '相部屋希望の値が正しくありません。';
  end if;

  update public.applications
  set
    user_name = nullif(btrim(applicant_name), ''),
    user_address = nullif(btrim(applicant_address), ''),
    user_phone = nullif(btrim(applicant_phone), ''),
    email_snapshot = current_email,
    emergency_name = nullif(btrim(emergency_contact_name), ''),
    emergency_address = nullif(btrim(emergency_contact_address), ''),
    emergency_phone = nullif(btrim(emergency_contact_phone), ''),
    usage_place = 'common_and_second_floor',
    purpose = nullif(btrim(usage_purpose), ''),
    special_notes = nullif(btrim(notes), ''),
    requires_guardian_consent = guardian_consent_required,
    room_preference = requested_room_preference
  where id = target_application_id;

  return target_application_id;
end;
$$;

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
  current_email text := lower(auth.jwt() ->> 'email');
  application_record public.applications%rowtype;
  camp_record public.camps%rowtype;
  previous_status text;
  submitted_count integer;
  fiscal_year_value integer;
  serial_number_value integer;
  reception_number_value text;
  charge_id_value uuid;
  total_amount_value integer;
  submission_time_value timestamptz := now();
begin
  if current_user_id is null or not private.has_active_profile() then
    raise exception 'ログインが必要です。';
  end if;

  select guard.id
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

  if application_record.status = 'submitted' then
    select number.display_number
    into reception_number_value
    from public.reception_numbers as number
    where number.application_id = target_application_id;

    return query
    select
      application_record.id,
      reception_number_value,
      application_record.last_submitted_at;
    return;
  end if;

  if application_record.status not in ('draft', 'revision_requested') then
    raise exception '現在の状態では申請を提出できません。';
  end if;

  if application_record.status = 'revision_requested'
    and application_record.revision_due_at is not null
    and submission_time_value >= application_record.revision_due_at then
    raise exception '修正期限を過ぎています。';
  end if;

  select camp.*
  into camp_record
  from public.camps as camp
  where camp.id = application_record.camp_id
    and camp.deleted_at is null
  for update;

  if not found then
    raise exception '対象のキャンプが見つかりません。';
  end if;

  if submission_time_value >= camp_record.application_deadline then
    raise exception 'このキャンプの申請期限を過ぎています。';
  end if;

  if not exists (
    select 1
    from public.camp_eligible_users as eligible
    where eligible.camp_id = camp_record.id
      and eligible.disabled_at is null
      and eligible.email_normalized = current_email
  ) then
    raise exception 'このキャンプの申請対象者ではありません。';
  end if;

  if application_record.user_name is null
    or application_record.user_address is null
    or application_record.user_phone is null
    or application_record.email_snapshot is null
    or application_record.emergency_name is null
    or application_record.emergency_address is null
    or application_record.emergency_phone is null
    or application_record.purpose is null
    or application_record.usage_place <> 'common_and_second_floor'
    or application_record.requires_guardian_consent is null
    or application_record.room_preference is null then
    raise exception '必須項目をすべて入力してください。';
  end if;

  if application_record.user_phone !~ '^[0-9+][0-9() -]{7,19}$'
    or application_record.emergency_phone !~ '^[0-9+][0-9() -]{7,19}$' then
    raise exception '電話番号の形式を確認してください。';
  end if;

  if application_record.requires_guardian_consent then
    raise exception '保護者同意書が必要な申請は、添付機能の完成後に提出できます。';
  end if;

  select count(*)
  into submitted_count
  from public.applications as application
  where application.camp_id = camp_record.id
    and application.id <> target_application_id
    and application.status in (
      'submitted',
      'under_review',
      'revision_requested',
      'approved',
      'cancellation_requested'
    );

  if submitted_count >= 15 then
    raise exception '施設の定員15人に達しています。';
  end if;

  previous_status := application_record.status;

  update public.applications
  set
    status = 'submitted',
    start_date = camp_record.start_date,
    end_date = camp_record.end_date,
    email_snapshot = current_email,
    submitted_at = coalesce(submitted_at, submission_time_value),
    last_submitted_at = submission_time_value,
    revision_due_at = null
  where id = target_application_id;

  select number.display_number
  into reception_number_value
  from public.reception_numbers as number
  where number.application_id = target_application_id;

  if reception_number_value is null then
    fiscal_year_value := extract(
      year from (submission_time_value at time zone 'Asia/Tokyo') - interval '3 months'
    )::integer;

    insert into public.reception_counters (fiscal_year, last_number)
    values (fiscal_year_value, 0)
    on conflict (fiscal_year) do nothing;

    update public.reception_counters
    set last_number = last_number + 1,
        updated_at = submission_time_value
    where fiscal_year = fiscal_year_value
    returning last_number into serial_number_value;

    reception_number_value := format(
      'SG-%s-%s',
      fiscal_year_value,
      lpad(serial_number_value::text, 4, '0')
    );

    insert into public.reception_numbers (
      fiscal_year,
      serial_number,
      display_number,
      application_id
    )
    values (
      fiscal_year_value,
      serial_number_value,
      reception_number_value,
      target_application_id
    );
  end if;

  insert into public.application_charges (
    application_id,
    total_amount,
    payment_status,
    calculated_at
  )
  values (
    target_application_id,
    0,
    'unpaid',
    submission_time_value
  )
  on conflict (application_id) do update
  set total_amount = 0,
      calculated_at = excluded.calculated_at
  returning id into charge_id_value;

  delete from public.charge_months
  where charge_id = charge_id_value;

  insert into public.charge_months (
    charge_id,
    month,
    usage_days,
    daily_rate,
    monthly_cap,
    amount
  )
  select
    charge_id_value,
    month_start::date,
    (
      least(camp_record.end_date, (month_start + interval '1 month - 1 day')::date)
      - greatest(camp_record.start_date, month_start::date)
      + 1
    )::integer as usage_days,
    300,
    9000,
    least(
      (
        least(camp_record.end_date, (month_start + interval '1 month - 1 day')::date)
        - greatest(camp_record.start_date, month_start::date)
        + 1
      )::integer * 300,
      9000
    ) as amount
  from generate_series(
    date_trunc('month', camp_record.start_date::timestamp),
    date_trunc('month', camp_record.end_date::timestamp),
    interval '1 month'
  ) as month_start;

  select coalesce(sum(month_charge.amount), 0)
  into total_amount_value
  from public.charge_months as month_charge
  where month_charge.charge_id = charge_id_value;

  update public.application_charges
  set total_amount = total_amount_value
  where id = charge_id_value;

  insert into public.application_status_events (
    application_id,
    from_status,
    to_status,
    actor_user_id
  )
  values (
    target_application_id,
    previous_status,
    'submitted',
    current_user_id
  );

  return query
  select
    target_application_id,
    reception_number_value,
    submission_time_value;
end;
$$;

revoke all on function public.create_camp_application_draft(uuid) from public;
revoke all on function public.save_camp_application_draft(
  uuid,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  boolean,
  text
) from public;
revoke all on function public.submit_camp_application(uuid) from public;

grant execute on function public.create_camp_application_draft(uuid) to authenticated;
grant execute on function public.save_camp_application_draft(
  uuid,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  boolean,
  text
) to authenticated;
grant execute on function public.submit_camp_application(uuid) to authenticated;
