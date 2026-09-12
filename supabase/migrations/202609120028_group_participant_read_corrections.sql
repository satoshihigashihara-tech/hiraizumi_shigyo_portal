-- Let group participants read and replace consent documents during an active correction period.
begin;
select private.lock_calendar_facility();

create or replace function public.get_group_participant_application(target_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a public.applications%rowtype; g public.group_applications%rowtype; validation_error text;
  moment timestamptz:=clock_timestamp(); fields jsonb; deadline timestamptz; editable boolean;
begin
  if auth.uid() is null or not private.has_active_profile() then raise exception using errcode='42501',message='active-user-required'; end if;
  select * into a from public.applications where id=target_application_id and user_id=auth.uid() and usage_type='community_group';
  if not found or not exists(select 1 from public.group_members m where m.application_id=a.id and m.group_id=a.group_id and m.state='active') then raise exception 'not-found'; end if;
  select * into g from public.group_applications where id=a.group_id;
  deadline:=case when a.status='revision_requested' and g.status='revision_requested' then g.revision_due_at else g.participant_due_at end;
  editable:=(a.status='draft' and g.status='collecting') or (a.status='revision_requested' and g.status='revision_requested');
  fields:=jsonb_build_object('user_name',a.user_name,'user_address',a.user_address,'user_phone',a.user_phone,
    'emergency_name',a.emergency_name,'emergency_address',a.emergency_address,'emergency_phone',a.emergency_phone,
    'special_notes',a.special_notes,'requires_guardian_consent',a.requires_guardian_consent);
  begin
    if not editable then raise exception 'not-editable'; end if;
    if deadline is null or moment>=deadline then raise exception 'participant-deadline-passed'; end if;
    perform private.validate_group_participant_fields(fields,true);
    if a.requires_guardian_consent and not exists(select 1 from public.consent_documents where application_id=a.id) then raise exception 'guardian-consent'; end if;
  exception when sqlstate 'P0001' then get stacked diagnostics validation_error=message_text; end;
  return jsonb_build_object('id',a.id,'group_id',g.id,'group_name',g.group_name,'group_status',g.status,
    'status',a.status,'updated_at',a.updated_at,'start_date',g.start_date,'end_date',g.end_date,
    'usage_place',g.usage_place,'purpose',g.purpose,'local_activity',g.local_activity,
    'participant_due_at',g.participant_due_at,'revision_due_at',g.revision_due_at,
    'active_deadline',deadline,'decision_reason',coalesce(a.decision_reason,g.decision_reason),'fields',fields,
    'submitted_at',a.submitted_at,'last_submitted_at',a.last_submitted_at,
    'reception_number',(select display_number from public.reception_numbers where application_id=a.id),
    'has_consent',exists(select 1 from public.consent_documents where application_id=a.id),
    'can_edit',editable and deadline is not null and moment<deadline,'validation_error',validation_error);
end; $$;

create or replace function public.register_group_guardian_consent_document(target_application_id uuid,expected_user_id uuid,
  expected_updated_at timestamptz,target_object_path text,target_mime_type text,target_size_bytes integer)
returns table(previous_object_path text,delete_previous boolean,result_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare a public.applications%rowtype; g public.group_applications%rowtype; before_value jsonb; previous_path text; deadline timestamptz;
begin
  perform private.lock_calendar_facility();
  perform id from public.profiles where id=expected_user_id and account_state='active' for share;
  if not found then raise exception using errcode='42501',message='active-user-required'; end if;
  select * into a from public.applications where id=target_application_id and usage_type='community_group' for update;
  if not found or a.user_id is distinct from expected_user_id
    or not exists(select 1 from public.group_members m where m.application_id=a.id and m.group_id=a.group_id and m.state='active') then raise exception 'not-found'; end if;
  select * into g from public.group_applications where id=a.group_id for update;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if not ((a.status='draft' and g.status='collecting')
    or (a.status='revision_requested' and g.status='revision_requested')) then raise exception 'not-editable'; end if;
  deadline:=case when g.status='revision_requested' then g.revision_due_at else g.participant_due_at end;
  if deadline is null or clock_timestamp()>=deadline then raise exception 'participant-deadline-passed'; end if;
  if target_object_path is null or target_object_path!~('^applications/'||a.id::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') then raise exception 'invalid-path'; end if;
  if target_mime_type is null or target_mime_type not in ('application/pdf','image/jpeg','image/png') then raise exception 'invalid-type'; end if;
  if target_size_bytes is null or target_size_bytes not between 1 and 5242880 then raise exception 'invalid-size'; end if;
  select object_path into previous_path from public.consent_documents where application_id=a.id for update;
  before_value:=private.community_snapshot(a.id);
  insert into public.consent_documents(application_id,object_path,mime_type,size_bytes)
    values(a.id,target_object_path,target_mime_type,target_size_bytes)
    on conflict(application_id) do update set object_path=excluded.object_path,mime_type=excluded.mime_type,size_bytes=excluded.size_bytes;
  update public.applications set updated_at=clock_timestamp() where id=a.id returning * into a;
  perform private.community_audit(a.id,'replace_group_participant_consent',before_value,expected_user_id,'user');
  return query select previous_path,true,a.updated_at;
end; $$;

revoke all on function public.get_group_participant_application(uuid),
  public.register_group_guardian_consent_document(uuid,uuid,timestamptz,text,text,integer)
  from public,anon,authenticated,service_role;
grant execute on function public.get_group_participant_application(uuid) to authenticated;
grant execute on function public.register_group_guardian_consent_document(uuid,uuid,timestamptz,text,text,integer) to service_role;
commit;
