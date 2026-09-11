-- T19 second half: participant-owned personal forms and atomic group review transition.
begin;
select private.lock_calendar_facility();

create function private.validate_group_participant_fields(fields jsonb, complete boolean)
returns void language plpgsql set search_path='' as $$
declare k text; v jsonb; limits jsonb:='{"user_name":100,"user_address":500,"user_phone":20,"emergency_name":100,"emergency_address":500,"emergency_phone":20,"special_notes":2000}';
begin
  if fields is null or jsonb_typeof(fields)<>'object' then raise exception 'invalid-fields'; end if;
  for k,v in select * from jsonb_each(fields) loop
    if not (limits ? k or k='requires_guardian_consent') then raise exception 'invalid-fields'; end if;
    if v<>'null'::jsonb and jsonb_typeof(v)<>(case when k='requires_guardian_consent' then 'boolean' else 'string' end) then
      raise exception 'invalid-fields'; end if;
    if limits ? k and char_length(btrim(fields->>k))>(limits->>k)::integer then raise exception 'field-too-long'; end if;
  end loop;
  foreach k in array array['user_phone','emergency_phone'] loop
    if nullif(btrim(fields->>k),'') is not null and btrim(fields->>k)!~'^[0-9+][0-9() -]{7,19}$' then raise exception 'invalid-phone'; end if;
  end loop;
  if complete then
    foreach k in array array['user_name','user_address','user_phone','emergency_name','emergency_address','emergency_phone'] loop
      if nullif(btrim(fields->>k),'') is null then raise exception 'required-fields'; end if;
    end loop;
    if fields->>'requires_guardian_consent' is null then raise exception 'required-fields'; end if;
  end if;
end; $$;

create function private.apply_group_participant_fields(target_id uuid, fields jsonb)
returns void language sql security definer set search_path='' as $$
  update public.applications set
    user_name=nullif(btrim(fields->>'user_name'),''),user_address=nullif(btrim(fields->>'user_address'),''),
    user_phone=nullif(btrim(fields->>'user_phone'),''),emergency_name=nullif(btrim(fields->>'emergency_name'),''),
    emergency_address=nullif(btrim(fields->>'emergency_address'),''),emergency_phone=nullif(btrim(fields->>'emergency_phone'),''),
    special_notes=nullif(btrim(fields->>'special_notes'),''),requires_guardian_consent=(fields->>'requires_guardian_consent')::boolean
  where id=target_id;
$$;

create function public.save_group_participant_application(target_application_id uuid,expected_updated_at timestamptz,draft_fields jsonb)
returns table(result_id uuid,result_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare actor uuid:=private.lock_group_user(); a public.applications%rowtype; g public.group_applications%rowtype; before_value jsonb;
begin
  select * into a from public.applications where id=target_application_id for update;
  if not found or a.user_id is distinct from actor or a.usage_type<>'community_group'
    or not exists(select 1 from public.group_members m where m.application_id=a.id and m.group_id=a.group_id and m.state='active')
    then raise exception 'not-found'; end if;
  select * into g from public.group_applications where id=a.group_id for update;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if a.status<>'draft' or g.status<>'collecting' then raise exception 'not-editable'; end if;
  if g.participant_due_at is null or clock_timestamp()>=g.participant_due_at then raise exception 'participant-deadline-passed'; end if;
  perform private.validate_group_participant_fields(draft_fields,false);
  before_value:=private.community_snapshot(a.id);
  perform private.apply_group_participant_fields(a.id,draft_fields);
  perform private.community_audit(a.id,'save_group_participant_application',before_value,actor,'user');
  return query select x.id,x.updated_at from public.applications x where x.id=a.id;
end; $$;

create function public.submit_group_participant_application(target_application_id uuid,expected_updated_at timestamptz,
  submission_key uuid,confirmed boolean)
returns table(result_id uuid,result_status text,result_updated_at timestamptz,reception_number text,submission_time timestamptz,
  result_group_id uuid,result_group_status text,result_group_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare actor uuid:=private.lock_group_user(); a public.applications%rowtype; g public.group_applications%rowtype;
  before_value jsonb; group_before jsonb; f jsonb; moment timestamptz:=clock_timestamp(); number_value text;
  year_value integer; serial_value integer; charge_value uuid; active_count integer; submitted_count integer;
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
  if a.status<>'draft' or g.status<>'collecting' then raise exception 'not-submittable'; end if;
  if g.participant_due_at is null or moment>=g.participant_due_at then raise exception 'participant-deadline-passed'; end if;
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
  before_value:=private.community_snapshot(a.id); group_before:=private.group_snapshot(g.id);
  insert into public.application_charges(application_id,total_amount,calculated_at) values(a.id,0,moment)
    on conflict(application_id) do update set calculated_at=excluded.calculated_at returning id into charge_value;
  delete from public.charge_months where charge_id=charge_value;
  insert into public.charge_months(charge_id,month,usage_days,daily_rate,monthly_cap,amount)
    select charge_value,m.* from private.community_charge_months(g.start_date,g.end_date) m;
  update public.application_charges set total_amount=(select sum(amount) from public.charge_months where charge_id=charge_value) where id=charge_value;
  update public.applications set status='submitted',email_snapshot=lower(auth.jwt()->>'email'),
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
    values(a.id,'draft','submitted',actor,moment);
  perform private.community_audit(a.id,'submit_group_participant_application',before_value,actor,'user');
  select count(*),count(*) filter(where x.status='submitted') into active_count,submitted_count
    from public.group_members m join public.applications x on x.id=m.application_id where m.group_id=g.id and m.state='active';
  if active_count=g.planned_participants and submitted_count=active_count then
    update public.group_applications set status='under_review' where id=g.id returning * into g;
    update public.group_invites set revoked_at=moment where group_id=g.id and revoked_at is null;
    insert into public.group_status_events(group_id,from_status,to_status,actor_user_id,occurred_at)
      values(g.id,'collecting','under_review',actor,moment);
    perform private.group_audit(g.id,'complete_group_participant_submissions',group_before,actor);
  end if;
  return query select a.id,a.status,a.updated_at,number_value,a.last_submitted_at,g.id,g.status,g.updated_at;
end; $$;

create function public.get_group_participant_application(target_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a public.applications%rowtype; g public.group_applications%rowtype; validation_error text; moment timestamptz:=clock_timestamp(); fields jsonb;
begin
  if auth.uid() is null or not private.has_active_profile() then raise exception using errcode='42501',message='active-user-required'; end if;
  select * into a from public.applications where id=target_application_id and user_id=auth.uid() and usage_type='community_group';
  if not found or not exists(select 1 from public.group_members m where m.application_id=a.id and m.state='active') then raise exception 'not-found'; end if;
  select * into g from public.group_applications where id=a.group_id;
  fields:=jsonb_build_object('user_name',a.user_name,'user_address',a.user_address,'user_phone',a.user_phone,
    'emergency_name',a.emergency_name,'emergency_address',a.emergency_address,'emergency_phone',a.emergency_phone,
    'special_notes',a.special_notes,'requires_guardian_consent',a.requires_guardian_consent);
  begin
    if a.status<>'draft' or g.status<>'collecting' then raise exception 'not-editable'; end if;
    if g.participant_due_at is null or moment>=g.participant_due_at then raise exception 'participant-deadline-passed'; end if;
    perform private.validate_group_participant_fields(fields,true);
    if a.requires_guardian_consent and not exists(select 1 from public.consent_documents where application_id=a.id) then raise exception 'guardian-consent'; end if;
  exception when sqlstate 'P0001' then get stacked diagnostics validation_error=message_text; end;
  return jsonb_build_object('id',a.id,'group_id',g.id,'group_name',g.group_name,'group_status',g.status,
    'status',a.status,'updated_at',a.updated_at,'start_date',g.start_date,'end_date',g.end_date,
    'usage_place',g.usage_place,'purpose',g.purpose,'local_activity',g.local_activity,
    'participant_due_at',g.participant_due_at,'fields',fields,'submitted_at',a.submitted_at,
    'last_submitted_at',a.last_submitted_at,'reception_number',(select display_number from public.reception_numbers where application_id=a.id),
    'has_consent',exists(select 1 from public.consent_documents where application_id=a.id),
    'can_edit',a.status='draft' and g.status='collecting' and g.participant_due_at is not null and moment<g.participant_due_at,
    'validation_error',validation_error);
end; $$;

create function public.register_group_guardian_consent_document(target_application_id uuid,expected_user_id uuid,
  expected_updated_at timestamptz,target_object_path text,target_mime_type text,target_size_bytes integer)
returns table(previous_object_path text,delete_previous boolean,result_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare a public.applications%rowtype; g public.group_applications%rowtype; before_value jsonb; previous_path text;
begin
  perform private.lock_calendar_facility();
  perform id from public.profiles where id=expected_user_id and account_state='active' for share;
  if not found then raise exception using errcode='42501',message='active-user-required'; end if;
  select * into a from public.applications where id=target_application_id and usage_type='community_group' for update;
  if not found or a.user_id is distinct from expected_user_id or not exists(select 1 from public.group_members m where m.application_id=a.id and m.state='active') then raise exception 'not-found'; end if;
  select * into g from public.group_applications where id=a.group_id for update;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if a.status<>'draft' or g.status<>'collecting' then raise exception 'not-editable'; end if;
  if g.participant_due_at is null or clock_timestamp()>=g.participant_due_at then raise exception 'participant-deadline-passed'; end if;
  if target_object_path is null or target_object_path!~('^applications/'||a.id::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') then raise exception 'invalid-path'; end if;
  if target_mime_type is null or target_mime_type not in ('application/pdf','image/jpeg','image/png') then raise exception 'invalid-type'; end if;
  if target_size_bytes is null or target_size_bytes not between 1 and 5242880 then raise exception 'invalid-size'; end if;
  select object_path into previous_path from public.consent_documents where application_id=a.id for update;
  before_value:=private.community_snapshot(a.id);
  insert into public.consent_documents(application_id,object_path,mime_type,size_bytes) values(a.id,target_object_path,target_mime_type,target_size_bytes)
    on conflict(application_id) do update set object_path=excluded.object_path,mime_type=excluded.mime_type,size_bytes=excluded.size_bytes;
  update public.applications set updated_at=clock_timestamp() where id=a.id returning * into a;
  perform private.community_audit(a.id,'replace_group_participant_consent',before_value,expected_user_id,'user');
  return query select previous_path,true,a.updated_at;
end; $$;

revoke all on function private.validate_group_participant_fields(jsonb,boolean),private.apply_group_participant_fields(uuid,jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.save_group_participant_application(uuid,timestamptz,jsonb),
  public.submit_group_participant_application(uuid,timestamptz,uuid,boolean),public.get_group_participant_application(uuid),
  public.register_group_guardian_consent_document(uuid,uuid,timestamptz,text,text,integer)
  from public,anon,authenticated,service_role;
grant execute on function public.save_group_participant_application(uuid,timestamptz,jsonb),
  public.submit_group_participant_application(uuid,timestamptz,uuid,boolean),public.get_group_participant_application(uuid) to authenticated;
grant execute on function public.register_group_guardian_consent_document(uuid,uuid,timestamptz,text,text,integer) to service_role;
commit;
