-- T20 phase 1: staff review, aggregate room allocation and approval for community groups.
begin;
select private.lock_calendar_facility();

alter table public.room_allocations alter column application_id drop not null;
alter table public.room_allocations drop constraint room_allocations_people_count_check;
alter table public.room_allocations add column group_id uuid references public.group_applications(id) on delete cascade;
alter table public.room_allocations add constraint room_allocations_people_count_check check (people_count between 1 and 3);
alter table public.room_allocations add constraint room_allocations_target_check
  check ((application_id is not null)::integer + (group_id is not null)::integer = 1);
create unique index room_allocations_group_room_uq on public.room_allocations(group_id,room_id) where group_id is not null;
create index room_allocations_group_idx on public.room_allocations(group_id) where group_id is not null;

create policy room_allocations_select_group_member on public.room_allocations for select to authenticated
using (group_id is not null and private.has_active_profile() and exists(
  select 1 from public.group_applications g where g.id=room_allocations.group_id
    and (g.representative_user_id=auth.uid() or exists(select 1 from public.group_members m
      join public.applications a on a.id=m.application_id where m.group_id=g.id and m.state='active' and a.user_id=auth.uid()))));

create function private.lock_group_for_staff(target_group_id uuid,expected_updated_at timestamptz)
returns public.group_applications language plpgsql security definer set search_path='' as $$
declare g public.group_applications%rowtype;
begin
  if auth.uid() is null or not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
  if expected_updated_at is null or not isfinite(expected_updated_at) then raise exception 'invalid-version'; end if;
  perform private.lock_calendar_facility();
  select * into g from public.group_applications where id=target_group_id for update;
  if not found then raise exception 'not-found'; end if;
  perform s.user_id from public.staff_roles s join public.profiles p on p.id=s.user_id
    where s.user_id=auth.uid() and p.account_state='active' for share of s,p;
  if not found then raise exception using errcode='42501',message='staff-required'; end if;
  if g.updated_at is distinct from expected_updated_at then raise exception 'stale-update'; end if;
  return g;
end; $$;

create function private.group_staff_audit(target_id uuid,operation text,before_value jsonb,reason_value text)
returns void language sql security definer set search_path='' as $$
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id,reason)
  values('group_application',target_id,operation,before_value,private.group_snapshot(target_id),'staff',auth.uid(),reason_value);
$$;

create or replace function private.group_snapshot(target_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('group',(select to_jsonb(g) from public.group_applications g where g.id=target_id),
    'claim',(select to_jsonb(q) from public.calendar_claims q where q.group_id=target_id),
    'number',(select to_jsonb(n) from public.reception_numbers n where n.group_id=target_id),
    'members',(select coalesce(jsonb_agg(to_jsonb(m) order by m.joined_at,m.id),'[]') from public.group_members m where m.group_id=target_id),
    'applications',(select coalesce(jsonb_agg(to_jsonb(a) order by a.id),'[]') from public.applications a where a.group_id=target_id),
    'rooms',(select coalesce(jsonb_agg(to_jsonb(r) order by r.room_id),'[]') from public.room_allocations r where r.group_id=target_id));
$$;

create function private.active_group_participant_count(target_group_id uuid)
returns integer language sql stable security definer set search_path='' as $$
  select count(*)::integer from public.group_members m join public.applications a on a.id=m.application_id
  where m.group_id=target_group_id and m.state='active' and a.status not in ('rejected','cancelled');
$$;

create function private.check_group_room_plan(target_group_id uuid,plan jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare g public.group_applications%rowtype; item jsonb; room_record public.rooms%rowtype; total integer:=0; people integer; room_value uuid;
begin
  select * into g from public.group_applications where id=target_group_id;
  if plan is null or jsonb_typeof(plan)<>'array' or jsonb_array_length(plan)=0 then raise exception 'room-required'; end if;
  if exists(select 1 from jsonb_array_elements(plan) x group by x->>'room_id' having count(*)>1) then raise exception 'duplicate-room'; end if;
  for item in select * from jsonb_array_elements(plan) loop
    if jsonb_typeof(item)<>'object' or exists(select 1 from jsonb_object_keys(item) k where k not in ('room_id','people_count'))
      or coalesce(item->>'room_id','')!~'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      or jsonb_typeof(item->'people_count')<>'number' or (item->>'people_count')!~'^\d+$' then raise exception 'invalid-room-plan'; end if;
    room_value:=(item->>'room_id')::uuid; people:=(item->>'people_count')::integer;
    select * into room_record from public.rooms where id=room_value for share;
    if not found then raise exception 'invalid-room'; end if;
    if people<1 or people>room_record.capacity then raise exception 'room-capacity-full'; end if;
    if exists(select 1 from generate_series(g.start_date,g.end_date,interval '1 day') day_value
      where people+(select coalesce(sum(r.people_count),0) from public.room_allocations r
        where r.group_id is distinct from target_group_id and r.room_id=room_value
          and r.start_date<=day_value::date and r.end_date>=day_value::date
          and (r.released_from is null or day_value::date<r.released_from))>room_record.capacity) then raise exception 'room-capacity-full'; end if;
    total:=total+people;
  end loop;
  if total<>private.active_group_participant_count(target_group_id) then raise exception 'allocation-count-mismatch'; end if;
  if total>15 or exists(select 1 from generate_series(g.start_date,g.end_date,interval '1 day') day_value
    where total+(select coalesce(sum(r.people_count),0) from public.room_allocations r
      where r.group_id is distinct from target_group_id and r.start_date<=day_value::date and r.end_date>=day_value::date
        and (r.released_from is null or day_value::date<r.released_from))>15) then raise exception 'facility-capacity-full'; end if;
end; $$;

create function public.set_group_room_allocations(target_group_id uuid,expected_updated_at timestamptz,room_plan jsonb,change_reason text default null)
returns table(result_id uuid,result_status text,result_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare g public.group_applications%rowtype; before_value jsonb; reason_value text:=nullif(btrim(change_reason),''); moment timestamptz:=clock_timestamp();
begin
  g:=private.lock_group_for_staff(target_group_id,expected_updated_at);
  if g.status not in ('under_review','approved') or g.purpose_reviewed_at is null then raise exception 'invalid-status'; end if;
  if g.status='approved' then perform private.check_calendar_reason(reason_value); elsif char_length(reason_value)>2000 then raise exception 'reason-too-long'; end if;
  perform id from public.room_allocations where group_id=g.id for update;
  perform private.check_group_room_plan(g.id,room_plan);
  if (select coalesce(jsonb_agg(jsonb_build_object('room_id',room_id,'people_count',people_count) order by room_id),'[]'::jsonb)
      from public.room_allocations where group_id=g.id and released_from is null)
     = (select jsonb_agg(jsonb_build_object('room_id',(x->>'room_id')::uuid,'people_count',(x->>'people_count')::integer) order by (x->>'room_id')::uuid)
        from jsonb_array_elements(room_plan) x) then return query select g.id,g.status,g.updated_at; return; end if;
  before_value:=private.group_snapshot(g.id);
  update public.room_allocations set released_from=start_date where group_id=g.id and released_from is null;
  insert into public.room_allocations(group_id,room_id,people_count,start_date,end_date)
    select g.id,(x->>'room_id')::uuid,(x->>'people_count')::integer,g.start_date,g.end_date from jsonb_array_elements(room_plan) x
    on conflict(group_id,room_id) where group_id is not null do update set people_count=excluded.people_count,
      start_date=excluded.start_date,end_date=excluded.end_date,released_from=null,updated_at=moment;
  update public.group_applications set updated_at=moment where id=g.id returning * into g;
  perform private.group_staff_audit(g.id,'set_group_room_allocations',before_value,reason_value);
  return query select g.id,g.status,g.updated_at;
end; $$;

create function public.review_group_participant(target_application_id uuid,review_action text,expected_updated_at timestamptz,
  public_reason text default null,revision_deadline timestamptz default null)
returns table(result_id uuid,result_status text,result_updated_at timestamptz,result_group_id uuid,result_group_status text,result_group_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare a public.applications%rowtype; g public.group_applications%rowtype; group_value uuid; next_status text; reason_value text:=nullif(btrim(public_reason),'');
  before_value jsonb; group_before jsonb; moment timestamptz:=clock_timestamp();
begin
  if auth.uid() is null or not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
  if expected_updated_at is null or not isfinite(expected_updated_at) then raise exception 'invalid-version'; end if;
  perform private.lock_calendar_facility();
  select group_id into group_value from public.applications where id=target_application_id and usage_type='community_group';
  if not found then raise exception 'not-found'; end if;
  select * into g from public.group_applications where id=group_value for update;
  select * into a from public.applications where id=target_application_id and group_id=g.id and usage_type='community_group' for update;
  if not found then raise exception 'not-found'; end if;
  perform s.user_id from public.staff_roles s join public.profiles p on p.id=s.user_id where s.user_id=auth.uid() and p.account_state='active' for share of s,p;
  if not found then raise exception using errcode='42501',message='staff-required'; end if;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if g.status<>'under_review' or g.purpose_reviewed_at is null or not exists(select 1 from public.group_members m where m.group_id=g.id and m.application_id=a.id and m.state='active') then raise exception 'invalid-status'; end if;
  if review_action not in ('start_review','request_revision','approve') then raise exception 'invalid-action'; end if;
  if (review_action='start_review' and a.status<>'submitted') or (review_action<>'start_review' and a.status<>'under_review') then raise exception 'invalid-status'; end if;
  if review_action='request_revision' then
    perform private.check_calendar_reason(reason_value);
    if revision_deadline is null or not isfinite(revision_deadline) or revision_deadline<=moment or revision_deadline>(g.start_date::timestamp at time zone 'Asia/Tokyo') then raise exception 'invalid-deadline'; end if;
  elsif char_length(reason_value)>2000 then raise exception 'reason-too-long'; end if;
  if review_action='approve' then
    perform private.validate_group_participant_fields(jsonb_build_object('user_name',a.user_name,'user_address',a.user_address,
      'user_phone',a.user_phone,'emergency_name',a.emergency_name,'emergency_address',a.emergency_address,
      'emergency_phone',a.emergency_phone,'special_notes',a.special_notes,'requires_guardian_consent',a.requires_guardian_consent),true);
    if a.submitted_at is null or a.last_submitted_at is null or coalesce(a.email_snapshot,'')!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
      or not exists(select 1 from public.reception_numbers n where n.application_id=a.id)
      or not exists(select 1 from public.application_charges c where c.application_id=a.id
        and c.total_amount=(select coalesce(sum(m.amount),0) from public.charge_months m where m.charge_id=c.id)) then raise exception 'application-inconsistent'; end if;
    if a.requires_guardian_consent and not exists(select 1 from public.consent_documents d where d.application_id=a.id) then raise exception 'guardian-consent'; end if;
  end if;
  before_value:=private.community_snapshot(a.id); group_before:=private.group_snapshot(g.id);
  next_status:=case review_action when 'start_review' then 'under_review' when 'request_revision' then 'revision_requested' else 'approved' end;
  update public.applications set status=next_status,decision_reason=case when review_action='request_revision' then reason_value end,
    approval_comment=case when review_action='approve' then reason_value else approval_comment end,revision_due_at=case when review_action='request_revision' then revision_deadline end where id=a.id returning * into a;
  insert into public.application_status_events(application_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
    values(a.id,case when review_action='start_review' then 'submitted' else 'under_review' end,next_status,reason_value,auth.uid(),moment);
  perform private.community_audit(a.id,'review_group_participant_'||review_action,before_value,auth.uid(),'staff',reason_value);
  if review_action='request_revision' then
    update public.group_applications set status='revision_requested',revision_due_at=revision_deadline,decision_reason=reason_value where id=g.id returning * into g;
    insert into public.group_status_events(group_id,from_status,to_status,public_reason,actor_user_id,occurred_at) values(g.id,'under_review','revision_requested',reason_value,auth.uid(),moment);
    perform private.group_staff_audit(g.id,'request_group_revision_for_participant',group_before,reason_value);
  end if;
  return query select a.id,a.status,a.updated_at,g.id,g.status,g.updated_at;
end; $$;

create function public.review_group_application(target_group_id uuid,review_action text,expected_updated_at timestamptz,public_reason text default null)
returns table(result_id uuid,result_status text,result_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare g public.group_applications%rowtype; reason_value text:=nullif(btrim(public_reason),''); before_value jsonb; moment timestamptz:=clock_timestamp(); n integer;
begin
  g:=private.lock_group_for_staff(target_group_id,expected_updated_at);
  if review_action not in ('confirm_purpose','reject','approve') or g.status<>'under_review' then raise exception 'invalid-action'; end if;
  if review_action='confirm_purpose' then
    if reason_value is not null and char_length(reason_value)>2000 then raise exception 'reason-too-long'; end if;
  elsif review_action='reject' then perform private.check_calendar_reason(reason_value);
  elsif char_length(reason_value)>2000 then raise exception 'reason-too-long'; end if;
  perform id from public.applications where group_id=g.id for update;
  perform id from public.group_members where group_id=g.id for update;
  perform id from public.room_allocations where group_id=g.id for update;
  before_value:=private.group_snapshot(g.id); n:=private.active_group_participant_count(g.id);
  if review_action='confirm_purpose' then
    if g.purpose_reviewed_at is null then update public.group_applications set purpose_reviewed_at=moment where id=g.id returning * into g;
      perform private.group_staff_audit(g.id,'confirm_group_purpose',before_value,reason_value); end if;
  elsif review_action='reject' then
    insert into public.application_status_events(application_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
      select a.id,a.status,'rejected',reason_value,auth.uid(),moment from public.applications a where a.group_id=g.id and a.status not in ('rejected','cancelled');
    update public.applications set status='rejected',decision_reason=reason_value where group_id=g.id and status not in ('rejected','cancelled');
    update public.room_allocations set released_from=start_date where group_id=g.id and released_from is null;
    update public.group_applications set status='rejected',decision_reason=reason_value where id=g.id returning * into g;
    insert into public.group_status_events(group_id,from_status,to_status,public_reason,actor_user_id,occurred_at) values(g.id,'under_review','rejected',reason_value,auth.uid(),moment);
    perform private.group_staff_audit(g.id,'reject_group_application',before_value,reason_value);
  else
    if g.purpose_reviewed_at is null then raise exception 'purpose-review-required'; end if;
    if n<2 or n<>g.planned_participants or exists(select 1 from public.group_members m join public.applications a on a.id=m.application_id where m.group_id=g.id and m.state='active' and a.status<>'approved') then raise exception 'participants-not-approved'; end if;
    perform private.check_group_room_plan(g.id,(select jsonb_agg(jsonb_build_object('room_id',room_id,'people_count',people_count)) from public.room_allocations where group_id=g.id and released_from is null));
    insert into public.stays(application_id,status,created_at,updated_at)
      select a.id,'before_move_in',moment,moment from public.group_members m join public.applications a on a.id=m.application_id
      where m.group_id=g.id and m.state='active' on conflict(application_id) do nothing;
    update public.group_applications set status='approved',approval_comment=reason_value where id=g.id returning * into g;
    insert into public.group_status_events(group_id,from_status,to_status,public_reason,actor_user_id,occurred_at) values(g.id,'under_review','approved',reason_value,auth.uid(),moment);
    perform private.group_staff_audit(g.id,'approve_group_application',before_value,reason_value);
  end if;
  return query select g.id,g.status,g.updated_at;
end; $$;

create function public.get_staff_group_review_context(target_group_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g public.group_applications%rowtype;
begin
  if auth.uid() is null or not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
  select * into g from public.group_applications where id=target_group_id;
  if not found then raise exception 'not-found'; end if;
  return jsonb_build_object('id',g.id,'group_name',g.group_name,'status',g.status,'updated_at',g.updated_at,
    'start_date',g.start_date,'end_date',g.end_date,'purpose',g.purpose,'local_activity',g.local_activity,
    'planned_participants',g.planned_participants,'purpose_reviewed_at',g.purpose_reviewed_at,
    'participants',(select coalesce(jsonb_agg(jsonb_build_object('application_id',a.id,'name',a.user_name,'status',a.status,'updated_at',a.updated_at) order by m.joined_at,a.id),'[]')
      from public.group_members m join public.applications a on a.id=m.application_id where m.group_id=g.id and m.state='active'),
    'allocations',(select coalesce(jsonb_agg(jsonb_build_object('room_id',r.room_id,'room_name',x.name,'people_count',r.people_count,'released_from',r.released_from) order by x.name),'[]')
      from public.room_allocations r join public.rooms x on x.id=r.room_id where r.group_id=g.id),
    'rooms',(select jsonb_agg(jsonb_build_object('id',id,'name',name,'capacity',capacity) order by name) from public.rooms));
end; $$;

revoke all on function private.lock_group_for_staff(uuid,timestamptz),private.group_staff_audit(uuid,text,jsonb,text),
  private.active_group_participant_count(uuid),private.check_group_room_plan(uuid,jsonb),private.group_snapshot(uuid) from public,anon,authenticated,service_role;
revoke all on function public.set_group_room_allocations(uuid,timestamptz,jsonb,text),
  public.review_group_participant(uuid,text,timestamptz,text,timestamptz),public.review_group_application(uuid,text,timestamptz,text),
  public.get_staff_group_review_context(uuid) from public,anon,authenticated,service_role;
grant execute on function public.set_group_room_allocations(uuid,timestamptz,jsonb,text),
  public.review_group_participant(uuid,text,timestamptz,text,timestamptz),public.review_group_application(uuid,text,timestamptz,text),
  public.get_staff_group_review_context(uuid) to authenticated;
commit;
