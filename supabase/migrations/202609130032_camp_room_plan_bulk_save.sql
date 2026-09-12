-- A3: complete roster room plans. No real room mapping is enabled here.
begin;
select private.lock_calendar_facility();

create table public.camp_room_mapping (
  room_id uuid primary key references public.rooms(id) on delete restrict,
  source_name text not null check (btrim(source_name)<>''),
  floor integer not null check (floor>0),
  display_name text not null check (btrim(display_name)<>''),
  print_name text not null check (btrim(print_name)<>''),
  assignment_enabled boolean not null default false,
  printing_enabled boolean not null default false,
  confirmed_at timestamptz,
  confirmation_evidence text,
  check (not (assignment_enabled or printing_enabled) or
    (confirmed_at is not null and nullif(btrim(confirmation_evidence),'') is not null))
);
create table public.camp_room_plan_versions (
  id uuid primary key default gen_random_uuid(),
  camp_id uuid not null references public.camps(id) on delete restrict,
  version bigint not null check (version>0),
  roster_version bigint not null check (roster_version>=0),
  start_date date not null,
  end_date date not null check (end_date>=start_date),
  assignments jsonb not null check (jsonb_typeof(assignments)='array'),
  created_at timestamptz not null default clock_timestamp(),
  actor_user_id uuid not null,
  unique(camp_id,version)
);
create table public.camp_room_assignments (
  id uuid primary key default gen_random_uuid(),
  camp_id uuid not null,
  eligible_user_id uuid not null,
  room_id uuid not null references public.rooms(id) on delete restrict,
  assignment_version bigint not null check (assignment_version>0),
  room_plan_version bigint not null,
  start_date date not null,
  end_date date not null check (end_date>=start_date),
  released_from date,
  release_reason text,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique(camp_id,eligible_user_id),
  foreign key(camp_id,eligible_user_id) references public.camp_eligible_users(camp_id,id) on delete restrict,
  foreign key(camp_id,room_plan_version) references public.camp_room_plan_versions(camp_id,version) on delete restrict,
  check ((released_from is null and release_reason is null) or
    (released_from is not null and nullif(btrim(release_reason),'') is not null))
);
alter table public.camp_room_mapping enable row level security;
alter table public.camp_room_plan_versions enable row level security;
alter table public.camp_room_assignments enable row level security;
revoke all on public.camp_room_mapping,public.camp_room_plan_versions,public.camp_room_assignments
  from public,anon,authenticated,service_role;

create function private.guard_camp_plan_history() returns trigger language plpgsql set search_path='' as $$
begin raise exception 'room-plan-history-immutable'; end $$;
create trigger camp_room_plan_versions_immutable before update or delete on public.camp_room_plan_versions
for each row execute function private.guard_camp_plan_history();
create function private.guard_camp_room_assignment() returns trigger language plpgsql security definer set search_path='' as $$
declare c public.camps%rowtype; e public.camp_eligible_users%rowtype; snapshot jsonb;
begin
  if tg_op='DELETE' then raise exception 'room-assignment-delete-forbidden'; end if;
  select * into c from public.camps where id=new.camp_id;
  if c.room_assignment_mode is distinct from 'eligible_roster' then raise exception 'eligible-roster-required'; end if;
  if tg_op='UPDATE' and (new.id,new.camp_id,new.eligible_user_id,new.created_at)
    is distinct from (old.id,old.camp_id,old.eligible_user_id,old.created_at) then raise exception 'room-assignment-identity-immutable'; end if;
  select * into e from public.camp_eligible_users where camp_id=new.camp_id and id=new.eligible_user_id;
  if not found then raise exception 'invalid-roster'; end if;
  if new.released_from is null and (e.disabled_at is not null or e.participation_status<>'participating') then raise exception 'invalid-roster'; end if;
  select v.assignments into snapshot from public.camp_room_plan_versions v
    where v.camp_id=new.camp_id and v.version=new.room_plan_version
      and v.start_date=new.start_date and v.end_date=new.end_date;
  if snapshot is null or not snapshot @> jsonb_build_array(jsonb_build_object(
    'eligible_user_id',new.eligible_user_id,'room_id',new.room_id,'assignment_version',new.assignment_version,
    'released_from',new.released_from)) then raise exception 'room-plan-inconsistent'; end if;
  return new;
end $$;
create trigger camp_room_assignments_guard before insert or update or delete on public.camp_room_assignments
for each row execute function private.guard_camp_room_assignment();

-- An uncommitted new camp has no claim. Existing claims are never silently removed.
create or replace function private.sync_calendar_claim()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_table_name='camps' then
    if new.room_assignment_mode='eligible_roster' and new.room_plan_committed_at is null then return new; end if;
    insert into public.calendar_claims(claim_type,camp_id,start_date,end_date,released_from)
    values('camp',new.id,new.start_date,new.end_date,case when new.deleted_at is not null then new.start_date end)
    on conflict(camp_id) do update set start_date=excluded.start_date,end_date=excluded.end_date,released_from=excluded.released_from
    where (calendar_claims.start_date,calendar_claims.end_date,calendar_claims.released_from)
      is distinct from (excluded.start_date,excluded.end_date,excluded.released_from);
  else
    insert into public.calendar_claims(claim_type,blocked_period_id,start_date,end_date,released_from)
    values('blocked',new.id,new.start_date,new.end_date,case when new.deleted_at is not null then new.start_date end)
    on conflict(blocked_period_id) do update set start_date=excluded.start_date,end_date=excluded.end_date,released_from=excluded.released_from
    where (calendar_claims.start_date,calendar_claims.end_date,calendar_claims.released_from)
      is distinct from (excluded.start_date,excluded.end_date,excluded.released_from);
  end if;
  return new;
end $$;
-- Only committed roster camps require claims; legacy checks are unchanged.
create or replace function private.check_group_availability(target_id uuid,starts_on date,ends_on date)
returns void language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from public.calendar_claims q where q.group_id is distinct from target_id
    and q.start_date<=ends_on and q.end_date>=starts_on
    and (q.released_from is null or greatest(q.start_date,starts_on)<q.released_from)) then raise exception 'calendar-unavailable'; end if;
  if exists(select 1 from public.camps c left join public.calendar_claims q on q.camp_id=c.id
    where c.deleted_at is null and (c.room_assignment_mode='legacy_application' or c.room_plan_committed_at is not null) and c.start_date<=ends_on and c.end_date>=starts_on
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

create or replace function private.check_community_availability(target_id uuid,actor uuid,starts_on date,ends_on date)
returns void language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from public.calendar_claims q where q.claim_type in ('camp','blocked','group')
    and q.start_date<=ends_on and q.end_date>=starts_on
    and (q.released_from is null or greatest(q.start_date,starts_on)<q.released_from))
    or exists(select 1 from public.camps c where c.deleted_at is null and (c.room_assignment_mode='legacy_application' or c.room_plan_committed_at is not null) and c.start_date<=ends_on and c.end_date>=starts_on)
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


-- A4/A10 must implement their own atomic period/deletion and workflow operations.
create function private.guard_roster_camp_period() returns trigger language plpgsql set search_path='' as $$
begin
  if old.room_assignment_mode='eligible_roster' and
    (new.start_date,new.end_date,new.deleted_at) is distinct from (old.start_date,old.end_date,old.deleted_at)
    then raise exception 'roster-lifecycle-required'; end if;
  return new;
end $$;
create trigger camps_guard_roster_period before update of start_date,end_date,deleted_at on public.camps
for each row execute function private.guard_roster_camp_period();
create function private.guard_legacy_camp_allocation() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from public.applications a join public.camps c on c.id=a.camp_id
    where a.id=new.application_id and c.room_assignment_mode='eligible_roster') then raise exception 'eligible-roster-required'; end if;
  return new;
end $$;
create trigger room_allocations_guard_roster before insert or update on public.room_allocations
for each row execute function private.guard_legacy_camp_allocation();

create or replace function private.lock_camp_application_for_staff(
  target_application_id uuid,
  expected_updated_at timestamptz
)
returns public.applications
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_record public.applications%rowtype;
begin
  if auth.uid() is null or not private.is_staff() then
    raise exception using errcode = '42501', message = 'staff-required';
  end if;

  if expected_updated_at is null or not isfinite(expected_updated_at) then
    raise exception using message = 'invalid-version';
  end if;

  -- Updating the guard also forces a serialization failure when a caller uses
  -- a stale REPEATABLE READ snapshot instead of PostgREST's READ COMMITTED.
  update public.facility_guard as guard set id = guard.id where guard.id = 1;
  if not found then
    raise exception using message = 'facility-guard-missing';
  end if;

  select application.* into application_record
  from public.applications as application
  where application.id = target_application_id and application.usage_type = 'camp'
  for update;
  if not found then
    raise exception using message = 'not-found';
  end if;

  -- Recheck after waiting and keep staff authorization valid until commit.
  perform staff.user_id
  from public.staff_roles as staff
  join public.profiles as profile on profile.id = staff.user_id
  where staff.user_id = auth.uid() and profile.account_state = 'active'
  for share of staff, profile;
  if not found then
    raise exception using errcode = '42501', message = 'staff-required';
  end if;

  if application_record.updated_at is distinct from expected_updated_at then
    raise exception using message = 'stale-update';
  end if;

  if exists(select 1 from public.camps where id=application_record.camp_id and room_assignment_mode='eligible_roster') then
    raise exception 'eligible-roster-required';
  end if;
  return application_record;
end;
$$;


-- Email/name edits affect labels, not the set that must be fully assigned.
create or replace function private.bump_camp_roster_versions()
returns trigger language plpgsql security definer set search_path='' as $$
declare target_camp uuid; roster_changed boolean; label_changed boolean;
begin
  if tg_op='DELETE' then target_camp:=old.camp_id; else target_camp:=new.camp_id; end if;
  if not exists(select 1 from public.camps where id=target_camp and room_assignment_mode='eligible_roster') then
    if tg_op='DELETE' then return old; else return new; end if;
  end if;
  if tg_op='INSERT' then roster_changed:=new.disabled_at is null and new.participation_status='participating'; label_changed:=true;
  elsif tg_op='DELETE' then roster_changed:=old.disabled_at is null and old.participation_status='participating'; label_changed:=true;
  else
    roster_changed:=(old.disabled_at is null and old.participation_status='participating')
      is distinct from (new.disabled_at is null and new.participation_status='participating');
    label_changed:=(old.management_name,old.email_normalized) is distinct from (new.management_name,new.email_normalized);
  end if;
  update public.camps set roster_version=roster_version+case when roster_changed then 1 else 0 end,
    roster_label_version=roster_label_version+case when label_changed then 1 else 0 end
    where id=target_camp and (roster_changed or label_changed);
  if tg_op='DELETE' then return old; else return new; end if;
end $$;

create function public.save_camp_room_plan(target_camp_id uuid,expected_roster_version bigint,
  expected_room_plan_version bigint,submitted_assignments jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.camps%rowtype; payload jsonb; snapshot jsonb; before_value jsonb;
  member_count integer; plan_version bigint; claim public.calendar_claims%rowtype;
begin
  perform private.lock_calendar_for_staff();
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
  -- Lock settings and rooms before eligible users, applications, stays and assignments.
  perform r.id from public.rooms r order by r.id for share;
  perform m.room_id from public.camp_room_mapping m order by m.room_id for share;
  perform e.id from public.camp_eligible_users e where e.camp_id=c.id order by e.id for update;
  perform a.id from public.applications a where a.camp_id=c.id order by a.id for update;
  perform s.id from public.stays s join public.applications a on a.id=s.application_id where a.camp_id=c.id order by s.application_id for update of s;
  perform r.id from public.camp_room_assignments r where r.camp_id=c.id order by r.eligible_user_id for update;
  if not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
  if c.start_date<=(clock_timestamp() at time zone 'Asia/Tokyo')::date
    or exists(select 1 from public.stays s join public.applications a on a.id=s.application_id where a.camp_id=c.id and s.status in ('staying','moved_out')) then raise exception 'camp-started'; end if;
  select count(*) into member_count from public.camp_eligible_users where camp_id=c.id and disabled_at is null and participation_status='participating';
  if member_count>15 then raise exception 'facility-capacity-full'; end if;
  if member_count<>jsonb_array_length(payload) or exists(select 1 from jsonb_array_elements(payload) x
    left join public.camp_eligible_users e on e.id=(x->>'eligible_user_id')::uuid and e.camp_id=c.id
    where e.id is null or e.disabled_at is not null or e.participation_status<>'participating') then raise exception 'invalid-roster'; end if;
  if exists(select 1 from jsonb_array_elements(payload) x left join public.camp_room_mapping m on m.room_id=(x->>'room_id')::uuid
    where m.room_id is null or not m.assignment_enabled) then raise exception 'room-not-confirmed'; end if;
  if exists(select 1 from jsonb_array_elements(payload) x join public.rooms r on r.id=(x->>'room_id')::uuid
    group by r.id,r.capacity having count(*)>r.capacity) then raise exception 'room-capacity-full'; end if;
  -- Never revive a released allocation, or discard an occupied allocation outside the roster.
  if exists(select 1 from public.camp_room_assignments r where r.camp_id=c.id and
    ((r.released_from is not null and exists(select 1 from jsonb_array_elements(payload) x where (x->>'eligible_user_id')::uuid=r.eligible_user_id))
    or (r.released_from is null and not exists(select 1 from jsonb_array_elements(payload) x where (x->>'eligible_user_id')::uuid=r.eligible_user_id)))) then raise exception 'roster-lifecycle-required'; end if;
  if exists(select 1 from public.applications a join jsonb_array_elements(payload) x on (x->>'eligible_user_id')::uuid=a.camp_eligible_user_id
    left join public.camp_room_assignments r on r.camp_id=c.id and r.eligible_user_id=a.camp_eligible_user_id
    where a.camp_id=c.id and a.status not in ('draft','rejected','cancelled') and
      (r.room_id is distinct from (x->>'room_id')::uuid or r.start_date is distinct from c.start_date or r.end_date is distinct from c.end_date)) then raise exception 'room-change-review-required'; end if;
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
  insert into public.camp_room_plan_versions(camp_id,version,roster_version,start_date,end_date,assignments,actor_user_id)
    values(c.id,plan_version,c.roster_version,c.start_date,c.end_date,snapshot,auth.uid());
  insert into public.camp_room_assignments(camp_id,eligible_user_id,room_id,assignment_version,room_plan_version,start_date,end_date)
    select c.id,(x->>'eligible_user_id')::uuid,(x->>'room_id')::uuid,(x->>'assignment_version')::bigint,plan_version,c.start_date,c.end_date
    from jsonb_array_elements(snapshot) x
    on conflict(camp_id,eligible_user_id) do update set room_id=excluded.room_id,assignment_version=excluded.assignment_version,
      room_plan_version=excluded.room_plan_version,start_date=excluded.start_date,end_date=excluded.end_date,updated_at=clock_timestamp();
  update public.camps set room_plan_version=plan_version,saved_roster_version=c.roster_version,
    room_plan_committed_at=coalesce(room_plan_committed_at,clock_timestamp()) where id=c.id;
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id)
    values('camp',c.id,'save_camp_room_plan',jsonb_build_object('version',c.room_plan_version,'assignments',before_value),
      jsonb_build_object('version',plan_version,'roster_version',c.roster_version,'assignments',snapshot),'staff',auth.uid());
  return jsonb_build_object('camp_id',c.id,'roster_version',c.roster_version::text,'room_plan_version',plan_version::text,'saved_roster_version',c.roster_version::text);
end $$;

create function public.get_staff_camp_room_plan(target_camp_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare c public.camps%rowtype;
begin
  if auth.uid() is null or not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
  select * into c from public.camps where id=target_camp_id and deleted_at is null;
  if not found then raise exception 'not-found'; end if;
  if c.room_assignment_mode<>'eligible_roster' then raise exception 'eligible-roster-required'; end if;
  return jsonb_build_object('camp_id',c.id,'roster_version',c.roster_version::text,'room_plan_version',c.room_plan_version::text,
    'saved_roster_version',c.saved_roster_version::text,'room_plan_committed_at',c.room_plan_committed_at,
    'eligible_users',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'management_name',e.management_name,
      'room_id',r.room_id,'assignment_version',r.assignment_version::text) order by e.id),'[]') from public.camp_eligible_users e
      left join public.camp_room_assignments r on r.camp_id=e.camp_id and r.eligible_user_id=e.id and r.released_from is null
      where e.camp_id=c.id and e.disabled_at is null and e.participation_status='participating'),
    'rooms',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'name',m.display_name,'capacity',r.capacity) order by r.id),'[]')
      from public.rooms r join public.camp_room_mapping m on m.room_id=r.id where m.assignment_enabled));
end $$;
revoke all on function private.guard_camp_plan_history(),private.guard_camp_room_assignment(),private.guard_roster_camp_period(),
  private.guard_legacy_camp_allocation(),public.save_camp_room_plan(uuid,bigint,bigint,jsonb),public.get_staff_camp_room_plan(uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.save_camp_room_plan(uuid,bigint,bigint,jsonb),public.get_staff_camp_room_plan(uuid) to authenticated;
commit;
