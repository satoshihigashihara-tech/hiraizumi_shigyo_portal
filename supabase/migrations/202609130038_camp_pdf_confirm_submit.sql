-- A9: eligible-roster camp form, name synchronization, and confirmed PDF submission.
-- SQL037 is reserved for A11. Existing legacy and community flows remain unchanged.
begin;
select private.lock_calendar_facility();

alter table public.camp_application_versions
  add column submission_key uuid;

create unique index camp_application_versions_submission_key_uq
on public.camp_application_versions(application_id,submission_key)
where submission_key is not null;

alter table public.applications
  add column latest_submitted_camp_pdf_version_id uuid,
  add constraint applications_latest_submitted_camp_pdf_version_fk
    foreign key(latest_submitted_camp_pdf_version_id)
    references public.camp_application_versions(id) on delete restrict
    deferrable initially deferred;

-- Only the A9 transaction may change editable fields or submit an
-- eligible-roster application. This closes the legacy save/submit RPC bypasses
-- without changing their signatures or their legacy behavior.
create function private.guard_eligible_roster_camp_application_write()
returns trigger language plpgsql security definer set search_path='' as $$
declare mode_value text;
begin
  if new.usage_type<>'camp' or new.camp_id is null then return new; end if;
  select c.room_assignment_mode into mode_value from public.camps c where c.id=new.camp_id;
  if mode_value<>'eligible_roster' then return new; end if;

  if (new.user_name,new.user_address,new.user_phone,new.email_snapshot,new.emergency_name,
      new.emergency_address,new.emergency_phone,new.usage_place,new.purpose,new.special_notes,
      new.requires_guardian_consent,new.room_preference)
    is distinct from
     (old.user_name,old.user_address,old.user_phone,old.email_snapshot,old.emergency_name,
      old.emergency_address,old.emergency_phone,old.usage_place,old.purpose,old.special_notes,
      old.requires_guardian_consent,old.room_preference)
    and current_setting('private.camp_roster_draft',true) is distinct from 'allowed'
    and current_setting('private.camp_pdf_submission',true) is distinct from 'allowed'
    and current_setting('private.camp_mode_migration',true) is distinct from 'allowed' then
    raise exception 'eligible-roster-form-required';
  end if;

  if new.status='submitted' and old.status in ('draft','revision_requested')
    and current_setting('private.camp_pdf_submission',true) is distinct from 'allowed' then
    raise exception 'pdf-confirmation-required';
  end if;
  return new;
end $$;

create trigger applications_guard_eligible_roster_camp_write
before update of user_name,user_address,user_phone,email_snapshot,emergency_name,
  emergency_address,emergency_phone,usage_place,purpose,special_notes,
  requires_guardian_consent,room_preference,status
on public.applications for each row
execute function private.guard_eligible_roster_camp_application_write();

-- Extend A7's immutable transition guard with one A9-only submission key.
create or replace function private.guard_camp_pdf_version()
returns trigger language plpgsql set search_path='' as $$
declare a public.applications%rowtype;
begin
  if tg_op='DELETE' then raise exception 'pdf-version-immutable'; end if;
  if tg_op='INSERT' then
    select * into a from public.applications where id=new.application_id;
    if not found or a.usage_type<>'camp' or a.camp_id is distinct from new.camp_id
      or a.camp_eligible_user_id is distinct from new.eligible_user_id or a.user_id is distinct from new.owner_id
      or not exists(select 1 from public.camps where id=a.camp_id and room_assignment_mode='eligible_roster') then
      raise exception 'pdf-scope-mismatch';
    end if;
    if new.state<>'pending' or new.submission_key is not null then raise exception 'pdf-version-immutable'; end if;
  else
    if (to_jsonb(new)-array['state','object_path','pdf_hash','size_bytes','validation','generated_at','confirmed_at','submitted_at','submission_key'])
      is distinct from (to_jsonb(old)-array['state','object_path','pdf_hash','size_bytes','validation','generated_at','confirmed_at','submitted_at','submission_key']) then
      raise exception 'pdf-version-immutable';
    end if;
    if old.state='submitted'
      or (old.state='ready' and
        ((to_jsonb(new)-array['state','confirmed_at','submitted_at','submission_key'])
          is distinct from (to_jsonb(old)-array['state','confirmed_at','submitted_at','submission_key'])
          or new.state<>'submitted' or new.submission_key is null
          or current_setting('private.camp_pdf_submission',true) is distinct from 'allowed'))
      or (old.state='pending' and (new.state<>'ready' or new.submission_key is not null)) then
      raise exception 'pdf-version-immutable';
    end if;
  end if;
  return new;
end $$;

create function private.check_latest_submitted_camp_pdf_version()
returns trigger language plpgsql security definer set search_path='' as $$
declare v public.camp_application_versions%rowtype;
begin
  if new.latest_submitted_camp_pdf_version_id is null then return new; end if;
  select * into v from public.camp_application_versions
    where id=new.latest_submitted_camp_pdf_version_id;
  if not found or v.application_id<>new.id or v.owner_id is distinct from new.user_id
    or v.camp_id is distinct from new.camp_id
    or v.eligible_user_id is distinct from new.camp_eligible_user_id
    or v.state<>'submitted' then
    raise exception 'submitted-pdf-inconsistent';
  end if;
  return new;
end $$;

create constraint trigger applications_check_latest_submitted_camp_pdf
after insert or update of latest_submitted_camp_pdf_version_id,status,user_id,camp_id,camp_eligible_user_id
on public.applications deferrable initially deferred for each row
execute function private.check_latest_submitted_camp_pdf_version();

create function public.save_camp_roster_application_draft(
  target_application_id uuid,
  expected_input_version bigint,
  applicant_name text,
  applicant_address text,
  applicant_phone text,
  emergency_contact_name text,
  emergency_contact_address text,
  emergency_contact_phone text,
  usage_purpose text,
  notes text,
  guardian_consent_required boolean
)
returns table(result_id uuid,result_input_version bigint,result_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); a public.applications%rowtype; c public.camps%rowtype;
  e public.camp_eligible_users%rowtype; verified_email text; before_consent jsonb;
  before_application jsonb;
  user_name_value text:=nullif(btrim(applicant_name),'');
  user_address_value text:=nullif(btrim(applicant_address),'');
  user_phone_value text:=nullif(btrim(applicant_phone),'');
  emergency_name_value text:=nullif(btrim(emergency_contact_name),'');
  emergency_address_value text:=nullif(btrim(emergency_contact_address),'');
  emergency_phone_value text:=nullif(btrim(emergency_contact_phone),'');
  purpose_value text:=nullif(btrim(usage_purpose),'');
  notes_value text:=nullif(btrim(notes),'');
begin
  if actor is null or expected_input_version is null or expected_input_version<1 then
    raise exception using errcode='42501',message='not-found';
  end if;
  perform private.lock_calendar_facility();
  perform p.id from public.profiles p where p.id=actor and p.account_state='active' for share;
  if not found then raise exception using errcode='42501',message='not-found'; end if;
  select * into c from public.camps where id=(select camp_id from public.applications where id=target_application_id)
    and deleted_at is null for update;
  if not found then raise exception using errcode='42501',message='not-found'; end if;
  if c.room_assignment_mode<>'eligible_roster' then raise exception 'eligible-roster-required'; end if;
  select * into e from public.camp_eligible_users where camp_id=c.id
    and id=(select camp_eligible_user_id from public.applications where id=target_application_id) for update;
  select * into a from public.applications where id=target_application_id and usage_type='camp' for update;
  if not found or a.user_id is distinct from actor or e.id is null or e.linked_user_id is distinct from actor
    or e.disabled_at is not null or e.participation_status<>'participating' then
    raise exception using errcode='42501',message='not-found';
  end if;
  if a.input_version<>expected_input_version then raise exception 'stale-update'; end if;
  if a.status not in ('draft','revision_requested') then raise exception 'not-editable'; end if;
  if (a.status='draft' and c.application_deadline<=clock_timestamp())
    or (a.status='revision_requested' and (a.revision_due_at is null or a.revision_due_at<=clock_timestamp())) then
    raise exception 'deadline-passed';
  end if;
  verified_email:=private.current_verified_email(actor);
  if verified_email is null then raise exception using errcode='42501',message='not-found'; end if;
  if char_length(coalesce(user_name_value,''))>100 or char_length(coalesce(user_address_value,''))>500
    or char_length(coalesce(user_phone_value,''))>20 or char_length(coalesce(emergency_name_value,''))>100
    or char_length(coalesce(emergency_address_value,''))>500 or char_length(coalesce(emergency_phone_value,''))>20
    or char_length(coalesce(purpose_value,''))>2000 or char_length(coalesce(notes_value,''))>2000 then
    raise exception 'field-too-long';
  end if;
  if (user_phone_value is not null and user_phone_value!~'^[0-9+][0-9() -]{7,19}$')
    or (emergency_phone_value is not null and emergency_phone_value!~'^[0-9+][0-9() -]{7,19}$') then
    raise exception 'invalid-phone';
  end if;
  before_consent:=private.camp_audit_consent(a.id);
  before_application:=to_jsonb(a);
  perform set_config('private.camp_roster_draft','allowed',true);
  update public.applications set
    user_name=user_name_value,user_address=user_address_value,user_phone=user_phone_value,
    email_snapshot=verified_email,emergency_name=emergency_name_value,
    emergency_address=emergency_address_value,emergency_phone=emergency_phone_value,
    usage_place='common_and_second_floor',purpose=purpose_value,special_notes=notes_value,
    requires_guardian_consent=guardian_consent_required,room_preference=null
  where id=a.id returning * into a;
  perform private.record_camp_user_audit(a.id,'save_camp_draft',before_application,before_consent,actor);
  return query select a.id,a.input_version,a.updated_at;
end $$;

-- Minimal owner-only DTO. No email, Storage path, source snapshot, render
-- context, other participant, or worker details leave the database.
create function public.get_my_camp_pdf_submission_context(target_application_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); a public.applications%rowtype; c public.camps%rowtype;
  e public.camp_eligible_users%rowtype; profile_name_value text; v public.camp_application_versions%rowtype;
  job_state text; current_version boolean:=false; public_state text:='not_requested';
begin
  if actor is null then raise exception using errcode='42501',message='not-found'; end if;
  perform private.lock_calendar_facility();
  perform p.id from public.profiles p where p.id=actor and p.account_state='active' for share;
  if not found then raise exception using errcode='42501',message='not-found'; end if;
  select * into c from public.camps where id=(select camp_id from public.applications where id=target_application_id)
    and room_assignment_mode='eligible_roster' and deleted_at is null for share;
  if not found then raise exception 'eligible-roster-required'; end if;
  select * into e from public.camp_eligible_users where camp_id=c.id
    and id=(select camp_eligible_user_id from public.applications where id=target_application_id)
    and linked_user_id=actor and disabled_at is null and participation_status='participating' for share;
  select * into a from public.applications where id=target_application_id and user_id=actor and usage_type='camp' for share;
  if not found or e.id is null then raise exception using errcode='42501',message='not-found'; end if;
  if a.status not in ('draft','revision_requested') then raise exception 'not-submittable'; end if;
  if (a.status='draft' and c.application_deadline<=clock_timestamp())
    or (a.status='revision_requested' and (a.revision_due_at is null or a.revision_due_at<=clock_timestamp())) then
    raise exception 'deadline-passed';
  end if;
  select p.full_name into profile_name_value from public.profiles p where p.id=actor;
  select * into v from public.camp_application_versions where application_id=a.id order by version_no desc limit 1;
  if found then
    begin current_version:=private.camp_pdf_is_current(v);
    exception when sqlstate '42501' or sqlstate 'P0001' then current_version:=false; end;
    select j.state into job_state from public.camp_pdf_jobs j where j.version_id=v.id;
    if not current_version then public_state:='stale';
    elsif v.state='ready' then public_state:='ready';
    elsif job_state in ('queued','running') then public_state:='generating';
    else public_state:='failed';
    end if;
  end if;
  return jsonb_build_object(
    'application_id',a.id,'eligible_user_id',e.id,'status',a.status,
    'input_version',a.input_version::text,'application_updated_at',a.updated_at,
    'room_plan_version',c.room_plan_version::text,
    'management_name',e.management_name,'profile_name',profile_name_value,'applicant_name',a.user_name,
    'pdf_state',public_state,'pdf_version_id',case when current_version then v.id else null end,
    'pdf_version_no',case when current_version then v.version_no::text else null end,
    'pdf_hash',case when current_version and v.state='ready' then v.pdf_hash else null end,
    'pdf_size_bytes',case when current_version and v.state='ready' then v.size_bytes else null end,
    'pdf_generated_at',case when current_version and v.state='ready' then v.generated_at else null end);
end $$;

create function public.submit_camp_application_with_pdf(
  target_application_id uuid,
  target_version_id uuid,
  expected_input_version bigint,
  submission_key_value uuid,
  confirmed boolean
)
returns table(submitted_application_id uuid,reception_number text,submission_time timestamptz,submitted_version_id uuid)
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); a public.applications%rowtype; c public.camps%rowtype;
  e public.camp_eligible_users%rowtype; p public.profiles%rowtype; v public.camp_application_versions%rowtype;
  previous_status text; reception_value text; submitted_time timestamptz; fiscal_year_value integer;
  serial_value integer; charge_id_value uuid; total_value integer; before_consent jsonb;
  old_management_name text; old_profile_name text;
begin
  if actor is null then raise exception using errcode='42501',message='not-found'; end if;
  if confirmed is distinct from true then raise exception 'pdf-confirmation-required'; end if;
  if target_version_id is null or expected_input_version is null or expected_input_version<1
    or submission_key_value is null then raise exception 'invalid-request'; end if;
  perform private.lock_calendar_facility();
  select * into p from public.profiles where id=actor and account_state='active' for update;
  if not found then raise exception using errcode='42501',message='not-found'; end if;
  select * into c from public.camps where id=(select camp_id from public.applications where id=target_application_id)
    and deleted_at is null for update;
  if not found or c.room_assignment_mode<>'eligible_roster' then raise exception using errcode='42501',message='not-found'; end if;
  perform r.id from public.rooms r join public.camp_room_assignments assignment on assignment.room_id=r.id
    where assignment.camp_id=c.id order by r.id for share of r;
  perform m.room_id from public.camp_room_mapping m join public.camp_room_assignments assignment on assignment.room_id=m.room_id
    where assignment.camp_id=c.id order by m.room_id for share of m;
  select * into e from public.camp_eligible_users where camp_id=c.id
    and id=(select camp_eligible_user_id from public.applications where id=target_application_id) for update;
  select * into a from public.applications where id=target_application_id and usage_type='camp' for update;
  if not found or a.user_id is distinct from actor or e.id is null or e.linked_user_id is distinct from actor
    or e.disabled_at is not null or e.participation_status<>'participating' then
    raise exception using errcode='42501',message='not-found';
  end if;
  select * into v from public.camp_application_versions where id=target_version_id for update;
  if not found or v.application_id<>a.id or v.owner_id<>actor or v.eligible_user_id<>e.id or v.camp_id<>c.id then
    raise exception using errcode='42501',message='not-found';
  end if;

  -- A replay with the same key is the one successful submission, even after
  -- its deadline. A different key/version never creates a second receipt.
  if a.status='submitted' then
    if a.latest_submitted_camp_pdf_version_id=v.id and v.state='submitted'
      and v.submission_key=submission_key_value then
      select n.display_number into reception_value from public.reception_numbers n where n.application_id=a.id;
      if reception_value is null then raise exception 'application-inconsistent'; end if;
      return query select a.id,reception_value,v.submitted_at,v.id; return;
    end if;
    raise exception 'not-submittable';
  end if;
  if a.status not in ('draft','revision_requested') then raise exception 'not-submittable'; end if;
  if a.input_version<>expected_input_version or v.input_version<>expected_input_version then raise exception 'stale-update'; end if;
  if (a.status='draft' and c.application_deadline<=clock_timestamp())
    or (a.status='revision_requested' and (a.revision_due_at is null or a.revision_due_at<=clock_timestamp())) then
    raise exception 'deadline-passed';
  end if;
  if v.state<>'ready' or v.submission_key is not null
    or v.validation is null or not (v.validation @> '{"page_count":1,"fonts_embedded":true,"text_verified":true,"layout_verified":true}'::jsonb)
    or private.camp_pdf_is_current(v) is distinct from true then raise exception 'stale-update'; end if;
  if a.user_name is null or a.user_address is null or a.user_phone is null
    or a.emergency_name is null or a.emergency_address is null or a.emergency_phone is null
    or a.purpose is null or a.usage_place<>'common_and_second_floor'
    or a.requires_guardian_consent is null then raise exception 'required-fields'; end if;
  if a.user_phone!~'^[0-9+][0-9() -]{7,19}$' or a.emergency_phone!~'^[0-9+][0-9() -]{7,19}$' then
    raise exception 'invalid-phone';
  end if;
  if a.requires_guardian_consent and not exists(
    select 1 from public.consent_documents d where d.application_id=a.id) then raise exception 'guardian-consent'; end if;
  if private.current_verified_email(actor) is null then raise exception using errcode='42501',message='not-found'; end if;
  if not exists(select 1 from public.camp_pdf_jobs j where j.version_id=v.id and j.state='succeeded') then
    raise exception 'pdf-not-ready';
  end if;

  previous_status:=a.status;
  before_consent:=private.camp_audit_consent(a.id);
  old_management_name:=e.management_name;
  old_profile_name:=p.full_name;
  submitted_time:=clock_timestamp();
  select n.display_number into reception_value from public.reception_numbers n where n.application_id=a.id;
  if previous_status='draft' then
    if reception_value is not null or exists(select 1 from public.application_charges q where q.application_id=a.id) then
      raise exception 'application-inconsistent';
    end if;
    fiscal_year_value:=extract(year from (submitted_time at time zone 'Asia/Tokyo')-interval '3 months')::integer;
    insert into public.reception_counters(fiscal_year,last_number) values(fiscal_year_value,0)
      on conflict(fiscal_year) do nothing;
    update public.reception_counters set last_number=last_number+1,updated_at=submitted_time
      where fiscal_year=fiscal_year_value returning last_number into serial_value;
    reception_value:=format('SG-%s-%s',fiscal_year_value,lpad(serial_value::text,4,'0'));
    insert into public.reception_numbers(fiscal_year,serial_number,display_number,application_id)
      values(fiscal_year_value,serial_value,reception_value,a.id);
    insert into public.application_charges(application_id,total_amount,payment_status,calculated_at)
      values(a.id,0,'unpaid',submitted_time) returning id into charge_id_value;
    insert into public.charge_months(charge_id,month,usage_days,daily_rate,monthly_cap,amount)
    select charge_id_value,month_start::date,
      (least(c.end_date,(month_start+interval '1 month - 1 day')::date)-greatest(c.start_date,month_start::date)+1)::integer,
      300,9000,least((least(c.end_date,(month_start+interval '1 month - 1 day')::date)
        -greatest(c.start_date,month_start::date)+1)::integer*300,9000)
    from generate_series(date_trunc('month',c.start_date::timestamp),date_trunc('month',c.end_date::timestamp),interval '1 month') month_start;
    select coalesce(sum(m.amount),0) into total_value from public.charge_months m where m.charge_id=charge_id_value;
    update public.application_charges set total_amount=total_value where id=charge_id_value;
  else
    if reception_value is null or not exists(select 1 from public.application_charges q where q.application_id=a.id)
      or exists(select 1 from public.application_charges q where q.application_id=a.id and q.total_amount<>
        (select coalesce(sum(m.amount),0) from public.charge_months m where m.charge_id=q.id)) then
      raise exception 'application-inconsistent';
    end if;
  end if;

  perform set_config('private.camp_pdf_submission','allowed',true);
  update public.camp_application_versions set state='submitted',confirmed_at=submitted_time,
    submitted_at=submitted_time,submission_key=submission_key_value where id=v.id returning * into v;
  update public.applications set status='submitted',start_date=c.start_date,end_date=c.end_date,
    submitted_at=coalesce(submitted_at,submitted_time),last_submitted_at=submitted_time,
    revision_due_at=null,latest_submitted_camp_pdf_version_id=v.id where id=a.id;
  if p.full_name is distinct from a.user_name then update public.profiles set full_name=a.user_name where id=p.id; end if;
  if e.management_name is distinct from a.user_name then update public.camp_eligible_users set management_name=a.user_name where id=e.id; end if;
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id)
  values('camp_eligible_user',e.id,'sync_camp_submission_names',
    jsonb_build_object('management_name',old_management_name,'profile_name',old_profile_name),
    jsonb_build_object('management_name',a.user_name,'profile_name',a.user_name,'pdf_version_id',v.id),'user',actor);
  insert into public.application_status_events(application_id,from_status,to_status,actor_user_id)
    values(a.id,previous_status,'submitted',actor);
  perform private.record_camp_user_audit(a.id,
    case when previous_status='draft' then 'submit_camp_application' else 'resubmit_camp_application' end,
    to_jsonb(a),before_consent,actor);
  perform private.camp_pdf_audit(v.id,'pdf_confirmed_and_submitted',actor,
    jsonb_build_object('application_id',a.id,'version_no',v.version_no));
  return query select a.id,reception_value,submitted_time,v.id;
end $$;

revoke all on function private.guard_eligible_roster_camp_application_write(),
  private.check_latest_submitted_camp_pdf_version() from public,anon,authenticated,service_role;
revoke all on function public.save_camp_roster_application_draft(uuid,bigint,text,text,text,text,text,text,text,text,boolean),
  public.get_my_camp_pdf_submission_context(uuid),
  public.submit_camp_application_with_pdf(uuid,uuid,bigint,uuid,boolean)
  from public,anon,authenticated,service_role;
grant execute on function public.save_camp_roster_application_draft(uuid,bigint,text,text,text,text,text,text,text,text,boolean),
  public.get_my_camp_pdf_submission_context(uuid),
  public.submit_camp_application_with_pdf(uuid,uuid,bigint,uuid,boolean) to authenticated;

commit;
