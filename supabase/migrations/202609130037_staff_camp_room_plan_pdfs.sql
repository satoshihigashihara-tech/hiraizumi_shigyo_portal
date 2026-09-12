-- A11: immutable, staff-only PDFs of the latest complete eligible roster room plan.
begin;
select private.lock_calendar_facility();

create table public.camp_room_plan_pdf_versions (
  id uuid primary key default gen_random_uuid(),
  camp_id uuid not null references public.camps(id) on delete restrict,
  version_no bigint not null check(version_no>0),
  request_key uuid not null,
  roster_version bigint not null check(roster_version>0),
  roster_label_version bigint not null check(roster_label_version>=0),
  room_plan_version bigint not null check(room_plan_version>0),
  source_snapshot jsonb not null check(jsonb_typeof(source_snapshot)='object'),
  source_hash text not null check(source_hash ~ '^[0-9a-f]{64}$'),
  render_context jsonb not null check(jsonb_typeof(render_context)='object'),
  state text not null default 'pending' check(state in ('pending','ready')),
  object_path text unique,
  pdf_hash text check(pdf_hash ~ '^[0-9a-f]{64}$'),
  size_bytes integer check(size_bytes between 1 and 3145728),
  validation jsonb,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  generated_at timestamptz,
  unique(camp_id,version_no), unique(camp_id,request_key),
  check ((state='pending' and object_path is null and pdf_hash is null and size_bytes is null and validation is null and generated_at is null)
    or (state='ready' and object_path is not null and pdf_hash is not null and size_bytes is not null and validation is not null and generated_at is not null))
);
create table public.camp_room_plan_pdf_jobs (
  id uuid primary key default gen_random_uuid(),
  version_id uuid not null unique references public.camp_room_plan_pdf_versions(id) on delete restrict,
  state text not null default 'queued' check(state in ('queued','running','succeeded','failed','expired')),
  attempt_id uuid unique,
  lease_until timestamptz,
  expires_at timestamptz not null default clock_timestamp()+interval '15 minutes',
  error_code text check(error_code in ('generation-failed','storage-failed','expired')),
  created_at timestamptz not null default clock_timestamp()
);
alter table public.camp_room_plan_pdf_versions enable row level security;
alter table public.camp_room_plan_pdf_jobs enable row level security;
revoke all on public.camp_room_plan_pdf_versions,public.camp_room_plan_pdf_jobs from public,anon,authenticated,service_role;

create function private.guard_camp_room_plan_pdf_version()
returns trigger language plpgsql set search_path='' as $$
begin
  if tg_op='DELETE' then raise exception 'pdf-version-immutable'; end if;
  if tg_op='UPDATE' then
    if (to_jsonb(new)-array['state','object_path','pdf_hash','size_bytes','validation','generated_at']) is distinct from
       (to_jsonb(old)-array['state','object_path','pdf_hash','size_bytes','validation','generated_at'])
      or old.state<>'pending' or new.state<>'ready' then raise exception 'pdf-version-immutable'; end if;
  end if;
  return new;
end $$;
create trigger camp_room_plan_pdf_version_guard before update or delete on public.camp_room_plan_pdf_versions
for each row execute function private.guard_camp_room_plan_pdf_version();

create function private.camp_room_plan_pdf_snapshot(target_camp_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.camps%rowtype; entries jsonb; eligible_count integer; assignment_count integer;
begin
  select * into c from public.camps where id=target_camp_id and room_assignment_mode='eligible_roster' and deleted_at is null;
  if not found then raise exception 'not-found'; end if;
  if c.room_plan_committed_at is null or c.saved_roster_version is distinct from c.roster_version or c.room_plan_version<1 then
    raise exception 'room-plan-incomplete';
  end if;
  if not exists(select 1 from public.calendar_claims q where q.camp_id=c.id and q.claim_type='camp'
    and q.start_date=c.start_date and q.end_date=c.end_date and q.released_from is null) then raise exception 'calendar-inconsistent'; end if;
  select count(*) into eligible_count from public.camp_eligible_users e
    where e.camp_id=c.id and e.disabled_at is null and e.participation_status='participating';
  if eligible_count not between 1 and 15 then raise exception 'room-plan-incomplete'; end if;
  select count(*) into assignment_count from public.camp_room_assignments a
    join public.camp_eligible_users e on e.camp_id=a.camp_id and e.id=a.eligible_user_id
    join public.rooms r on r.id=a.room_id
    join public.camp_room_mapping m on m.room_id=r.id
    where a.camp_id=c.id and a.released_from is null and a.room_plan_version=c.room_plan_version
      and a.start_date=c.start_date and a.end_date=c.end_date
      and e.disabled_at is null and e.participation_status='participating'
      and nullif(btrim(e.management_name),'') is not null and char_length(btrim(e.management_name))<=200
      and m.assignment_enabled and m.printing_enabled and m.floor=2 and m.confirmed_at is not null
      and nullif(btrim(m.confirmation_evidence),'') is not null and nullif(btrim(m.print_name),'') is not null;
  if assignment_count<>eligible_count or exists(
    select 1 from public.camp_room_assignments a join public.rooms r on r.id=a.room_id
    where a.camp_id=c.id and a.released_from is null group by a.room_id,r.capacity having count(*)>r.capacity
  ) then raise exception 'room-plan-incomplete'; end if;
  if not exists(select 1 from public.camp_room_plan_versions p where p.camp_id=c.id and p.version=c.room_plan_version
    and p.roster_version=c.roster_version and p.start_date=c.start_date and p.end_date=c.end_date
    and jsonb_array_length(p.assignments)=eligible_count) then raise exception 'room-plan-incomplete'; end if;
  select jsonb_agg(jsonb_build_object('eligible_user_id',e.id,'management_name',e.management_name,
    'room_name',m.print_name,'start_date',a.start_date,'end_date',a.end_date)
    order by m.print_name,e.management_name,e.id) into entries
  from public.camp_eligible_users e join public.camp_room_assignments a on a.camp_id=e.camp_id and a.eligible_user_id=e.id
  join public.camp_room_mapping m on m.room_id=a.room_id
  where e.camp_id=c.id and e.disabled_at is null and e.participation_status='participating'
    and a.released_from is null and a.room_plan_version=c.room_plan_version;
  return jsonb_build_object('document_type','staff_room_plan','camp_id',c.id,'camp_name',c.name,
    'start_date',c.start_date,'end_date',c.end_date,'roster_version',c.roster_version,
    'roster_label_version',c.roster_label_version,'room_plan_version',c.room_plan_version,'entries',entries);
end $$;

create function private.camp_room_plan_pdf_context()
returns jsonb language plpgsql security definer set search_path='' as $$
declare s private.camp_pdf_render_setting_versions%rowtype;
begin
  select v.* into s from private.camp_pdf_active_render_setting a join private.camp_pdf_render_setting_versions v
    on v.settings_version=a.settings_version where a.singleton;
  if not found then raise exception 'pdf-prerequisites-unavailable'; end if;
  return jsonb_build_object('document_type','staff_room_plan','template_hash','01381635183d96b6cf8345372f94d1fc1a687e19c72fd6b5d88db562af071ecc',
    'settings_version',s.settings_version,'font_version',s.font_version,'converter_image',s.converter_image);
end $$;

create function private.camp_room_plan_pdf_is_current(v public.camp_room_plan_pdf_versions)
returns boolean language plpgsql security definer set search_path='' as $$
begin
  return v.source_snapshot=private.camp_room_plan_pdf_snapshot(v.camp_id)
    and v.render_context=private.camp_room_plan_pdf_context()
    and not exists(select 1 from public.camp_room_plan_pdf_versions n where n.camp_id=v.camp_id and n.version_no>v.version_no);
exception when sqlstate 'P0001' then return false;
end $$;

create function private.camp_room_plan_pdf_audit(version_id uuid,event_name text,actor uuid default null)
returns void language sql security definer set search_path='' as $$
 insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id)
 values('camp_room_plan_pdf',version_id,event_name,'{}','{}',case when actor is null then 'system' else 'staff' end,actor)
$$;

create function public.begin_staff_camp_room_plan_pdf(target_camp_id uuid,expected_roster_version bigint,
  expected_roster_label_version bigint,expected_room_plan_version bigint,request_key_value uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare snapshot_value jsonb; context_value jsonb; v public.camp_room_plan_pdf_versions%rowtype;
begin
  perform private.lock_calendar_for_staff();
  perform private.lock_calendar_facility();
  perform id from public.camps where id=target_camp_id for share;
  snapshot_value:=private.camp_room_plan_pdf_snapshot(target_camp_id);
  if request_key_value is null or (snapshot_value->>'roster_version')::bigint is distinct from expected_roster_version
    or (snapshot_value->>'roster_label_version')::bigint is distinct from expected_roster_label_version
    or (snapshot_value->>'room_plan_version')::bigint is distinct from expected_room_plan_version then raise exception 'stale-update'; end if;
  select * into v from public.camp_room_plan_pdf_versions where camp_id=target_camp_id and request_key=request_key_value;
  if found then
    if private.camp_room_plan_pdf_is_current(v) then return v.id; end if;
    raise exception 'stale-update';
  end if;
  context_value:=private.camp_room_plan_pdf_context();
  insert into public.camp_room_plan_pdf_versions(camp_id,version_no,request_key,roster_version,roster_label_version,
    room_plan_version,source_snapshot,source_hash,render_context,created_by)
  values(target_camp_id,(select coalesce(max(version_no),0)+1 from public.camp_room_plan_pdf_versions where camp_id=target_camp_id),
    request_key_value,expected_roster_version,expected_roster_label_version,expected_room_plan_version,snapshot_value,
    encode(sha256(convert_to(snapshot_value::text,'UTF8')),'hex'),context_value,auth.uid()) returning * into v;
  insert into public.camp_room_plan_pdf_jobs(version_id) values(v.id);
  perform private.camp_room_plan_pdf_audit(v.id,'room_plan_pdf_requested',auth.uid());
  return v.id;
end $$;

create function public.get_staff_camp_room_plan_pdf(target_camp_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.camp_room_plan_pdf_versions%rowtype; snapshot_value jsonb;
begin
  perform private.lock_calendar_for_staff();
  snapshot_value:=private.camp_room_plan_pdf_snapshot(target_camp_id);
  select * into v from public.camp_room_plan_pdf_versions where camp_id=target_camp_id order by version_no desc limit 1;
  return jsonb_build_object('camp_id',target_camp_id,'roster_version',snapshot_value->'roster_version',
    'roster_label_version',snapshot_value->'roster_label_version','room_plan_version',snapshot_value->'room_plan_version',
    'version_id',case when v.id is not null and private.camp_room_plan_pdf_is_current(v) then to_jsonb(v.id) else 'null'::jsonb end,
    'state',case when v.id is not null and private.camp_room_plan_pdf_is_current(v) then to_jsonb(v.state) else 'null'::jsonb end);
end $$;

create function public.claim_camp_room_plan_pdf_job(target_job_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.camp_room_plan_pdf_jobs%rowtype; v public.camp_room_plan_pdf_versions%rowtype;
begin
  perform private.lock_calendar_facility();
  select * into j from public.camp_room_plan_pdf_jobs where (target_job_id is null or id=target_job_id)
    and state='queued' and expires_at>clock_timestamp() order by created_at limit 1 for update skip locked;
  if not found then return null; end if;
  select * into v from public.camp_room_plan_pdf_versions where id=j.version_id for update;
  if private.camp_room_plan_pdf_is_current(v) is distinct from true then
    update public.camp_room_plan_pdf_jobs set state='failed',error_code='generation-failed' where id=j.id; return null;
  end if;
  update public.camp_room_plan_pdf_jobs set state='running',attempt_id=gen_random_uuid(),lease_until=clock_timestamp()+interval '5 minutes'
    where id=j.id returning * into j;
  perform private.camp_room_plan_pdf_audit(v.id,'room_plan_pdf_generation_started');
  return jsonb_build_object('document_type','staff_room_plan','job_id',j.id,'version_id',v.id,'attempt_id',j.attempt_id,
    'source_hash',v.source_hash,'source_snapshot',v.source_snapshot,'render_context',v.render_context,
    'object_path','room-plans/'||v.id::text||'/'||j.attempt_id::text||'.pdf');
end $$;

create function public.check_camp_room_plan_pdf_attempt(target_job_id uuid,target_attempt_id uuid,source_hash_value text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.camp_room_plan_pdf_jobs%rowtype; v public.camp_room_plan_pdf_versions%rowtype;
begin
  perform private.lock_calendar_facility();
  select * into j from public.camp_room_plan_pdf_jobs where id=target_job_id for update;
  if not found or j.state not in ('running','succeeded') or j.attempt_id is distinct from target_attempt_id
    or (j.state='running' and j.lease_until<=clock_timestamp()) then raise exception 'job-unavailable'; end if;
  select * into v from public.camp_room_plan_pdf_versions where id=j.version_id for update;
  if j.state='succeeded' and v.source_hash=source_hash_value then return jsonb_build_object('committed',true,'pdf_hash',v.pdf_hash,'size_bytes',v.size_bytes,'validation',v.validation); end if;
  if v.state<>'pending' or v.source_hash is distinct from source_hash_value or private.camp_room_plan_pdf_is_current(v) is distinct from true then raise exception 'stale-update'; end if;
  return jsonb_build_object('version_id',v.id,'object_path','room-plans/'||v.id::text||'/'||j.attempt_id::text||'.pdf');
end $$;

create function public.complete_camp_room_plan_pdf_job(target_job_id uuid,target_attempt_id uuid,source_hash_value text,
  pdf_hash_value text,size_bytes_value integer,validation_value jsonb)
returns boolean language plpgsql security definer set search_path='' as $$
declare info jsonb; j public.camp_room_plan_pdf_jobs%rowtype; v public.camp_room_plan_pdf_versions%rowtype;
begin
  perform private.lock_calendar_facility();
  select * into j from public.camp_room_plan_pdf_jobs where id=target_job_id;
  select * into v from public.camp_room_plan_pdf_versions where id=j.version_id;
  if j.state='succeeded' and j.attempt_id=target_attempt_id and v.source_hash=source_hash_value and v.pdf_hash=pdf_hash_value
    and v.size_bytes=size_bytes_value and v.validation=validation_value then return true; end if;
  info:=public.check_camp_room_plan_pdf_attempt(target_job_id,target_attempt_id,source_hash_value);
  if pdf_hash_value !~ '^[0-9a-f]{64}$' or size_bytes_value not between 1 and 3145728
    or validation_value is null or jsonb_typeof(validation_value)<>'object'
    or coalesce(validation_value->>'page_count','') !~ '^[1-8]$'
    or not (validation_value @> '{"fonts_embedded":true,"text_verified":true,"layout_verified":true}'::jsonb)
    or (validation_value->>'page_count')::integer not between 1 and 8 then raise exception 'invalid-pdf-result'; end if;
  update public.camp_room_plan_pdf_versions set state='ready',object_path=info->>'object_path',pdf_hash=pdf_hash_value,
    size_bytes=size_bytes_value,validation=validation_value,generated_at=clock_timestamp() where id=(info->>'version_id')::uuid;
  update public.camp_room_plan_pdf_jobs set state='succeeded' where id=target_job_id;
  perform private.camp_room_plan_pdf_audit((info->>'version_id')::uuid,'room_plan_pdf_ready'); return true;
end $$;

create function public.fail_camp_room_plan_pdf_job(target_job_id uuid,target_attempt_id uuid,error_code_value text)
returns boolean language plpgsql security definer set search_path='' as $$
declare j public.camp_room_plan_pdf_jobs%rowtype;
begin
  perform private.lock_calendar_facility();
  select * into j from public.camp_room_plan_pdf_jobs where id=target_job_id for update;
  if not found or j.state<>'running' or j.attempt_id is distinct from target_attempt_id then return false; end if;
  if error_code_value not in ('generation-failed','storage-failed') then raise exception 'invalid-request'; end if;
  update public.camp_room_plan_pdf_jobs set state='failed',error_code=error_code_value where id=j.id;
  perform private.camp_room_plan_pdf_audit(j.version_id,'room_plan_pdf_generation_failed'); return true;
end $$;

create function public.authorize_camp_room_plan_pdf_delivery(target_version_id uuid,actor uuid,request_method text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.camp_room_plan_pdf_versions%rowtype;
begin
  if request_method not in ('GET','HEAD') then raise exception 'invalid-request'; end if;
  perform private.lock_calendar_facility();
  perform p.id from public.profiles p join public.staff_roles s on s.user_id=p.id where p.id=actor and p.account_state='active' for share;
  if not found then return jsonb_build_object('allowed',false); end if;
  select * into v from public.camp_room_plan_pdf_versions where id=target_version_id;
  if not found or v.state<>'ready' or private.camp_room_plan_pdf_is_current(v) is distinct from true then return jsonb_build_object('allowed',false); end if;
  perform private.camp_room_plan_pdf_audit(v.id,'room_plan_pdf_delivery_authorized',actor);
  return jsonb_build_object('allowed',true,'document_type','staff_room_plan','object_path',v.object_path,'pdf_hash',v.pdf_hash,'size_bytes',v.size_bytes);
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure signature,n.nspname,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where p.proname like '%camp_room_plan_pdf%'
  loop
    execute format('revoke all on function %s from public,anon,authenticated,service_role',f.signature);
    if f.nspname='public' then execute format('grant execute on function %s to %I',f.signature,
      case when f.proname in ('begin_staff_camp_room_plan_pdf','get_staff_camp_room_plan_pdf') then 'authenticated' else 'service_role' end); end if;
  end loop;
end $$;
commit;
