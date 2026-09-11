-- T12: community individuals only. Apply once after 013.
-- Existing submissions, fees, receipt numbers and camp APIs are preserved.
begin;
select private.lock_calendar_facility();

-- Reuse the facility/staff authorization guard. All room/review mutations then
-- lock the application and related rows before checking or writing anything.
create function private.lock_community_application_for_staff(
  target_id uuid, expected_version timestamptz
)
returns public.applications
language plpgsql security definer set search_path = '' as $$
declare a public.applications%rowtype;
begin
  perform private.lock_calendar_for_staff();
  select * into a from public.applications
  where id = target_id and usage_type = 'community_individual'
    and original_application_id is null for update;
  if not found then raise exception 'not-found'; end if;
  perform private.check_calendar_version(a.updated_at, expected_version);
  return a;
end;
$$;

-- Caller holds facility_guard and the application. This never reserves a
-- second facility place: the existing submission already represents one person.
create function private.check_community_room_capacity(target_id uuid, target_room_id uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare a public.applications%rowtype; capacity_value integer;
begin
  select * into a from public.applications where id = target_id
    and usage_type = 'community_individual';
  if not found then raise exception 'not-found'; end if;
  perform private.check_community_period(a.start_date, a.end_date, null, false);
  perform q.id from public.calendar_claims q where q.application_id = a.id
    and q.claim_type = 'individual' and q.start_date = a.start_date
    and q.end_date = a.end_date and q.released_from is null for update;
  if not found then raise exception 'calendar-inconsistent'; end if;

  select capacity into capacity_value from public.rooms where id = target_room_id for share;
  if not found then raise exception 'invalid-room'; end if;
  perform private.check_community_availability(a.id, a.user_id, a.start_date, a.end_date);

  -- Even an inconsistent camp with a missing/released parent claim must not
  -- make an active camp participant appear compatible with community use.
  if exists (select 1 from public.applications other
    where other.usage_type = 'camp'
      and other.status in ('submitted','under_review','revision_requested','approved','cancellation_requested')
      and other.start_date <= a.end_date and other.end_date >= a.start_date) then
    raise exception 'calendar-inconsistent';
  end if;

  -- Count reservations without requiring a room allocation. The target is
  -- excluded then added once. Released days do not consume facility capacity.
  if exists (
    select d.n from generate_series(0, a.end_date - a.start_date) d(n)
    join public.applications other on other.id <> a.id
      and a.start_date + d.n between other.start_date and other.end_date
      and other.status in ('submitted','under_review','revision_requested','approved','cancellation_requested')
    left join public.calendar_claims q on q.application_id = other.id
    where q.released_from is null or a.start_date + d.n < q.released_from
    group by d.n having count(*) + 1 > 15
  ) then raise exception 'facility-capacity-full'; end if;

  -- Released historical allocations from a date-changing resubmission are
  -- valid history. A live allocation outside its source period is corruption.
  if exists (
    select 1 from public.room_allocations r join public.applications other on other.id = r.application_id
    where other.id <> a.id
      and other.status in ('submitted','under_review','revision_requested','approved','cancellation_requested')
      and r.start_date <= a.end_date and r.end_date >= a.start_date
      and (r.released_from is null or greatest(r.start_date, a.start_date) < r.released_from)
      and (r.start_date is distinct from other.start_date or r.end_date is distinct from other.end_date
        or r.people_count <> 1)
  ) then raise exception 'invalid-allocation'; end if;

  if exists (
    select d.n from generate_series(0, a.end_date - a.start_date) d(n)
    join public.room_allocations r on r.application_id <> a.id
      and a.start_date + d.n between r.start_date and r.end_date
      and (r.released_from is null or a.start_date + d.n < r.released_from)
    join public.applications other on other.id = r.application_id
      and other.status in ('submitted','under_review','revision_requested','approved','cancellation_requested')
    group by d.n having sum(r.people_count) + 1 > 15
      or coalesce(sum(r.people_count) filter (where r.room_id = target_room_id), 0) + 1 > capacity_value
  ) then raise exception 'room-capacity-full'; end if;
end;
$$;

create or replace function private.community_snapshot(target_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('application',(select to_jsonb(a) from public.applications a where id=target_id),
    'claim',(select to_jsonb(q) from public.calendar_claims q where application_id=target_id),
    'room',(select to_jsonb(r) from public.room_allocations r where application_id=target_id),
    'stay',(select to_jsonb(s) from public.stays s where application_id=target_id),
    'charge',(select to_jsonb(c) from public.application_charges c where application_id=target_id),
    'months',(select jsonb_agg(to_jsonb(m) order by m.month) from public.charge_months m
      join public.application_charges c on c.id=m.charge_id where c.application_id=target_id),
    'consent',(select to_jsonb(d) from public.consent_documents d where application_id=target_id));
$$;

create function public.assign_community_application_room(
  target_application_id uuid, target_room_id uuid,
  expected_updated_at timestamptz, change_reason text default null
)
returns table(result_id uuid, result_status text, result_updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  a public.applications%rowtype;
  r public.room_allocations%rowtype;
  s public.stays%rowtype;
  reason_value text := nullif(btrim(change_reason), '');
  before_value jsonb;
begin
  a := private.lock_community_application_for_staff(target_application_id, expected_updated_at);
  if a.status not in ('under_review','approved') then raise exception 'invalid-status'; end if;
  if char_length(reason_value) > 2000 then raise exception 'reason-too-long'; end if;
  select * into r from public.room_allocations where application_id = a.id for update;
  select * into s from public.stays where application_id = a.id for update;
  if a.status = 'approved' then
    if r.id is null then raise exception 'room-required'; end if;
    if s.id is null then raise exception 'invalid-stay'; end if;
    if s.status = 'moved_out' then raise exception 'stay-completed'; end if;
    if r.released_from is not null then raise exception 'invalid-allocation'; end if;
  elsif s.id is not null then raise exception 'invalid-stay';
  end if;

  if r.id is not null and (r.people_count <> 1
    or (r.released_from is null and
      (r.start_date is distinct from a.start_date or r.end_date is distinct from a.end_date))
    or (r.released_from is not null and r.released_from <> r.start_date)) then
    raise exception 'invalid-allocation';
  end if;
  perform private.check_community_room_capacity(a.id, target_room_id);
  if r.id is not null and r.released_from is null and r.room_id = target_room_id then
    return query select a.id, a.status, a.updated_at;
    return;
  end if;
  -- Reassigning a fully released old period also needs an explicit staff reason.
  if r.id is not null then perform private.check_calendar_reason(reason_value); end if;
  before_value := private.community_snapshot(a.id);
  insert into public.room_allocations(application_id, room_id, people_count, start_date, end_date)
  values(a.id, target_room_id, 1, a.start_date, a.end_date)
  on conflict(application_id) do update set room_id = excluded.room_id,
    start_date = excluded.start_date, end_date = excluded.end_date, released_from = null;
  update public.applications set updated_at = clock_timestamp() where id = a.id returning * into a;
  perform private.community_audit(a.id,
    case when r.id is null then 'assign_room'
      when r.released_from is not null then 'reassign_room' else 'change_room' end,
    before_value, auth.uid(), 'staff', reason_value);
  return query select a.id, a.status, a.updated_at;
end;
$$;

-- Keep all five arguments and all three result columns from 013.
create or replace function public.review_community_application(
  target_application_id uuid, review_action text, expected_updated_at timestamptz,
  public_reason text default null, revision_deadline timestamptz default null
)
returns table(result_id uuid, result_status text, result_updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  a public.applications%rowtype;
  r public.room_allocations%rowtype;
  next_status text;
  before_value jsonb;
  moment timestamptz;
  reason_value text := nullif(btrim(public_reason), '');
begin
  a := private.lock_community_application_for_staff(target_application_id, expected_updated_at);
  if review_action is null or review_action not in ('start_review','request_revision','reject','approve') then
    raise exception 'invalid-action'; end if;
  if (review_action = 'start_review' and a.status <> 'submitted')
    or (review_action <> 'start_review' and a.status <> 'under_review') then
    raise exception 'invalid-status'; end if;
  if review_action in ('request_revision','reject') then
    perform private.check_calendar_reason(reason_value);
  elsif review_action = 'start_review' then reason_value := null;
  elsif char_length(reason_value) > 2000 then raise exception 'reason-too-long';
  end if;

  select * into r from public.room_allocations where application_id = a.id for update;
  perform id from public.stays where application_id = a.id for update;
  if found then raise exception 'invalid-stay'; end if;
  moment := clock_timestamp();
  if review_action = 'request_revision' and revision_deadline is not null
    and (not isfinite(revision_deadline) or revision_deadline <= moment
      or revision_deadline > (a.start_date::timestamp at time zone 'Asia/Tokyo')) then
    raise exception 'invalid-deadline'; end if;
  before_value := private.community_snapshot(a.id);

  if review_action = 'approve' then
    if r.id is null then raise exception 'room-required'; end if;
    if r.people_count <> 1 or r.released_from is not null
      or r.start_date is distinct from a.start_date or r.end_date is distinct from a.end_date then
      raise exception 'invalid-allocation'; end if;
    -- Validate the submitted snapshot, never the reviewing staff's identity/email.
    perform private.validate_community_fields(jsonb_build_object(
      'user_name',a.user_name,'user_address',a.user_address,'user_phone',a.user_phone,
      'emergency_name',a.emergency_name,'emergency_address',a.emergency_address,'emergency_phone',a.emergency_phone,
      'purpose',a.purpose,'local_activity',a.local_activity,'special_notes',a.special_notes,
      'usage_place',a.usage_place,'requires_guardian_consent',a.requires_guardian_consent,
      'start_date',a.start_date,'end_date',a.end_date), true);
    if coalesce(a.email_snapshot,'') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
      raise exception 'invalid-email'; end if;
    if a.submitted_at is null or a.last_submitted_at is null
      or a.revision_start_date is not null or a.revision_end_date is not null
      or not exists(select 1 from public.reception_numbers where application_id = a.id)
      or not exists(select 1 from public.application_charges c where c.application_id = a.id
        and c.total_amount = (select sum(m.amount) from public.charge_months m where m.charge_id = c.id)) then
      raise exception 'application-inconsistent'; end if;
    perform id from public.consent_documents where application_id = a.id for share;
    if a.requires_guardian_consent and not found then raise exception 'guardian-consent'; end if;
    perform private.check_community_room_capacity(a.id, r.room_id);
    insert into public.stays(application_id,status,created_at,updated_at)
    values(a.id,'before_move_in',moment,moment);
  end if;

  next_status := case review_action when 'start_review' then 'under_review'
    when 'request_revision' then 'revision_requested' when 'approve' then 'approved' else 'rejected' end;
  update public.applications set status = next_status,
    decision_reason = case when review_action in ('request_revision','reject') then reason_value end,
    approval_comment = case when review_action = 'approve' then reason_value else approval_comment end,
    revision_due_at = case when review_action = 'request_revision' then revision_deadline end,
    revision_start_date = null, revision_end_date = null where id = a.id;
  if next_status = 'rejected' then
    update public.room_allocations set released_from = start_date where application_id = a.id;
  end if;
  insert into public.application_status_events(application_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
  values(a.id,a.status,next_status,reason_value,auth.uid(),moment);
  perform private.community_audit(a.id,review_action,before_value,auth.uid(),'staff',reason_value);
  return query select id,status,updated_at from public.applications where id = a.id;
end;
$$;

-- Read-only fixed-column result, with an explicit flag for released old rooms.
create function private.community_room_result(target_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'room_allocation', case when r.id is not null then jsonb_build_object(
      'room_id',r.room_id,'room_name',room.name,'people_count',r.people_count,
      'start_date',r.start_date,'end_date',r.end_date,'released_from',r.released_from,
      'is_current',r.released_from is null and r.people_count = 1
        and r.start_date = a.start_date and r.end_date = a.end_date
        and a.status in ('submitted','under_review','revision_requested','approved','cancellation_requested')) end,
    'stay',case when s.id is not null then jsonb_build_object(
      'status',s.status,'checked_in_at',s.checked_in_at,'checked_out_at',s.checked_out_at) end)
  from public.applications a left join public.room_allocations r on r.application_id = a.id
  left join public.rooms room on room.id = r.room_id
  left join public.stays s on s.application_id = a.id where a.id = target_id;
$$;

create function public.get_staff_community_application_room_context(target_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.applications%rowtype;
begin
  if auth.uid() is null or not private.is_staff() then
    raise exception using errcode = '42501', message = 'staff-required'; end if;
  select * into a from public.applications where id = target_application_id
    and usage_type = 'community_individual' and original_application_id is null;
  if not found then raise exception 'not-found'; end if;
  return jsonb_build_object('id',a.id,'status',a.status,'updated_at',a.updated_at,
    'start_date',a.start_date,'end_date',a.end_date,'approval_comment',a.approval_comment,
    'rooms',(select jsonb_agg(jsonb_build_object('id',id,'name',name,'capacity',capacity) order by name) from public.rooms))
    || private.community_room_result(a.id);
end;
$$;

-- Preserve the owner-only T10 read contract and add fixed room/stay fields.
create or replace function public.get_community_application(target_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.applications%rowtype; fields jsonb; validation_error text; moment timestamptz:=clock_timestamp();
  starts_on date; ends_on date; charge jsonb;
begin
  if auth.uid() is null or not private.has_active_profile() then raise exception using errcode='42501',message='active-user-required'; end if;
  select * into a from public.applications where id=target_application_id and user_id=auth.uid() and usage_type='community_individual';
  if not found then raise exception 'not-found'; end if;
  starts_on:=coalesce(a.revision_start_date,a.start_date); ends_on:=coalesce(a.revision_end_date,a.end_date);
  fields:=jsonb_build_object('user_name',a.user_name,'user_address',a.user_address,'user_phone',a.user_phone,
    'emergency_name',a.emergency_name,'emergency_address',a.emergency_address,'emergency_phone',a.emergency_phone,
    'purpose',a.purpose,'local_activity',a.local_activity,'special_notes',a.special_notes,'usage_place',a.usage_place,
    'requires_guardian_consent',a.requires_guardian_consent,'start_date',starts_on,'end_date',ends_on);
  begin
    if a.status not in ('draft','revision_requested') then raise exception 'not-editable'; end if;
    if a.status='revision_requested' then perform private.check_community_revision(a.revision_due_at,moment); end if;
    perform private.validate_community_fields(fields,true);
    perform private.check_community_period(starts_on,ends_on,moment,a.status='draft' or (starts_on,ends_on) is distinct from (a.start_date,a.end_date));
    if a.requires_guardian_consent and not exists(select 1 from public.consent_documents where application_id=a.id) then raise exception 'guardian-consent'; end if;
    perform private.check_community_availability(a.id,auth.uid(),starts_on,ends_on);
  exception when sqlstate 'P0001' then get stacked diagnostics validation_error=message_text;
  end;
  select jsonb_build_object('total_amount',c.total_amount,'payment_status',c.payment_status,'payment_due_date',c.payment_due_date,
    'months',(select jsonb_agg(jsonb_build_object('month',m.month,'usage_days',m.usage_days,'daily_rate',m.daily_rate,'monthly_cap',m.monthly_cap,'amount',m.amount) order by m.month)
      from public.charge_months m where m.charge_id=c.id)) into charge from public.application_charges c where c.application_id=a.id;
  return jsonb_build_object('id',a.id,'status',a.status,'updated_at',a.updated_at,'fields',fields,
    'reserved_start_date',case when a.submitted_at is not null then a.start_date end,
    'reserved_end_date',case when a.submitted_at is not null then a.end_date end,
    'submitted_at',a.submitted_at,'last_submitted_at',a.last_submitted_at,'revision_due_at',a.revision_due_at,'decision_reason',a.decision_reason,'approval_comment',a.approval_comment,
    'reception_number',(select display_number from public.reception_numbers where application_id=a.id),
    'has_consent',exists(select 1 from public.consent_documents where application_id=a.id),
    'can_edit',a.status in ('draft','revision_requested') and (a.revision_due_at is null or moment<a.revision_due_at),
    'validation_error',validation_error,'charge',charge,
    'estimated_months',(select jsonb_agg(to_jsonb(m) order by m.month) from private.community_charge_months(starts_on,ends_on) m),
    'events',(select coalesce(jsonb_agg(jsonb_build_object('from_status',e.from_status,'to_status',e.to_status,'public_reason',e.public_reason,'occurred_at',e.occurred_at) order by e.occurred_at,e.id),'[]'::jsonb)
      from public.application_status_events e where e.application_id=a.id)) || private.community_room_result(a.id);
end; $$;


revoke all on function private.lock_community_application_for_staff(uuid,timestamptz),
  private.check_community_room_capacity(uuid,uuid), private.community_room_result(uuid),
  private.community_snapshot(uuid)
from public, anon, authenticated, service_role;
revoke all on function public.assign_community_application_room(uuid,uuid,timestamptz,text),
  public.review_community_application(uuid,text,timestamptz,text,timestamptz),
  public.get_staff_community_application_room_context(uuid), public.get_community_application(uuid)
from public, anon, authenticated, service_role;
grant execute on function public.assign_community_application_room(uuid,uuid,timestamptz,text),
  public.review_community_application(uuid,text,timestamptz,text,timestamptz),
  public.get_staff_community_application_room_context(uuid), public.get_community_application(uuid)
to authenticated;
-- RLS continues to allow only owner/staff reads and staff-only audit reads.
-- All client writes must go through the authorized business RPCs.
revoke insert, update, delete, truncate, references, trigger on
  public.applications, public.room_allocations, public.stays, public.calendar_claims,
  public.application_status_events, public.audit_logs
from public, anon, authenticated;
commit;
