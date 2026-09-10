-- MVP phase 2: camp applications and their related records.

create table public.camps (
  id uuid primary key default gen_random_uuid(),
  name text not null check (btrim(name) <> ''),
  start_date date not null,
  end_date date not null,
  application_deadline timestamptz not null,
  deleted_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (start_date <= end_date)
);

create table public.camp_eligible_users (
  id uuid primary key default gen_random_uuid(),
  camp_id uuid not null references public.camps(id) on delete cascade,
  email_normalized text not null
    check (
      email_normalized = lower(btrim(email_normalized))
      and email_normalized <> ''
    ),
  disabled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (camp_id, email_normalized)
);

create table public.applications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  usage_type text not null default 'camp' check (usage_type = 'camp'),
  camp_id uuid not null references public.camps(id),
  original_application_id uuid references public.applications(id),
  status text not null default 'draft'
    check (
      status in (
        'draft',
        'submitted',
        'under_review',
        'revision_requested',
        'approved',
        'rejected',
        'cancellation_requested',
        'cancelled'
      )
    ),
  start_date date,
  end_date date,
  user_name text,
  user_address text,
  user_phone text,
  email_snapshot text,
  emergency_name text,
  emergency_address text,
  emergency_phone text,
  usage_place text check (
    usage_place is null or usage_place = 'common_and_second_floor'
  ),
  purpose text,
  local_activity text,
  special_notes text,
  requires_guardian_consent boolean,
  room_preference text check (
    room_preference is null
    or room_preference in ('shared_ok', 'private_requested')
  ),
  extension_reason text,
  submitted_at timestamptz,
  last_submitted_at timestamptz,
  revision_due_at timestamptz,
  decision_reason text,
  approval_comment text,
  cancel_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (start_date is null and end_date is null)
    or (start_date is not null and end_date is not null and start_date <= end_date)
  ),
  check (original_application_id is null or original_application_id <> id)
);

create unique index applications_one_active_camp_per_user
on public.applications (user_id, camp_id)
where user_id is not null and status not in ('rejected', 'cancelled');

create index applications_user_id_idx on public.applications (user_id);
create index applications_camp_id_idx on public.applications (camp_id);
create index applications_status_idx on public.applications (status);

create table public.application_status_events (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.applications(id) on delete cascade,
  from_status text,
  to_status text not null,
  public_reason text,
  actor_user_id uuid references auth.users(id) on delete set null,
  occurred_at timestamptz not null default now()
);

create index application_status_events_application_id_idx
on public.application_status_events (application_id, occurred_at);

create table public.reception_counters (
  fiscal_year integer primary key,
  last_number integer not null default 0 check (last_number >= 0),
  updated_at timestamptz not null default now()
);

create table public.reception_numbers (
  id uuid primary key default gen_random_uuid(),
  fiscal_year integer not null references public.reception_counters(fiscal_year),
  serial_number integer not null check (serial_number > 0),
  display_number text not null unique,
  application_id uuid not null unique references public.applications(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (fiscal_year, serial_number)
);

create table public.application_charges (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null unique references public.applications(id) on delete cascade,
  total_amount integer not null check (total_amount >= 0),
  payment_status text not null default 'unpaid'
    check (payment_status in ('unpaid', 'paid')),
  payment_due_date date,
  paid_at timestamptz,
  calculated_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (payment_status = 'unpaid' and paid_at is null)
    or (payment_status = 'paid' and paid_at is not null)
  )
);

create table public.charge_months (
  id uuid primary key default gen_random_uuid(),
  charge_id uuid not null references public.application_charges(id) on delete cascade,
  month date not null check (month = date_trunc('month', month)::date),
  usage_days integer not null check (usage_days > 0),
  daily_rate integer not null default 300 check (daily_rate = 300),
  monthly_cap integer not null default 9000 check (monthly_cap = 9000),
  amount integer not null check (amount >= 0),
  unique (charge_id, month),
  check (amount = least(usage_days * daily_rate, monthly_cap))
);

create table public.room_allocations (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id),
  application_id uuid not null unique references public.applications(id) on delete cascade,
  people_count integer not null default 1 check (people_count = 1),
  start_date date not null,
  end_date date not null,
  released_from date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (start_date <= end_date)
);

create index room_allocations_room_dates_idx
on public.room_allocations (room_id, start_date, end_date);

create table public.stays (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null unique references public.applications(id) on delete cascade,
  status text not null default 'before_move_in'
    check (status in ('before_move_in', 'staying', 'moved_out')),
  checked_in_at timestamptz,
  checked_out_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (status = 'before_move_in' and checked_in_at is null and checked_out_at is null)
    or (status = 'staying' and checked_in_at is not null and checked_out_at is null)
    or (
      status = 'moved_out'
      and checked_in_at is not null
      and checked_out_at is not null
      and checked_out_at >= checked_in_at
    )
  )
);

create trigger camps_set_updated_at
before update on public.camps
for each row execute function public.set_updated_at();

create trigger camp_eligible_users_set_updated_at
before update on public.camp_eligible_users
for each row execute function public.set_updated_at();

create trigger applications_set_updated_at
before update on public.applications
for each row execute function public.set_updated_at();

create trigger application_charges_set_updated_at
before update on public.application_charges
for each row execute function public.set_updated_at();

create trigger room_allocations_set_updated_at
before update on public.room_allocations
for each row execute function public.set_updated_at();

create trigger stays_set_updated_at
before update on public.stays
for each row execute function public.set_updated_at();

create or replace function private.has_active_profile()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles as profile
    where profile.id = auth.uid()
      and profile.account_state = 'active'
  );
$$;

create or replace function private.can_read_camp(target_camp_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_staff() or (
    private.has_active_profile()
    and exists (
      select 1
      from public.camp_eligible_users as eligible
      where eligible.camp_id = target_camp_id
        and eligible.disabled_at is null
        and eligible.email_normalized = lower(auth.jwt() ->> 'email')
    )
  );
$$;

create or replace function private.can_read_application(target_application_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_staff() or exists (
    select 1
    from public.applications as application
    join public.profiles as profile on profile.id = application.user_id
    where application.id = target_application_id
      and application.user_id = auth.uid()
      and profile.account_state = 'active'
  );
$$;

revoke all on function private.has_active_profile() from public;
revoke all on function private.can_read_camp(uuid) from public;
revoke all on function private.can_read_application(uuid) from public;

grant execute on function private.has_active_profile() to authenticated;
grant execute on function private.can_read_camp(uuid) to authenticated;
grant execute on function private.can_read_application(uuid) to authenticated;

alter table public.camps enable row level security;
alter table public.camp_eligible_users enable row level security;
alter table public.applications enable row level security;
alter table public.application_status_events enable row level security;
alter table public.reception_counters enable row level security;
alter table public.reception_numbers enable row level security;
alter table public.application_charges enable row level security;
alter table public.charge_months enable row level security;
alter table public.room_allocations enable row level security;
alter table public.stays enable row level security;

create policy "camps_select_eligible_or_staff"
on public.camps
for select
to authenticated
using (deleted_at is null and private.can_read_camp(id));

create policy "camp_eligible_users_select_staff"
on public.camp_eligible_users
for select
to authenticated
using (private.is_staff());

create policy "applications_select_owner_or_staff"
on public.applications
for select
to authenticated
using (private.can_read_application(id));

create policy "application_status_events_select_owner_or_staff"
on public.application_status_events
for select
to authenticated
using (private.can_read_application(application_id));

create policy "reception_numbers_select_owner_or_staff"
on public.reception_numbers
for select
to authenticated
using (private.can_read_application(application_id));

create policy "application_charges_select_owner_or_staff"
on public.application_charges
for select
to authenticated
using (private.can_read_application(application_id));

create policy "charge_months_select_owner_or_staff"
on public.charge_months
for select
to authenticated
using (
  exists (
    select 1
    from public.application_charges as charge
    where charge.id = charge_months.charge_id
      and private.can_read_application(charge.application_id)
  )
);

create policy "room_allocations_select_owner_or_staff"
on public.room_allocations
for select
to authenticated
using (private.can_read_application(application_id));

create policy "stays_select_owner_or_staff"
on public.stays
for select
to authenticated
using (private.can_read_application(application_id));

revoke all on public.camps from anon, authenticated;
revoke all on public.camp_eligible_users from anon, authenticated;
revoke all on public.applications from anon, authenticated;
revoke all on public.application_status_events from anon, authenticated;
revoke all on public.reception_counters from anon, authenticated;
revoke all on public.reception_numbers from anon, authenticated;
revoke all on public.application_charges from anon, authenticated;
revoke all on public.charge_months from anon, authenticated;
revoke all on public.room_allocations from anon, authenticated;
revoke all on public.stays from anon, authenticated;

grant select on public.camps to authenticated;
grant select on public.camp_eligible_users to authenticated;
grant select on public.applications to authenticated;
grant select on public.application_status_events to authenticated;
grant select on public.reception_numbers to authenticated;
grant select on public.application_charges to authenticated;
grant select on public.charge_months to authenticated;
grant select on public.room_allocations to authenticated;
grant select on public.stays to authenticated;
