-- A4: atomic eligible-roster withdrawal, rejection and stay completion.
-- No hosted data, room mappings or mode switches are installed by this migration.
begin;
select private.lock_calendar_facility();

-- Retain approved applications after real checkout. All other open applications
-- still require an active participant. This is a camp-only exception.
create or replace function private.check_camp_roster_application()
returns trigger language plpgsql security definer set search_path='' as $$
declare mode_value text; eligible public.camp_eligible_users%rowtype;
begin
  if new.usage_type<>'camp' then
    if new.camp_eligible_user_id is not null then raise exception 'camp-eligible-user-not-applicable'; end if;
    return new;
  end if;
  select c.room_assignment_mode into mode_value from public.camps c where c.id=new.camp_id;
  if new.camp_eligible_user_id is not null then
    select * into eligible from public.camp_eligible_users e
      where e.camp_id=new.camp_id and e.id=new.camp_eligible_user_id;
    if not found then raise exception 'camp-eligible-user-inconsistent'; end if;
    if eligible.linked_user_id is null
      or (new.user_id is not null and eligible.linked_user_id is distinct from new.user_id) then
      raise exception 'camp-eligible-user-owner-inconsistent';
    end if;
  end if;
  if mode_value='eligible_roster' and new.status not in ('rejected','cancelled') then
    if new.camp_eligible_user_id is null then raise exception 'camp-eligible-user-required'; end if;
    if (eligible.disabled_at is not null or eligible.participation_status<>'participating')
      and not (new.status='approved' and eligible.participation_status='released'
        and exists(select 1 from public.stays s where s.application_id=new.id
          and s.status='moved_out' and s.checked_out_at is not null)) then
      raise exception 'camp-eligible-user-not-participating';
    end if;
  end if;
  return new;
end; $$;

create or replace function private.account_cleanup_blocker(target_user_id uuid)
returns text language plpgsql stable security definer set search_path='' as $$
begin
  if target_user_id is null or not exists(select 1 from public.profiles p where p.id=target_user_id) then return 'profile-missing'; end if;
  if exists(select 1 from public.staff_roles s where s.user_id=target_user_id) then return 'staff-protected'; end if;
  if exists(select 1 from public.camp_eligible_users e join public.camps c on c.id=e.camp_id
    where c.room_assignment_mode='eligible_roster' and c.deleted_at is null and e.disabled_at is null
      and e.participation_status='participating' and (e.linked_user_id=target_user_id
        or (e.linked_user_id is null and e.email_normalized=private.current_verified_email(target_user_id)))) then
    return 'camp-participation-open';
  end if;
  if exists(select 1 from public.applications a where a.user_id=target_user_id and (
      a.status in ('draft','submitted','under_review','revision_requested','cancellation_requested')
      or (a.status='approved' and not exists(select 1 from public.stays s where s.application_id=a.id and s.status='moved_out'))
    )) then return 'application-open'; end if;
  if exists(select 1 from public.group_members m join public.applications a on a.id=m.application_id
    join public.group_applications g on g.id=m.group_id
    where a.user_id=target_user_id and m.state='active' and g.completed_at is null) then return 'group-membership-open'; end if;
  if exists(select 1 from public.group_applications g
    where g.representative_user_id=target_user_id and g.completed_at is null) then return 'group-representative-open'; end if;
  if not (
    exists(select 1 from public.applications a join public.stays s on s.application_id=a.id
      where a.user_id=target_user_id and s.status='moved_out' and s.checked_out_at is not null)
    or exists(select 1 from public.group_applications g where g.representative_user_id=target_user_id
      and not g.representative_stays and g.completed_at is not null)
  ) then return 'completion-required'; end if;
  return null;
end; $$;

-- Called only under the facility/staff lock by the two public entry points below.
create function private.end_camp_roster_participation(
  target_camp_id uuid,target_eligible_user_id uuid,expected_updated_at timestamptz,
  expected_roster_version bigint,expected_room_plan_version bigint,
  expected_application_id uuid,expected_application_updated_at timestamptz,
  end_action text,change_reason text,checkout_confirmed boolean
) returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.camps%rowtype; e public.camp_eligible_users%rowtype; a public.applications%rowtype;
 s public.stays%rowtype; r public.camp_room_assignments%rowtype; q public.calendar_claims%rowtype;
 moment timestamptz; today_jst date; release_date date; next_plan bigint; snapshot jsonb;
 before_value jsonb; old_status text; new_status text; roster bigint;
begin
  if end_action is null or end_action not in ('withdraw','reject','complete') then raise exception 'invalid-action'; end if;
  perform private.check_calendar_reason(change_reason);
  -- Cleanup triggers also lock the owner profile. Acquire it before the camp.
  perform p.id from public.profiles p where p.id in (
    select x.user_id from public.applications x where x.camp_id=target_camp_id
      and x.camp_eligible_user_id=target_eligible_user_id) order by p.id for update;
  select * into c from public.camps where id=target_camp_id and deleted_at is null for update;
  if not found then raise exception 'not-found'; end if;
  if c.room_assignment_mode<>'eligible_roster' then raise exception 'eligible-roster-required'; end if;
  if expected_roster_version is null or expected_room_plan_version is null
    or least(expected_roster_version,expected_room_plan_version)<0 then raise exception 'invalid-version'; end if;
  if (c.roster_version,c.room_plan_version) is distinct from (expected_roster_version,expected_room_plan_version) then raise exception 'stale-update'; end if;
  perform room.id from public.rooms room order by room.id for share;
  perform m.room_id from public.camp_room_mapping m order by m.room_id for share;
  select * into e from public.camp_eligible_users where id=target_eligible_user_id and camp_id=c.id for update;
  if not found then raise exception 'not-found'; end if;
  perform private.check_calendar_version(e.updated_at,expected_updated_at);
  select * into a from public.applications where camp_id=c.id and camp_eligible_user_id=e.id
    order by (status not in ('rejected','cancelled')) desc,created_at desc,id limit 1 for update;
  if a.id is distinct from expected_application_id then raise exception 'stale-update'; end if;
  if a.id is not null then perform private.check_calendar_version(a.updated_at,expected_application_updated_at);
  elsif expected_application_updated_at is not null then raise exception 'invalid-version'; end if;
  select * into s from public.stays where application_id=a.id for update;
  perform x.id from public.camp_room_assignments x where x.camp_id=c.id order by x.eligible_user_id for update;
  select * into r from public.camp_room_assignments where camp_id=c.id and eligible_user_id=e.id;
  select * into q from public.calendar_claims where camp_id=c.id for update;
  if not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
  if e.disabled_at is not null or e.participation_status<>'participating' then raise exception 'invalid-status'; end if;
  if (c.room_plan_committed_at is not null and q.id is null) or (q.id is not null and
    (q.start_date,q.end_date,q.released_from) is distinct from (c.start_date,c.end_date,null::date)) then raise exception 'calendar-inconsistent'; end if;
  if r.id is not null and (r.released_from is not null or
    (r.start_date,r.end_date) is distinct from (c.start_date,c.end_date)) then raise exception 'invalid-allocation'; end if;
  if a.id is not null and (a.usage_type<>'camp' or (a.start_date,a.end_date) is distinct from (c.start_date,c.end_date)
    or a.status='cancellation_requested') then raise exception 'invalid-status'; end if;
  if (s.status='before_move_in' and (s.checked_in_at is not null or s.checked_out_at is not null))
    or (s.status='staying' and s.checked_out_at is not null) then raise exception 'invalid-stay'; end if;
  if a.status='approved' and (s.id is null or r.id is null) then raise exception 'invalid-stay'; end if;
  if s.id is not null and s.status in ('staying','moved_out') and (a.status<>'approved' or r.id is null) then raise exception 'invalid-stay'; end if;
  if end_action='reject' and (a.id is null or a.status not in ('submitted','under_review','revision_requested','approved')
    or coalesce(s.status,'before_move_in')<>'before_move_in') then raise exception 'invalid-status'; end if;
  if end_action='complete' and (a.status is distinct from 'approved' or s.status is distinct from 'staying') then raise exception 'invalid-stay'; end if;
  if s.status='staying' and checkout_confirmed is distinct from true then raise exception 'checkout-confirmation-required'; end if;
  moment:=clock_timestamp(); today_jst:=(moment at time zone 'Asia/Tokyo')::date;
  if s.status in ('staying','moved_out') and (s.checked_in_at is null or s.checked_in_at>moment
    or (s.checked_in_at at time zone 'Asia/Tokyo')::date not between a.start_date and a.end_date
    or (s.status='moved_out' and (s.checked_out_at is null or s.checked_out_at<s.checked_in_at or s.checked_out_at>moment))) then raise exception 'invalid-stay'; end if;
  -- Never erase elapsed camp occupancy, even for a no-show. No caller date accepted.
  release_date:=greatest(c.start_date,least(today_jst+1,c.end_date+1));
  if s.status='moved_out' then release_date:=least((s.checked_out_at at time zone 'Asia/Tokyo')::date+1,c.end_date+1); end if;
  before_value:=jsonb_build_object('disabled_at',e.disabled_at,'participation_status',e.participation_status,
    'application_id',a.id,'application_status',a.status,'stay',to_jsonb(s),'assignment',to_jsonb(r),
    'roster_version',c.roster_version,'room_plan_version',c.room_plan_version);
  old_status:=a.status;
  new_status:=case when end_action='reject' then 'rejected'
    when end_action='complete' or s.status='moved_out' then a.status
    when a.status not in ('rejected','cancelled') then 'cancelled' else a.status end;
  -- Update the eligibility first, so cleanup sees the final participation state.
  update public.camp_eligible_users set disabled_at=case when end_action='withdraw' then moment else disabled_at end,
    participation_status='released',released_at=moment,release_reason=btrim(change_reason) where id=e.id returning * into e;
  select roster_version into roster from public.camps where id=c.id;
  next_plan:=c.room_plan_version+1;
  select coalesce(jsonb_agg(jsonb_build_object('eligible_user_id',x.eligible_user_id,'room_id',x.room_id,
    'capacity',(select capacity from public.rooms where id=x.room_id),
    'assignment_version',x.assignment_version+case when x.id=r.id then 1 else 0 end,
    'released_from',case when x.id=r.id then release_date else x.released_from end)
    order by x.eligible_user_id),'[]') into snapshot from public.camp_room_assignments x where x.camp_id=c.id;
  insert into public.camp_room_plan_versions(camp_id,version,roster_version,start_date,end_date,assignments,actor_user_id)
    values(c.id,next_plan,roster,c.start_date,c.end_date,snapshot,auth.uid());
  update public.camp_room_assignments set released_from=release_date,release_reason=btrim(change_reason),
    assignment_version=assignment_version+1,room_plan_version=next_plan,updated_at=moment where id=r.id;
  update public.camps set room_plan_version=next_plan,
    saved_roster_version=case when c.saved_roster_version=c.roster_version then roster else c.saved_roster_version end where id=c.id;
  if s.status='staying' then
    update public.stays set status='moved_out',checked_out_at=moment where id=s.id returning * into s;
  end if;
  if a.id is not null then
    update public.applications set status=new_status,
      decision_reason=case when end_action='reject' then btrim(change_reason) else decision_reason end,
      cancel_reason=case when new_status='cancelled' and old_status<>new_status then btrim(change_reason) else cancel_reason end,
      updated_at=moment where id=a.id returning * into a;
    if new_status is distinct from old_status then
      insert into public.application_status_events(application_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
        values(a.id,old_status,new_status,case when end_action='reject' then btrim(change_reason) else 'キャンプ参加取りやめ' end,auth.uid(),moment);
    end if;
    if a.user_id is not null then perform private.reconcile_account_cleanup(a.user_id,moment); end if;
  end if;
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id,reason)
    values('camp_eligible_user',e.id,'end_camp_roster_participation',before_value,
      jsonb_build_object('end_action',end_action,'disabled_at',e.disabled_at,'participation_status',e.participation_status,
        'application_id',a.id,'application_status',a.status,'stay',to_jsonb(s),'released_from',case when r.id is not null then release_date end,
        'roster_version',roster,'room_plan_version',next_plan,'assignment_version',case when r.id is not null then r.assignment_version+1 end),
      'staff',auth.uid(),btrim(change_reason));
  return jsonb_build_object('camp_id',c.id,'eligible_user_id',e.id,'updated_at',e.updated_at,
    'participation_status',e.participation_status,'disabled_at',e.disabled_at,'roster_version',roster::text,
    'room_plan_version',next_plan::text,'application_id',a.id,'application_updated_at',a.updated_at,
    'application_status',a.status,'stay_status',s.status,'released_from',case when r.id is not null then release_date end);
end $$;

create function public.end_camp_roster_participation(
  target_camp_id uuid,target_eligible_user_id uuid,expected_updated_at timestamptz,
  expected_roster_version bigint,expected_room_plan_version bigint,
  expected_application_id uuid,expected_application_updated_at timestamptz,
  end_action text,change_reason text,confirmed boolean,checkout_confirmed boolean default false
) returns jsonb language plpgsql security definer set search_path='' as $$
begin
  perform private.lock_calendar_for_staff();
  if confirmed is distinct from true then raise exception 'confirmation-required'; end if;
  if end_action is null or end_action not in ('withdraw','reject') then raise exception 'invalid-action'; end if;
  return private.end_camp_roster_participation(target_camp_id,target_eligible_user_id,expected_updated_at,
    expected_roster_version,expected_room_plan_version,expected_application_id,expected_application_updated_at,
    end_action,change_reason,checkout_confirmed);
end $$;

create function private.update_camp_roster_stay(target_application_id uuid,expected_updated_at timestamptz,stay_action text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.camps%rowtype; e public.camp_eligible_users%rowtype; a public.applications%rowtype;
 s public.stays%rowtype; r public.camp_room_assignments%rowtype; moment timestamptz; today_jst date; before_value jsonb;
begin
  perform p.id from public.profiles p where p.id=(select user_id from public.applications where id=target_application_id) for update;
  select * into c from public.camps where id=(select camp_id from public.applications where id=target_application_id) and deleted_at is null for update;
  if not found or c.room_assignment_mode<>'eligible_roster' then raise exception 'not-found'; end if;
  perform x.id from public.rooms x order by x.id for share;
  perform x.room_id from public.camp_room_mapping x order by x.room_id for share;
  select * into e from public.camp_eligible_users where camp_id=c.id
    and id=(select camp_eligible_user_id from public.applications where id=target_application_id) for update;
  select * into a from public.applications where id=target_application_id and camp_id=c.id and usage_type='camp' for update;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if a.status<>'approved' or a.submitted_at is null or e.id is null or e.disabled_at is not null
    or e.participation_status<>'participating' then raise exception 'invalid-status'; end if;
  if stay_action is null or stay_action not in ('check_in','check_out') then raise exception 'invalid-action'; end if;
  select * into s from public.stays where application_id=a.id for update;
  if not found then raise exception 'invalid-stay'; end if;
  if s.status='moved_out' then raise exception 'stay-completed'; end if;
  if stay_action='check_out' then
    return private.end_camp_roster_participation(c.id,e.id,e.updated_at,c.roster_version,c.room_plan_version,
      a.id,a.updated_at,'complete','対面で退去確認',true);
  end if;
  if s.status<>'before_move_in' or s.checked_in_at is not null or s.checked_out_at is not null then raise exception 'invalid-stay'; end if;
  select * into r from public.camp_room_assignments where camp_id=c.id and eligible_user_id=e.id for update;
  if not found or r.released_from is not null or (r.start_date,r.end_date) is distinct from (c.start_date,c.end_date)
    or (a.start_date,a.end_date) is distinct from (c.start_date,c.end_date) then raise exception 'invalid-allocation'; end if;
  if not exists(select 1 from public.camp_room_plan_versions v where v.camp_id=c.id and v.version=r.room_plan_version
    and v.assignments @> jsonb_build_array(jsonb_build_object('eligible_user_id',e.id,'room_id',r.room_id,
      'assignment_version',r.assignment_version,'released_from',null))) then raise exception 'invalid-allocation'; end if;
  if not exists(select 1 from public.camp_room_mapping where room_id=r.room_id and assignment_enabled) then raise exception 'room-not-confirmed'; end if;
  if c.room_plan_committed_at is null or not exists(select 1 from public.calendar_claims where camp_id=c.id
    and start_date=c.start_date and end_date=c.end_date and released_from is null) then raise exception 'calendar-inconsistent'; end if;
  perform private.assert_calendar_available(c.start_date,c.end_date,c.id);
  if exists(select 1 from generate_series(0,c.end_date-c.start_date) d
    join public.camp_room_assignments x on x.camp_id=c.id and c.start_date+d between x.start_date and x.end_date
      and (x.released_from is null or c.start_date+d<x.released_from)
    join public.rooms room on room.id=x.room_id group by d,x.room_id,room.capacity having count(*)>room.capacity)
    or exists(select 1 from generate_series(0,c.end_date-c.start_date) d
      join public.camp_room_assignments x on x.camp_id=c.id and c.start_date+d between x.start_date and x.end_date
        and (x.released_from is null or c.start_date+d<x.released_from) group by d having count(*)>15) then raise exception 'invalid-allocation'; end if;
  moment:=clock_timestamp(); today_jst:=(moment at time zone 'Asia/Tokyo')::date;
  if today_jst not between a.start_date and a.end_date then raise exception 'outside-stay-period'; end if;
  before_value:=to_jsonb(s);
  update public.stays set status='staying',checked_in_at=moment where id=s.id returning * into s;
  update public.applications set updated_at=moment where id=a.id returning * into a;
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id)
    values('application',a.id,'check_in',jsonb_build_object('stay',before_value),
      jsonb_build_object('stay',to_jsonb(s),'assignment_id',r.id,'assignment_version',r.assignment_version),'staff',auth.uid());
  return jsonb_build_object('camp_id',c.id,'application_id',a.id,'application_updated_at',a.updated_at,'stay_status',s.status,'released_from',null);
end $$;

create or replace function public.update_application_stay(target_application_id uuid,expected_updated_at timestamptz,stay_action text)
returns table(result_id uuid,result_usage_type text,result_camp_id uuid,
  result_updated_at timestamptz,result_status text,result_released_from date)
language plpgsql security definer set search_path = '' as $$
declare a public.applications%rowtype; s public.stays%rowtype; r public.room_allocations%rowtype;
  q public.calendar_claims%rowtype; moment timestamptz; today_jst date; release_date date; before_value jsonb; roster_result jsonb;
begin
  perform private.lock_calendar_for_staff();
  if exists(select 1 from public.applications x join public.camps c on c.id=x.camp_id
    where x.id=target_application_id and x.usage_type='camp' and c.room_assignment_mode='eligible_roster') then
    roster_result:=private.update_camp_roster_stay(target_application_id,expected_updated_at,stay_action);
    return query select (roster_result->>'application_id')::uuid,'camp'::text,(roster_result->>'camp_id')::uuid,
      (roster_result->>'application_updated_at')::timestamptz,roster_result->>'stay_status',(roster_result->>'released_from')::date;
    return;
  end if;
  select * into a from public.applications where id=target_application_id
    and usage_type in ('camp','community_individual') for update;
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
  moment:=clock_timestamp(); today_jst:=(moment at time zone 'Asia/Tokyo')::date;
  if stay_action='check_in' then
    if a.usage_type='camp' then
      perform private.check_camp_calendar(a.camp_id); perform private.check_camp_room_capacity(a.id,r.room_id);
    else perform private.check_community_room_capacity(a.id,r.room_id); end if;
    moment:=clock_timestamp(); today_jst:=(moment at time zone 'Asia/Tokyo')::date;
    if today_jst<a.start_date or today_jst>a.end_date then raise exception 'outside-stay-period'; end if;
  elsif s.checked_in_at is null or s.checked_in_at>moment
    or (s.checked_in_at at time zone 'Asia/Tokyo')::date<a.start_date
    or (s.checked_in_at at time zone 'Asia/Tokyo')::date>a.end_date then raise exception 'invalid-stay'; end if;
  before_value:=private.application_stay_snapshot(a.id);
  if stay_action='check_in' then
    update public.stays set status='staying',checked_in_at=moment where id=s.id returning * into s;
  else
    release_date:=least(today_jst+1,a.end_date+1);
    update public.stays set status='moved_out',checked_out_at=moment where id=s.id returning * into s;
    update public.room_allocations set released_from=release_date where id=r.id;
    if a.usage_type='community_individual' then update public.calendar_claims set released_from=release_date where id=q.id; end if;
  end if;
  update public.applications set updated_at=clock_timestamp() where id=a.id returning * into a;
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id)
  values('application',a.id,stay_action,before_value,private.application_stay_snapshot(a.id),'staff',auth.uid());
  return query select a.id,a.usage_type,a.camp_id,a.updated_at,s.status,release_date;
end; $$;

create function private.camp_roster_stay_result(target_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('room_allocation',case when r.id is not null then jsonb_build_object(
   'room_id',r.room_id,'room_name',coalesce(m.display_name,room.name),'people_count',1,
   'start_date',r.start_date,'end_date',r.end_date,'released_from',r.released_from,
   'is_current',r.released_from is null and e.disabled_at is null and e.participation_status='participating'
      and r.start_date=a.start_date and r.end_date=a.end_date and a.status not in ('rejected','cancelled')) end,
   'stay',case when s.id is not null then jsonb_build_object('status',s.status,'checked_in_at',s.checked_in_at,'checked_out_at',s.checked_out_at) end)
 from public.applications a join public.camp_eligible_users e on e.id=a.camp_eligible_user_id and e.camp_id=a.camp_id
 left join public.camp_room_assignments r on r.eligible_user_id=e.id and r.camp_id=e.camp_id
 left join public.rooms room on room.id=r.room_id left join public.camp_room_mapping m on m.room_id=r.room_id
 left join public.stays s on s.application_id=a.id where a.id=target_id;
$$;
create or replace function public.get_application_stay(target_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.applications%rowtype;
begin
  if auth.uid() is null or not private.has_active_profile() then
    raise exception using errcode='42501',message='active-user-required'; end if;
  select * into a from public.applications where id=target_application_id
    and usage_type in ('camp','community_individual') and (user_id=auth.uid() or private.is_staff());
  if not found then raise exception 'not-found'; end if;
  return jsonb_build_object('id',a.id,'usage_type',a.usage_type,'camp_id',a.camp_id,
    'original_application_id',a.original_application_id,'status',a.status,'updated_at',a.updated_at,
    'start_date',a.start_date,'end_date',a.end_date) || case when a.usage_type='camp' and exists(select 1 from public.camps where id=a.camp_id and room_assignment_mode='eligible_roster')
      then private.camp_roster_stay_result(a.id) else private.community_room_result(a.id) end;
end; $$;


create function public.get_staff_camp_roster_lifecycle(target_camp_id uuid,target_eligible_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.camps%rowtype; e public.camp_eligible_users%rowtype; a public.applications%rowtype; s public.stays%rowtype;
begin
 if auth.uid() is null or not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
 select * into c from public.camps where id=target_camp_id and deleted_at is null;
 if not found then raise exception 'not-found'; end if;
 if c.room_assignment_mode<>'eligible_roster' then raise exception 'eligible-roster-required'; end if;
 select * into e from public.camp_eligible_users where camp_id=c.id and id=target_eligible_user_id;
 if not found then raise exception 'not-found'; end if;
 select * into a from public.applications where camp_id=c.id and camp_eligible_user_id=e.id
   order by (status not in ('rejected','cancelled')) desc,created_at desc,id limit 1;
 select * into s from public.stays where application_id=a.id;
 return jsonb_build_object('camp_id',c.id,'eligible_user_id',e.id,'management_name',e.management_name,
   'updated_at',e.updated_at,'roster_version',c.roster_version::text,'room_plan_version',c.room_plan_version::text,
   'disabled_at',e.disabled_at,'participation_status',e.participation_status,'released_at',e.released_at,'release_reason',e.release_reason,
   'application_id',a.id,'application_updated_at',a.updated_at,'application_status',a.status,'stay_status',s.status,
   'released_from',(select released_from from public.camp_room_assignments where camp_id=c.id and eligible_user_id=e.id),
   'can_withdraw',e.disabled_at is null and e.participation_status='participating',
   'can_reject',e.disabled_at is null and e.participation_status='participating' and coalesce(a.status in ('submitted','under_review','revision_requested','approved'),false)
     and coalesce(s.status,'before_move_in')='before_move_in',
   'requires_checkout_confirmation',coalesce(s.status='staying',false));
end $$;

revoke all on function private.end_camp_roster_participation(uuid,uuid,timestamptz,bigint,bigint,uuid,timestamptz,text,text,boolean),
 private.update_camp_roster_stay(uuid,timestamptz,text),private.camp_roster_stay_result(uuid),
 public.end_camp_roster_participation(uuid,uuid,timestamptz,bigint,bigint,uuid,timestamptz,text,text,boolean,boolean),
 public.get_staff_camp_roster_lifecycle(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.end_camp_roster_participation(uuid,uuid,timestamptz,bigint,bigint,uuid,timestamptz,text,text,boolean,boolean),
 public.get_staff_camp_roster_lifecycle(uuid,uuid) to authenticated;
commit;
