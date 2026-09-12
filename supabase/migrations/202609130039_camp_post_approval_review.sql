-- A10: pre-arrival room changes and review of immutable submitted camp PDFs.
-- No data backfill, mode switch, render-setting activation or storage mutation.
begin;
select private.lock_calendar_facility();

create function private.lock_camp_roster_review_scope(target_camp_id uuid)
returns public.camps language plpgsql security definer set search_path='' as $$
declare c public.camps%rowtype;
begin
  perform private.lock_calendar_for_staff();
  -- Status/cleanup triggers touch owner profiles. Lock these before the camp.
  perform p.id from public.profiles p where p.id in (
    select a.user_id from public.applications a where a.camp_id=target_camp_id
    union select e.linked_user_id from public.camp_eligible_users e where e.camp_id=target_camp_id)
    order by p.id for update;
  select * into c from public.camps where id=target_camp_id and deleted_at is null for update;
  if not found then raise exception 'not-found'; end if;
  if c.room_assignment_mode<>'eligible_roster' then raise exception 'eligible-roster-required'; end if;
  perform r.id from public.rooms r order by r.id for share;
  perform m.room_id from public.camp_room_mapping m order by m.room_id for share;
  perform e.id from public.camp_eligible_users e where e.camp_id=c.id order by e.id for update;
  perform a.id from public.applications a where a.camp_id=c.id order by a.id for update;
  perform s.id from public.stays s join public.applications a on a.id=s.application_id
    where a.camp_id=c.id order by s.application_id for update of s;
  perform r.id from public.camp_room_assignments r where r.camp_id=c.id order by r.eligible_user_id for update;
  perform q.id from public.calendar_claims q where q.camp_id=c.id for update;
  perform v.id from public.camp_application_versions v where v.camp_id=c.id order by v.id for share;
  if not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
  return c;
end $$;

-- READ COMMITTED readers take the same locks as writes, pairing every expected
-- timestamp with the displayed application, including an absent application.
create function public.get_staff_camp_room_change_context(target_camp_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.camps%rowtype;
begin
  c:=private.lock_camp_roster_review_scope(target_camp_id);
  return public.get_staff_camp_room_plan(c.id)||jsonb_build_object(
    'proposed_revision_due_at',case when c.start_date>(clock_timestamp() at time zone 'Asia/Tokyo')::date
      then private.camp_roster_revision_deadline(c.start_date,clock_timestamp()) end,
    'can_change',c.start_date>(clock_timestamp() at time zone 'Asia/Tokyo')::date
      and not exists(select 1 from public.stays s join public.applications a on a.id=s.application_id
        where a.camp_id=c.id and s.status in ('staying','moved_out')),
    'participants',(select coalesce(jsonb_agg(jsonb_build_object('eligible_user_id',e.id,
      'updated_at',e.updated_at,'application_id',a.id,'application_updated_at',a.updated_at,
      'application_status',a.status,'stay_status',s.status,'revision_due_at',a.revision_due_at) order by e.id),'[]')
      from public.camp_eligible_users e left join lateral (select x.* from public.applications x
        where x.camp_id=c.id and x.camp_eligible_user_id=e.id
        order by (x.status not in ('rejected','cancelled')) desc,x.created_at desc,x.id limit 1) a on true
      left join public.stays s on s.application_id=a.id
      where e.camp_id=c.id and e.disabled_at is null and e.participation_status='participating'));
end $$;

create function private.camp_roster_revision_deadline(starts_on date,moment timestamptz)
returns timestamptz language plpgsql set search_path='' as $$
declare due timestamptz;
begin
  due:=least((((moment at time zone 'Asia/Tokyo')::date+4)::timestamp at time zone 'Asia/Tokyo'),
    starts_on::timestamp at time zone 'Asia/Tokyo');
  if starts_on is null or moment is null or due<=moment then raise exception 'camp-started'; end if;
  return due;
end $$;

create function private.assert_camp_roster_review_stay(target_application_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare a public.applications%rowtype; s public.stays%rowtype; previously_approved boolean;
begin
  select * into a from public.applications where id=target_application_id;
  select * into s from public.stays where application_id=a.id;
  select exists(select 1 from public.application_status_events where application_id=a.id and to_status='approved') into previously_approved;
  if (previously_approved and s.id is null) or (not previously_approved and (s.id is not null or a.status='approved'))
    or (s.id is not null and (s.status<>'before_move_in' or s.checked_in_at is not null or s.checked_out_at is not null)) then
    raise exception 'invalid-stay';
  end if;
end $$;

create function public.change_camp_rooms_and_request_revisions(target_camp_id uuid,expected_roster_version bigint,
  expected_room_plan_version bigint,submitted_assignments jsonb,expected_participants jsonb,change_reason text,confirmed boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.camps%rowtype; payload jsonb; snapshot jsonb; before_value jsonb;
  member_count integer; plan_version bigint; claim public.calendar_claims%rowtype;
  expected record; member record; app public.applications%rowtype; stay public.stays%rowtype;
  moment timestamptz; revision_due timestamptz; changed_ids uuid[]; revised_ids uuid[]:='{}';
begin
  c:=private.lock_camp_roster_review_scope(target_camp_id);
  perform private.check_calendar_reason(change_reason);
  if confirmed is distinct from true then raise exception 'confirmation-required'; end if;
  select * into c from public.camps where id=target_camp_id and deleted_at is null for update;
  if not found then raise exception 'not-found'; end if;
  if c.room_assignment_mode<>'eligible_roster' then raise exception 'eligible-roster-required'; end if;
  if expected_roster_version is null or expected_room_plan_version is null or least(expected_roster_version,expected_room_plan_version)<0 then raise exception 'invalid-version'; end if;
  if (c.roster_version,c.room_plan_version) is distinct from (expected_roster_version,expected_room_plan_version) then raise exception 'stale-update'; end if;
  if submitted_assignments is null or jsonb_typeof(submitted_assignments)<>'array' then raise exception 'invalid-assignments'; end if;
  if jsonb_array_length(submitted_assignments) not between 1 and 15 then raise exception 'invalid-assignments'; end if;
  if exists(select 1 from jsonb_array_elements(submitted_assignments) x where jsonb_typeof(x)<>'object'
    or not (x ?& array['eligible_user_id','room_id']) or x-array['eligible_user_id','room_id']<>'{}'::jsonb
    or jsonb_typeof(x->'eligible_user_id')<>'string' or jsonb_typeof(x->'room_id')<>'string') then raise exception 'invalid-assignments'; end if;
  begin
    select jsonb_agg(jsonb_build_object('eligible_user_id',(x->>'eligible_user_id')::uuid,'room_id',(x->>'room_id')::uuid)
      order by (x->>'eligible_user_id')::uuid) into payload from jsonb_array_elements(submitted_assignments) x;
  exception when invalid_text_representation then raise exception 'invalid-assignments'; end;
  if (select count(distinct x->>'eligible_user_id') from jsonb_array_elements(payload) x)<>jsonb_array_length(payload) then raise exception 'duplicate-assignment'; end if;
  if not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
  if c.start_date<=(clock_timestamp() at time zone 'Asia/Tokyo')::date
    or exists(select 1 from public.stays s join public.applications a on a.id=s.application_id where a.camp_id=c.id and s.status in ('staying','moved_out')) then raise exception 'camp-started'; end if;
  select count(*) into member_count from public.camp_eligible_users where camp_id=c.id and disabled_at is null and participation_status='participating';
  if member_count>15 then raise exception 'facility-capacity-full'; end if;
  if member_count<>jsonb_array_length(payload) or exists(select 1 from jsonb_array_elements(payload) x
    left join public.camp_eligible_users e on e.id=(x->>'eligible_user_id')::uuid and e.camp_id=c.id
    where e.id is null or e.disabled_at is not null or e.participation_status<>'participating') then raise exception 'invalid-roster'; end if;
  if exists(select 1 from jsonb_array_elements(payload) x left join public.camp_room_mapping m on m.room_id=(x->>'room_id')::uuid
    where m.room_id is null or not m.assignment_enabled or not m.printing_enabled or m.floor<>2
      or m.confirmed_at is null or nullif(btrim(m.confirmation_evidence),'') is null) then raise exception 'room-not-confirmed'; end if;
  if exists(select 1 from jsonb_array_elements(payload) x join public.rooms r on r.id=(x->>'room_id')::uuid
    group by r.id,r.capacity having count(*)>r.capacity) then raise exception 'room-capacity-full'; end if;
  -- Never revive a released allocation, or discard an occupied allocation outside the roster.
  if exists(select 1 from public.camp_room_assignments r where r.camp_id=c.id and
    ((r.released_from is not null and exists(select 1 from jsonb_array_elements(payload) x where (x->>'eligible_user_id')::uuid=r.eligible_user_id))
    or (r.released_from is null and not exists(select 1 from jsonb_array_elements(payload) x where (x->>'eligible_user_id')::uuid=r.eligible_user_id)))) then raise exception 'roster-lifecycle-required'; end if;
  -- The expectation includes absence of an application; do not silently adopt a
  -- submission made since the staff member reviewed the proposed changes.
  if expected_participants is null or jsonb_typeof(expected_participants)<>'array'
    or jsonb_array_length(expected_participants)<>member_count then raise exception 'invalid-expectations'; end if;
  if exists(select 1 from jsonb_array_elements(expected_participants) x where jsonb_typeof(x)<>'object'
    or not x ?& array['eligible_user_id','updated_at','application_id','application_updated_at']
    or x-array['eligible_user_id','updated_at','application_id','application_updated_at']<>'{}') then
    raise exception 'invalid-expectations'; end if;
  begin
    if (select count(distinct (x->>'eligible_user_id')::uuid) from jsonb_array_elements(expected_participants) x)<>member_count then
      raise exception 'invalid-expectations'; end if;
    for expected in select * from jsonb_to_recordset(expected_participants)
      as x(eligible_user_id uuid,updated_at timestamptz,application_id uuid,application_updated_at timestamptz) loop
      select e.* into member from public.camp_eligible_users e where e.id=expected.eligible_user_id
        and e.camp_id=c.id and e.disabled_at is null and e.participation_status='participating';
      if not found then raise exception 'invalid-expectations'; end if;
      perform private.check_calendar_version(member.updated_at,expected.updated_at);
      select a.* into app from public.applications a where a.camp_id=c.id and a.camp_eligible_user_id=member.id
        order by (a.status not in ('rejected','cancelled')) desc,a.created_at desc,a.id limit 1;
      if app.id is distinct from expected.application_id then raise exception 'stale-update'; end if;
      if app.id is not null then perform private.check_calendar_version(app.updated_at,expected.application_updated_at);
      elsif expected.application_updated_at is not null then raise exception 'invalid-expectations'; end if;
    end loop;
  exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then
    raise exception 'invalid-expectations';
  end;
  select coalesce(array_agg((x->>'eligible_user_id')::uuid),'{}') into changed_ids
    from jsonb_array_elements(payload) x left join public.camp_room_assignments r
      on r.camp_id=c.id and r.eligible_user_id=(x->>'eligible_user_id')::uuid
    where (r.room_id,r.start_date,r.end_date) is distinct from ((x->>'room_id')::uuid,c.start_date,c.end_date);
  moment:=clock_timestamp();
  revision_due:=private.camp_roster_revision_deadline(c.start_date,moment);
  for app in select a.* from public.applications a where a.camp_id=c.id
    and a.camp_eligible_user_id=any(changed_ids) and a.status not in ('rejected','cancelled') order by a.id loop
    if app.usage_type<>'camp' or (app.start_date,app.end_date) is distinct from (c.start_date,c.end_date)
      or not exists(select 1 from public.camp_eligible_users e join public.profiles p on p.id=e.linked_user_id
        where e.id=app.camp_eligible_user_id and e.camp_id=c.id and p.id=app.user_id and p.account_state='active') then
      raise exception 'invalid-status'; end if;
    perform private.assert_camp_roster_review_stay(app.id);
    if app.status not in ('draft','submitted','under_review','revision_requested','approved') then raise exception 'invalid-status'; end if;
    if app.status<>'draft' and (app.submitted_at is null or app.latest_submitted_camp_pdf_version_id is null) then raise exception 'submitted-pdf-inconsistent'; end if;
    if app.status='revision_requested' and (app.revision_due_at is null or app.revision_due_at<=moment) then raise exception 'deadline-passed'; end if;
  end loop;
  -- Historical released rows can still occupy the saved period; count each person once per day.
  if exists(with occupied as (
    select (x->>'room_id')::uuid room_id,c.start_date starts,c.end_date ends from jsonb_array_elements(payload) x
    union all select r.room_id,r.start_date,least(r.end_date,r.released_from-1) from public.camp_room_assignments r
      where r.camp_id=c.id and r.released_from is not null)
    select 1 from generate_series(0,c.end_date-c.start_date) d
    join occupied o on c.start_date+d between o.starts and o.ends join public.rooms r on r.id=o.room_id
    group by d,r.id,r.capacity having count(*)>r.capacity) then raise exception 'room-capacity-full'; end if;
  if exists(select 1 from generate_series(0,c.end_date-c.start_date) d where member_count+
    (select count(*) from public.camp_room_assignments r where r.camp_id=c.id and r.released_from is not null
      and c.start_date+d between r.start_date and r.end_date and c.start_date+d<r.released_from)>15) then raise exception 'facility-capacity-full'; end if;
  select * into claim from public.calendar_claims where camp_id=c.id for update;
  if found and (claim.start_date,claim.end_date,claim.released_from) is distinct from (c.start_date,c.end_date,null::date) then raise exception 'calendar-inconsistent'; end if;
  if c.room_plan_committed_at is not null and claim.id is null then raise exception 'calendar-inconsistent'; end if;
  begin perform private.assert_calendar_available(c.start_date,c.end_date,c.id);
  exception when sqlstate 'P0001' then raise exception using message='date-conflict',detail=''; end;
  plan_version:=c.room_plan_version+1;
  select coalesce(jsonb_agg(to_jsonb(r) order by r.eligible_user_id),'[]') into before_value from public.camp_room_assignments r where r.camp_id=c.id;
  select jsonb_agg(jsonb_build_object('eligible_user_id',(x->>'eligible_user_id')::uuid,'room_id',(x->>'room_id')::uuid,
    'capacity',room.capacity,'assignment_version',coalesce(r.assignment_version,0)+case when r.id is null or
      (r.room_id,r.start_date,r.end_date) is distinct from ((x->>'room_id')::uuid,c.start_date,c.end_date) then 1 else 0 end,
    'released_from',null) order by x->>'eligible_user_id') into snapshot
    from jsonb_array_elements(payload) x join public.rooms room on room.id=(x->>'room_id')::uuid
    left join public.camp_room_assignments r on r.camp_id=c.id and r.eligible_user_id=(x->>'eligible_user_id')::uuid;
  snapshot:=snapshot||coalesce((select jsonb_agg(jsonb_build_object('eligible_user_id',r.eligible_user_id,
    'room_id',r.room_id,'capacity',room.capacity,'assignment_version',r.assignment_version,'released_from',r.released_from)
    order by r.eligible_user_id) from public.camp_room_assignments r join public.rooms room on room.id=r.room_id
    where r.camp_id=c.id and r.released_from is not null),'[]');
  if cardinality(changed_ids)=0 and c.saved_roster_version=c.roster_version then
    return jsonb_build_object('camp_id',c.id,'roster_version',c.roster_version::text,'room_plan_version',c.room_plan_version::text,
      'changed_ids','[]'::jsonb,'revised_ids','[]'::jsonb,'changed',false);
  end if;
  insert into public.camp_room_plan_versions(camp_id,version,roster_version,start_date,end_date,assignments,actor_user_id)
    values(c.id,plan_version,c.roster_version,c.start_date,c.end_date,snapshot,auth.uid());
  insert into public.camp_room_assignments(camp_id,eligible_user_id,room_id,assignment_version,room_plan_version,start_date,end_date)
    select c.id,(x->>'eligible_user_id')::uuid,(x->>'room_id')::uuid,(x->>'assignment_version')::bigint,plan_version,c.start_date,c.end_date
    from jsonb_array_elements(snapshot) x where x->>'released_from' is null
    on conflict(camp_id,eligible_user_id) do update set room_id=excluded.room_id,assignment_version=excluded.assignment_version,
      room_plan_version=excluded.room_plan_version,start_date=excluded.start_date,end_date=excluded.end_date,updated_at=clock_timestamp();
  update public.camps set room_plan_version=plan_version,saved_roster_version=c.roster_version,
    room_plan_committed_at=coalesce(room_plan_committed_at,clock_timestamp()) where id=c.id;
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id,reason)
    values('camp',c.id,'change_camp_rooms_and_request_revisions',jsonb_build_object('version',c.room_plan_version,'assignments',before_value),
      jsonb_build_object('version',plan_version,'roster_version',c.roster_version,'assignments',snapshot),'staff',auth.uid(),btrim(change_reason));
  for app in select a.* from public.applications a where a.camp_id=c.id and a.camp_eligible_user_id=any(changed_ids)
    and a.status in ('submitted','under_review','revision_requested','approved') order by a.id loop
    update public.applications set status='revision_requested',decision_reason=btrim(change_reason),
      revision_due_at=case when app.status='revision_requested' then app.revision_due_at else revision_due end where id=app.id;
    if app.status<>'revision_requested' then
      insert into public.application_status_events(application_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
        values(app.id,app.status,'revision_requested',btrim(change_reason),auth.uid(),moment);
    end if;
    insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id,reason)
      values('application',app.id,'camp_room_change_revision',
        jsonb_build_object('status',app.status,'revision_due_at',app.revision_due_at,'submitted_pdf_version_id',app.latest_submitted_camp_pdf_version_id),
        jsonb_build_object('status','revision_requested','revision_due_at',case when app.status='revision_requested' then app.revision_due_at else revision_due end,
          'room_plan_version',plan_version),'staff',auth.uid(),btrim(change_reason));
    revised_ids:=array_append(revised_ids,app.id);
  end loop;
  return jsonb_build_object('camp_id',c.id,'roster_version',c.roster_version::text,'room_plan_version',plan_version::text,
    'changed_ids',to_jsonb(changed_ids),'revised_ids',to_jsonb(revised_ids),'changed',true);
end $$;
-- Check the latest immutable plan, which also includes unchanged assignments
-- retained by A4. A member need not have changed in every camp plan version.
create or replace function private.camp_pdf_assignment_context(target_application_id uuid)
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
    or assignment.room_plan_version>c.room_plan_version then raise exception 'pdf-assignment-unavailable'; end if;
  select * into mapping from public.camp_room_mapping where room_id=assignment.room_id;
  if not found or not mapping.assignment_enabled or not mapping.printing_enabled or mapping.floor<>2
    or mapping.confirmed_at is null or nullif(btrim(mapping.confirmation_evidence),'') is null then raise exception 'pdf-room-not-printable'; end if;
  select * into room from public.rooms where id=assignment.room_id;
  select * into plan from public.camp_room_plan_versions where camp_id=c.id and version=c.room_plan_version;
  if not found or plan.start_date<>c.start_date or plan.end_date<>c.end_date or not plan.assignments @>
    jsonb_build_array(jsonb_build_object('eligible_user_id',a.camp_eligible_user_id,'room_id',room.id,
      'assignment_version',assignment.assignment_version,'capacity',room.capacity,'released_from',null)) then raise exception 'pdf-assignment-unavailable'; end if;
  if not exists(select 1 from public.calendar_claims q where q.camp_id=c.id and q.claim_type='camp'
    and q.start_date=c.start_date and q.end_date=c.end_date and q.released_from is null) then raise exception 'pdf-calendar-unavailable'; end if;
  -- roster_version can advance when another eligible user is added. Existing
  -- valid individual assignments stay usable; roster completeness is A11's gate.
  return jsonb_build_object('assignment_version',assignment.assignment_version,'assignment_id',assignment.id,
    'room_id',room.id,'room_name',mapping.print_name,'room_capacity',room.capacity,
    'room_plan_version',c.room_plan_version,'start_date',assignment.start_date,'end_date',assignment.end_date);
end $$;

-- A submitted PDF is historical. Review checks its own assignment and input,
-- not today's application date, today's active template, or another member's plan.
create function private.assert_camp_roster_submitted_pdf(target_application_id uuid)
returns public.camp_application_versions language plpgsql security definer set search_path='' as $$
declare a public.applications%rowtype; v public.camp_application_versions%rowtype; live jsonb; fields text[];
begin
  select * into a from public.applications where id=target_application_id;
  select * into v from public.camp_application_versions where id=a.latest_submitted_camp_pdf_version_id for share;
  if not found or v.state<>'submitted' or v.application_id<>a.id or v.camp_id is distinct from a.camp_id
    or v.eligible_user_id is distinct from a.camp_eligible_user_id or v.owner_id is distinct from a.user_id
    or v.input_version<>a.input_version or a.submitted_at is null or a.last_submitted_at is distinct from v.submitted_at
    or exists(select 1 from public.camp_application_versions n where n.application_id=a.id and n.state='submitted' and n.version_no>v.version_no)
    or v.source_hash<>encode(sha256(convert_to(v.source_snapshot::text,'UTF8')),'hex')
    or v.validation is null or not v.validation @> '{"page_count":1,"fonts_embedded":true,"text_verified":true,"layout_verified":true}'::jsonb
    or not exists(select 1 from public.camp_pdf_jobs j where j.version_id=v.id and j.state='succeeded') then
    raise exception 'submitted-pdf-inconsistent';
  end if;
  fields:=array['user_name','user_address','user_phone','emergency_name','emergency_address','emergency_phone',
    'start_date','end_date','purpose','special_notes','usage_place'];
  if exists(select 1 from unnest(fields) key where v.source_snapshot->key is distinct from to_jsonb(a)->key) then
    raise exception 'submitted-pdf-inconsistent'; end if;
  live:=private.camp_pdf_assignment_context(a.id);
  fields:=array['assignment_id','assignment_version','room_id','start_date','end_date'];
  if exists(select 1 from unnest(fields) key where v.render_context->key is distinct from live->key) then
    raise exception 'submitted-pdf-inconsistent'; end if;
  return v;
end $$;

create function public.review_camp_roster_application(target_camp_id uuid,target_application_id uuid,
  expected_updated_at timestamptz,expected_room_plan_version bigint,expected_assignment_version bigint,
  expected_submitted_version_id uuid,review_action text,public_reason text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.camps%rowtype; a public.applications%rowtype; e public.camp_eligible_users%rowtype;
  r public.camp_room_assignments%rowtype; v public.camp_application_versions%rowtype;
  moment timestamptz; due timestamptz; next_status text; before_value jsonb;
begin
  c:=private.lock_camp_roster_review_scope(target_camp_id);
  select * into a from public.applications where id=target_application_id and camp_id=c.id and usage_type='camp';
  if not found then raise exception 'not-found'; end if;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  select * into e from public.camp_eligible_users where id=a.camp_eligible_user_id and camp_id=c.id;
  if not found or e.linked_user_id is distinct from a.user_id or e.disabled_at is not null
    or e.participation_status<>'participating' or not exists(select 1 from public.profiles p where p.id=a.user_id and p.account_state='active') then
    raise exception 'invalid-status'; end if;
  select * into r from public.camp_room_assignments where eligible_user_id=e.id and camp_id=c.id;
  if expected_room_plan_version is null or expected_assignment_version is null or expected_submitted_version_id is null then
    raise exception 'invalid-version'; end if;
  if c.room_plan_version<>expected_room_plan_version or r.assignment_version is distinct from expected_assignment_version
    or a.latest_submitted_camp_pdf_version_id is distinct from expected_submitted_version_id then raise exception 'stale-update'; end if;
  if review_action is null or review_action not in ('start_review','request_revision','approve') then raise exception 'invalid-action'; end if;
  if (review_action='start_review' and a.status<>'submitted') or (review_action<>'start_review' and a.status<>'under_review') then
    raise exception 'invalid-status'; end if;
  if review_action='request_revision' then perform private.check_calendar_reason(public_reason);
  elsif char_length(btrim(public_reason))>2000 then raise exception 'reason-too-long'; end if;
  moment:=clock_timestamp();
  if c.start_date<=(moment at time zone 'Asia/Tokyo')::date then raise exception 'camp-started'; end if;
  perform private.assert_camp_roster_review_stay(a.id);
  v:=private.assert_camp_roster_submitted_pdf(a.id);
  if not exists(select 1 from public.reception_numbers where application_id=a.id)
    or not exists(select 1 from public.application_charges q where q.application_id=a.id
      and q.total_amount=(select coalesce(sum(m.amount),0) from public.charge_months m where m.charge_id=q.id)) then
    raise exception 'application-inconsistent'; end if;
  -- Recheck live occupancy rather than trusting the historical PDF's capacity.
  if exists(select 1 from generate_series(c.start_date::timestamp,c.end_date::timestamp,interval '1 day') d
    join public.camp_room_assignments x on x.camp_id=c.id and d::date between x.start_date and x.end_date
      and (x.released_from is null or d::date<x.released_from)
    join public.rooms room on room.id=x.room_id group by d,room.id,room.capacity having count(*)>room.capacity)
    or exists(select 1 from generate_series(c.start_date::timestamp,c.end_date::timestamp,interval '1 day') d
      join public.camp_room_assignments x on x.camp_id=c.id and d::date between x.start_date and x.end_date
        and (x.released_from is null or d::date<x.released_from) group by d having count(*)>15) then raise exception 'room-capacity-full'; end if;
  perform private.assert_calendar_available(c.start_date,c.end_date,c.id);
  before_value:=jsonb_build_object('status',a.status,'revision_due_at',a.revision_due_at,'submitted_pdf_version_id',v.id);
  next_status:=case review_action when 'start_review' then 'under_review' when 'request_revision' then 'revision_requested' else 'approved' end;
  if review_action='request_revision' then due:=private.camp_roster_revision_deadline(c.start_date,moment); end if;
  if review_action='approve' and not exists(select 1 from public.stays where application_id=a.id) then
    insert into public.stays(application_id,status,created_at,updated_at) values(a.id,'before_move_in',moment,moment);
  end if;
  update public.applications set status=next_status,revision_due_at=due,
    decision_reason=case when review_action='request_revision' then btrim(public_reason) else null end,
    approval_comment=case when review_action='approve' then nullif(btrim(public_reason),'') else approval_comment end
    where id=a.id returning * into a;
  insert into public.application_status_events(application_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
    values(a.id,before_value->>'status',a.status,case when review_action<>'start_review' then nullif(btrim(public_reason),'') end,auth.uid(),moment);
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id,reason)
    values('application',a.id,'camp_roster_'||review_action,before_value,
      jsonb_build_object('status',a.status,'revision_due_at',a.revision_due_at,'submitted_pdf_version_id',v.id,
        'stay_id',(select id from public.stays where application_id=a.id)),'staff',auth.uid(),nullif(btrim(public_reason),''));
  return jsonb_build_object('camp_id',c.id,'application_id',a.id,'status',a.status,'updated_at',a.updated_at);
end $$;

create function public.get_staff_camp_roster_application_review(target_camp_id uuid,target_application_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.camps%rowtype; a public.applications%rowtype; r public.camp_room_assignments%rowtype;
  v public.camp_application_versions%rowtype; available boolean:=false;
begin
  c:=private.lock_camp_roster_review_scope(target_camp_id);
  select * into a from public.applications where id=target_application_id and camp_id=c.id and usage_type='camp';
  if not found then raise exception 'not-found'; end if;
  select * into r from public.camp_room_assignments where camp_id=c.id and eligible_user_id=a.camp_eligible_user_id;
  select * into v from public.camp_application_versions where id=a.latest_submitted_camp_pdf_version_id and state='submitted'
    and application_id=a.id and camp_id=c.id and eligible_user_id=a.camp_eligible_user_id;
  if a.status in ('submitted','under_review') and c.start_date>(clock_timestamp() at time zone 'Asia/Tokyo')::date then
    begin
      perform private.assert_camp_roster_review_stay(a.id);
      perform private.assert_camp_roster_submitted_pdf(a.id);
      available:=exists(select 1 from public.camp_eligible_users e join public.profiles p on p.id=e.linked_user_id
        where e.id=a.camp_eligible_user_id and e.camp_id=c.id and e.disabled_at is null
          and e.participation_status='participating' and p.id=a.user_id and p.account_state='active');
    exception when sqlstate 'P0001' then available:=false; end;
  end if;
  return jsonb_build_object('camp_id',c.id,'application_id',a.id,'updated_at',a.updated_at,'status',a.status,
    'room_plan_version',c.room_plan_version::text,'assignment_version',r.assignment_version::text,'submitted_version_id',v.id,
    'can_review',available,'previously_approved',exists(select 1 from public.application_status_events where application_id=a.id and to_status='approved'),
    'room_name',(select display_name from public.camp_room_mapping where room_id=r.room_id),
    'snapshot',case when v.id is null then null else v.source_snapshot-array['render_context'] end,
    'versions',(select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'version_no',x.version_no::text,'submitted_at',x.submitted_at)
      order by x.version_no desc),'[]') from public.camp_application_versions x where x.application_id=a.id and x.state='submitted'),
    'lifecycle',public.get_staff_camp_roster_lifecycle(c.id,a.camp_eligible_user_id));
end $$;

revoke all on function private.lock_camp_roster_review_scope(uuid),private.camp_roster_revision_deadline(date,timestamptz),
  private.assert_camp_roster_review_stay(uuid),private.assert_camp_roster_submitted_pdf(uuid),
  public.get_staff_camp_room_change_context(uuid),
  public.change_camp_rooms_and_request_revisions(uuid,bigint,bigint,jsonb,jsonb,text,boolean),
  public.review_camp_roster_application(uuid,uuid,timestamptz,bigint,bigint,uuid,text,text),
  public.get_staff_camp_roster_application_review(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.get_staff_camp_room_change_context(uuid),
  public.change_camp_rooms_and_request_revisions(uuid,bigint,bigint,jsonb,jsonb,text,boolean),
  public.review_camp_roster_application(uuid,uuid,timestamptz,bigint,bigint,uuid,text,text),
  public.get_staff_camp_roster_application_review(uuid,uuid) to authenticated;
commit;
