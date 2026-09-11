-- T09 foundation: camp/blocked calendar claims only. Apply after 011.
-- Individual claims arrive with T10; group claims arrive with T18 onward.
begin;

-- Serialize backfill with existing camp creation/submission/review RPCs.
update public.facility_guard set id = id where id = 1;
do $$
begin
  if not exists (select 1 from public.facility_guard where id = 1) then
    raise exception 'facility-guard-missing';
  end if;
  if exists (select 1 from public.camps where
    start_date not between date '0001-01-01' and date '9999-12-31'
    or end_date not between date '0001-01-01' and date '9999-12-31'
    or not isfinite(application_deadline)) then
    raise exception 'calendar-backfill-invalid-dates';
  end if;
  if exists (
    select 1 from public.camps a join public.camps b on a.id < b.id
    where a.deleted_at is null and b.deleted_at is null
      and a.start_date <= b.end_date and b.start_date <= a.end_date
  ) then
    raise exception 'calendar-backfill-overlap';
  end if;
  if exists (
    select 1 from public.applications a join public.camps c on c.id = a.camp_id
    where a.status in ('submitted', 'under_review', 'revision_requested', 'approved', 'cancellation_requested')
      and (c.deleted_at is not null or a.start_date is distinct from c.start_date
        or a.end_date is distinct from c.end_date)
  ) then
    raise exception 'calendar-backfill-invalid-applications';
  end if;
end;
$$;

create table public.blocked_periods (
  id uuid primary key default gen_random_uuid(),
  start_date date not null check (start_date between date '0001-01-01' and date '9999-12-31'),
  end_date date not null check (end_date between date '0001-01-01' and date '9999-12-31'),
  internal_reason text not null check (char_length(btrim(internal_reason)) between 1 and 2000),
  created_by uuid references auth.users(id) on delete set null,
  deleted_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (start_date <= end_date)
);

create table public.calendar_claims (
  id uuid primary key default gen_random_uuid(),
  claim_type text not null check (claim_type in ('camp', 'blocked')),
  camp_id uuid unique references public.camps(id) on delete restrict,
  blocked_period_id uuid unique references public.blocked_periods(id) on delete restrict,
  start_date date not null check (start_date between date '0001-01-01' and date '9999-12-31'),
  end_date date not null check (end_date between date '0001-01-01' and date '9999-12-31'),
  released_from date,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (start_date <= end_date),
  check (released_from is null or released_from between start_date and end_date + 1),
  check ((claim_type = 'camp' and camp_id is not null and blocked_period_id is null)
    or (claim_type = 'blocked' and blocked_period_id is not null and camp_id is null))
);
create index calendar_claims_dates_idx on public.calendar_claims (start_date, end_date);
create index blocked_periods_dates_idx on public.blocked_periods (start_date, end_date);

alter table public.blocked_periods enable row level security;
alter table public.calendar_claims enable row level security;
create policy blocked_periods_select_staff on public.blocked_periods
for select to authenticated using (private.is_staff());
create policy calendar_claims_select_staff on public.calendar_claims
for select to authenticated using (private.is_staff());
revoke all on public.blocked_periods, public.calendar_claims from public, anon, authenticated;
grant select on public.blocked_periods, public.calendar_claims to authenticated;

-- Reuse the monotonic microsecond version trigger introduced by 010.
drop trigger camps_set_updated_at on public.camps;
create trigger camps_set_updated_at before update on public.camps
for each row execute function private.set_application_updated_at();
create trigger blocked_periods_set_updated_at before update on public.blocked_periods
for each row execute function private.set_application_updated_at();
create trigger calendar_claims_set_updated_at before update on public.calendar_claims
for each row execute function private.set_application_updated_at();

create function private.lock_calendar_facility()
returns void language plpgsql security definer set search_path = '' as $$
begin
  -- A real UPDATE also rejects stale REPEATABLE READ snapshots.
  update public.facility_guard as g set id = g.id where g.id = 1;
  if not found then raise exception 'facility-guard-missing'; end if;
end;
$$;

create function private.lock_calendar_for_staff()
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not private.is_staff() then
    raise exception using errcode = '42501', message = 'staff-required';
  end if;
  perform private.lock_calendar_facility();
  perform s.user_id from public.staff_roles s join public.profiles p on p.id = s.user_id
  where s.user_id = auth.uid() and p.account_state = 'active' for share of s, p;
  if not found then
    raise exception using errcode = '42501', message = 'staff-required';
  end if;
end;
$$;

create function private.check_calendar_version(actual_value timestamptz, expected_value timestamptz)
returns void language plpgsql set search_path = '' as $$
begin
  if expected_value is null or not isfinite(expected_value) then raise exception 'invalid-version'; end if;
  if actual_value is distinct from expected_value then raise exception 'stale-update'; end if;
end;
$$;

create function private.check_calendar_period(starts_on date, ends_on date)
returns void language plpgsql set search_path = '' as $$
begin
  if starts_on is null or ends_on is null or starts_on > ends_on
    or starts_on not between date '0001-01-01' and date '9999-12-31'
    or ends_on not between date '0001-01-01' and date '9999-12-31' then
    raise exception 'invalid-period';
  end if;
end;
$$;

create function private.check_calendar_reason(reason_value text)
returns void language plpgsql set search_path = '' as $$
begin
  if nullif(btrim(reason_value), '') is null then raise exception 'reason-required'; end if;
  if char_length(btrim(reason_value)) > 2000 then raise exception 'reason-too-long'; end if;
end;
$$;

-- Only internal code maintains derived claims. Source writes and claim writes
-- share a transaction; clients have no direct write grants on either table.
-- The business RPC must acquire facility_guard BEFORE modifying its source.
create function private.sync_calendar_claim()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'camps' then
    insert into public.calendar_claims (claim_type, camp_id, start_date, end_date, released_from)
    values ('camp', new.id, new.start_date, new.end_date,
      case when new.deleted_at is not null then new.start_date end)
    on conflict (camp_id) do update set start_date = excluded.start_date,
      end_date = excluded.end_date, released_from = excluded.released_from
    where (calendar_claims.start_date, calendar_claims.end_date, calendar_claims.released_from)
      is distinct from (excluded.start_date, excluded.end_date, excluded.released_from);
  else
    insert into public.calendar_claims (claim_type, blocked_period_id, start_date, end_date, released_from)
    values ('blocked', new.id, new.start_date, new.end_date,
      case when new.deleted_at is not null then new.start_date end)
    on conflict (blocked_period_id) do update set start_date = excluded.start_date,
      end_date = excluded.end_date, released_from = excluded.released_from
    where (calendar_claims.start_date, calendar_claims.end_date, calendar_claims.released_from)
      is distinct from (excluded.start_date, excluded.end_date, excluded.released_from);
  end if;
  return new;
end;
$$;
create trigger camps_sync_calendar_claim after insert or update on public.camps
for each row execute function private.sync_calendar_claim();
create trigger blocked_periods_sync_calendar_claim after insert or update on public.blocked_periods
for each row execute function private.sync_calendar_claim();

insert into public.calendar_claims (claim_type, camp_id, start_date, end_date, released_from)
select 'camp', id, start_date, end_date, case when deleted_at is not null then start_date end
from public.camps;

create function private.calendar_snapshot(entity_kind text, target_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('record', coalesce(
    case when entity_kind = 'camp' then (select to_jsonb(c) from public.camps c where c.id = target_id)
    else (select to_jsonb(b) from public.blocked_periods b where b.id = target_id) end, '{}'::jsonb),
    'claim', coalesce((select to_jsonb(q) from public.calendar_claims q
      where (entity_kind = 'camp' and q.camp_id = target_id)
        or (entity_kind = 'blocked' and q.blocked_period_id = target_id)), '{}'::jsonb));
$$;

create function private.record_calendar_audit(
  entity_kind text, target_id uuid, operation text, before_value jsonb, reason_value text
)
returns void language sql security definer set search_path = '' as $$
  insert into public.audit_logs (entity_type, entity_id, action, before_data, after_data,
    actor_kind, actor_user_id, reason)
  values (entity_kind, target_id, operation, before_value,
    private.calendar_snapshot(entity_kind, target_id), 'staff', auth.uid(), nullif(btrim(reason_value), ''));
$$;

-- Error DETAIL is staff-only diagnostic data. Public reads never call this.
-- Besides claims, check active applications so an inconsistent reservation
-- cannot be hidden by a missing claim. Own-camp participants are not competitors.
create function private.assert_calendar_available(
  starts_on date, ends_on date, ignored_camp uuid default null, ignored_block uuid default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare conflicts jsonb;
begin
  perform private.check_calendar_period(starts_on, ends_on);
  select jsonb_agg(x.item) into conflicts from (
    select jsonb_build_object('type', q.claim_type,
      'id', coalesce(q.camp_id, q.blocked_period_id),
      'name', coalesce(c.name, '利用停止'), 'startDate', q.start_date, 'endDate', q.end_date,
      'status', 'active') as item
    from public.calendar_claims q left join public.camps c on c.id = q.camp_id
    where q.start_date <= ends_on and q.end_date >= starts_on
      and (q.released_from is null or greatest(q.start_date, starts_on) < q.released_from)
      and (ignored_camp is null or q.camp_id is distinct from ignored_camp)
      and (ignored_block is null or q.blocked_period_id is distinct from ignored_block)
    union all
    select jsonb_build_object('type', 'application', 'id', a.id, 'campId', a.camp_id,
      'name', a.user_name, 'receptionNumber', n.display_number,
      'startDate', a.start_date, 'endDate', a.end_date, 'status', a.status)
    from public.applications a left join public.reception_numbers n on n.application_id = a.id
    where a.start_date <= ends_on and a.end_date >= starts_on
      and a.status in ('submitted', 'under_review', 'revision_requested', 'approved', 'cancellation_requested')
      and (ignored_camp is null or a.camp_id <> ignored_camp)
  ) x;
  if conflicts is not null then
    raise exception using message = 'date-conflict', detail = conflicts::text;
  end if;
end;
$$;

create function private.assert_camp_editable(target_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare conflicts jsonb;
begin
  perform a.id from public.applications a where a.camp_id = target_id order by a.id for update;
  select jsonb_agg(jsonb_build_object('type', 'application', 'id', a.id, 'campId', a.camp_id,
    'name', a.user_name, 'receptionNumber', n.display_number, 'status', a.status,
    'startDate', a.start_date, 'endDate', a.end_date)) into conflicts
  from public.applications a left join public.reception_numbers n on n.application_id = a.id
  where a.camp_id = target_id
    and a.status in ('submitted', 'under_review', 'revision_requested', 'approved', 'cancellation_requested');
  if conflicts is not null then
    raise exception using message = 'camp-has-applications', detail = conflicts::text;
  end if;
end;
$$;

create function private.check_camp_calendar(target_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare camp_record public.camps%rowtype;
begin
  select * into camp_record from public.camps where id = target_id and deleted_at is null for share;
  if not found then raise exception '対象のキャンプが見つかりません。'; end if;
  if not exists (select 1 from public.calendar_claims q where q.camp_id = target_id
    and q.start_date = camp_record.start_date and q.end_date = camp_record.end_date
    and q.released_from is null) then raise exception 'calendar-inconsistent'; end if;
  -- Do not disclose competing applications to a camp applicant through DETAIL.
  begin
    perform private.assert_calendar_available(camp_record.start_date, camp_record.end_date, target_id);
  exception when sqlstate 'P0001' then
    raise exception using message = 'calendar-unavailable', detail = '';
  end;
end;
$$;

create function private.check_camp_calendar_input(
  camp_name text, starts_on date, ends_on date, deadline_value timestamptz
)
returns void language plpgsql set search_path = '' as $$
begin
  perform private.check_calendar_period(starts_on, ends_on);
  if nullif(btrim(camp_name), '') is null or char_length(btrim(camp_name)) > 120 then
    raise exception 'invalid-name';
  end if;
  if deadline_value is null or not isfinite(deadline_value)
    or deadline_value > (starts_on::timestamp at time zone 'Asia/Tokyo') then
    raise exception 'invalid-deadline';
  end if;
end;
$$;

create or replace function public.create_staff_camp(
  camp_name text, camp_start_date date, camp_end_date date, camp_application_deadline timestamptz
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare new_id uuid;
begin
  perform private.lock_calendar_for_staff();
  perform private.check_camp_calendar_input(camp_name, camp_start_date, camp_end_date, camp_application_deadline);
  perform private.assert_calendar_available(camp_start_date, camp_end_date);
  insert into public.camps (name, start_date, end_date, application_deadline, created_by)
  values (btrim(camp_name), camp_start_date, camp_end_date, camp_application_deadline, auth.uid())
  returning id into new_id;
  perform private.record_calendar_audit('camp', new_id, 'create_camp', '{}'::jsonb, null);
  return new_id;
end;
$$;

create function public.update_staff_camp(
  target_camp_id uuid, camp_name text, camp_start_date date, camp_end_date date,
  camp_application_deadline timestamptz, expected_updated_at timestamptz, change_reason text
)
returns table (result_id uuid, result_updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare c public.camps%rowtype; before_value jsonb; draft_record public.applications%rowtype;
begin
  perform private.lock_calendar_for_staff();
  select * into c from public.camps where id = target_camp_id for update;
  if not found then raise exception 'not-found'; end if;
  perform private.check_calendar_version(c.updated_at, expected_updated_at);
  if c.deleted_at is not null then raise exception 'invalid-status'; end if;
  perform private.check_camp_calendar_input(camp_name, camp_start_date, camp_end_date, camp_application_deadline);
  if (c.name, c.start_date, c.end_date, c.application_deadline) is not distinct from
    (btrim(camp_name), camp_start_date, camp_end_date, camp_application_deadline) then
    return query select c.id, c.updated_at; return;
  end if;
  perform private.check_calendar_reason(change_reason);
  if (c.start_date, c.end_date) is distinct from (camp_start_date, camp_end_date) then
    perform private.assert_camp_editable(c.id);
  end if;
  perform private.assert_calendar_available(camp_start_date, camp_end_date, c.id);
  before_value := private.calendar_snapshot('camp', c.id);
  if (c.start_date, c.end_date) is distinct from (camp_start_date, camp_end_date) then
    for draft_record in select * from public.applications where camp_id = c.id and status = 'draft'
      order by id for update loop
      update public.applications set start_date = camp_start_date, end_date = camp_end_date
      where id = draft_record.id;
      insert into public.audit_logs (entity_type, entity_id, action, before_data, after_data,
        actor_kind, actor_user_id, reason)
      select 'application', a.id, 'camp_dates_changed',
        jsonb_build_object('start_date', draft_record.start_date, 'end_date', draft_record.end_date,
          'updated_at', draft_record.updated_at),
        jsonb_build_object('start_date', a.start_date, 'end_date', a.end_date, 'updated_at', a.updated_at),
        'staff', auth.uid(), btrim(change_reason) from public.applications a where a.id = draft_record.id;
    end loop;
  end if;
  update public.camps set name = btrim(camp_name), start_date = camp_start_date,
    end_date = camp_end_date, application_deadline = camp_application_deadline
  where id = c.id returning * into c;
  perform private.record_calendar_audit('camp', c.id, 'update_camp', before_value, change_reason);
  return query select c.id, c.updated_at;
end;
$$;

create function public.delete_staff_camp(target_camp_id uuid, expected_updated_at timestamptz, change_reason text)
returns table (result_id uuid, result_updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare c public.camps%rowtype; before_value jsonb;
begin
  perform private.lock_calendar_for_staff();
  select * into c from public.camps where id = target_camp_id for update;
  if not found then raise exception 'not-found'; end if;
  perform private.check_calendar_version(c.updated_at, expected_updated_at);
  if c.deleted_at is not null then raise exception 'invalid-status'; end if;
  perform private.check_calendar_reason(change_reason);
  perform private.assert_camp_editable(c.id);
  before_value := private.calendar_snapshot('camp', c.id);
  update public.camps set deleted_at = clock_timestamp() where id = c.id returning * into c;
  perform private.record_calendar_audit('camp', c.id, 'delete_camp', before_value, change_reason);
  return query select c.id, c.updated_at;
end;
$$;

create function public.save_staff_blocked_period(
  target_blocked_period_id uuid, blocked_start_date date, blocked_end_date date, internal_reason text,
  expected_updated_at timestamptz default null, change_reason text default null
)
returns table (result_id uuid, result_updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare b public.blocked_periods%rowtype; before_value jsonb := '{}'::jsonb; operation text := 'create_blocked_period';
begin
  perform private.lock_calendar_for_staff();
  perform private.check_calendar_period(blocked_start_date, blocked_end_date);
  perform private.check_calendar_reason(internal_reason);
  if target_blocked_period_id is not null then
    select * into b from public.blocked_periods where id = target_blocked_period_id for update;
    if not found then raise exception 'not-found'; end if;
    perform private.check_calendar_version(b.updated_at, expected_updated_at);
    if b.deleted_at is not null then raise exception 'invalid-status'; end if;
    if (b.start_date, b.end_date, b.internal_reason) is not distinct from
      (blocked_start_date, blocked_end_date, btrim(internal_reason)) then
      return query select b.id, b.updated_at; return;
    end if;
    perform private.check_calendar_reason(change_reason);
    before_value := private.calendar_snapshot('blocked', b.id);
    operation := 'update_blocked_period';
  end if;
  perform private.assert_calendar_available(blocked_start_date, blocked_end_date, null, target_blocked_period_id);
  if target_blocked_period_id is null then
    insert into public.blocked_periods (start_date, end_date, internal_reason, created_by)
    values (blocked_start_date, blocked_end_date, btrim(internal_reason), auth.uid()) returning * into b;
  else
    update public.blocked_periods set start_date = blocked_start_date, end_date = blocked_end_date,
      internal_reason = btrim(save_staff_blocked_period.internal_reason)
    where id = b.id returning * into b;
  end if;
  perform private.record_calendar_audit('blocked', b.id, operation, before_value, change_reason);
  return query select b.id, b.updated_at;
end;
$$;

create function public.delete_staff_blocked_period(
  target_blocked_period_id uuid, expected_updated_at timestamptz, change_reason text
)
returns table (result_id uuid, result_updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare b public.blocked_periods%rowtype; before_value jsonb;
begin
  perform private.lock_calendar_for_staff();
  select * into b from public.blocked_periods where id = target_blocked_period_id for update;
  if not found then raise exception 'not-found'; end if;
  perform private.check_calendar_version(b.updated_at, expected_updated_at);
  if b.deleted_at is not null then raise exception 'invalid-status'; end if;
  perform private.check_calendar_reason(change_reason);
  before_value := private.calendar_snapshot('blocked', b.id);
  update public.blocked_periods set deleted_at = clock_timestamp() where id = b.id returning * into b;
  perform private.record_calendar_audit('blocked', b.id, 'delete_blocked_period', before_value, change_reason);
  return query select b.id, b.updated_at;
end;
$$;

create function private.calendar_month_end(target_month date)
returns date language plpgsql immutable set search_path = '' as $$
begin
  if target_month is null or target_month not between date '0001-01-01' and date '9999-12-01'
    or extract(day from target_month) <> 1 then raise exception 'invalid-month'; end if;
  return (target_month + interval '1 month')::date - 1;
end;
$$;

create function public.get_public_calendar(target_month date)
returns table (date date, availability text)
language plpgsql stable security definer set search_path = '' as $$
declare last_day date := private.calendar_month_end(target_month);
  today_jst date := (clock_timestamp() at time zone 'Asia/Tokyo')::date;
begin
  return query select target_month + d.day_offset,
    case when target_month + d.day_offset > today_jst + 60 then 'not_yet_open'
      when target_month + d.day_offset < today_jst + 14 then 'unavailable'
      when exists (select 1 from public.calendar_claims q
        where q.start_date <= target_month + d.day_offset and q.end_date >= target_month + d.day_offset
          and (q.released_from is null or target_month + d.day_offset < q.released_from)) then 'unavailable'
      else 'available' end
  from generate_series(0, last_day - target_month) d(day_offset) order by d.day_offset;
end;
$$;

create function public.get_staff_calendar(target_month date)
returns table (entry_type text, entry_id uuid, start_date date, end_date date, title text,
  people_count bigint, internal_reason text, updated_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare last_day date;
begin
  if auth.uid() is null or not private.is_staff() then
    raise exception using errcode = '42501', message = 'staff-required';
  end if;
  last_day := private.calendar_month_end(target_month);
  return query select 'camp'::text, c.id, c.start_date, c.end_date, c.name,
    (select count(*) from public.applications a where a.camp_id = c.id
      and a.status in ('submitted', 'under_review', 'revision_requested', 'approved', 'cancellation_requested')),
    null::text, c.updated_at
  from public.camps c where c.deleted_at is null and c.start_date <= last_day and c.end_date >= target_month
  union all
  select 'blocked'::text, b.id, b.start_date, b.end_date, '利用停止'::text, 0::bigint, b.internal_reason, b.updated_at
  from public.blocked_periods b where b.deleted_at is null and b.start_date <= last_day and b.end_date >= target_month
  order by 3, 1, 2;
end;
$$;

create function public.get_staff_calendar_day(target_date date)
returns table (entry_type text, entry_id uuid, camp_id uuid, reception_number text,
  display_name text, people_count bigint, status text, start_date date, end_date date,
  internal_reason text, updated_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not private.is_staff() then
    raise exception using errcode = '42501', message = 'staff-required';
  end if;
  perform private.check_calendar_period(target_date, target_date);
  return query
  select 'camp'::text, c.id, c.id, null::text, c.name,
    (select count(*) from public.applications a where a.camp_id = c.id
      and a.status in ('submitted', 'under_review', 'revision_requested', 'approved', 'cancellation_requested')),
    'scheduled'::text, c.start_date, c.end_date, null::text, c.updated_at
  from public.camps c where c.deleted_at is null and target_date between c.start_date and c.end_date
  union all
  select 'blocked'::text, b.id, null::uuid, null::text, '利用停止'::text, 0::bigint,
    'blocked'::text, b.start_date, b.end_date, b.internal_reason, b.updated_at
  from public.blocked_periods b where b.deleted_at is null and target_date between b.start_date and b.end_date
  union all
  select 'application'::text, a.id, a.camp_id, n.display_number, a.user_name, 1::bigint,
    a.status, a.start_date, a.end_date, null::text, a.updated_at
  from public.applications a left join public.reception_numbers n on n.application_id = a.id
  where target_date between a.start_date and a.end_date
    and a.status in ('submitted', 'under_review', 'revision_requested', 'approved', 'cancellation_requested')
  order by 1, 2;
end;
$$;

-- Keep deleted camp records accessible to staff for the retained history.
drop policy camps_select_eligible_or_staff on public.camps;
create policy camps_select_eligible_or_staff on public.camps for select to authenticated
using (private.is_staff() or (deleted_at is null and private.can_read_camp(id)));

-- Entry-point compatibility updates and explicit function grants follow below.

-- Preserve 011 draft reuse and deadline behavior, with a serialized entry.
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

  perform private.lock_calendar_facility();
  perform p.id from public.profiles p where p.id = current_user_id
    and p.account_state = 'active' for share;
  if not found then raise exception 'このアカウントでは申請できません。'; end if;

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

-- Preserve 006 consent wrapper and the 009 core; recheck the calendar safely.
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
  perform private.lock_calendar_facility();
  perform p.id from public.profiles p where p.id = current_user_id
    and p.account_state = 'active' for share;
  if not found then raise exception 'ログインが必要です。'; end if;

  select application.*
  into application_record
  from public.applications as application
  where application.id = target_application_id
  for update;

  if not found or application_record.user_id <> current_user_id then
    raise exception '申請が見つかりません。';
  end if;

  perform private.check_camp_calendar(application_record.camp_id);

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

-- Prevent eligibility additions racing with camp deletion.
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

  perform private.lock_calendar_for_staff();

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

revoke all on function private.lock_calendar_facility() from public, anon, authenticated, service_role;
revoke all on function private.lock_calendar_for_staff() from public, anon, authenticated, service_role;
revoke all on function private.check_calendar_version(timestamptz, timestamptz) from public, anon, authenticated, service_role;
revoke all on function private.check_calendar_period(date, date) from public, anon, authenticated, service_role;
revoke all on function private.check_calendar_reason(text) from public, anon, authenticated, service_role;
revoke all on function private.sync_calendar_claim() from public, anon, authenticated, service_role;
revoke all on function private.calendar_snapshot(text, uuid) from public, anon, authenticated, service_role;
revoke all on function private.record_calendar_audit(text, uuid, text, jsonb, text) from public, anon, authenticated, service_role;
revoke all on function private.assert_calendar_available(date, date, uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function private.assert_camp_editable(uuid) from public, anon, authenticated, service_role;
revoke all on function private.check_camp_calendar(uuid) from public, anon, authenticated, service_role;
revoke all on function private.check_camp_calendar_input(text, date, date, timestamptz) from public, anon, authenticated, service_role;
revoke all on function private.calendar_month_end(date) from public, anon, authenticated, service_role;
revoke all on function public.create_staff_camp(text, date, date, timestamptz) from public, anon, authenticated;
grant execute on function public.create_staff_camp(text, date, date, timestamptz) to authenticated;
revoke all on function public.update_staff_camp(uuid, text, date, date, timestamptz, timestamptz, text) from public, anon, authenticated;
grant execute on function public.update_staff_camp(uuid, text, date, date, timestamptz, timestamptz, text) to authenticated;
revoke all on function public.delete_staff_camp(uuid, timestamptz, text) from public, anon, authenticated;
grant execute on function public.delete_staff_camp(uuid, timestamptz, text) to authenticated;
revoke all on function public.save_staff_blocked_period(uuid, date, date, text, timestamptz, text) from public, anon, authenticated;
grant execute on function public.save_staff_blocked_period(uuid, date, date, text, timestamptz, text) to authenticated;
revoke all on function public.delete_staff_blocked_period(uuid, timestamptz, text) from public, anon, authenticated;
grant execute on function public.delete_staff_blocked_period(uuid, timestamptz, text) to authenticated;
revoke all on function public.get_staff_calendar(date) from public, anon, authenticated;
grant execute on function public.get_staff_calendar(date) to authenticated;
revoke all on function public.get_staff_calendar_day(date) from public, anon, authenticated;
grant execute on function public.get_staff_calendar_day(date) to authenticated;
revoke all on function public.create_camp_application_draft(uuid) from public, anon, authenticated;
grant execute on function public.create_camp_application_draft(uuid) to authenticated;
revoke all on function public.submit_camp_application(uuid) from public, anon, authenticated;
grant execute on function public.submit_camp_application(uuid) to authenticated;
revoke all on function public.add_camp_eligible_users(uuid, text[]) from public, anon, authenticated;
grant execute on function public.add_camp_eligible_users(uuid, text[]) to authenticated;
revoke all on function public.get_public_calendar(date) from public, anon, authenticated;
grant execute on function public.get_public_calendar(date) to anon, authenticated;
revoke insert, update, delete, truncate, references, trigger
on public.camps, public.camp_eligible_users, public.blocked_periods, public.calendar_claims
from public, anon, authenticated;

commit;
