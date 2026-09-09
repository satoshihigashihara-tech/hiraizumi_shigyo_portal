-- MVP phase 1: authentication profiles, staff roles, and fixed room master.

create schema if not exists private;

revoke all on schema private from public;
grant usage on schema private to authenticated;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke all on function public.set_updated_at() from public, anon, authenticated;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  address text,
  phone text,
  emergency_name text,
  emergency_address text,
  emergency_phone text,
  account_state text not null default 'active'
    check (account_state in ('active', 'cleanup_pending', 'disabled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.staff_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (btrim(name) <> ''),
  capacity integer not null check (capacity between 1 and 3),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.contact_settings (
  id smallint primary key check (id = 1),
  name text not null check (btrim(name) <> ''),
  phone text not null check (btrim(phone) <> ''),
  service_hours text not null check (btrim(service_hours) <> ''),
  updated_at timestamptz not null default now()
);

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

create trigger rooms_set_updated_at
before update on public.rooms
for each row execute function public.set_updated_at();

create trigger contact_settings_set_updated_at
before update on public.contact_settings
for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id)
  values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke all on function public.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- If a demo account was created before this migration, add its profile too.
insert into public.profiles (id)
select id from auth.users
on conflict (id) do nothing;

create or replace function private.is_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.staff_roles as staff
    join public.profiles as profile on profile.id = staff.user_id
    where staff.user_id = auth.uid()
      and profile.account_state = 'active'
  );
$$;

revoke all on function private.is_staff() from public;
grant execute on function private.is_staff() to authenticated;

alter table public.profiles enable row level security;
alter table public.staff_roles enable row level security;
alter table public.rooms enable row level security;
alter table public.contact_settings enable row level security;

create policy "profiles_select_own_or_staff"
on public.profiles
for select
to authenticated
using (id = auth.uid() or private.is_staff());

create policy "profiles_update_own"
on public.profiles
for update
to authenticated
using (id = auth.uid() and account_state = 'active')
with check (id = auth.uid() and account_state = 'active');

create policy "staff_roles_select_self_or_staff"
on public.staff_roles
for select
to authenticated
using (user_id = auth.uid() or private.is_staff());

create policy "rooms_select_authenticated"
on public.rooms
for select
to authenticated
using (true);

create policy "contact_settings_select_authenticated"
on public.contact_settings
for select
to authenticated
using (true);

create policy "contact_settings_update_staff"
on public.contact_settings
for update
to authenticated
using (private.is_staff())
with check (private.is_staff() and id = 1);

revoke all on public.profiles from anon, authenticated;
revoke all on public.staff_roles from anon, authenticated;
revoke all on public.rooms from anon, authenticated;
revoke all on public.contact_settings from anon, authenticated;

grant select on public.profiles to authenticated;
grant update (
  full_name,
  address,
  phone,
  emergency_name,
  emergency_address,
  emergency_phone
) on public.profiles to authenticated;

grant select (user_id) on public.staff_roles to authenticated;
grant select on public.rooms to authenticated;
grant select on public.contact_settings to authenticated;
grant update (name, phone, service_hours) on public.contact_settings to authenticated;

insert into public.rooms (name, capacity)
values
  ('桐', 1),
  ('藤', 1),
  ('梅', 2),
  ('竹', 2),
  ('松', 2),
  ('あやめ', 2),
  ('もみぢ', 2),
  ('さくら', 3)
on conflict (name) do update
set capacity = excluded.capacity;

insert into public.contact_settings (id, name, phone, service_hours)
values (1, '平泉町役場（デモ）', '000-000-0000', '平日 8:30〜17:15')
on conflict (id) do nothing;
