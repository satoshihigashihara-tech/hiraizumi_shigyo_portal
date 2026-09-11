-- T18 foundation: representative-owned community group drafts and exclusive claims.
-- Invitations, members, review, rooms, cancellation and automated expiry are later phases.
begin;
select private.lock_calendar_facility();

create table public.group_applications (
  id uuid primary key default gen_random_uuid(),
  representative_user_id uuid references auth.users(id) on delete set null,
  group_name text,
  representative_name text,
  representative_address text,
  representative_phone text,
  representative_email text,
  start_date date,
  end_date date,
  usage_place text check (usage_place is null or usage_place='common_and_second_floor'),
  purpose text,
  local_activity text,
  special_notes text,
  planned_participants integer check (planned_participants is null or planned_participants between 2 and 15),
  representative_stays boolean not null default false,
  status text not null default 'draft' check (status in
    ('draft','collecting','under_review','revision_requested','approved','rejected','cancellation_requested','cancelled')),
  submitted_at timestamptz,
  participant_due_at timestamptz,
  revision_due_at timestamptz,
  purpose_reviewed_at timestamptz,
  decision_reason text,
  approval_comment text,
  cancel_reason text,
  status_before_cancellation text,
  completed_at timestamptz,
  last_submission_key uuid,
  last_submission_version timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check ((start_date is null and end_date is null) or
    (start_date between date '0001-01-01' and date '9999-12-31'
      and end_date between date '0001-01-01' and date '9999-12-31' and end_date-start_date between 1 and 14)),
  check ((status='draft' and submitted_at is null) or (status<>'draft' and submitted_at is not null)),
  check (participant_due_at is null or isfinite(participant_due_at)),
  check (revision_due_at is null or isfinite(revision_due_at))
);
create index group_applications_representative_idx on public.group_applications(representative_user_id,created_at desc);
create index group_applications_status_due_idx on public.group_applications(status,participant_due_at);
create trigger group_applications_set_updated_at before update on public.group_applications
for each row execute function private.set_application_updated_at();

create table public.group_status_events (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.group_applications(id) on delete cascade,
  from_status text,
  to_status text not null,
  public_reason text,
  actor_user_id uuid references auth.users(id) on delete set null,
  occurred_at timestamptz not null default clock_timestamp()
);
create index group_status_events_group_idx on public.group_status_events(group_id,occurred_at,id);

alter table public.calendar_claims drop constraint calendar_claims_claim_type_check;
alter table public.calendar_claims drop constraint calendar_claims_source_check;
alter table public.calendar_claims add column group_id uuid unique
  references public.group_applications(id) on delete restrict;
alter table public.calendar_claims add constraint calendar_claims_claim_type_check
  check (claim_type in ('camp','blocked','individual','group'));
alter table public.calendar_claims add constraint calendar_claims_source_check check (
  (claim_type='camp' and camp_id is not null and blocked_period_id is null and application_id is null and group_id is null)
  or (claim_type='blocked' and blocked_period_id is not null and camp_id is null and application_id is null and group_id is null)
  or (claim_type='individual' and application_id is not null and camp_id is null and blocked_period_id is null and group_id is null)
  or (claim_type='group' and group_id is not null and camp_id is null and blocked_period_id is null and application_id is null));

alter table public.reception_numbers alter column application_id drop not null;
alter table public.reception_numbers add column group_id uuid unique
  references public.group_applications(id) on delete cascade;
alter table public.reception_numbers add constraint reception_numbers_target_check
  check ((application_id is not null)::integer+(group_id is not null)::integer=1);

alter table public.group_applications enable row level security;
alter table public.group_status_events enable row level security;
create policy group_applications_select_representative on public.group_applications for select to authenticated
using (representative_user_id=auth.uid() and private.has_active_profile());
create policy group_applications_select_staff on public.group_applications for select to authenticated using (private.is_staff());
create policy group_status_events_select_representative on public.group_status_events for select to authenticated
using (private.has_active_profile() and exists(select 1 from public.group_applications g
  where g.id=group_status_events.group_id and g.representative_user_id=auth.uid()));
create policy group_status_events_select_staff on public.group_status_events for select to authenticated using (private.is_staff());
revoke all on public.group_applications,public.group_status_events from public,anon,authenticated,service_role;
grant select on public.group_applications,public.group_status_events to authenticated;

create function private.lock_group_user()
returns uuid language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();
begin
  if actor is null or not private.has_active_profile() then
    raise exception using errcode='42501',message='active-user-required'; end if;
  perform private.lock_calendar_facility();
  perform p.id from public.profiles p where p.id=actor and p.account_state='active' for share;
  if not found then raise exception using errcode='42501',message='active-user-required'; end if;
  return actor;
end; $$;

create function private.validate_group_fields(fields jsonb,complete boolean)
returns void language plpgsql set search_path='' as $$
declare k text; v jsonb; limits jsonb:='{"group_name":120,"representative_name":100,"representative_address":500,"representative_phone":20,"purpose":2000,"local_activity":2000,"special_notes":2000}';
begin
  if fields is null or jsonb_typeof(fields)<>'object' then raise exception 'invalid-fields'; end if;
  for k,v in select * from jsonb_each(fields) loop
    if not (limits ? k or k in ('start_date','end_date','usage_place','planned_participants','representative_stays')) then
      raise exception 'invalid-fields'; end if;
    if k='planned_participants' and v<>'null'::jsonb
      and (jsonb_typeof(v)<>'number' or v::text !~ '^\d+$') then raise exception 'invalid-fields'; end if;
    if k='representative_stays' and v<>'null'::jsonb and jsonb_typeof(v)<>'boolean' then raise exception 'invalid-fields'; end if;
    if k not in ('planned_participants','representative_stays') and v<>'null'::jsonb and jsonb_typeof(v)<>'string' then raise exception 'invalid-fields'; end if;
    if limits ? k and char_length(btrim(fields->>k))>(limits->>k)::integer then raise exception 'field-too-long'; end if;
  end loop;
  if nullif(btrim(fields->>'representative_phone'),'') is not null
    and btrim(fields->>'representative_phone') !~ '^[0-9+][0-9() -]{7,19}$' then raise exception 'invalid-phone'; end if;
  if fields->>'usage_place' is not null and fields->>'usage_place'<>'common_and_second_floor' then raise exception 'invalid-place'; end if;
  if fields ? 'planned_participants' and fields->'planned_participants'<>'null'::jsonb
    and (fields->>'planned_participants')::integer not between 2 and 15 then raise exception 'invalid-participant-count'; end if;
  if nullif(fields->>'start_date','') is not null or nullif(fields->>'end_date','') is not null then
    if coalesce(fields->>'start_date','') !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(fields->>'end_date','') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'invalid-period'; end if;
    begin perform private.check_community_period((fields->>'start_date')::date,(fields->>'end_date')::date,null,false);
    exception when datetime_field_overflow or invalid_datetime_format then raise exception 'invalid-period'; end;
  end if;
  if complete then
    foreach k in array array['group_name','representative_name','representative_address','representative_phone','purpose','local_activity','usage_place','start_date','end_date'] loop
      if nullif(btrim(fields->>k),'') is null then raise exception 'required-fields'; end if;
    end loop;
    if fields->'planned_participants' is null or fields->'planned_participants'='null'::jsonb
      or fields->'representative_stays' is null or fields->'representative_stays'='null'::jsonb then raise exception 'required-fields'; end if;
  end if;
end; $$;

create function private.apply_group_fields(target_id uuid,fields jsonb)
returns void language sql security definer set search_path='' as $$
  update public.group_applications set
    group_name=nullif(btrim(fields->>'group_name'),''),representative_name=nullif(btrim(fields->>'representative_name'),''),
    representative_address=nullif(btrim(fields->>'representative_address'),''),representative_phone=nullif(btrim(fields->>'representative_phone'),''),
    start_date=nullif(fields->>'start_date','')::date,end_date=nullif(fields->>'end_date','')::date,
    usage_place=fields->>'usage_place',purpose=nullif(btrim(fields->>'purpose'),''),
    local_activity=nullif(btrim(fields->>'local_activity'),''),special_notes=nullif(btrim(fields->>'special_notes'),''),
    planned_participants=nullif(fields->>'planned_participants','')::integer,
    representative_stays=coalesce((fields->>'representative_stays')::boolean,false)
  where id=target_id;
$$;

create function private.group_snapshot(target_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('group',(select jsonb_build_object('id',g.id,'status',g.status,
      'start_date',g.start_date,'end_date',g.end_date,'usage_place',g.usage_place,
      'planned_participants',g.planned_participants,'representative_stays',g.representative_stays,
      'submitted_at',g.submitted_at,'participant_due_at',g.participant_due_at,
      'revision_due_at',g.revision_due_at,'purpose_reviewed_at',g.purpose_reviewed_at,
      'completed_at',g.completed_at,'updated_at',g.updated_at)
      from public.group_applications g where g.id=target_id),
    'claim',(select to_jsonb(q) from public.calendar_claims q where q.group_id=target_id),
    'number',(select to_jsonb(n) from public.reception_numbers n where n.group_id=target_id));
$$;

create function private.group_audit(target_id uuid,operation text,before_value jsonb,actor uuid)
returns void language sql security definer set search_path='' as $$
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id)
  values('group_application',target_id,operation,before_value,private.group_snapshot(target_id),'user',actor);
$$;

create function private.check_group_availability(target_id uuid,starts_on date,ends_on date)
returns void language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from public.calendar_claims q where q.group_id is distinct from target_id
    and q.start_date<=ends_on and q.end_date>=starts_on
    and (q.released_from is null or greatest(q.start_date,starts_on)<q.released_from)) then raise exception 'calendar-unavailable'; end if;
  if exists(select 1 from public.camps c left join public.calendar_claims q on q.camp_id=c.id
    where c.deleted_at is null and c.start_date<=ends_on and c.end_date>=starts_on
      and (q.id is null or q.start_date is distinct from c.start_date or q.end_date is distinct from c.end_date))
    or exists(select 1 from public.blocked_periods b left join public.calendar_claims q on q.blocked_period_id=b.id
      where b.deleted_at is null and b.start_date<=ends_on and b.end_date>=starts_on
        and (q.id is null or q.start_date is distinct from b.start_date or q.end_date is distinct from b.end_date))
    or exists(select 1 from public.applications a left join public.calendar_claims q on q.application_id=a.id
      where a.usage_type='community_individual' and a.status in ('submitted','under_review','revision_requested','approved','cancellation_requested')
        and a.start_date<=ends_on and a.end_date>=starts_on
        and (q.id is null or q.start_date is distinct from a.start_date or q.end_date is distinct from a.end_date))
    or exists(select 1 from public.group_applications g left join public.calendar_claims q on q.group_id=g.id
      where g.id<>target_id and g.status in ('collecting','under_review','revision_requested','approved','cancellation_requested')
        and g.start_date<=ends_on and g.end_date>=starts_on
        and (q.id is null or q.start_date is distinct from g.start_date or q.end_date is distinct from g.end_date))
    then raise exception 'calendar-inconsistent'; end if;
end; $$;

create function private.sync_group_claim()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.status in ('collecting','under_review','revision_requested','approved','cancellation_requested') then
    insert into public.calendar_claims(claim_type,group_id,start_date,end_date)
    values('group',new.id,new.start_date,new.end_date)
    on conflict(group_id) do update set start_date=excluded.start_date,end_date=excluded.end_date,
      released_from=case when (calendar_claims.start_date,calendar_claims.end_date) is distinct from
        (excluded.start_date,excluded.end_date) then null else calendar_claims.released_from end;
  elsif new.status in ('rejected','cancelled') then update public.calendar_claims set released_from=start_date where group_id=new.id;
  end if;
  return new;
end; $$;
create trigger group_applications_sync_claim after insert or update of status,start_date,end_date
on public.group_applications for each row execute function private.sync_group_claim();

create function public.create_community_group_draft(target_group_id uuid,draft_fields jsonb default '{}'::jsonb)
returns table(result_id uuid,result_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare actor uuid:=private.lock_group_user(); g public.group_applications%rowtype; f jsonb;
begin
  if target_group_id is null then raise exception 'invalid-group'; end if;
  select * into g from public.group_applications where id=target_group_id for update;
  if found then
    if g.representative_user_id is distinct from actor then raise exception 'not-found'; end if;
    return query select g.id,g.updated_at; return;
  end if;
  select jsonb_build_object('representative_name',p.full_name,'representative_address',p.address,
    'representative_phone',p.phone,'usage_place','common_and_second_floor','representative_stays',false)
    into f from public.profiles p where p.id=actor;
  f:=f||draft_fields;
  perform private.validate_group_fields(f,false);
  insert into public.group_applications(id,representative_user_id) values(target_group_id,actor);
  perform private.apply_group_fields(target_group_id,f);
  insert into public.group_status_events(group_id,to_status,actor_user_id) values(target_group_id,'draft',actor);
  perform private.group_audit(target_group_id,'create_community_group_draft','{}',actor);
  return query select x.id,x.updated_at from public.group_applications x where x.id=target_group_id;
end; $$;

create function public.save_community_group_draft(target_group_id uuid,expected_updated_at timestamptz,draft_fields jsonb)
returns table(result_id uuid,result_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare actor uuid:=private.lock_group_user(); g public.group_applications%rowtype; before_value jsonb;
begin
  select * into g from public.group_applications where id=target_group_id for update;
  if not found or g.representative_user_id is distinct from actor then raise exception 'not-found'; end if;
  perform private.check_calendar_version(g.updated_at,expected_updated_at);
  if g.status<>'draft' then raise exception 'not-editable'; end if;
  perform private.validate_group_fields(draft_fields,false);
  before_value:=private.group_snapshot(g.id); perform private.apply_group_fields(g.id,draft_fields);
  perform private.group_audit(g.id,'save_community_group_draft',before_value,actor);
  return query select x.id,x.updated_at from public.group_applications x where x.id=g.id;
end; $$;

create function public.start_community_group_application(target_group_id uuid,expected_updated_at timestamptz,
  submission_key uuid,confirmed boolean)
returns table(result_id uuid,result_status text,result_updated_at timestamptz,reception_number text,
  submission_time timestamptz,participant_due_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare actor uuid:=private.lock_group_user(); g public.group_applications%rowtype; f jsonb; before_value jsonb;
  moment timestamptz; today_jst date; due_value timestamptz; year_value integer; serial_value integer; number_value text;
begin
  select * into g from public.group_applications where id=target_group_id for update;
  if not found or g.representative_user_id is distinct from actor then raise exception 'not-found'; end if;
  if confirmed is distinct from true then raise exception 'confirmation-required'; end if;
  if submission_key is null then raise exception 'invalid-submission-key'; end if;
  if expected_updated_at is null or not isfinite(expected_updated_at) then raise exception 'invalid-version'; end if;
  if g.last_submission_key=submission_key and g.last_submission_version=expected_updated_at then
    return query select g.id,g.status,g.updated_at,n.display_number,g.submitted_at,g.participant_due_at
      from public.reception_numbers n where n.group_id=g.id; return;
  end if;
  perform private.check_calendar_version(g.updated_at,expected_updated_at);
  if g.status<>'draft' then raise exception 'not-submittable'; end if;
  f:=jsonb_build_object('group_name',g.group_name,'representative_name',g.representative_name,
    'representative_address',g.representative_address,'representative_phone',g.representative_phone,
    'start_date',g.start_date,'end_date',g.end_date,'usage_place',g.usage_place,'purpose',g.purpose,
    'local_activity',g.local_activity,'special_notes',g.special_notes,'planned_participants',g.planned_participants,
    'representative_stays',g.representative_stays);
  perform private.validate_group_fields(f,true);
  moment:=clock_timestamp(); today_jst:=(moment at time zone 'Asia/Tokyo')::date;
  perform private.check_community_period(g.start_date,g.end_date,moment,true);
  if coalesce(auth.jwt()->>'email','') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'invalid-email'; end if;
  perform private.check_group_availability(g.id,g.start_date,g.end_date);
  due_value:=least(((today_jst+8)::timestamp at time zone 'Asia/Tokyo'),
    (g.start_date::timestamp at time zone 'Asia/Tokyo'));
  before_value:=private.group_snapshot(g.id);
  update public.group_applications set status='collecting',representative_email=lower(auth.jwt()->>'email'),
    submitted_at=moment,participant_due_at=due_value,last_submission_key=submission_key,
    last_submission_version=expected_updated_at where id=g.id;
  select display_number into number_value from public.reception_numbers where group_id=g.id;
  if number_value is null then
    year_value:=extract(year from (moment at time zone 'Asia/Tokyo')-interval '3 months')::integer;
    insert into public.reception_counters(fiscal_year,last_number) values(year_value,0) on conflict do nothing;
    update public.reception_counters set last_number=last_number+1,updated_at=moment
      where fiscal_year=year_value returning last_number into serial_value;
    number_value:=format('SG-%s-%s',year_value,lpad(serial_value::text,greatest(4,length(serial_value::text)),'0'));
    insert into public.reception_numbers(fiscal_year,serial_number,display_number,group_id)
      values(year_value,serial_value,number_value,g.id);
  end if;
  insert into public.group_status_events(group_id,from_status,to_status,actor_user_id,occurred_at)
    values(g.id,'draft','collecting',actor,moment);
  perform private.group_audit(g.id,'start_community_group_application',before_value,actor);
  return query select x.id,x.status,x.updated_at,number_value,x.submitted_at,x.participant_due_at
    from public.group_applications x where x.id=g.id;
end; $$;

create function public.get_community_group(target_group_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g public.group_applications%rowtype;
begin
  if auth.uid() is null or not private.has_active_profile() then
    raise exception using errcode='42501',message='active-user-required'; end if;
  select * into g from public.group_applications where id=target_group_id and representative_user_id=auth.uid();
  if not found then raise exception 'not-found'; end if;
  return jsonb_build_object('id',g.id,'status',g.status,'updated_at',g.updated_at,'submitted_at',g.submitted_at,
    'participant_due_at',g.participant_due_at,'reception_number',(select n.display_number from public.reception_numbers n where n.group_id=g.id),
    'fields',jsonb_build_object('group_name',g.group_name,'representative_name',g.representative_name,
      'representative_address',g.representative_address,'representative_phone',g.representative_phone,
      'start_date',g.start_date,'end_date',g.end_date,'usage_place',g.usage_place,'purpose',g.purpose,
      'local_activity',g.local_activity,'special_notes',g.special_notes,'planned_participants',g.planned_participants,
      'representative_stays',g.representative_stays),
    'events',(select coalesce(jsonb_agg(jsonb_build_object('from_status',e.from_status,'to_status',e.to_status,
      'public_reason',e.public_reason,'occurred_at',e.occurred_at) order by e.occurred_at,e.id),'[]'::jsonb)
      from public.group_status_events e where e.group_id=g.id));
end; $$;

-- Existing calendar APIs now understand the exclusive group claim.
create or replace function private.check_community_availability(target_id uuid,actor uuid,starts_on date,ends_on date)
returns void language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from public.calendar_claims q where q.claim_type in ('camp','blocked','group')
    and q.start_date<=ends_on and q.end_date>=starts_on
    and (q.released_from is null or greatest(q.start_date,starts_on)<q.released_from))
    or exists(select 1 from public.camps c where c.deleted_at is null and c.start_date<=ends_on and c.end_date>=starts_on)
    or exists(select 1 from public.blocked_periods b where b.deleted_at is null and b.start_date<=ends_on and b.end_date>=starts_on)
    or exists(select 1 from public.group_applications g where g.status in
      ('collecting','under_review','revision_requested','approved','cancellation_requested')
      and g.start_date<=ends_on and g.end_date>=starts_on) then raise exception 'calendar-unavailable'; end if;
  if exists(select 1 from public.applications a left join public.calendar_claims q on q.application_id=a.id
    where a.usage_type='community_individual' and a.status in ('submitted','under_review','revision_requested','approved','cancellation_requested')
      and a.start_date<=ends_on and a.end_date>=starts_on
      and (q.id is null or q.start_date is distinct from a.start_date or q.end_date is distinct from a.end_date))
    or exists(select 1 from public.group_applications g left join public.calendar_claims q on q.group_id=g.id
      where g.status in ('collecting','under_review','revision_requested','approved','cancellation_requested')
        and g.start_date<=ends_on and g.end_date>=starts_on
        and (q.id is null or q.start_date is distinct from g.start_date or q.end_date is distinct from g.end_date))
    then raise exception 'calendar-inconsistent'; end if;
  if exists(select 1 from public.applications a left join public.calendar_claims q on q.application_id=a.id
    where a.user_id=actor and a.id<>target_id and a.start_date<=ends_on and a.end_date>=starts_on
      and a.status in ('submitted','under_review','revision_requested','approved','cancellation_requested')
      and (q.released_from is null or greatest(a.start_date,starts_on)<q.released_from)) then raise exception 'duplicate-stay'; end if;
  if exists(select 1 from generate_series(0,ends_on-starts_on)d(n)
    where private.community_occupancy(starts_on+d.n,target_id)>=15) then raise exception 'capacity-full'; end if;
end; $$;

create or replace function private.assert_calendar_available(starts_on date,ends_on date,
  ignored_camp uuid default null,ignored_block uuid default null)
returns void language plpgsql security definer set search_path='' as $$
declare conflicts jsonb;
begin
  perform private.check_calendar_period(starts_on,ends_on);
  select jsonb_agg(x.item) into conflicts from (
    select jsonb_build_object('type',q.claim_type,'id',coalesce(q.camp_id,q.blocked_period_id,q.group_id),
      'name',coalesce(c.name,g.group_name,'利用停止'),'startDate',q.start_date,'endDate',q.end_date,'status','active') item
    from public.calendar_claims q left join public.camps c on c.id=q.camp_id
    left join public.group_applications g on g.id=q.group_id
    where q.claim_type in ('camp','blocked','group') and q.start_date<=ends_on and q.end_date>=starts_on
      and (q.released_from is null or greatest(q.start_date,starts_on)<q.released_from)
      and (ignored_camp is null or q.camp_id is distinct from ignored_camp)
      and (ignored_block is null or q.blocked_period_id is distinct from ignored_block)
    union all
    select jsonb_build_object('type','application','id',a.id,'campId',a.camp_id,'name',a.user_name,
      'receptionNumber',n.display_number,'startDate',a.start_date,'endDate',a.end_date,'status',a.status)
    from public.applications a left join public.reception_numbers n on n.application_id=a.id
    left join public.calendar_claims iq on iq.application_id=a.id
    where a.start_date<=ends_on and a.end_date>=starts_on
      and a.status in ('submitted','under_review','revision_requested','approved','cancellation_requested')
      and (ignored_camp is null or a.camp_id is distinct from ignored_camp)
      and (iq.released_from is null or greatest(a.start_date,starts_on)<iq.released_from)
  )x;
  if conflicts is not null then raise exception using message='date-conflict',detail=conflicts::text; end if;
end; $$;

create or replace function public.get_public_calendar(target_month date)
returns table(date date,availability text) language plpgsql stable security definer set search_path='' as $$
declare last_day date:=private.calendar_month_end(target_month); today_jst date:=(clock_timestamp() at time zone 'Asia/Tokyo')::date;
begin
  return query select target_month+d.day_offset,case
    when target_month+d.day_offset>today_jst+60 then 'not_yet_open'
    when target_month+d.day_offset<today_jst+14 then 'unavailable'
    when exists(select 1 from public.calendar_claims q where q.claim_type in ('camp','blocked','group')
      and target_month+d.day_offset between q.start_date and q.end_date
      and (q.released_from is null or target_month+d.day_offset<q.released_from))
      or private.community_occupancy(target_month+d.day_offset)>=15 then 'unavailable' else 'available' end
  from generate_series(0,last_day-target_month)d(day_offset) order by d.day_offset;
end; $$;

create or replace function public.get_staff_calendar(target_month date)
returns table(entry_type text,entry_id uuid,start_date date,end_date date,title text,
  people_count bigint,internal_reason text,updated_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
declare last_day date;
begin
  if auth.uid() is null or not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
  last_day:=private.calendar_month_end(target_month);
  return query select 'camp'::text,c.id,c.start_date,c.end_date,c.name,
    (select count(*) from public.applications a left join public.room_allocations r on r.application_id=a.id
      where a.camp_id=c.id and (r.released_from is null or greatest(a.start_date,target_month)<r.released_from)
      and a.status in ('submitted','under_review','revision_requested','approved','cancellation_requested')),
    null::text,c.updated_at
  from public.camps c where c.deleted_at is null and c.start_date<=last_day and c.end_date>=target_month
  union all select 'blocked',b.id,b.start_date,b.end_date,'利用停止',0::bigint,b.internal_reason,b.updated_at
  from public.blocked_periods b where b.deleted_at is null and b.start_date<=last_day and b.end_date>=target_month
  union all select 'individual',a.id,a.start_date,least(a.end_date,q.released_from-1),a.user_name,1::bigint,null::text,a.updated_at
  from public.applications a join public.calendar_claims q on q.application_id=a.id
  where a.usage_type='community_individual' and a.status in
    ('submitted','under_review','revision_requested','approved','cancellation_requested')
    and a.start_date<=last_day and a.end_date>=target_month
    and (q.released_from is null or greatest(a.start_date,target_month)<q.released_from)
  union all select 'group',g.id,g.start_date,g.end_date,g.group_name,g.planned_participants::bigint,null::text,g.updated_at
  from public.group_applications g join public.calendar_claims q on q.group_id=g.id
  where g.status in ('collecting','under_review','revision_requested','approved','cancellation_requested')
    and g.start_date<=last_day and g.end_date>=target_month
    and (q.released_from is null or greatest(g.start_date,target_month)<q.released_from)
  order by 3,1,2;
end; $$;

create or replace function public.get_staff_calendar_day(target_date date)
returns table(entry_type text,entry_id uuid,camp_id uuid,reception_number text,display_name text,
  people_count bigint,status text,start_date date,end_date date,internal_reason text,updated_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
  if auth.uid() is null or not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
  perform private.check_calendar_period(target_date,target_date);
  return query select 'camp'::text,c.id,c.id,null::text,c.name,
    (select count(*) from public.applications a left join public.room_allocations r on r.application_id=a.id
      where a.camp_id=c.id and (r.released_from is null or target_date<r.released_from)
      and a.status in ('submitted','under_review','revision_requested','approved','cancellation_requested')),
    'scheduled'::text,c.start_date,c.end_date,null::text,c.updated_at
  from public.camps c where c.deleted_at is null and target_date between c.start_date and c.end_date
  union all select 'blocked',b.id,null::uuid,null::text,'利用停止',0::bigint,'blocked',b.start_date,b.end_date,b.internal_reason,b.updated_at
  from public.blocked_periods b where b.deleted_at is null and target_date between b.start_date and b.end_date
  union all select 'application',a.id,a.camp_id,n.display_number,a.user_name,1::bigint,a.status,
    a.start_date,least(a.end_date,coalesce(iq.released_from,r.released_from)-1),null::text,a.updated_at
  from public.applications a left join public.reception_numbers n on n.application_id=a.id
  left join public.calendar_claims iq on iq.application_id=a.id
  left join public.room_allocations r on r.application_id=a.id and a.usage_type='camp'
  where target_date between a.start_date and a.end_date and a.status in
    ('submitted','under_review','revision_requested','approved','cancellation_requested')
    and (coalesce(iq.released_from,r.released_from) is null or target_date<coalesce(iq.released_from,r.released_from))
  union all select 'group',g.id,null::uuid,n.display_number,g.group_name,g.planned_participants::bigint,g.status,
    g.start_date,g.end_date,null::text,g.updated_at
  from public.group_applications g left join public.reception_numbers n on n.group_id=g.id
  join public.calendar_claims q on q.group_id=g.id
  where target_date between g.start_date and g.end_date and g.status in
    ('collecting','under_review','revision_requested','approved','cancellation_requested')
    and (q.released_from is null or target_date<q.released_from)
  order by 1,2;
end; $$;

revoke all on function private.lock_group_user(),private.validate_group_fields(jsonb,boolean),private.apply_group_fields(uuid,jsonb),
  private.group_snapshot(uuid),private.group_audit(uuid,text,jsonb,uuid),private.check_group_availability(uuid,date,date),
  private.sync_group_claim(),private.check_community_availability(uuid,uuid,date,date),
  private.assert_calendar_available(date,date,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.create_community_group_draft(uuid,jsonb),public.save_community_group_draft(uuid,timestamptz,jsonb),
  public.start_community_group_application(uuid,timestamptz,uuid,boolean),public.get_community_group(uuid)
from public,anon,authenticated,service_role;
grant execute on function public.create_community_group_draft(uuid,jsonb),public.save_community_group_draft(uuid,timestamptz,jsonb),
  public.start_community_group_application(uuid,timestamptz,uuid,boolean),public.get_community_group(uuid) to authenticated;
commit;
