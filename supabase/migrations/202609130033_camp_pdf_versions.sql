-- A7 foundation. No bucket mutation, conversion, submission, or camp mode switch.
begin;
select private.lock_calendar_facility();

create table public.camp_application_versions (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.applications(id) on delete restrict,
  camp_id uuid not null,
  eligible_user_id uuid not null,
  owner_id uuid not null, -- Historical identity survives Auth cleanup.
  version_no bigint not null check(version_no>0),
  request_key uuid not null,
  input_version bigint not null check(input_version>0),
  room_plan_version bigint not null check(room_plan_version>=0),
  application_date date not null,
  source_snapshot jsonb not null check(jsonb_typeof(source_snapshot)='object'),
  source_hash text not null check(source_hash ~ '^[0-9a-f]{64}$'),
  render_context jsonb not null check(jsonb_typeof(render_context)='object'),
  state text not null default 'pending' check(state in ('pending','ready','submitted')),
  object_path text unique,
  pdf_hash text check(pdf_hash ~ '^[0-9a-f]{64}$'),
  size_bytes integer check(size_bytes between 1 and 3145728),
  validation jsonb,
  created_at timestamptz not null default clock_timestamp(),
  generated_at timestamptz,
  confirmed_at timestamptz,
  submitted_at timestamptz,
  unique(application_id,version_no), unique(application_id,request_key),
  foreign key(camp_id,eligible_user_id) references public.camp_eligible_users(camp_id,id) on delete restrict,
  check ((state='pending' and object_path is null and pdf_hash is null and size_bytes is null and validation is null and generated_at is null)
    or (state in ('ready','submitted') and object_path is not null and pdf_hash is not null and size_bytes is not null
      and validation is not null and generated_at is not null)),
  check ((state='submitted' and confirmed_at is not null and submitted_at is not null and submitted_at>=confirmed_at)
    or (state<>'submitted' and confirmed_at is null and submitted_at is null))
);
create table public.camp_pdf_jobs (
  id uuid primary key default gen_random_uuid(),
  version_id uuid not null unique references public.camp_application_versions(id) on delete restrict,
  state text not null default 'queued' check(state in ('queued','running','succeeded','failed','expired','cleaning','cleaned')),
  attempt_id uuid unique,
  lease_until timestamptz,
  expires_at timestamptz not null default clock_timestamp()+interval '15 minutes',
  cleanup_token uuid,
  cleanup_until timestamptz,
  error_code text check(error_code in ('generation-failed','storage-failed','registration-failed','expired')),
  created_at timestamptz not null default clock_timestamp()
);
alter table public.camp_application_versions enable row level security;
alter table public.camp_pdf_jobs enable row level security;
revoke all on public.camp_application_versions,public.camp_pdf_jobs from public,anon,authenticated,service_role;

-- Restrictive boundary overrides unrelated permissive policies on other buckets.
-- Storage metadata/object mutations remain exclusively through the Storage API.
do $$ begin
  if to_regclass('storage.objects') is not null then
    execute 'create policy camp_pdf_objects_boundary on storage.objects as restrictive for all to anon,authenticated
      using (bucket_id <> ''camp-application-pdfs'') with check (bucket_id <> ''camp-application-pdfs'')';
  end if;
end $$;

-- A8 remains closed. Only a later migration may supply verified, versioned
-- template/font/converter settings; there is no environment or browser switch.
create function private.camp_pdf_render_settings(target_application_id uuid)
returns jsonb language plpgsql set search_path='' as $$
begin raise exception 'pdf-prerequisites-unavailable'; end $$;

-- A3 is the sole live room source. Never fall back to legacy room_allocations.
-- Caller holds facility/profile/camp/room/mapping/eligible/application locks.
create function private.camp_pdf_assignment_context(target_application_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.applications%rowtype; c public.camps%rowtype;
  assignment public.camp_room_assignments%rowtype; mapping public.camp_room_mapping%rowtype;
  room public.rooms%rowtype; plan public.camp_room_plan_versions%rowtype;
begin
  select * into a from public.applications where id=target_application_id and usage_type='camp';
  if not found then raise exception 'pdf-assignment-unavailable'; end if;
  select * into c from public.camps where id=a.camp_id and room_assignment_mode='eligible_roster' and deleted_at is null;
  if not found or c.room_plan_committed_at is null or c.start_date is distinct from a.start_date
    or c.end_date is distinct from a.end_date then raise exception 'pdf-assignment-unavailable'; end if;
  select * into assignment from public.camp_room_assignments
    where camp_id=c.id and eligible_user_id=a.camp_eligible_user_id for share;
  if not found or assignment.released_from is not null or assignment.start_date<>c.start_date or assignment.end_date<>c.end_date
    or assignment.room_plan_version<>c.room_plan_version then raise exception 'pdf-assignment-unavailable'; end if;
  select * into mapping from public.camp_room_mapping where room_id=assignment.room_id;
  if not found or not mapping.assignment_enabled or not mapping.printing_enabled or mapping.floor<>2
    or mapping.confirmed_at is null or nullif(btrim(mapping.confirmation_evidence),'') is null then raise exception 'pdf-room-not-printable'; end if;
  select * into room from public.rooms where id=assignment.room_id;
  select * into plan from public.camp_room_plan_versions where camp_id=c.id and version=assignment.room_plan_version;
  if not found or plan.start_date<>c.start_date or plan.end_date<>c.end_date or not plan.assignments @>
    jsonb_build_array(jsonb_build_object('eligible_user_id',a.camp_eligible_user_id,'room_id',room.id,
      'assignment_version',assignment.assignment_version,'capacity',room.capacity,'released_from',null)) then raise exception 'pdf-assignment-unavailable'; end if;
  if not exists(select 1 from public.calendar_claims q where q.camp_id=c.id and q.claim_type='camp'
    and q.start_date=c.start_date and q.end_date=c.end_date and q.released_from is null) then raise exception 'pdf-calendar-unavailable'; end if;
  -- roster_version can advance when another eligible user is added. Existing
  -- valid individual assignments stay usable; roster completeness is A11's gate.
  return jsonb_build_object('assignment_version',assignment.assignment_version,'assignment_id',assignment.id,
    'room_id',room.id,'room_name',mapping.print_name,'room_capacity',room.capacity,
    'room_plan_version',assignment.room_plan_version,'start_date',assignment.start_date,'end_date',assignment.end_date);
end $$;

create function private.camp_pdf_render_context(target_application_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare assignment jsonb; settings jsonb;
begin
  assignment:=private.camp_pdf_assignment_context(target_application_id);
  settings:=private.camp_pdf_render_settings(target_application_id);
  if settings is null or jsonb_typeof(settings)<>'object' or not settings ?&
    array['template_hash','settings_version','font_version','converter_image','mayor_name']
    or settings->>'template_hash' !~ '^[0-9a-f]{64}$' then raise exception 'pdf-prerequisites-unavailable'; end if;
  -- Project only render settings, preventing any override of A3's room fields.
  settings:=jsonb_build_object('template_hash',settings->'template_hash','settings_version',settings->'settings_version',
    'font_version',settings->'font_version','converter_image',settings->'converter_image','mayor_name',settings->'mayor_name');
  if exists(select 1 from jsonb_each(settings) where value='null'::jsonb or value='""'::jsonb) then raise exception 'pdf-prerequisites-unavailable'; end if;
  return assignment||settings;
end $$;

create function private.camp_pdf_audit(version_id uuid,event_name text,actor uuid default null,details jsonb default '{}')
returns void language sql security definer set search_path='' as $$
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id)
  values('camp_pdf',version_id,event_name,'{}',details,case when actor is null then 'system' when exists(select 1 from public.staff_roles where user_id=actor) then 'staff' else 'user' end,actor);
$$;

create function private.guard_camp_pdf_version()
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
    if new.state<>'pending' then raise exception 'pdf-version-immutable'; end if;
  else
    if (to_jsonb(new)-array['state','object_path','pdf_hash','size_bytes','validation','generated_at','confirmed_at','submitted_at'])
      is distinct from (to_jsonb(old)-array['state','object_path','pdf_hash','size_bytes','validation','generated_at','confirmed_at','submitted_at']) then
      raise exception 'pdf-version-immutable';
    end if;
    if old.state='submitted' or (old.state='ready' and
      ((to_jsonb(new)-array['state','confirmed_at','submitted_at']) is distinct from (to_jsonb(old)-array['state','confirmed_at','submitted_at'])
        or new.state<>'submitted' or current_setting('private.camp_pdf_submission',true) is distinct from 'allowed'))
      or (old.state='pending' and new.state<>'ready') then raise exception 'pdf-version-immutable'; end if;
  end if;
  return new;
end $$;
create trigger camp_pdf_version_guard before insert or update or delete on public.camp_application_versions
for each row execute function private.guard_camp_pdf_version();

create function private.camp_pdf_owner_application(actor uuid,target_application_id uuid)
returns public.applications language plpgsql security definer set search_path='' as $$
declare a public.applications%rowtype; c public.camps%rowtype;
begin
  perform p.id from public.profiles p where p.id=actor and p.account_state='active' for share;
  if not found then raise exception using errcode='42501',message='not-found'; end if;
  select * into c from public.camps where id=(select camp_id from public.applications where id=target_application_id)
    and room_assignment_mode='eligible_roster' and deleted_at is null for share;
  if not found then raise exception using errcode='42501',message='not-found'; end if;
  perform r.id from public.rooms r join public.camp_room_assignments ar on ar.room_id=r.id
    join public.applications x on x.camp_id=ar.camp_id and x.camp_eligible_user_id=ar.eligible_user_id
    where x.id=target_application_id order by r.id for share of r;
  perform m.room_id from public.camp_room_mapping m join public.camp_room_assignments ar on ar.room_id=m.room_id
    join public.applications x on x.camp_id=ar.camp_id and x.camp_eligible_user_id=ar.eligible_user_id
    where x.id=target_application_id order by m.room_id for share of m;
  perform e.id from public.camp_eligible_users e join public.applications x on x.camp_eligible_user_id=e.id and x.camp_id=e.camp_id
    where x.id=target_application_id and e.linked_user_id=actor and e.disabled_at is null
      and e.participation_status='participating' for share of e;
  if not found then raise exception using errcode='42501',message='not-found'; end if;
  select * into a from public.applications where id=target_application_id and user_id=actor and usage_type='camp' for share;
  if not found then raise exception using errcode='42501',message='not-found'; end if;
  if a.status not in ('draft','revision_requested') then raise exception 'not-editable'; end if;
  if (a.status='draft' and c.application_deadline<=clock_timestamp())
    or (a.status='revision_requested' and (a.revision_due_at is null or a.revision_due_at<=clock_timestamp())) then
    raise exception 'deadline-passed';
  end if;
  return a;
end $$;

create function private.camp_pdf_is_current(v public.camp_application_versions)
returns boolean language plpgsql security definer set search_path='' as $$
declare a public.applications%rowtype;
begin
  a:=private.camp_pdf_owner_application(v.owner_id,v.application_id);
  return a.input_version=v.input_version
    and v.application_date=(clock_timestamp() at time zone 'Asia/Tokyo')::date
    and v.room_plan_version=(select room_plan_version from public.camps where id=v.camp_id)
    and not exists(select 1 from public.camp_application_versions n where n.application_id=v.application_id and n.version_no>v.version_no)
    and v.render_context=private.camp_pdf_render_context(v.application_id);
end $$;

create function public.begin_camp_application_pdf(target_application_id uuid,expected_input_version bigint,request_key_value uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare a public.applications%rowtype; v public.camp_application_versions%rowtype; context_value jsonb; snapshot_value jsonb;
begin
  if auth.uid() is null then raise exception using errcode='42501',message='not-found'; end if;
  perform private.lock_calendar_facility();
  a:=private.camp_pdf_owner_application(auth.uid(),target_application_id);
  if expected_input_version is distinct from a.input_version then raise exception 'stale-update'; end if;
  if request_key_value is null then raise exception 'invalid-request'; end if;
  select * into v from public.camp_application_versions where application_id=a.id and request_key=request_key_value;
  if found then
    if v.input_version<>expected_input_version or private.camp_pdf_is_current(v) is distinct from true then raise exception 'stale-update'; end if;
    return v.id;
  end if;
  context_value:=private.camp_pdf_render_context(a.id);
  if context_value is null or jsonb_typeof(context_value)<>'object' or not context_value ?& array[
    'assignment_version','room_id','room_name','room_capacity','template_hash','settings_version','font_version','converter_image','mayor_name']
    or context_value->>'template_hash' !~ '^[0-9a-f]{64}$'
    or exists(select 1 from jsonb_each(context_value) where value='null'::jsonb) then raise exception 'pdf-prerequisites-unavailable'; end if;
  snapshot_value:=jsonb_build_object('user_name',a.user_name,'user_address',a.user_address,'user_phone',a.user_phone,
    'emergency_name',a.emergency_name,'emergency_address',a.emergency_address,'emergency_phone',a.emergency_phone,
    'start_date',a.start_date,'end_date',a.end_date,'purpose',a.purpose,'special_notes',a.special_notes,'usage_place',a.usage_place,
    'application_date',(clock_timestamp() at time zone 'Asia/Tokyo')::date,'render_context',context_value,
    'previously_approved',exists(select 1 from public.application_status_events where application_id=a.id and to_status='approved'));
  insert into public.camp_application_versions(application_id,camp_id,eligible_user_id,owner_id,version_no,request_key,
    input_version,room_plan_version,application_date,source_snapshot,source_hash,render_context)
  values(a.id,a.camp_id,a.camp_eligible_user_id,a.user_id,
    (select coalesce(max(version_no),0)+1 from public.camp_application_versions where application_id=a.id),request_key_value,
    a.input_version,(select room_plan_version from public.camps where id=a.camp_id),
    (clock_timestamp() at time zone 'Asia/Tokyo')::date,snapshot_value,
    encode(sha256(convert_to(snapshot_value::text,'UTF8')),'hex'),context_value) returning * into v;
  insert into public.camp_pdf_jobs(version_id) values(v.id);
  perform private.camp_pdf_audit(v.id,'pdf_requested',auth.uid(),jsonb_build_object('version_no',v.version_no));
  return v.id;
end $$;

create function public.claim_camp_pdf_job(target_job_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.camp_pdf_jobs%rowtype; v public.camp_application_versions%rowtype;
begin
  perform private.lock_calendar_facility();
  select * into j from public.camp_pdf_jobs where (target_job_id is null or id=target_job_id) and state='queued' and expires_at>clock_timestamp()
    and not exists(select 1 from public.camp_application_versions source_version join public.camp_application_versions newer
      on newer.application_id=source_version.application_id and newer.version_no>source_version.version_no where source_version.id=camp_pdf_jobs.version_id)
    order by created_at limit 1;
  if not found then
    if target_job_id is null then return null; end if;
    raise exception 'job-unavailable';
  end if;
  select * into v from public.camp_application_versions where id=j.version_id;
  begin
    if private.camp_pdf_is_current(v) is distinct from true then raise exception 'stale-update'; end if;
  exception when sqlstate '42501' or sqlstate 'P0001' then
    update public.camp_pdf_jobs set state='failed',error_code='generation-failed' where id=j.id;
    perform private.camp_pdf_audit(v.id,'pdf_generation_failed',null,'{"error_code":"generation-failed"}');
    return null;
  end;
  -- Facility -> owner/profile -> camp/eligible/application -> document/job.
  perform id from public.camp_application_versions where id=v.id for update;
  perform id from public.camp_pdf_jobs where id=j.id for update;
  update public.camp_pdf_jobs set state='running',attempt_id=gen_random_uuid(),lease_until=clock_timestamp()+interval '5 minutes'
    where id=j.id returning * into j;
  perform private.camp_pdf_audit(v.id,'pdf_generation_started');
  return jsonb_build_object('job_id',j.id,'version_id',v.id,'attempt_id',j.attempt_id,'lease_until',j.lease_until,
    'source_hash',v.source_hash,'source_snapshot',v.source_snapshot,'render_context',v.render_context,
    'object_path',v.id::text||'/'||j.attempt_id::text||'.pdf');
end $$;

-- Check immediately before upload; completion repeats the same checks afterward.
create function public.check_camp_pdf_attempt(target_job_id uuid,target_attempt_id uuid,source_hash_value text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.camp_pdf_jobs%rowtype; v public.camp_application_versions%rowtype;
begin
  perform private.lock_calendar_facility();
  select * into j from public.camp_pdf_jobs where id=target_job_id;
  if not found or target_attempt_id is null or j.attempt_id is distinct from target_attempt_id
    or j.state not in ('running','succeeded') or (j.state='running' and j.lease_until<=clock_timestamp()) then raise exception 'job-unavailable'; end if;
  select * into v from public.camp_application_versions where id=j.version_id;
  if j.state='succeeded' and v.source_hash=source_hash_value then
    return jsonb_build_object('committed',true,'pdf_hash',v.pdf_hash,'size_bytes',v.size_bytes,'validation',v.validation);
  end if;
  if v.state<>'pending' or v.source_hash is distinct from source_hash_value or private.camp_pdf_is_current(v) is distinct from true then raise exception 'stale-update'; end if;
  perform id from public.camp_application_versions where id=v.id for update;
  perform id from public.camp_pdf_jobs where id=j.id for update;
  return jsonb_build_object('version_id',v.id,'object_path',v.id::text||'/'||j.attempt_id::text||'.pdf');
end $$;

create function public.complete_camp_pdf_job(target_job_id uuid,target_attempt_id uuid,source_hash_value text,
  pdf_hash_value text,size_bytes_value integer,validation_value jsonb)
returns boolean language plpgsql security definer set search_path='' as $$
declare info jsonb; j public.camp_pdf_jobs%rowtype; v public.camp_application_versions%rowtype;
begin
  perform private.lock_calendar_facility();
  select * into j from public.camp_pdf_jobs where id=target_job_id;
  select * into v from public.camp_application_versions where id=j.version_id;
  -- Lost-response retry may acknowledge the exact committed artifact, never replace it.
  if j.state='succeeded' and j.attempt_id=target_attempt_id and v.source_hash=source_hash_value
    and v.pdf_hash=pdf_hash_value and v.size_bytes=size_bytes_value and v.validation=validation_value then return true; end if;
  info:=public.check_camp_pdf_attempt(target_job_id,target_attempt_id,source_hash_value);
  if info->>'committed'='true' then raise exception 'pdf-version-immutable'; end if;
  if pdf_hash_value is null or pdf_hash_value !~ '^[0-9a-f]{64}$' or size_bytes_value is null or size_bytes_value not between 1 and 3145728
    or validation_value is null or not (validation_value @> '{"page_count":1,"fonts_embedded":true,"text_verified":true,"layout_verified":true}'::jsonb)
    then raise exception 'invalid-pdf-result'; end if;
  update public.camp_application_versions set state='ready',object_path=info->>'object_path',pdf_hash=pdf_hash_value,
    size_bytes=size_bytes_value,validation=validation_value,generated_at=clock_timestamp() where id=(info->>'version_id')::uuid;
  update public.camp_pdf_jobs set state='succeeded' where id=target_job_id;
  perform private.camp_pdf_audit((info->>'version_id')::uuid,'pdf_ready');
  return true;
end $$;

create function public.fail_camp_pdf_job(target_job_id uuid,target_attempt_id uuid,error_code_value text)
returns boolean language plpgsql security definer set search_path='' as $$
declare j public.camp_pdf_jobs%rowtype;
begin
  perform private.lock_calendar_facility();
  select * into j from public.camp_pdf_jobs where id=target_job_id for update;
  if not found or j.state<>'running' or j.attempt_id is distinct from target_attempt_id or target_attempt_id is null then return false; end if;
  if error_code_value not in ('generation-failed','storage-failed','registration-failed') or error_code_value is null then raise exception 'invalid-request'; end if;
  update public.camp_pdf_jobs set state='failed',error_code=error_code_value where id=j.id;
  perform private.camp_pdf_audit(j.version_id,'pdf_generation_failed',null,jsonb_build_object('error_code',error_code_value));
  return true;
end $$;

-- A transport failure is an observation, not proof that completion rolled back.
-- Record it without changing state or deleting a possibly committed artifact.
create function public.record_camp_pdf_job_response_failure(target_job_id uuid,target_attempt_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare j public.camp_pdf_jobs%rowtype;
begin
  perform private.lock_calendar_facility();
  select * into j from public.camp_pdf_jobs where id=target_job_id and attempt_id=target_attempt_id;
  if found then perform private.camp_pdf_audit(j.version_id,'pdf_result_response_failed'); end if;
end $$;

-- Service-only: actor comes from getUser(JWT), never from a browser-supplied UUID.
-- Ordinary user RPCs never return a Storage path.
create function public.authorize_camp_pdf_delivery(target_version_id uuid,actor uuid,request_method text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.camp_application_versions%rowtype; staff boolean:=false; permitted boolean:=false;
begin
  if request_method not in ('GET','HEAD') or request_method is null then raise exception 'invalid-request'; end if;
  perform private.lock_calendar_facility();
  perform id from public.profiles where id=actor and account_state='active' for share;
  if found then
    perform user_id from public.staff_roles where user_id=actor for share;
    staff:=found;
    select * into v from public.camp_application_versions where id=target_version_id;
    if found then
      if staff and v.state='submitted' then permitted:=true;
      elsif v.owner_id=actor and v.state='ready' then
        begin permitted:=private.camp_pdf_is_current(v);
        exception when sqlstate '42501' or sqlstate 'P0001' then permitted:=false; end;
      end if;
    end if;
  end if;
  -- Unknown IDs are never inserted into audit, avoiding attacker-controlled growth.
  if v.id is not null then
    perform private.camp_pdf_audit(v.id,case when permitted then 'pdf_delivery_authorized' else 'pdf_delivery_denied' end,
      case when exists(select 1 from public.profiles where id=actor) then actor else null end,
      jsonb_build_object('method',request_method,'staff',staff));
  end if;
  if permitted is distinct from true then return jsonb_build_object('allowed',false); end if;
  return jsonb_build_object('allowed',true,'object_path',v.object_path,'pdf_hash',v.pdf_hash,'size_bytes',v.size_bytes);
end $$;

create function public.record_camp_pdf_delivery_failure(target_version_id uuid,actor uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from public.camp_application_versions where id=target_version_id) then
    perform private.camp_pdf_audit(target_version_id,'pdf_delivery_failed',
      case when exists(select 1 from public.profiles where id=actor) then actor else null end);
  end if;
end $$;

create function public.get_staff_camp_application_versions(target_application_id uuid)
returns table(version_id uuid,version_no bigint,application_date date,submitted_at timestamptz,pdf_hash text)
language plpgsql security definer set search_path='' as $$
begin
  perform private.lock_calendar_for_staff();
  return query select v.id,v.version_no,v.application_date,v.submitted_at,v.pdf_hash
    from public.camp_application_versions v where v.application_id=target_application_id and v.state='submitted' order by v.version_no desc;
end $$;

create function public.claim_camp_pdf_cleanup()
returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.camp_pdf_jobs%rowtype;
begin
  perform private.lock_calendar_facility();
  for j in update public.camp_pdf_jobs set state='expired',error_code='expired'
    where (state='queued' and expires_at<=clock_timestamp()) or (state='running' and lease_until<=clock_timestamp()) returning *
  loop perform private.camp_pdf_audit(j.version_id,'pdf_job_expired'); end loop;
  select q.* into j from public.camp_pdf_jobs q join public.camp_application_versions v on v.id=q.version_id
    where v.state='pending' and v.object_path is null and q.attempt_id is not null
      -- Grace period also exceeds the bounded worker HTTP/upload timeout.
      and q.lease_until<clock_timestamp()-interval '1 hour'
      and (q.state in ('failed','expired') or (q.state='cleaning' and q.cleanup_until<clock_timestamp()))
    order by q.created_at limit 1 for update of q;
  if not found then return null; end if;
  update public.camp_pdf_jobs set state='cleaning',cleanup_token=gen_random_uuid(),cleanup_until=clock_timestamp()+interval '5 minutes'
    where id=j.id returning * into j;
  perform private.camp_pdf_audit(j.version_id,'pdf_cleanup_reserved');
  return jsonb_build_object('job_id',j.id,'cleanup_token',j.cleanup_token,'object_path',j.version_id::text||'/'||j.attempt_id::text||'.pdf');
end $$;
create function public.complete_camp_pdf_cleanup(target_job_id uuid,token_value uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare j public.camp_pdf_jobs%rowtype;
begin
  perform private.lock_calendar_facility();
  select * into j from public.camp_pdf_jobs where id=target_job_id for update;
  if not found or j.state<>'cleaning' or token_value is null or j.cleanup_token is distinct from token_value then return false; end if;
  if exists(select 1 from public.camp_application_versions where id=j.version_id and (state<>'pending' or object_path is not null)) then raise exception 'pdf-retention-required'; end if;
  update public.camp_pdf_jobs set state='cleaned',cleanup_until=null where id=j.id;
  perform private.camp_pdf_audit(j.version_id,'pdf_orphan_removed');
  return true;
end $$;

-- Enumerate only A7 functions; do not touch existing grants.
do $$ declare f record; begin
  for f in select p.oid::regprocedure signature,n.nspname,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where (n.nspname='private' and p.proname in ('camp_pdf_render_context','camp_pdf_render_settings','camp_pdf_assignment_context','camp_pdf_audit','guard_camp_pdf_version','camp_pdf_owner_application','camp_pdf_is_current'))
      or (n.nspname='public' and p.proname in ('begin_camp_application_pdf','claim_camp_pdf_job','check_camp_pdf_attempt','complete_camp_pdf_job',
        'fail_camp_pdf_job','record_camp_pdf_job_response_failure','authorize_camp_pdf_delivery','record_camp_pdf_delivery_failure','get_staff_camp_application_versions','claim_camp_pdf_cleanup','complete_camp_pdf_cleanup'))
  loop
    execute format('revoke all on function %s from public,anon,authenticated,service_role',f.signature);
    if f.nspname='public' then
      execute format('grant execute on function %s to %I',f.signature,
        case when f.proname in ('begin_camp_application_pdf','get_staff_camp_application_versions') then 'authenticated' else 'service_role' end);
    end if;
  end loop;
end $$;
commit;
