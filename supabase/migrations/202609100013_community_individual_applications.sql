-- T10 only: community individuals, minimal review, no approval/cancellation APIs.
-- Apply once after 012. Source records, reservations and history commit together.
begin;
select private.lock_calendar_facility();

alter table public.applications drop constraint applications_usage_type_check;
alter table public.applications alter column camp_id drop not null;
alter table public.applications add constraint applications_usage_type_check
  check (usage_type in ('camp', 'community_individual'));
alter table public.applications add constraint applications_usage_camp_check
  check ((usage_type = 'camp' and camp_id is not null)
    or (usage_type = 'community_individual' and camp_id is null and room_preference is null));
alter table public.applications
  add column revision_start_date date,
  add column revision_end_date date,
  add column last_submission_key uuid,
  add column last_submission_version timestamptz;
alter table public.applications add constraint community_dates_check check (
  usage_type <> 'community_individual' or (start_date is null and end_date is null)
  or (start_date is not null and end_date is not null and start_date between date '0001-01-01' and date '9999-12-31'
    and end_date between date '0001-01-01' and date '9999-12-31'
    and end_date - start_date between 1 and 14));
alter table public.applications add constraint community_revision_dates_check check (
  (revision_start_date is null and revision_end_date is null)
  or (usage_type = 'community_individual' and revision_start_date is not null and revision_end_date is not null
    and revision_start_date between date '0001-01-01' and date '9999-12-31'
    and revision_end_date between date '0001-01-01' and date '9999-12-31'
    and revision_end_date - revision_start_date between 1 and 14));
create index applications_community_dates_idx on public.applications(start_date, end_date)
where usage_type = 'community_individual';

alter table public.calendar_claims drop constraint calendar_claims_claim_type_check;
-- The unnamed source combination CHECK in 012 is calendar_claims_check2.
alter table public.calendar_claims drop constraint calendar_claims_check2;
alter table public.calendar_claims add column application_id uuid unique
  references public.applications(id) on delete restrict;
alter table public.calendar_claims add constraint calendar_claims_claim_type_check
  check (claim_type in ('camp', 'blocked', 'individual'));
alter table public.calendar_claims add constraint calendar_claims_source_check check (
  (claim_type = 'camp' and camp_id is not null and blocked_period_id is null and application_id is null)
  or (claim_type = 'blocked' and blocked_period_id is not null and camp_id is null and application_id is null)
  or (claim_type = 'individual' and application_id is not null and camp_id is null and blocked_period_id is null));

create function private.sync_individual_claim()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.usage_type <> 'community_individual' then return new; end if;
  if new.status in ('submitted','under_review','revision_requested','approved','cancellation_requested') then
    insert into public.calendar_claims(claim_type,application_id,start_date,end_date)
    values ('individual',new.id,new.start_date,new.end_date)
    on conflict(application_id) do update set start_date=excluded.start_date, end_date=excluded.end_date,
      released_from=case when (calendar_claims.start_date,calendar_claims.end_date)
        is distinct from (excluded.start_date,excluded.end_date) then null else calendar_claims.released_from end;
  elsif new.status in ('rejected','cancelled') then
    update public.calendar_claims set released_from=start_date where application_id=new.id;
  end if;
  return new;
end; $$;
create trigger applications_sync_individual_claim after insert or update of status,start_date,end_date
on public.applications for each row execute function private.sync_individual_claim();

create function private.check_community_period(starts_on date, ends_on date, operation_time timestamptz, check_window boolean)
returns void language plpgsql immutable set search_path = '' as $$
declare today_jst date := (operation_time at time zone 'Asia/Tokyo')::date;
begin
  perform private.check_calendar_period(starts_on,ends_on);
  if ends_on-starts_on not between 1 and 14 then raise exception 'invalid-duration'; end if;
  if check_window then
    if operation_time is null or not isfinite(operation_time) then raise exception 'invalid-period'; end if;
    if starts_on < today_jst+14 then raise exception 'start-too-soon'; end if;
    if ends_on > today_jst+60 then raise exception 'end-too-late'; end if;
  end if;
end; $$;

create function private.check_community_revision(due_at timestamptz, operation_time timestamptz)
returns void language plpgsql immutable set search_path = '' as $$
begin
  -- Individual deadlines are optional. No group deadline/default/cancellation rule.
  if due_at is not null and (not isfinite(due_at) or operation_time >= due_at) then
    raise exception 'revision-expired';
  end if;
end; $$;

create function private.lock_community_user()
returns uuid language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid();
begin
  if actor is null or not private.has_active_profile() then
    raise exception using errcode='42501',message='active-user-required'; end if;
  perform private.lock_calendar_facility();
  perform p.id from public.profiles p where p.id=actor and p.account_state='active' for share;
  if not found then raise exception using errcode='42501',message='active-user-required'; end if;
  return actor;
end; $$;

create function private.community_snapshot(target_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('application',(select to_jsonb(a) from public.applications a where id=target_id),
    'claim',(select to_jsonb(q) from public.calendar_claims q where application_id=target_id),
    'room',(select to_jsonb(r) from public.room_allocations r where application_id=target_id),
    'charge',(select to_jsonb(c) from public.application_charges c where application_id=target_id),
    'months',(select jsonb_agg(to_jsonb(m) order by m.month) from public.charge_months m
      join public.application_charges c on c.id=m.charge_id where c.application_id=target_id),
    'consent',(select to_jsonb(d) from public.consent_documents d where application_id=target_id));
$$;
create function private.community_audit(target_id uuid, operation text, before_value jsonb, actor uuid, kind text, reason_value text default null)
returns void language sql security definer set search_path = '' as $$
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id,reason)
  values('application',target_id,operation,before_value,private.community_snapshot(target_id),kind,actor,reason_value);
$$;

create function private.validate_community_fields(fields jsonb, complete boolean)
returns void language plpgsql set search_path = '' as $$
declare k text; v jsonb; limits jsonb := '{"user_name":100,"user_address":500,"user_phone":20,"emergency_name":100,"emergency_address":500,"emergency_phone":20,"purpose":2000,"local_activity":2000,"special_notes":2000}';
begin
  if fields is null or jsonb_typeof(fields)<>'object' then raise exception 'invalid-fields'; end if;
  for k,v in select * from jsonb_each(fields) loop
    if not (limits ? k or k in ('start_date','end_date','usage_place','requires_guardian_consent')) then
      raise exception 'invalid-fields'; end if;
    if v <> 'null'::jsonb and jsonb_typeof(v) <> (case when k='requires_guardian_consent' then 'boolean' else 'string' end) then
      raise exception 'invalid-fields'; end if;
    if limits ? k and char_length(btrim(fields->>k)) > (limits->>k)::integer then raise exception 'field-too-long'; end if;
  end loop;
  foreach k in array array['user_phone','emergency_phone'] loop
    if nullif(btrim(fields->>k),'') is not null and btrim(fields->>k) !~ '^[0-9+][0-9() -]{7,19}$' then raise exception 'invalid-phone'; end if;
  end loop;
  if fields->>'usage_place' is not null and fields->>'usage_place'<>'common_and_second_floor' then raise exception 'invalid-place'; end if;
  if nullif(fields->>'start_date','') is not null or nullif(fields->>'end_date','') is not null then
    if coalesce(fields->>'start_date','') !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(fields->>'end_date','') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'invalid-period'; end if;
    begin
      perform private.check_community_period((fields->>'start_date')::date,(fields->>'end_date')::date,null,false);
    exception when datetime_field_overflow or invalid_datetime_format then raise exception 'invalid-period'; end;
  end if;
  if complete then
    foreach k in array array['user_name','user_address','user_phone','emergency_name','emergency_address','emergency_phone','purpose','local_activity','usage_place','start_date','end_date'] loop
      if nullif(btrim(fields->>k),'') is null then raise exception 'required-fields'; end if;
    end loop;
    if fields->>'requires_guardian_consent' is null then raise exception 'required-fields'; end if;
  end if;
end; $$;

create function private.apply_community_fields(target_id uuid, fields jsonb)
returns void language sql security definer set search_path = '' as $$
  update public.applications set
    user_name=nullif(btrim(fields->>'user_name'),''),user_address=nullif(btrim(fields->>'user_address'),''),
    user_phone=nullif(btrim(fields->>'user_phone'),''),emergency_name=nullif(btrim(fields->>'emergency_name'),''),
    emergency_address=nullif(btrim(fields->>'emergency_address'),''),emergency_phone=nullif(btrim(fields->>'emergency_phone'),''),
    purpose=nullif(btrim(fields->>'purpose'),''),local_activity=nullif(btrim(fields->>'local_activity'),''),
    special_notes=nullif(btrim(fields->>'special_notes'),''),usage_place=fields->>'usage_place',
    requires_guardian_consent=(fields->>'requires_guardian_consent')::boolean,
    start_date=case when status='draft' then nullif(fields->>'start_date','')::date else start_date end,
    end_date=case when status='draft' then nullif(fields->>'end_date','')::date else end_date end,
    revision_start_date=case when status='revision_requested' then nullif(fields->>'start_date','')::date end,
    revision_end_date=case when status='revision_requested' then nullif(fields->>'end_date','')::date end
  where id=target_id;
$$;

create function public.create_community_application_draft(target_application_id uuid, draft_fields jsonb default '{}'::jsonb)
returns table(result_id uuid,result_updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.lock_community_user(); a public.applications%rowtype; f jsonb;
begin
  if target_application_id is null then raise exception 'invalid-application'; end if;
  select * into a from public.applications where id=target_application_id for update;
  if found then
    if a.user_id is distinct from actor or a.usage_type<>'community_individual' then raise exception 'not-found'; end if;
    return query select a.id,a.updated_at; return;
  end if;
  select jsonb_build_object('user_name',p.full_name,'user_address',p.address,'user_phone',p.phone,
    'emergency_name',p.emergency_name,'emergency_address',p.emergency_address,'emergency_phone',p.emergency_phone,
    'usage_place','common_and_second_floor') into f from public.profiles p where p.id=actor;
  f:=f || draft_fields;
  perform private.validate_community_fields(f,false);
  insert into public.applications(id,user_id,usage_type,camp_id)
  values(target_application_id,actor,'community_individual',null);
  perform private.apply_community_fields(target_application_id,f);
  insert into public.application_status_events(application_id,to_status,actor_user_id,occurred_at)
  values(target_application_id,'draft',actor,clock_timestamp());
  perform private.community_audit(target_application_id,'create_community_draft','{}',actor,'user');
  return query select id,updated_at from public.applications where id=target_application_id;
end; $$;

create function public.save_community_application_draft(target_application_id uuid, expected_updated_at timestamptz, draft_fields jsonb)
returns table(result_id uuid,result_updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.lock_community_user(); a public.applications%rowtype; before_value jsonb;
begin
  select * into a from public.applications where id=target_application_id for update;
  if not found or a.user_id is distinct from actor or a.usage_type<>'community_individual' then raise exception 'not-found'; end if;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if a.status not in ('draft','revision_requested') then raise exception 'not-editable'; end if;
  if a.status='revision_requested' then
    perform private.check_community_revision(a.revision_due_at,clock_timestamp());
    if nullif(draft_fields->>'start_date','') is null or nullif(draft_fields->>'end_date','') is null then raise exception 'required-fields'; end if;
  end if;
  perform private.validate_community_fields(draft_fields,false);
  before_value:=private.community_snapshot(a.id);
  perform private.apply_community_fields(a.id,draft_fields);
  perform private.community_audit(a.id,'save_community_draft',before_value,actor,'user');
  return query select id,updated_at from public.applications where id=a.id;
end; $$;

-- Missing derived claims are never treated as free capacity. RPCs additionally
-- reject inconsistent source/claim pairs; normal writes synchronize via trigger.
create function private.community_occupancy(target_date date, ignored_application uuid default null)
returns bigint language sql stable security definer set search_path = '' as $$
  select count(*) from public.applications a left join public.calendar_claims q on q.application_id=a.id
  where a.usage_type='community_individual' and a.id is distinct from ignored_application
    and a.status in ('submitted','under_review','revision_requested','approved','cancellation_requested')
    and target_date between a.start_date and a.end_date
    and (q.released_from is null or target_date<q.released_from);
$$;

create function private.check_community_availability(target_id uuid, actor uuid, starts_on date, ends_on date)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if exists(select 1 from public.calendar_claims q where q.claim_type in ('camp','blocked')
    and q.start_date<=ends_on and q.end_date>=starts_on
    and (q.released_from is null or greatest(q.start_date,starts_on)<q.released_from))
    or exists(select 1 from public.camps c where c.deleted_at is null and c.start_date<=ends_on and c.end_date>=starts_on)
    or exists(select 1 from public.blocked_periods b where b.deleted_at is null and b.start_date<=ends_on and b.end_date>=starts_on) then
    raise exception 'calendar-unavailable';
  end if;
  if exists(select 1 from public.applications a left join public.calendar_claims q on q.application_id=a.id
    where a.usage_type='community_individual' and a.status in ('submitted','under_review','revision_requested','approved','cancellation_requested')
      and a.start_date<=ends_on and a.end_date>=starts_on
      and (q.id is null or q.start_date is distinct from a.start_date or q.end_date is distinct from a.end_date)) then
    raise exception 'calendar-inconsistent'; end if;
  if exists(select 1 from public.applications a left join public.calendar_claims q on q.application_id=a.id
    where a.user_id=actor and a.id<>target_id and a.start_date<=ends_on and a.end_date>=starts_on
      and a.status in ('submitted','under_review','revision_requested','approved','cancellation_requested')
      and (q.released_from is null or greatest(a.start_date,starts_on)<q.released_from)) then raise exception 'duplicate-stay'; end if;
  if exists(select 1 from generate_series(0,ends_on-starts_on) d(n)
    where private.community_occupancy(starts_on+d.n,target_id)>=15) then raise exception 'capacity-full'; end if;
end; $$;

create function private.community_charge_months(starts_on date, ends_on date)
returns table(month date,usage_days integer,daily_rate integer,monthly_cap integer,amount integer)
language sql immutable set search_path = '' as $$
  select m::date,(least(ends_on,(m+interval '1 month')::date-1)-greatest(starts_on,m::date)+1)::integer,
    300,9000,least((least(ends_on,(m+interval '1 month')::date-1)-greatest(starts_on,m::date)+1)*300,9000)::integer
  from generate_series(date_trunc('month',starts_on::timestamp),date_trunc('month',ends_on::timestamp),interval '1 month') m;
$$;

create function public.submit_community_application(target_application_id uuid, expected_updated_at timestamptz, submission_key uuid, confirmed boolean)
returns table(result_id uuid,result_status text,result_updated_at timestamptz,reception_number text,submission_time timestamptz)
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.lock_community_user(); a public.applications%rowtype; before_value jsonb;
  starts_on date; ends_on date; moment timestamptz; number_value text; year_value integer; serial_value integer; charge_value uuid; f jsonb;
begin
  select * into a from public.applications where id=target_application_id for update;
  if not found or a.user_id is distinct from actor or a.usage_type<>'community_individual' then raise exception 'not-found'; end if;
  if confirmed is distinct from true then raise exception 'confirmation-required'; end if;
  if submission_key is null then raise exception 'invalid-submission-key'; end if;
  if expected_updated_at is null or not isfinite(expected_updated_at) then raise exception 'invalid-version'; end if;
  if a.last_submission_key=submission_key and a.last_submission_version=expected_updated_at then
    return query select a.id,a.status,a.updated_at,n.display_number,a.last_submitted_at
    from public.reception_numbers n where n.application_id=a.id; return;
  end if;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if a.status not in ('draft','revision_requested') then raise exception 'not-submittable'; end if;
  starts_on:=coalesce(a.revision_start_date,a.start_date); ends_on:=coalesce(a.revision_end_date,a.end_date);
  moment:=clock_timestamp();
  if a.status='revision_requested' then perform private.check_community_revision(a.revision_due_at,moment); end if;
  perform private.check_community_period(starts_on,ends_on,moment,a.status='draft' or (starts_on,ends_on) is distinct from (a.start_date,a.end_date));
  f:=jsonb_build_object('user_name',a.user_name,'user_address',a.user_address,'user_phone',a.user_phone,
    'emergency_name',a.emergency_name,'emergency_address',a.emergency_address,'emergency_phone',a.emergency_phone,
    'purpose',a.purpose,'local_activity',a.local_activity,'special_notes',a.special_notes,'usage_place',a.usage_place,
    'requires_guardian_consent',a.requires_guardian_consent,'start_date',starts_on,'end_date',ends_on);
  perform private.validate_community_fields(f,true);
  if coalesce(auth.jwt()->>'email','') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'invalid-email'; end if;
  if a.requires_guardian_consent and not exists(select 1 from public.consent_documents where application_id=a.id) then raise exception 'guardian-consent'; end if;
  perform private.check_community_availability(a.id,actor,starts_on,ends_on);
  before_value:=private.community_snapshot(a.id);
  -- T12 is not implemented. Never silently move a previously assigned room.
  if (starts_on,ends_on) is distinct from (a.start_date,a.end_date) then
    update public.room_allocations set released_from=start_date where application_id=a.id;
  end if;
  if a.status='revision_requested' and (not exists(select 1 from public.application_charges where application_id=a.id)
    or not exists(select 1 from public.reception_numbers where application_id=a.id)) then raise exception 'calendar-inconsistent'; end if;
  if a.status='draft' or (starts_on,ends_on) is distinct from (a.start_date,a.end_date) then
    insert into public.application_charges(application_id,total_amount,calculated_at)
    values(a.id,0,moment) on conflict(application_id) do update set calculated_at=excluded.calculated_at
    returning id into charge_value;
    delete from public.charge_months where charge_id=charge_value;
    insert into public.charge_months(charge_id,month,usage_days,daily_rate,monthly_cap,amount)
    select charge_value,m.* from private.community_charge_months(starts_on,ends_on) m;
    update public.application_charges set total_amount=(select sum(amount) from public.charge_months where charge_id=charge_value)
    where id=charge_value;
  end if;
  update public.applications set status='submitted',start_date=starts_on,end_date=ends_on,
    revision_start_date=null,revision_end_date=null,revision_due_at=null,decision_reason=null,
    email_snapshot=lower(auth.jwt()->>'email'),submitted_at=coalesce(submitted_at,moment),last_submitted_at=moment,
    last_submission_key=submission_key,last_submission_version=expected_updated_at where id=a.id;
  select display_number into number_value from public.reception_numbers where application_id=a.id;
  if number_value is null then
    year_value:=extract(year from (moment at time zone 'Asia/Tokyo')-interval '3 months')::integer;
    insert into public.reception_counters(fiscal_year,last_number) values(year_value,0) on conflict do nothing;
    update public.reception_counters set last_number=last_number+1,updated_at=moment where fiscal_year=year_value returning last_number into serial_value;
    number_value:=format('SG-%s-%s',year_value,lpad(serial_value::text,greatest(4,length(serial_value::text)),'0'));
    insert into public.reception_numbers(fiscal_year,serial_number,display_number,application_id) values(year_value,serial_value,number_value,a.id);
  end if;
  insert into public.application_status_events(application_id,from_status,to_status,actor_user_id,occurred_at)
  values(a.id,a.status,'submitted',actor,moment);
  perform private.community_audit(a.id,'submit_community_application',before_value,actor,'user');
  return query select x.id,x.status,x.updated_at,number_value,x.last_submitted_at from public.applications x where x.id=a.id;
end; $$;

create function public.review_community_application(target_application_id uuid, review_action text, expected_updated_at timestamptz,
  public_reason text default null, revision_deadline timestamptz default null)
returns table(result_id uuid,result_status text,result_updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare a public.applications%rowtype; next_status text; before_value jsonb; moment timestamptz; reason_value text:=nullif(btrim(public_reason),'');
begin
  perform private.lock_calendar_for_staff();
  select * into a from public.applications where id=target_application_id and usage_type='community_individual' for update;
  if not found then raise exception 'not-found'; end if;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if review_action is null or review_action not in ('start_review','request_revision','reject') then raise exception 'invalid-action'; end if;
  if (review_action='start_review' and a.status<>'submitted') or (review_action<>'start_review' and a.status<>'under_review') then raise exception 'invalid-status'; end if;
  if review_action<>'start_review' then perform private.check_calendar_reason(reason_value); else reason_value:=null; end if;
  moment:=clock_timestamp();
  if review_action='request_revision' and revision_deadline is not null and (not isfinite(revision_deadline)
    or revision_deadline<=moment or revision_deadline>(a.start_date::timestamp at time zone 'Asia/Tokyo')) then raise exception 'invalid-deadline'; end if;
  next_status:=case review_action when 'start_review' then 'under_review' when 'request_revision' then 'revision_requested' else 'rejected' end;
  before_value:=private.community_snapshot(a.id);
  update public.applications set status=next_status,decision_reason=reason_value,
    revision_due_at=case when review_action='request_revision' then revision_deadline end,
    revision_start_date=null,revision_end_date=null where id=a.id;
  if next_status='rejected' then update public.room_allocations set released_from=start_date where application_id=a.id; end if;
  insert into public.application_status_events(application_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
  values(a.id,a.status,next_status,reason_value,auth.uid(),moment);
  perform private.community_audit(a.id,review_action,before_value,auth.uid(),'staff',reason_value);
  return query select id,status,updated_at from public.applications where id=a.id;
end; $$;

create function public.register_community_guardian_consent_document(target_application_id uuid, expected_user_id uuid,
  expected_updated_at timestamptz,target_object_path text,target_mime_type text,target_size_bytes integer)
returns table(previous_object_path text,delete_previous boolean,result_updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare a public.applications%rowtype; before_value jsonb; previous_path text;
begin
  perform private.lock_calendar_facility();
  perform id from public.profiles where id=expected_user_id and account_state='active' for share;
  if not found then raise exception using errcode='42501',message='active-user-required'; end if;
  select * into a from public.applications where id=target_application_id and usage_type='community_individual' for update;
  if not found or a.user_id is distinct from expected_user_id then raise exception 'not-found'; end if;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if a.status not in ('draft','revision_requested') then raise exception 'not-editable'; end if;
  if a.status='revision_requested' then perform private.check_community_revision(a.revision_due_at,clock_timestamp()); end if;
  if target_object_path is null or target_object_path !~ ('^applications/'||a.id::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') then raise exception 'invalid-path'; end if;
  if target_mime_type is null or target_mime_type not in ('application/pdf','image/jpeg','image/png') then raise exception 'invalid-type'; end if;
  if target_size_bytes is null or target_size_bytes not between 1 and 5242880 then raise exception 'invalid-size'; end if;
  select object_path into previous_path from public.consent_documents where application_id=a.id for update;
  if previous_path=target_object_path then raise exception 'invalid-path'; end if;
  before_value:=private.community_snapshot(a.id);
  insert into public.consent_documents(application_id,object_path,mime_type,size_bytes)
  values(a.id,target_object_path,target_mime_type,target_size_bytes)
  on conflict(application_id) do update set object_path=excluded.object_path,mime_type=excluded.mime_type,size_bytes=excluded.size_bytes;
  update public.applications set updated_at=clock_timestamp() where id=a.id;
  perform private.community_audit(a.id,'replace_community_consent',before_value,expected_user_id,'user');
  return query select previous_path,a.submitted_at is null,x.updated_at from public.applications x where x.id=a.id;
end; $$;

-- Keep the camp save signature; disallow use as an unversioned community save.
create or replace function public.save_camp_application_draft(
  target_application_id uuid,
  applicant_name text,
  applicant_address text,
  applicant_phone text,
  emergency_contact_name text,
  emergency_contact_address text,
  emergency_contact_phone text,
  usage_purpose text,
  notes text,
  guardian_consent_required boolean,
  requested_room_preference text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  current_email text := lower(auth.jwt() ->> 'email');
  application_record public.applications%rowtype;
begin
  if current_user_id is null or not private.has_active_profile() then
    raise exception 'ログインが必要です。';
  end if;

  select application.*
  into application_record
  from public.applications as application
  where application.id = target_application_id and application.usage_type = 'camp'
  for update;

  if not found or application_record.user_id is distinct from current_user_id then
    raise exception '申請が見つかりません。';
  end if;

  if application_record.status not in ('draft', 'revision_requested') then
    raise exception '現在の状態では申請を編集できません。';
  end if;

  if application_record.status = 'revision_requested'
    and application_record.revision_due_at is not null
    and now() >= application_record.revision_due_at then
    raise exception '修正期限を過ぎています。';
  end if;

  if requested_room_preference is not null
    and requested_room_preference not in ('shared_ok', 'private_requested') then
    raise exception '相部屋希望の値が正しくありません。';
  end if;

  update public.applications
  set
    user_name = nullif(btrim(applicant_name), ''),
    user_address = nullif(btrim(applicant_address), ''),
    user_phone = nullif(btrim(applicant_phone), ''),
    email_snapshot = current_email,
    emergency_name = nullif(btrim(emergency_contact_name), ''),
    emergency_address = nullif(btrim(emergency_contact_address), ''),
    emergency_phone = nullif(btrim(emergency_contact_phone), ''),
    usage_place = 'common_and_second_floor',
    purpose = nullif(btrim(usage_purpose), ''),
    special_notes = nullif(btrim(notes), ''),
    requires_guardian_consent = guardian_consent_required,
    room_preference = requested_room_preference
  where id = target_application_id;

  return target_application_id;
end;
$$;


-- The legacy service-only attachment entry remains camp-only.
create or replace function public.register_guardian_consent_document(
  target_application_id uuid,
  expected_user_id uuid,
  target_object_path text,
  target_mime_type text,
  target_size_bytes integer
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_record public.applications%rowtype;
  previous_object_path text;
  expected_path_pattern text;
begin
  if expected_user_id is null or not exists (
    select 1
    from public.profiles as profile
    where profile.id = expected_user_id
      and profile.account_state = 'active'
  ) then
    raise exception '有効な利用者が見つかりません。';
  end if;

  select application.*
  into application_record
  from public.applications as application
  where application.id = target_application_id and application.usage_type = 'camp'
  for update;

  if not found or application_record.user_id is distinct from expected_user_id then
    raise exception '申請が見つかりません。';
  end if;

  if application_record.status not in ('draft', 'revision_requested') then
    raise exception '現在の状態では同意書を変更できません。';
  end if;

  if application_record.status = 'revision_requested'
    and application_record.revision_due_at is not null
    and now() >= application_record.revision_due_at then
    raise exception '修正期限を過ぎています。';
  end if;

  expected_path_pattern := format(
    '^applications/%s/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    target_application_id
  );

  if target_object_path is null
    or target_object_path !~ expected_path_pattern then
    raise exception '同意書の保存先が正しくありません。';
  end if;

  if target_mime_type not in ('application/pdf', 'image/jpeg', 'image/png') then
    raise exception 'PDF、JPEG、PNG形式のファイルを選択してください。';
  end if;

  if target_size_bytes is null
    or target_size_bytes not between 1 and 5242880 then
    raise exception 'ファイルサイズは5MiB以下にしてください。';
  end if;

  select document.object_path
  into previous_object_path
  from public.consent_documents as document
  where document.application_id = target_application_id
  for update;

  insert into public.consent_documents (
    application_id,
    object_path,
    mime_type,
    size_bytes
  )
  values (
    target_application_id,
    target_object_path,
    target_mime_type,
    target_size_bytes
  )
  on conflict (application_id) do update
  set
    object_path = excluded.object_path,
    mime_type = excluded.mime_type,
    size_bytes = excluded.size_bytes;

  return previous_object_path;
end;
$$;

revoke all on function public.register_guardian_consent_document(
  uuid,
  uuid,
  text,
  text,
  integer
) from public, anon, authenticated;

grant execute on function public.register_guardian_consent_document(
  uuid,
  uuid,
  text,
  text,
  integer
) to service_role;

-- Exclusion must include NULL camp_id; individual diagnostics use application type.
create or replace function private.assert_calendar_available(
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
    where q.claim_type in ('camp','blocked') and q.start_date <= ends_on and q.end_date >= starts_on
      and (q.released_from is null or greatest(q.start_date, starts_on) < q.released_from)
      and (ignored_camp is null or q.camp_id is distinct from ignored_camp)
      and (ignored_block is null or q.blocked_period_id is distinct from ignored_block)
    union all
    select jsonb_build_object('type', 'application', 'id', a.id, 'campId', a.camp_id,
      'name', a.user_name, 'receptionNumber', n.display_number,
      'startDate', a.start_date, 'endDate', a.end_date, 'status', a.status)
    from public.applications a left join public.reception_numbers n on n.application_id = a.id
    left join public.calendar_claims iq on iq.application_id=a.id
    where a.start_date <= ends_on and a.end_date >= starts_on
      and a.status in ('submitted', 'under_review', 'revision_requested', 'approved', 'cancellation_requested')
      and (ignored_camp is null or a.camp_id is distinct from ignored_camp)
      and (iq.released_from is null or greatest(a.start_date, starts_on)<iq.released_from)
  ) x;
  if conflicts is not null then
    raise exception using message = 'date-conflict', detail = conflicts::text;
  end if;
end;
$$;


-- Preserve the two-column public contract and existing staff column contracts.
create or replace function public.get_public_calendar(target_month date)
returns table (date date, availability text)
language plpgsql stable security definer set search_path = '' as $$
declare last_day date := private.calendar_month_end(target_month);
  today_jst date := (clock_timestamp() at time zone 'Asia/Tokyo')::date;
begin
  return query select target_month + d.day_offset,
    case when target_month + d.day_offset > today_jst + 60 then 'not_yet_open'
      when target_month + d.day_offset < today_jst + 14 then 'unavailable'
      when exists (select 1 from public.calendar_claims q
        where q.claim_type in ('camp','blocked') and q.start_date <= target_month + d.day_offset and q.end_date >= target_month + d.day_offset
          and (q.released_from is null or target_month + d.day_offset < q.released_from)) or private.community_occupancy(target_month + d.day_offset)>=15 then 'unavailable'
      else 'available' end
  from generate_series(0, last_day - target_month) d(day_offset) order by d.day_offset;
end;
$$;

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
    (select count(*) from public.applications a where a.camp_id = c.id
      and a.status in ('submitted', 'under_review', 'revision_requested', 'approved', 'cancellation_requested')),
    null::text, c.updated_at
  from public.camps c where c.deleted_at is null and c.start_date <= last_day and c.end_date >= target_month
  union all
  select 'blocked'::text, b.id, b.start_date, b.end_date, '利用停止'::text, 0::bigint, b.internal_reason, b.updated_at
  from public.blocked_periods b where b.deleted_at is null and b.start_date <= last_day and b.end_date >= target_month
  union all
  select 'individual'::text,a.id,a.start_date,a.end_date,a.user_name,1::bigint,null::text,a.updated_at
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
  left join public.calendar_claims iq on iq.application_id=a.id
  where target_date between a.start_date and a.end_date
    and a.status in ('submitted', 'under_review', 'revision_requested', 'approved', 'cancellation_requested')
    and (iq.released_from is null or target_date<iq.released_from)
  order by 1, 2;
end;
$$;


-- Single read-only snapshot for edit/confirm/complete. Ownership is required
-- even for staff callers; approval/cancellation operations are not exposed.
create function public.get_community_application(target_application_id uuid)
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
    'submitted_at',a.submitted_at,'last_submitted_at',a.last_submitted_at,'revision_due_at',a.revision_due_at,'decision_reason',a.decision_reason,
    'reception_number',(select display_number from public.reception_numbers where application_id=a.id),
    'has_consent',exists(select 1 from public.consent_documents where application_id=a.id),
    'can_edit',a.status in ('draft','revision_requested') and (a.revision_due_at is null or moment<a.revision_due_at),
    'validation_error',validation_error,'charge',charge,
    'estimated_months',(select jsonb_agg(to_jsonb(m) order by m.month) from private.community_charge_months(starts_on,ends_on) m),
    'events',(select coalesce(jsonb_agg(jsonb_build_object('from_status',e.from_status,'to_status',e.to_status,'public_reason',e.public_reason,'occurred_at',e.occurred_at) order by e.occurred_at,e.id),'[]'::jsonb)
      from public.application_status_events e where e.application_id=a.id));
end; $$;

-- Explicit execution grants. No new direct writes, group tables or cron jobs.
revoke all on function private.sync_individual_claim(), private.check_community_period(date,date,timestamptz,boolean),
  private.check_community_revision(timestamptz,timestamptz),private.lock_community_user(),private.community_snapshot(uuid),
  private.community_audit(uuid,text,jsonb,uuid,text,text),private.validate_community_fields(jsonb,boolean),
  private.apply_community_fields(uuid,jsonb),private.community_occupancy(date,uuid),
  private.check_community_availability(uuid,uuid,date,date),private.community_charge_months(date,date)
from public,anon,authenticated,service_role;
revoke all on function public.create_community_application_draft(uuid,jsonb),public.save_community_application_draft(uuid,timestamptz,jsonb),
  public.submit_community_application(uuid,timestamptz,uuid,boolean),public.review_community_application(uuid,text,timestamptz,text,timestamptz),
  public.get_community_application(uuid),public.register_community_guardian_consent_document(uuid,uuid,timestamptz,text,text,integer)
from public,anon,authenticated,service_role;
grant execute on function public.create_community_application_draft(uuid,jsonb),public.save_community_application_draft(uuid,timestamptz,jsonb),
  public.submit_community_application(uuid,timestamptz,uuid,boolean),public.review_community_application(uuid,text,timestamptz,text,timestamptz),
  public.get_community_application(uuid) to authenticated;
grant execute on function public.register_community_guardian_consent_document(uuid,uuid,timestamptz,text,text,integer) to service_role;
commit;
