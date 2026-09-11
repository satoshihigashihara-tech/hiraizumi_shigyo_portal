-- T20 phase 2: participant correction/replacement and group cancellation.
begin;
select private.lock_calendar_facility();

alter table public.group_applications drop constraint group_applications_planned_participants_check;
alter table public.group_applications add constraint group_applications_planned_participants_check check (
  planned_participants is null or planned_participants between 2 and 15
  or (planned_participants=1 and status in ('approved','cancellation_requested','cancelled'))
  or (planned_participants=0 and status='cancelled'));

create or replace function public.save_group_participant_application(target_application_id uuid,expected_updated_at timestamptz,draft_fields jsonb)
returns table(result_id uuid,result_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare actor uuid:=private.lock_group_user(); a public.applications%rowtype; g public.group_applications%rowtype; before_value jsonb; deadline timestamptz;
begin
  select * into a from public.applications where id=target_application_id for update;
  if not found or a.user_id is distinct from actor or a.usage_type<>'community_group'
    or not exists(select 1 from public.group_members m where m.application_id=a.id and m.group_id=a.group_id and m.state='active')
    then raise exception 'not-found'; end if;
  select * into g from public.group_applications where id=a.group_id for update;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if not ((a.status='draft' and g.status='collecting')
    or (a.status='revision_requested' and g.status='revision_requested')) then raise exception 'not-editable'; end if;
  deadline:=case when g.status='revision_requested' then g.revision_due_at else g.participant_due_at end;
  if deadline is null or clock_timestamp()>=deadline then raise exception 'participant-deadline-passed'; end if;
  perform private.validate_group_participant_fields(draft_fields,false);
  before_value:=private.community_snapshot(a.id);
  perform private.apply_group_participant_fields(a.id,draft_fields);
  perform private.community_audit(a.id,'save_group_participant_application',before_value,actor,'user');
  return query select x.id,x.updated_at from public.applications x where x.id=a.id;
end; $$;

create or replace function public.submit_group_participant_application(target_application_id uuid,expected_updated_at timestamptz,
  submission_key uuid,confirmed boolean)
returns table(result_id uuid,result_status text,result_updated_at timestamptz,reception_number text,submission_time timestamptz,
  result_group_id uuid,result_group_status text,result_group_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare actor uuid:=private.lock_group_user(); a public.applications%rowtype; g public.group_applications%rowtype;
  before_value jsonb; group_before jsonb; f jsonb; moment timestamptz:=clock_timestamp(); number_value text;
  year_value integer; serial_value integer; charge_value uuid; active_count integer; ready_count integer;
  prior_status text; deadline timestamptz; prior_group_status text;
begin
  select * into a from public.applications where id=target_application_id for update;
  if not found or a.user_id is distinct from actor or a.usage_type<>'community_group'
    or not exists(select 1 from public.group_members m where m.application_id=a.id and m.group_id=a.group_id and m.state='active')
    then raise exception 'not-found'; end if;
  select * into g from public.group_applications where id=a.group_id for update;
  if confirmed is distinct from true then raise exception 'confirmation-required'; end if;
  if submission_key is null then raise exception 'invalid-submission-key'; end if;
  if expected_updated_at is null or not isfinite(expected_updated_at) then raise exception 'invalid-version'; end if;
  if a.last_submission_key=submission_key and a.last_submission_version=expected_updated_at then
    return query select a.id,a.status,a.updated_at,n.display_number,a.last_submitted_at,g.id,g.status,g.updated_at
      from public.reception_numbers n where n.application_id=a.id; return;
  end if;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if not ((a.status='draft' and g.status='collecting')
    or (a.status='revision_requested' and g.status='revision_requested')) then raise exception 'not-submittable'; end if;
  deadline:=case when g.status='revision_requested' then g.revision_due_at else g.participant_due_at end;
  if deadline is null or moment>=deadline then raise exception 'participant-deadline-passed'; end if;
  if (a.start_date,a.end_date) is distinct from (g.start_date,g.end_date) then raise exception 'group-member-inconsistent'; end if;
  if not exists(select 1 from public.calendar_claims q where q.group_id=g.id and q.claim_type='group'
    and q.start_date=g.start_date and q.end_date=g.end_date and q.released_from is null) then raise exception 'calendar-inconsistent'; end if;
  f:=jsonb_build_object('user_name',a.user_name,'user_address',a.user_address,'user_phone',a.user_phone,
    'emergency_name',a.emergency_name,'emergency_address',a.emergency_address,'emergency_phone',a.emergency_phone,
    'special_notes',a.special_notes,'requires_guardian_consent',a.requires_guardian_consent);
  perform private.validate_group_participant_fields(f,true);
  if coalesce(auth.jwt()->>'email','')!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'invalid-email'; end if;
  if a.requires_guardian_consent and not exists(select 1 from public.consent_documents where application_id=a.id) then raise exception 'guardian-consent'; end if;
  if exists(select 1 from public.applications other_a where other_a.user_id=actor and other_a.id<>a.id
    and other_a.status in ('submitted','under_review','revision_requested','approved','cancellation_requested')
    and other_a.start_date<=g.end_date and other_a.end_date>=g.start_date) then raise exception 'duplicate-stay'; end if;
  before_value:=private.community_snapshot(a.id); group_before:=private.group_snapshot(g.id); prior_status:=a.status;
  insert into public.application_charges(application_id,total_amount,calculated_at) values(a.id,0,moment)
    on conflict(application_id) do update set calculated_at=excluded.calculated_at returning id into charge_value;
  delete from public.charge_months where charge_id=charge_value;
  insert into public.charge_months(charge_id,month,usage_days,daily_rate,monthly_cap,amount)
    select charge_value,m.* from private.community_charge_months(g.start_date,g.end_date) m;
  update public.application_charges set total_amount=(select sum(amount) from public.charge_months where charge_id=charge_value) where id=charge_value;
  update public.applications set status='submitted',email_snapshot=lower(auth.jwt()->>'email'),decision_reason=null,revision_due_at=null,
    submitted_at=coalesce(submitted_at,moment),last_submitted_at=moment,last_submission_key=submission_key,
    last_submission_version=expected_updated_at where id=a.id returning * into a;
  select display_number into number_value from public.reception_numbers where application_id=a.id;
  if number_value is null then
    year_value:=extract(year from (moment at time zone 'Asia/Tokyo')-interval '3 months')::integer;
    insert into public.reception_counters(fiscal_year,last_number) values(year_value,0) on conflict do nothing;
    update public.reception_counters set last_number=last_number+1,updated_at=moment where fiscal_year=year_value returning last_number into serial_value;
    number_value:=format('SG-%s-%s',year_value,lpad(serial_value::text,greatest(4,length(serial_value::text)),'0'));
    insert into public.reception_numbers(fiscal_year,serial_number,display_number,application_id) values(year_value,serial_value,number_value,a.id);
  end if;
  insert into public.application_status_events(application_id,from_status,to_status,actor_user_id,occurred_at)
    values(a.id,prior_status,'submitted',actor,moment);
  perform private.community_audit(a.id,'submit_group_participant_application',before_value,actor,'user');
  select count(*),count(*) filter(where x.status in ('submitted','approved')) into active_count,ready_count
    from public.group_members m join public.applications x on x.id=m.application_id where m.group_id=g.id and m.state='active';
  if active_count=g.planned_participants and ready_count=active_count then
    prior_group_status:=g.status;
    update public.group_applications set status='under_review',revision_due_at=null,decision_reason=null where id=g.id returning * into g;
    update public.group_invites set revoked_at=moment where group_id=g.id and revoked_at is null;
    insert into public.group_status_events(group_id,from_status,to_status,actor_user_id,occurred_at)
      values(g.id,prior_group_status,'under_review',actor,moment);
    perform private.group_audit(g.id,'complete_group_participant_submissions',group_before,actor);
  end if;
  return query select a.id,a.status,a.updated_at,number_value,a.last_submitted_at,g.id,g.status,g.updated_at;
end; $$;

create function public.reject_group_participant(target_application_id uuid,expected_updated_at timestamptz,
  public_reason text,revision_deadline timestamptz)
returns table(result_id uuid,result_status text,result_updated_at timestamptz,result_group_id uuid,result_group_status text,result_group_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare a public.applications%rowtype; g public.group_applications%rowtype; group_value uuid; reason_value text:=nullif(btrim(public_reason),'');
  before_value jsonb; group_before jsonb; moment timestamptz:=clock_timestamp();
begin
  if auth.uid() is null or not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
  if expected_updated_at is null or not isfinite(expected_updated_at) then raise exception 'invalid-version'; end if;
  perform private.lock_calendar_facility();
  select group_id into group_value from public.applications where id=target_application_id and usage_type='community_group';
  if not found then raise exception 'not-found'; end if;
  select * into g from public.group_applications where id=group_value for update;
  select * into a from public.applications where id=target_application_id and group_id=g.id for update;
  perform s.user_id from public.staff_roles s join public.profiles p on p.id=s.user_id
    where s.user_id=auth.uid() and p.account_state='active' for share of s,p;
  if not found then raise exception using errcode='42501',message='staff-required'; end if;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if g.status<>'under_review' or g.purpose_reviewed_at is null or a.status<>'under_review'
    or not exists(select 1 from public.group_members m where m.group_id=g.id and m.application_id=a.id and m.state='active')
    then raise exception 'invalid-status'; end if;
  perform private.check_calendar_reason(reason_value);
  if revision_deadline is null or not isfinite(revision_deadline) or revision_deadline<=moment
    or revision_deadline>(g.start_date::timestamp at time zone 'Asia/Tokyo') then raise exception 'invalid-deadline'; end if;
  before_value:=private.community_snapshot(a.id); group_before:=private.group_snapshot(g.id);
  update public.applications set status='rejected',decision_reason=reason_value,revision_due_at=null where id=a.id returning * into a;
  insert into public.application_status_events(application_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
    values(a.id,'under_review','rejected',reason_value,auth.uid(),moment);
  perform private.community_audit(a.id,'reject_group_participant',before_value,auth.uid(),'staff',reason_value);
  update public.group_applications set status='revision_requested',revision_due_at=revision_deadline,decision_reason=reason_value where id=g.id returning * into g;
  insert into public.group_status_events(group_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
    values(g.id,'under_review','revision_requested',reason_value,auth.uid(),moment);
  perform private.group_staff_audit(g.id,'reject_group_participant',group_before,reason_value);
  return query select a.id,a.status,a.updated_at,g.id,g.status,g.updated_at;
end; $$;

create function public.remove_community_group_participant(target_group_id uuid,target_application_id uuid,
  expected_updated_at timestamptz,removal_reason text)
returns table(result_group_id uuid,result_group_status text,result_group_updated_at timestamptz,result_application_status text)
language plpgsql security definer set search_path='' as $$
declare actor uuid:=private.lock_group_user(); g public.group_applications%rowtype; a public.applications%rowtype;
  m public.group_members%rowtype; reason_value text:=nullif(btrim(removal_reason),''); before_value jsonb; app_before jsonb;
  moment timestamptz:=clock_timestamp(); prior_status text; prior_group_status text;
begin
  select * into g from public.group_applications where id=target_group_id for update;
  if not found or g.representative_user_id is distinct from actor then raise exception 'not-found'; end if;
  perform private.check_calendar_version(g.updated_at,expected_updated_at);
  if g.status not in ('collecting','revision_requested') then raise exception 'invalid-status'; end if;
  if (g.status='collecting' and (g.participant_due_at is null or moment>=g.participant_due_at))
    or (g.status='revision_requested' and (g.revision_due_at is null or moment>=g.revision_due_at)) then raise exception 'participant-deadline-passed'; end if;
  perform private.check_calendar_reason(reason_value);
  select * into m from public.group_members where group_id=g.id and application_id=target_application_id and state='active' for update;
  select * into a from public.applications where id=target_application_id and group_id=g.id for update;
  if m.id is null or a.id is null then raise exception 'not-found'; end if;
  if a.user_id=g.representative_user_id then raise exception 'representative-participant'; end if;
  if (g.status='collecting' and a.status not in ('draft','submitted'))
    or (g.status='revision_requested' and a.status not in ('revision_requested','rejected')) then raise exception 'invalid-status'; end if;
  before_value:=private.group_snapshot(g.id); app_before:=private.community_snapshot(a.id);
  prior_status:=a.status; prior_group_status:=g.status;
  update public.group_members set state='removed',removed_at=moment,removal_reason=reason_value where id=m.id;
  update public.applications set status='cancelled',cancel_reason=reason_value where id=a.id returning * into a;
  insert into public.application_status_events(application_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
    values(a.id,prior_status,'cancelled',reason_value,actor,moment);
  perform private.community_audit(a.id,'remove_group_participant',app_before,actor,'user',reason_value);
  if prior_group_status='revision_requested' then
    update public.group_applications set status='collecting',participant_due_at=revision_due_at,decision_reason=null where id=g.id returning * into g;
    insert into public.group_status_events(group_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
      values(g.id,'revision_requested','collecting',reason_value,actor,moment);
  else update public.group_applications set updated_at=moment where id=g.id returning * into g; end if;
  update public.group_invites set revoked_at=moment where group_id=g.id and revoked_at is null;
  update public.room_allocations set released_from=start_date where group_id=g.id and released_from is null;
  perform private.group_audit(g.id,'remove_group_participant',before_value,actor);
  return query select g.id,g.status,g.updated_at,a.status;
end; $$;

create function public.request_community_group_cancellation(target_group_id uuid,expected_updated_at timestamptz,cancellation_reason text)
returns table(result_id uuid,result_status text,result_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare actor uuid:=private.lock_group_user(); g public.group_applications%rowtype; reason_value text:=nullif(btrim(cancellation_reason),'');
  before_value jsonb; moment timestamptz:=clock_timestamp(); prior_status text;
begin
  select * into g from public.group_applications where id=target_group_id for update;
  if not found or g.representative_user_id is distinct from actor then raise exception 'not-found'; end if;
  perform private.check_calendar_version(g.updated_at,expected_updated_at);
  if g.status not in ('collecting','under_review','revision_requested','approved') then raise exception 'invalid-status'; end if;
  perform private.check_calendar_reason(reason_value);
  perform a.id from public.applications a where a.group_id=g.id for update;
  perform s.id from public.stays s join public.applications a on a.id=s.application_id where a.group_id=g.id for update of s;
  if exists(select 1 from public.stays s join public.applications a on a.id=s.application_id
    join public.group_members m on m.application_id=a.id and m.state='active'
    where a.group_id=g.id and s.status<>'before_move_in') then raise exception 'stay-started'; end if;
  before_value:=private.group_snapshot(g.id); prior_status:=g.status;
  update public.group_applications set status='cancellation_requested',status_before_cancellation=prior_status,
    cancel_reason=reason_value where id=g.id returning * into g;
  insert into public.group_status_events(group_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
    values(g.id,prior_status,'cancellation_requested',reason_value,actor,moment);
  update public.group_invites set revoked_at=moment where group_id=g.id and revoked_at is null;
  perform private.group_audit(g.id,'request_group_cancellation',before_value,actor);
  return query select g.id,g.status,g.updated_at;
end; $$;

create function public.confirm_community_group_cancellation(target_group_id uuid,expected_updated_at timestamptz,confirmation_reason text)
returns table(result_id uuid,result_status text,result_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare g public.group_applications%rowtype; reason_value text:=nullif(btrim(confirmation_reason),''); before_value jsonb;
  moment timestamptz:=clock_timestamp();
begin
  g:=private.lock_group_for_staff(target_group_id,expected_updated_at);
  if g.status<>'cancellation_requested' then raise exception 'invalid-status'; end if;
  perform private.check_calendar_reason(reason_value);
  perform a.id from public.applications a where a.group_id=g.id for update;
  perform m.id from public.group_members m where m.group_id=g.id for update;
  perform s.id from public.stays s join public.applications a on a.id=s.application_id where a.group_id=g.id for update of s;
  perform r.id from public.room_allocations r where r.group_id=g.id for update;
  if exists(select 1 from public.stays s join public.applications a on a.id=s.application_id
    join public.group_members m on m.application_id=a.id and m.state='active'
    where a.group_id=g.id and s.status<>'before_move_in') then raise exception 'stay-started'; end if;
  before_value:=private.group_snapshot(g.id);
  insert into public.application_status_events(application_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
    select a.id,a.status,'cancelled',reason_value,auth.uid(),moment from public.applications a
    where a.group_id=g.id and a.status not in ('rejected','cancelled');
  update public.applications set status='cancelled',cancel_reason=coalesce(cancel_reason,g.cancel_reason)
    where group_id=g.id and status not in ('rejected','cancelled');
  update public.room_allocations set released_from=start_date where group_id=g.id and released_from is null;
  update public.group_applications set status='cancelled',completed_at=moment where id=g.id returning * into g;
  insert into public.group_status_events(group_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
    values(g.id,'cancellation_requested','cancelled',reason_value,auth.uid(),moment);
  perform private.group_staff_audit(g.id,'confirm_group_cancellation',before_value,reason_value);
  return query select g.id,g.status,g.updated_at;
end; $$;

create function public.cancel_approved_group_participant(target_group_id uuid,target_application_id uuid,
  expected_updated_at timestamptz,cancellation_reason text,room_plan jsonb)
returns table(result_id uuid,result_status text,result_updated_at timestamptz,result_application_status text,remaining_participants integer)
language plpgsql security definer set search_path='' as $$
declare g public.group_applications%rowtype; a public.applications%rowtype; m public.group_members%rowtype; s public.stays%rowtype;
  reason_value text:=nullif(btrim(cancellation_reason),''); before_value jsonb; app_before jsonb; moment timestamptz:=clock_timestamp();
  remaining integer; item jsonb;
begin
  g:=private.lock_group_for_staff(target_group_id,expected_updated_at);
  if g.status<>'approved' then raise exception 'invalid-status'; end if;
  perform private.check_calendar_reason(reason_value);
  select * into m from public.group_members where group_id=g.id and application_id=target_application_id and state='active' for update;
  select * into a from public.applications where id=target_application_id and group_id=g.id for update;
  select * into s from public.stays where application_id=a.id for update;
  perform r.id from public.room_allocations r where r.group_id=g.id for update;
  if m.id is null or a.id is null then raise exception 'not-found'; end if;
  if a.status<>'approved' or s.id is null then raise exception 'invalid-status'; end if;
  if s.status<>'before_move_in' then raise exception 'stay-started'; end if;
  before_value:=private.group_snapshot(g.id); app_before:=private.community_snapshot(a.id);
  update public.group_members set state='removed',removed_at=moment,removal_reason=reason_value where id=m.id;
  update public.applications set status='cancelled',cancel_reason=reason_value where id=a.id returning * into a;
  insert into public.application_status_events(application_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
    values(a.id,'approved','cancelled',reason_value,auth.uid(),moment);
  perform private.community_audit(a.id,'cancel_approved_group_participant',app_before,auth.uid(),'staff',reason_value);
  select count(*)::integer into remaining from public.group_members x join public.applications y on y.id=x.application_id
    where x.group_id=g.id and x.state='active' and y.status<>'cancelled';
  if remaining=0 then
    update public.room_allocations set released_from=start_date where group_id=g.id and released_from is null;
    update public.group_applications set status='cancelled',planned_participants=0,completed_at=moment where id=g.id returning * into g;
    insert into public.group_status_events(group_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
      values(g.id,'approved','cancelled',reason_value,auth.uid(),moment);
  else
    update public.group_applications set planned_participants=remaining,updated_at=moment where id=g.id returning * into g;
    perform private.check_group_room_plan(g.id,room_plan);
    update public.room_allocations set released_from=start_date where group_id=g.id and released_from is null;
    for item in select * from jsonb_array_elements(room_plan) loop
      insert into public.room_allocations(group_id,room_id,people_count,start_date,end_date)
      values(g.id,(item->>'room_id')::uuid,(item->>'people_count')::integer,g.start_date,g.end_date)
      on conflict(group_id,room_id) where group_id is not null do update set people_count=excluded.people_count,
        start_date=excluded.start_date,end_date=excluded.end_date,released_from=null,updated_at=moment;
    end loop;
  end if;
  perform private.group_staff_audit(g.id,'cancel_approved_group_participant',before_value,reason_value);
  return query select g.id,g.status,g.updated_at,a.status,remaining;
end; $$;

create function public.get_community_group_cancellation(target_group_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g public.group_applications%rowtype; staff_actor boolean; started boolean;
begin
  if auth.uid() is null or not private.has_active_profile() then raise exception using errcode='42501',message='active-user-required'; end if;
  staff_actor:=private.is_staff();
  select * into g from public.group_applications where id=target_group_id and (representative_user_id=auth.uid() or staff_actor);
  if not found then raise exception 'not-found'; end if;
  select exists(select 1 from public.stays s join public.applications a on a.id=s.application_id
    join public.group_members m on m.application_id=a.id and m.state='active'
    where a.group_id=g.id and s.status<>'before_move_in') into started;
  return jsonb_build_object('id',g.id,'group_name',g.group_name,'status',g.status,'updated_at',g.updated_at,
    'start_date',g.start_date,'end_date',g.end_date,'cancel_reason',g.cancel_reason,
    'can_request',not staff_actor and g.representative_user_id=auth.uid()
      and g.status in ('collecting','under_review','revision_requested','approved') and not started,
    'can_confirm',staff_actor and g.status='cancellation_requested' and not started);
end; $$;

revoke all on function public.reject_group_participant(uuid,timestamptz,text,timestamptz),
  public.remove_community_group_participant(uuid,uuid,timestamptz,text),
  public.request_community_group_cancellation(uuid,timestamptz,text),
  public.confirm_community_group_cancellation(uuid,timestamptz,text),
  public.cancel_approved_group_participant(uuid,uuid,timestamptz,text,jsonb),
  public.get_community_group_cancellation(uuid) from public,anon,authenticated,service_role;
grant execute on function public.reject_group_participant(uuid,timestamptz,text,timestamptz),
  public.remove_community_group_participant(uuid,uuid,timestamptz,text),
  public.request_community_group_cancellation(uuid,timestamptz,text),
  public.confirm_community_group_cancellation(uuid,timestamptz,text),
  public.cancel_approved_group_participant(uuid,uuid,timestamptz,text,jsonb),
  public.get_community_group_cancellation(uuid) to authenticated;
commit;
