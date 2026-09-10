-- Fix camp correction submissions rejected by the initial application deadline.
-- Apply after 008. Keep the public consent-checking wrapper from 006 and the
-- internal-only execution permissions from 007.

create or replace function private.submit_camp_application(
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
  submission_time_value timestamptz;
begin
  if current_user_id is null or not private.has_active_profile() then
    raise exception 'ログインが必要です。';
  end if;

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

  select camp.*
  into camp_record
  from public.camps as camp
  where camp.id = application_record.camp_id
    and camp.deleted_at is null
  for update;

  if not found then
    raise exception '対象のキャンプが見つかりません。';
  end if;

  -- Evaluate deadlines after all locks, including time spent waiting.
  submission_time_value := clock_timestamp();

  if application_record.status = 'draft' then
    if submission_time_value >= camp_record.application_deadline then
      raise exception 'このキャンプの申請期限を過ぎています。';
    end if;
  else
    -- A correction to an already submitted, unchanged stay uses its own
    -- deadline. Never turn a missing revision deadline into unlimited access.
    if application_record.revision_due_at is null then
      raise exception '修正期限が設定されていません。町へお問い合わせください。';
    end if;

    if submission_time_value >= application_record.revision_due_at then
      raise exception '修正期限を過ぎています。';
    end if;

    -- Camp date changes must be handled explicitly by staff, not silently
    -- copied onto an existing submission through the correction workflow.
    if application_record.start_date is distinct from camp_record.start_date
      or application_record.end_date is distinct from camp_record.end_date then
      raise exception 'キャンプ期間が変更されているため再提出できません。町へお問い合わせください。';
    end if;
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

revoke all on function private.submit_camp_application(uuid)
from public, anon, authenticated;

