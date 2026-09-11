-- Phase 2 / T14. Apply after 001-015; existing rows are not migrated.
begin;
select private.lock_calendar_facility();

create function private.application_stay_snapshot(target_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'application_updated_at',(select updated_at from public.applications where id=target_id),
    'stay',(select to_jsonb(s) from public.stays s where application_id=target_id),
    'room',(select to_jsonb(r) from public.room_allocations r where application_id=target_id),
    'claim',(select to_jsonb(q) from public.calendar_claims q where application_id=target_id));
$$;

create function public.update_application_stay(
  target_application_id uuid, expected_updated_at timestamptz, stay_action text
)
returns table(result_id uuid, result_usage_type text, result_camp_id uuid,
  result_updated_at timestamptz, result_status text, result_released_from date)
language plpgsql security definer set search_path = '' as $$
declare a public.applications%rowtype; s public.stays%rowtype;
  r public.room_allocations%rowtype; q public.calendar_claims%rowtype;
  moment timestamptz; today_jst date; release_date date; before_value jsonb;
begin
  perform private.lock_calendar_for_staff();
  select * into a from public.applications where id=target_application_id
    and usage_type in ('camp','community_individual') and original_application_id is null for update;
  if not found then raise exception 'not-found'; end if;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if a.status<>'approved' or a.submitted_at is null then raise exception 'invalid-status'; end if;
  if stay_action is null or stay_action not in ('check_in','check_out') then raise exception 'invalid-action'; end if;
  select * into s from public.stays where application_id=a.id for update;
  if not found then raise exception 'invalid-stay'; end if;
  if s.status='moved_out' then raise exception 'stay-completed'; end if;
  if (stay_action='check_in' and s.status<>'before_move_in')
    or (stay_action='check_out' and s.status<>'staying') then raise exception 'invalid-stay'; end if;
  select * into r from public.room_allocations where application_id=a.id for update;
  if not found or r.people_count<>1 or r.start_date is distinct from a.start_date
    or r.end_date is distinct from a.end_date or r.released_from is not null then raise exception 'invalid-allocation'; end if;
  if a.usage_type='community_individual' then
    select * into q from public.calendar_claims where application_id=a.id for update;
    if not found or q.claim_type<>'individual' or q.start_date is distinct from a.start_date
      or q.end_date is distinct from a.end_date or q.released_from is not null then raise exception 'calendar-inconsistent'; end if;
  end if;
  -- All timestamps and the JST release boundary are sampled AFTER lock waits.
  moment:=clock_timestamp(); today_jst:=(moment at time zone 'Asia/Tokyo')::date;
  if stay_action='check_in' then
    if a.usage_type='camp' then
      perform private.check_camp_calendar(a.camp_id);
      perform private.check_camp_room_capacity(a.id,r.room_id);
    else
      perform private.check_community_room_capacity(a.id,r.room_id);
    end if;
    moment:=clock_timestamp(); today_jst:=(moment at time zone 'Asia/Tokyo')::date;
    if today_jst<a.start_date or today_jst>a.end_date then raise exception 'outside-stay-period'; end if;
  elsif s.checked_in_at is null or s.checked_in_at>moment
    or (s.checked_in_at at time zone 'Asia/Tokyo')::date<a.start_date
    or (s.checked_in_at at time zone 'Asia/Tokyo')::date>a.end_date then
    raise exception 'invalid-stay';
  end if;
  before_value:=private.application_stay_snapshot(a.id);
  if stay_action='check_in' then
    update public.stays set status='staying',checked_in_at=moment where id=s.id returning * into s;
  else
    -- The confirmation day remains occupied. Late checkout never extends the reservation.
    release_date:=least(today_jst+1,a.end_date+1);
    update public.stays set status='moved_out',checked_out_at=moment where id=s.id returning * into s;
    update public.room_allocations set released_from=release_date where id=r.id;
    if a.usage_type='community_individual' then
      update public.calendar_claims set released_from=release_date where id=q.id;
    end if;
    -- Camp-wide claims deliberately remain intact, even after the last participant leaves.
  end if;
  update public.applications set updated_at=clock_timestamp() where id=a.id returning * into a;
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id)
  values('application',a.id,stay_action,before_value,private.application_stay_snapshot(a.id),'staff',auth.uid());
  return query select a.id,a.usage_type,a.camp_id,a.updated_at,s.status,release_date;
end; $$;

create function public.get_application_stay(target_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.applications%rowtype;
begin
  if auth.uid() is null or not private.has_active_profile() then
    raise exception using errcode='42501',message='active-user-required'; end if;
  select * into a from public.applications where id=target_application_id
    and usage_type in ('camp','community_individual') and original_application_id is null
    and (user_id=auth.uid() or private.is_staff());
  if not found then raise exception 'not-found'; end if;
  return jsonb_build_object('id',a.id,'usage_type',a.usage_type,'camp_id',a.camp_id,
    'status',a.status,'updated_at',a.updated_at,'start_date',a.start_date,'end_date',a.end_date)
    || private.community_room_result(a.id);
end; $$;

-- Preserve camp capacity checks, excluding released individual days.
create or replace function private.check_camp_room_capacity(
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
    left join public.calendar_claims q on q.application_id=other.id
    where q.released_from is null or application_record.start_date + day.day_offset < q.released_from
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

-- Calendar entries describe occupied days; application detail retains the original period.
create or replace function public.get_staff_calendar(target_month date)
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
    (select count(*) from public.applications a left join public.room_allocations r on r.application_id=a.id
      where a.camp_id=c.id and (r.released_from is null or greatest(a.start_date,target_month)<r.released_from)
      and a.status in ('submitted', 'under_review', 'revision_requested', 'approved', 'cancellation_requested')),
    null::text, c.updated_at
  from public.camps c where c.deleted_at is null and c.start_date <= last_day and c.end_date >= target_month
  union all
  select 'blocked'::text, b.id, b.start_date, b.end_date, '利用停止'::text, 0::bigint, b.internal_reason, b.updated_at
  from public.blocked_periods b where b.deleted_at is null and b.start_date <= last_day and b.end_date >= target_month
  union all
  select 'individual'::text,a.id,a.start_date,least(a.end_date,q.released_from-1),a.user_name,1::bigint,null::text,a.updated_at
  from public.applications a join public.calendar_claims q on q.application_id=a.id
  where a.usage_type='community_individual' and a.status in ('submitted','under_review','revision_requested','approved','cancellation_requested')
    and a.start_date<=last_day and a.end_date>=target_month
    and (q.released_from is null or greatest(a.start_date,target_month)<q.released_from)
  order by 3, 1, 2;
end;
$$;

create or replace function public.get_staff_calendar_day(target_date date)
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
    (select count(*) from public.applications a left join public.room_allocations r on r.application_id=a.id
      where a.camp_id=c.id and (r.released_from is null or target_date<r.released_from)
      and a.status in ('submitted', 'under_review', 'revision_requested', 'approved', 'cancellation_requested')),
    'scheduled'::text, c.start_date, c.end_date, null::text, c.updated_at
  from public.camps c where c.deleted_at is null and target_date between c.start_date and c.end_date
  union all
  select 'blocked'::text, b.id, null::uuid, null::text, '利用停止'::text, 0::bigint,
    'blocked'::text, b.start_date, b.end_date, b.internal_reason, b.updated_at
  from public.blocked_periods b where b.deleted_at is null and target_date between b.start_date and b.end_date
  union all
  select 'application'::text, a.id, a.camp_id, n.display_number, a.user_name, 1::bigint,
    a.status, a.start_date, least(a.end_date,coalesce(iq.released_from,r.released_from)-1), null::text, a.updated_at
  from public.applications a left join public.reception_numbers n on n.application_id = a.id
  left join public.calendar_claims iq on iq.application_id=a.id
  left join public.room_allocations r on r.application_id=a.id and a.usage_type='camp'
  where target_date between a.start_date and a.end_date
    and a.status in ('submitted', 'under_review', 'revision_requested', 'approved', 'cancellation_requested')
    and (coalesce(iq.released_from,r.released_from) is null or target_date<coalesce(iq.released_from,r.released_from))
  order by 1, 2;
end;
$$;



revoke all on function private.application_stay_snapshot(uuid) from public,anon,authenticated,service_role;
revoke all on function public.update_application_stay(uuid,timestamptz,text),
  public.get_application_stay(uuid) from public,anon,authenticated,service_role;
grant execute on function public.update_application_stay(uuid,timestamptz,text),
  public.get_application_stay(uuid) to authenticated;
commit;
