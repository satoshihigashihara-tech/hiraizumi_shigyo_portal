-- MVP phase 4: staff-only camp creation and eligible-user registration.

create or replace function public.create_staff_camp(
  camp_name text,
  camp_start_date date,
  camp_end_date date,
  camp_application_deadline timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_camp_id uuid;
  normalized_name text := nullif(btrim(camp_name), '');
begin
  if auth.uid() is null or not private.is_staff() then
    raise exception '職員としてログインしてください。';
  end if;

  if normalized_name is null then
    raise exception 'キャンプ名を入力してください。';
  end if;

  if char_length(normalized_name) > 120 then
    raise exception 'キャンプ名は120文字以内で入力してください。';
  end if;

  if camp_start_date is null or camp_end_date is null then
    raise exception 'キャンプ期間を入力してください。';
  end if;

  if camp_start_date > camp_end_date then
    raise exception '終了日は開始日以降にしてください。';
  end if;

  if camp_application_deadline is null then
    raise exception '申請期限を入力してください。';
  end if;

  select guard.id
  from public.facility_guard as guard
  where guard.id = 1
  for update;

  if exists (
    select 1
    from public.camps as camp
    where camp.deleted_at is null
      and daterange(camp.start_date, camp.end_date, '[]')
        && daterange(camp_start_date, camp_end_date, '[]')
  ) then
    raise exception '指定した期間は別のキャンプと重複しています。';
  end if;

  insert into public.camps (
    name,
    start_date,
    end_date,
    application_deadline,
    created_by
  )
  values (
    normalized_name,
    camp_start_date,
    camp_end_date,
    camp_application_deadline,
    auth.uid()
  )
  returning id into new_camp_id;

  return new_camp_id;
end;
$$;

create or replace function public.add_camp_eligible_users(
  target_camp_id uuid,
  eligible_emails text[]
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  registered_count integer;
begin
  if auth.uid() is null or not private.is_staff() then
    raise exception '職員としてログインしてください。';
  end if;

  if target_camp_id is null or not exists (
    select 1
    from public.camps as camp
    where camp.id = target_camp_id
      and camp.deleted_at is null
  ) then
    raise exception '対象のキャンプが見つかりません。';
  end if;

  if eligible_emails is null or cardinality(eligible_emails) = 0 then
    raise exception '対象者のメールアドレスを入力してください。';
  end if;

  if cardinality(eligible_emails) > 1000 then
    raise exception '一度に登録できるメールアドレスは1000件までです。';
  end if;

  if exists (
    select 1
    from unnest(eligible_emails) as submitted(email)
    where submitted.email is null
      or submitted.email <> lower(btrim(submitted.email))
      or submitted.email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  ) then
    raise exception '形式が正しくないメールアドレスがあります。';
  end if;

  with normalized_emails as (
    select distinct submitted.email
    from unnest(eligible_emails) as submitted(email)
  )
  insert into public.camp_eligible_users (
    camp_id,
    email_normalized
  )
  select
    target_camp_id,
    normalized.email
  from normalized_emails as normalized
  on conflict (camp_id, email_normalized)
  do update set
    disabled_at = null,
    updated_at = now();

  get diagnostics registered_count = row_count;
  return registered_count;
end;
$$;

revoke all on function public.create_staff_camp(
  text,
  date,
  date,
  timestamptz
) from public;
revoke all on function public.add_camp_eligible_users(uuid, text[]) from public;

grant execute on function public.create_staff_camp(
  text,
  date,
  date,
  timestamptz
) to authenticated;
grant execute on function public.add_camp_eligible_users(uuid, text[])
to authenticated;
