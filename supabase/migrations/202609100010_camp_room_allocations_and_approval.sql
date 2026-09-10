-- T12: staff room assignment and approval for camp individuals only.
-- Apply after 009, together with the updated staff Server Actions.
-- Drop the old review signature so callers cannot bypass version checks.
begin;

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null check (btrim(entity_type) <> ''),
  entity_id uuid not null,
  action text not null check (btrim(action) <> ''),
  before_data jsonb not null check (jsonb_typeof(before_data) = 'object'),
  after_data jsonb not null check (jsonb_typeof(after_data) = 'object'),
  actor_kind text not null check (actor_kind in ('user', 'staff', 'system')),
  actor_user_id uuid references auth.users(id) on delete set null,
  reason text,
  occurred_at timestamptz not null default clock_timestamp()
);

create index audit_logs_entity_idx
on public.audit_logs (entity_type, entity_id, occurred_at);

alter table public.audit_logs enable row level security;
create policy "audit_logs_select_staff"
on public.audit_logs for select to authenticated
using (private.is_staff());

revoke all on public.audit_logs from public, anon, authenticated;
grant select on public.audit_logs to authenticated;

-- A transaction can start before a competing transaction finishes. now()
-- alone can move the version backwards or reuse it within one transaction.
create function private.set_application_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := greatest(clock_timestamp(), old.updated_at + interval '1 microsecond');
  return new;
end;
$$;

revoke all on function private.set_application_updated_at()
from public, anon, authenticated, service_role;

drop trigger applications_set_updated_at on public.applications;
create trigger applications_set_updated_at
before update on public.applications
for each row execute function private.set_application_updated_at();

-- Internal only. Lock facility -> application -> staff/profile rows.
create function private.lock_camp_application_for_staff(
  target_application_id uuid,
  expected_updated_at timestamptz
)
returns public.applications
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_record public.applications%rowtype;
begin
  if auth.uid() is null or not private.is_staff() then
    raise exception using errcode = '42501', message = 'staff-required';
  end if;

  if expected_updated_at is null or not isfinite(expected_updated_at) then
    raise exception using message = 'invalid-version';
  end if;

  -- Updating the guard also forces a serialization failure when a caller uses
  -- a stale REPEATABLE READ snapshot instead of PostgREST's READ COMMITTED.
  update public.facility_guard as guard set id = guard.id where guard.id = 1;
  if not found then
    raise exception using message = 'facility-guard-missing';
  end if;

  select application.* into application_record
  from public.applications as application
  where application.id = target_application_id and application.usage_type = 'camp'
  for update;
  if not found then
    raise exception using message = 'not-found';
  end if;

  -- Recheck after waiting and keep staff authorization valid until commit.
  perform staff.user_id
  from public.staff_roles as staff
  join public.profiles as profile on profile.id = staff.user_id
  where staff.user_id = auth.uid() and profile.account_state = 'active'
  for share of staff, profile;
  if not found then
    raise exception using errcode = '42501', message = 'staff-required';
  end if;

  if application_record.updated_at is distinct from expected_updated_at then
    raise exception using message = 'stale-update';
  end if;

  return application_record;
end;
$$;

revoke all on function private.lock_camp_application_for_staff(uuid, timestamptz)
from public, anon, authenticated, service_role;

-- Caller must already hold facility_guard and the target application lock.
-- Count both pending reservations and room occupants, across all camps.
-- Use integer date offsets so day boundaries do not depend on session timezone.
create function private.check_camp_room_capacity(
  target_application_id uuid,
  target_room_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_record public.applications%rowtype;
  camp_record public.camps%rowtype;
  room_capacity integer;
begin
  select application.* into application_record
  from public.applications as application
  where application.id = target_application_id and application.usage_type = 'camp';
  if not found then
    raise exception using message = 'not-found';
  end if;

  select camp.* into camp_record from public.camps as camp
  where camp.id = application_record.camp_id and camp.deleted_at is null
  for share;
  if not found then
    raise exception using message = 'camp-unavailable';
  end if;

  if application_record.start_date is null or application_record.end_date is null
    or application_record.start_date is distinct from camp_record.start_date
    or application_record.end_date is distinct from camp_record.end_date then
    raise exception using message = 'camp-dates-changed';
  end if;

  select room.capacity into room_capacity from public.rooms as room
  where room.id = target_room_id for share;
  if not found then
    raise exception using message = 'invalid-room';
  end if;

  -- Include submitted/revision/cancellation requests even without a room.
  if exists (
    select day.day_offset
    from generate_series(0, application_record.end_date - application_record.start_date)
      as day(day_offset)
    join public.applications as other
      on other.start_date <= application_record.start_date + day.day_offset
      and other.end_date >= application_record.start_date + day.day_offset
      and other.id <> target_application_id
      and other.status in (
        'submitted', 'under_review', 'revision_requested', 'approved', 'cancellation_requested'
      )
    group by day.day_offset
    having count(*) + 1 > 15
  ) then
    raise exception using message = 'facility-capacity-full';
  end if;

  if exists (
    select day.day_offset
    from generate_series(0, application_record.end_date - application_record.start_date)
      as day(day_offset)
    join public.room_allocations as allocation
      on allocation.start_date <= application_record.start_date + day.day_offset
      and allocation.end_date >= application_record.start_date + day.day_offset
      and (allocation.released_from is null
        or application_record.start_date + day.day_offset < allocation.released_from)
      and allocation.application_id <> target_application_id
    join public.applications as other on other.id = allocation.application_id
      and other.status in (
        'submitted', 'under_review', 'revision_requested', 'approved', 'cancellation_requested'
      )
    group by day.day_offset
    having sum(allocation.people_count) + 1 > 15
      or coalesce(sum(allocation.people_count)
        filter (where allocation.room_id = target_room_id), 0) + 1 > room_capacity
  ) then
    raise exception using message = 'room-capacity-full';
  end if;
end;
$$;

revoke all on function private.check_camp_room_capacity(uuid, uuid)
from public, anon, authenticated, service_role;

-- Capture just review, room and stay fields. Internal reasons stay in audit_logs.
create function private.camp_review_snapshot(target_application_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'application', jsonb_build_object(
      'id', application.id,
      'camp_id', application.camp_id,
      'status', application.status,
      'start_date', application.start_date,
      'end_date', application.end_date,
      'revision_due_at', application.revision_due_at,
      'decision_reason', application.decision_reason,
      'approval_comment', application.approval_comment,
      'updated_at', application.updated_at
    ),
    'room_allocation', coalesce(to_jsonb(allocation), '{}'::jsonb),
    'stay', coalesce(to_jsonb(stay), '{}'::jsonb)
  )
  from public.applications as application
  left join public.room_allocations as allocation on allocation.application_id = application.id
  left join public.stays as stay on stay.application_id = application.id
  where application.id = target_application_id;
$$;

revoke all on function private.camp_review_snapshot(uuid)
from public, anon, authenticated, service_role;

create function public.assign_camp_application_room(
  target_application_id uuid,
  target_room_id uuid,
  expected_updated_at timestamptz,
  change_reason text default null
)
returns table (result_camp_id uuid, result_status text, result_updated_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_record public.applications%rowtype;
  allocation_record public.room_allocations%rowtype;
  stay_record public.stays%rowtype;
  normalized_reason text := nullif(btrim(change_reason), '');
  before_snapshot jsonb;
begin
  application_record := private.lock_camp_application_for_staff(
    target_application_id, expected_updated_at
  );

  if application_record.status not in ('under_review', 'approved') then
    raise exception using message = 'invalid-status';
  end if;
  if char_length(normalized_reason) > 2000 then
    raise exception using message = 'reason-too-long';
  end if;

  select allocation.* into allocation_record
  from public.room_allocations as allocation
  where allocation.application_id = target_application_id for update;

  select stay.* into stay_record from public.stays as stay
  where stay.application_id = target_application_id for update;

  if application_record.status = 'approved' then
    if allocation_record.id is null then
      raise exception using message = 'room-required';
    end if;
    if stay_record.id is null then
      raise exception using message = 'invalid-stay';
    end if;
    if stay_record.status = 'moved_out' then
      raise exception using message = 'stay-completed';
    end if;
  elsif stay_record.id is not null then
    raise exception using message = 'invalid-stay';
  end if;

  if allocation_record.id is not null and (
    allocation_record.released_from is not null
    or allocation_record.start_date is distinct from application_record.start_date
    or allocation_record.end_date is distinct from application_record.end_date
    or allocation_record.people_count <> 1
  ) then
    raise exception using message = 'invalid-allocation';
  end if;

  perform private.check_camp_room_capacity(target_application_id, target_room_id);

  -- A current-version save of the same room is a no-op, with no duplicate history.
  if allocation_record.id is not null and allocation_record.room_id = target_room_id then
    return query select application_record.camp_id, application_record.status,
      application_record.updated_at;
    return;
  end if;

  if allocation_record.id is not null and normalized_reason is null then
    raise exception using message = 'reason-required';
  end if;

  before_snapshot := private.camp_review_snapshot(target_application_id);

  insert into public.room_allocations (application_id, room_id, people_count, start_date, end_date)
  values (target_application_id, target_room_id, 1,
    application_record.start_date, application_record.end_date)
  on conflict (application_id) do update
  set room_id = excluded.room_id;

  -- A related room change must invalidate any earlier review/approval form too.
  update public.applications set updated_at = clock_timestamp()
  where id = target_application_id returning * into application_record;

  insert into public.audit_logs (
    entity_type, entity_id, action, before_data, after_data,
    actor_kind, actor_user_id, reason
  ) values (
    'application', target_application_id,
    case when allocation_record.id is null then 'assign_room' else 'change_room' end,
    before_snapshot, private.camp_review_snapshot(target_application_id),
    'staff', auth.uid(), normalized_reason
  );

  return query select application_record.camp_id, application_record.status,
    application_record.updated_at;
end;
$$;

revoke all on function public.assign_camp_application_room(uuid, uuid, timestamptz, text)
from public, anon, authenticated;
grant execute on function public.assign_camp_application_room(uuid, uuid, timestamptz, text)
to authenticated;

drop function public.review_camp_application(uuid, text, text);

create function public.review_camp_application(
  target_application_id uuid,
  review_action text,
  expected_updated_at timestamptz,
  public_reason text default null
)
returns table (
  result_camp_id uuid,
  result_status text,
  result_revision_due_at timestamptz,
  result_updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_record public.applications%rowtype;
  allocation_record public.room_allocations%rowtype;
  normalized_reason text := nullif(btrim(public_reason), '');
  previous_status text;
  next_status text;
  revision_due_value timestamptz;
  operation_time timestamptz;
  before_snapshot jsonb;
begin
  application_record := private.lock_camp_application_for_staff(
    target_application_id, expected_updated_at
  );

  if review_action is null
    or review_action not in ('start_review', 'request_revision', 'reject', 'approve') then
    raise exception using message = 'invalid-action';
  end if;

  if (review_action = 'start_review' and application_record.status <> 'submitted')
    or (review_action <> 'start_review' and application_record.status <> 'under_review') then
    raise exception using message = 'invalid-status';
  end if;

  if review_action in ('request_revision', 'reject') and normalized_reason is null then
    raise exception using message = 'reason-required';
  end if;
  if char_length(normalized_reason) > 2000 then
    raise exception using message = 'reason-too-long';
  end if;

  select allocation.* into allocation_record
  from public.room_allocations as allocation
  where allocation.application_id = target_application_id for update;

  perform stay.id from public.stays as stay
  where stay.application_id = target_application_id for update;
  if found then
    -- Review never resets a previously initialized stay.
    raise exception using message = 'invalid-stay';
  end if;

  previous_status := application_record.status;
  before_snapshot := private.camp_review_snapshot(target_application_id);
  operation_time := clock_timestamp();

  if review_action = 'start_review' then
    next_status := 'under_review';
    normalized_reason := null;
  elsif review_action = 'request_revision' then
    if application_record.start_date is null then
      raise exception using message = 'camp-dates-changed';
    end if;
    revision_due_value := least(
      (((operation_time at time zone 'Asia/Tokyo')::date + 4)::timestamp
        at time zone 'Asia/Tokyo'),
      (application_record.start_date::timestamp at time zone 'Asia/Tokyo')
    );
    if revision_due_value <= operation_time then
      raise exception using message = 'start-date-passed';
    end if;
    next_status := 'revision_requested';
  elsif review_action = 'reject' then
    next_status := 'rejected';
    -- Preserve the allocation and release every day. Revisions keep it reserved.
    update public.room_allocations set released_from = start_date
    where application_id = target_application_id;
  else
    if allocation_record.id is null then
      raise exception using message = 'room-required';
    end if;
    if allocation_record.people_count <> 1
      or allocation_record.released_from is not null
      or allocation_record.start_date is distinct from application_record.start_date
      or allocation_record.end_date is distinct from application_record.end_date then
      raise exception using message = 'invalid-allocation';
    end if;

    perform private.check_camp_room_capacity(target_application_id, allocation_record.room_id);
    next_status := 'approved';

    insert into public.stays (application_id, status, created_at, updated_at)
    values (target_application_id, 'before_move_in', operation_time, operation_time);
  end if;

  update public.applications set
    status = next_status,
    decision_reason = case when review_action in ('request_revision', 'reject')
      then normalized_reason else null end,
    approval_comment = case when review_action = 'approve'
      then normalized_reason else approval_comment end,
    revision_due_at = revision_due_value
  where id = target_application_id returning * into application_record;

  insert into public.application_status_events (
    application_id, from_status, to_status, public_reason, actor_user_id, occurred_at
  ) values (
    target_application_id, previous_status, next_status, normalized_reason, auth.uid(),
    clock_timestamp()
  );

  insert into public.audit_logs (
    entity_type, entity_id, action, before_data, after_data,
    actor_kind, actor_user_id, reason
  ) values (
    'application', target_application_id, review_action,
    before_snapshot, private.camp_review_snapshot(target_application_id),
    'staff', auth.uid(), normalized_reason
  );

  return query select application_record.camp_id, application_record.status,
    application_record.revision_due_at, application_record.updated_at;
end;
$$;

revoke all on function public.review_camp_application(uuid, text, timestamptz, text)
from public, anon, authenticated;
grant execute on function public.review_camp_application(uuid, text, timestamptz, text)
to authenticated;

-- No direct client writes: all related writes and history commit in the RPC.
revoke insert, update, delete, truncate, references, trigger
on public.applications, public.room_allocations, public.stays,
  public.application_status_events, public.audit_logs
from public, anon, authenticated;

commit;
