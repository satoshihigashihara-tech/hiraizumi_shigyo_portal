-- T18 single-connection regression. Run the whole file on an isolated test project after SQL 021.
-- Fictional data only. The final ROLLBACK removes all fixtures and temporary helpers.
begin;
set local lock_timeout='3s';
set local statement_timeout='60s';
set local timezone='UTC';
do $$ begin
  if current_user<>'postgres' or to_regprocedure('public.start_community_group_application(uuid,timestamptz,uuid,boolean)') is null then
    raise exception 'Run as postgres after SQL 021.'; end if;
  if exists(select 1 from public.calendar_claims where start_date<=(clock_timestamp() at time zone 'Asia/Tokyo')::date+60
    and end_date>=(clock_timestamp() at time zone 'Asia/Tokyo')::date+14
    and (released_from is null or released_from>start_date)) then
    raise exception 'Use an isolated test project with no existing claims in the 14-60 day window.'; end if;
end; $$;

create temporary table t18_results(n integer generated always as identity,label text,passed boolean) on commit drop;
create temporary table t18_context(owner_id uuid,other_id uuid,staff_id uuid,disabled_id uuid,today date) on commit drop;
create function pg_temp.t18_check(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  insert into pg_temp.t18_results(label,passed) values(label,true);
end; $$;
create function pg_temp.t18_user(kind text default 'user') returns uuid language plpgsql as $$
declare x uuid:=gen_random_uuid(); begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','t18-'||x::text||'@example.invalid','',clock_timestamp(),
    '{"provider":"email","providers":["email"]}','{}',clock_timestamp(),clock_timestamp());
  if kind='staff' then insert into public.staff_roles(user_id) values(x); end if;
  if kind='disabled' then update public.profiles set account_state='disabled' where id=x; end if;
  return x;
end; $$;
insert into pg_temp.t18_context select pg_temp.t18_user(),pg_temp.t18_user(),pg_temp.t18_user('staff'),
  pg_temp.t18_user('disabled'),(clock_timestamp() at time zone 'Asia/Tokyo')::date;

create function pg_temp.t18_call(actor uuid,query_text text,role_name text default 'authenticated') returns jsonb language plpgsql as $$
declare r record; rows_value jsonb:='[]'; result_value jsonb; code_value text; msg text;
  actor_email text:=(select email from auth.users where id=actor);
begin
  begin
    execute format('set local role %I',role_name);
    perform set_config('request.jwt.claim.sub',coalesce(actor::text,''),true);
    perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'email',actor_email,'role',role_name)::text,true);
    for r in execute query_text loop rows_value:=rows_value||jsonb_build_array(to_jsonb(r)); end loop;
    result_value:=jsonb_build_object('ok',true,'rows',rows_value);
  exception when others then get stacked diagnostics code_value=returned_sqlstate,msg=message_text;
    result_value:=jsonb_build_object('ok',false,'code',code_value,'message',msg);
  end;
  set local role postgres; perform set_config('request.jwt.claim.sub','',true); perform set_config('request.jwt.claims','{}',true);
  return result_value;
end; $$;
create function pg_temp.t18_ok(r jsonb,label text) returns jsonb language plpgsql as $$ begin
  perform pg_temp.t18_check(r->>'ok'='true',label||': '||r::text); return r->'rows';
end; $$;
create function pg_temp.t18_error(r jsonb,message_value text,label text,state_value text default 'P0001') returns void language plpgsql as $$ begin
  perform pg_temp.t18_check(r->>'ok'='false' and r->>'code'=state_value
    and (message_value is null or r->>'message'=message_value),label||': '||r::text);
end; $$;
create function pg_temp.t18_fields(starts_on date,ends_on date,count_value integer default 4,stays boolean default false)
returns jsonb language sql as $$ select jsonb_build_object('group_name','架空地域研究会','representative_name','架空代表者',
  'representative_address','架空住所','representative_phone','000-0000-0000','start_date',starts_on,'end_date',ends_on,
  'usage_place','common_and_second_floor','purpose','架空の地域調査','local_activity','町内で架空の聞き取り',
  'special_notes',null,'planned_participants',count_value,'representative_stays',stays); $$;
create function pg_temp.t18_version(x uuid) returns timestamptz language sql as $$
  select updated_at from public.group_applications where id=x; $$;
create function pg_temp.t18_draft(actor uuid,starts_on date,ends_on date,count_value integer default 4) returns uuid language plpgsql as $$
declare x uuid:=gen_random_uuid(); begin
  perform pg_temp.t18_ok(pg_temp.t18_call(actor,format('select * from public.create_community_group_draft(%L,%L::jsonb)',
    x,pg_temp.t18_fields(starts_on,ends_on,count_value))),'create group draft'); return x;
end; $$;
create function pg_temp.t18_start(x uuid,version_value timestamptz default null,key_value uuid default null,confirm_value boolean default true)
returns jsonb language sql as $$ select pg_temp.t18_call(g.representative_user_id,
  format('select * from public.start_community_group_application(%L,%L,%L,%L)',x,coalesce(version_value,g.updated_at),
    coalesce(key_value,gen_random_uuid()),confirm_value)) from public.group_applications g where g.id=x; $$;
create function pg_temp.t18_snapshot(x uuid) returns jsonb language sql as $$ select jsonb_build_object(
  'group',(select to_jsonb(g) from public.group_applications g where id=x),
  'claim',(select to_jsonb(q) from public.calendar_claims q where group_id=x),
  'number',(select to_jsonb(n) from public.reception_numbers n where group_id=x),
  'events',(select jsonb_agg(to_jsonb(e) order by id) from public.group_status_events e where group_id=x),
  'audit',(select jsonb_agg(to_jsonb(a) order by id) from public.audit_logs a where entity_type='group_application' and entity_id=x)); $$;
create function pg_temp.t18_individual_fields(starts_on date,ends_on date) returns jsonb language sql as $$
  select jsonb_build_object('start_date',starts_on,'end_date',ends_on,'user_name','架空個人','user_address','架空住所',
    'user_phone','000-0000-0000','emergency_name','架空連絡先','emergency_address','架空住所',
    'emergency_phone','000-0000-0000','purpose','架空調査','local_activity','町内で架空の調査',
    'special_notes',null,'usage_place','common_and_second_floor','requires_guardian_consent',false); $$;

-- Lifecycle, retry safety, deadlines, shared numbering and owner reads.
do $$ declare c pg_temp.t18_context%rowtype; x uuid:=gen_random_uuid(); v timestamptz; k uuid:=gen_random_uuid();
  before_value jsonb; rows_value jsonb; first_number text; individual_id uuid;
begin
  select * into c from pg_temp.t18_context;
  update public.profiles set full_name='プロフィール架空名',address='プロフィール架空住所',phone='0000000000' where id=c.owner_id;
  perform pg_temp.t18_ok(pg_temp.t18_call(c.owner_id,format('select * from public.create_community_group_draft(%L)',x)),'empty draft');
  perform pg_temp.t18_check((select representative_name='プロフィール架空名' and status='draft' from public.group_applications where id=x),'profile defaults');
  before_value:=pg_temp.t18_snapshot(x);
  perform pg_temp.t18_ok(pg_temp.t18_call(c.owner_id,format('select * from public.create_community_group_draft(%L)',x)),'creation retry');
  perform pg_temp.t18_check(pg_temp.t18_snapshot(x)=before_value,'creation retry is read-only');
  perform pg_temp.t18_check(not exists(select 1 from public.calendar_claims where group_id=x)
    and not exists(select 1 from public.reception_numbers where group_id=x),'draft has no claim or number');
  v:=pg_temp.t18_version(x);
  perform pg_temp.t18_ok(pg_temp.t18_call(c.owner_id,format('select * from public.save_community_group_draft(%L,%L,%L::jsonb)',
    x,v,pg_temp.t18_fields(c.today+20,c.today+22,4,true))),'save complete group');
  perform pg_temp.t18_error(pg_temp.t18_call(c.owner_id,format('select * from public.save_community_group_draft(%L,%L,%L::jsonb)',
    x,v,pg_temp.t18_fields(c.today+20,c.today+22))),'stale-update','stale save');
  perform pg_temp.t18_error(pg_temp.t18_start(x,null,null,false),'confirmation-required','confirmation required');
  v:=pg_temp.t18_version(x);
  rows_value:=pg_temp.t18_ok(pg_temp.t18_start(x,v,k),'start group application');
  first_number:=rows_value#>>'{0,reception_number}';
  perform pg_temp.t18_check(first_number~'^SG-[0-9]{4}-[0-9]{4,}$','group reception format');
  perform pg_temp.t18_check((select status='collecting' and participant_due_at=least(((c.today+8)::timestamp at time zone 'Asia/Tokyo'),
    (start_date::timestamp at time zone 'Asia/Tokyo')) and representative_stays from public.group_applications where id=x),'status and participant deadline');
  perform pg_temp.t18_check((select count(*)=1 from public.calendar_claims where group_id=x and claim_type='group' and released_from is null),'exclusive group claim');
  perform pg_temp.t18_check((select count(*)=2 from public.group_status_events where group_id=x),'draft and collecting events');
  before_value:=pg_temp.t18_snapshot(x);
  perform pg_temp.t18_ok(pg_temp.t18_start(x,v,k),'identical start retry');
  perform pg_temp.t18_check(pg_temp.t18_snapshot(x)=before_value,'start retry creates no duplicates');
  perform pg_temp.t18_error(pg_temp.t18_start(x,v,gen_random_uuid()),'stale-update','different retry key rejected');
  perform pg_temp.t18_error(pg_temp.t18_call(c.owner_id,format('select * from public.save_community_group_draft(%L,%L,%L::jsonb)',
    x,pg_temp.t18_version(x),pg_temp.t18_fields(c.today+20,c.today+22))),'not-editable','collecting cannot edit in T18');
  rows_value:=pg_temp.t18_ok(pg_temp.t18_call(c.owner_id,format('select public.get_community_group(%L) as data',x)),'owner detail');
  perform pg_temp.t18_check(not ((rows_value#>'{0,data}') ? 'representative_user_id')
    and not ((rows_value#>'{0,data}') ? 'last_submission_key')
    and not exists(select 1 from jsonb_array_elements(rows_value#>'{0,data,events}') e where e ? 'actor_user_id'),'detail hides internal fields');
  -- Shared SG sequence: create an individual after the group and ensure a different monotonic serial.
  individual_id:=gen_random_uuid();
  perform pg_temp.t18_ok(pg_temp.t18_call(c.other_id,format('select * from public.create_community_application_draft(%L,%L::jsonb)',individual_id,
    pg_temp.t18_individual_fields(c.today+30,c.today+31))),'individual draft after group');
  perform pg_temp.t18_ok(pg_temp.t18_call(c.other_id,format('select * from public.submit_community_application(%L,(select updated_at from public.applications where id=%L),%L,true)',
    individual_id,individual_id,gen_random_uuid())),'individual submission after group');
  perform pg_temp.t18_check((select i.serial_number=g.serial_number+1 from public.reception_numbers i cross join public.reception_numbers g
    where i.application_id=individual_id and g.group_id=x),'individual and group share sequence');
end; $$;

-- Strict input validation, ownership and direct-write denial.
do $$ declare c pg_temp.t18_context%rowtype; x uuid; f jsonb; field text; before_value jsonb; q text; r jsonb;
begin
  select * into c from pg_temp.t18_context;
  x:=pg_temp.t18_draft(c.owner_id,c.today+35,c.today+36); f:=pg_temp.t18_fields(c.today+35,c.today+36);
  foreach field in array array['group_name','representative_name','representative_address','representative_phone',
    'usage_place','purpose','local_activity','planned_participants'] loop
    perform pg_temp.t18_ok(pg_temp.t18_call(c.owner_id,format('select * from public.save_community_group_draft(%L,%L,%L::jsonb)',
      x,pg_temp.t18_version(x),f||jsonb_build_object(field,null))),'save missing '||field);
    perform pg_temp.t18_error(pg_temp.t18_start(x),'required-fields','required '||field);
  end loop;
  perform pg_temp.t18_ok(pg_temp.t18_call(c.owner_id,format('select * from public.save_community_group_draft(%L,%L,%L::jsonb)',
    x,pg_temp.t18_version(x),f||'{"start_date":null,"end_date":null}')),'save missing period');
  perform pg_temp.t18_error(pg_temp.t18_start(x),'required-fields','period required at start');
  perform pg_temp.t18_error(pg_temp.t18_call(c.owner_id,format('select * from public.save_community_group_draft(%L,%L,%L::jsonb)',
    x,pg_temp.t18_version(x),f||'{"status":"approved"}')),'invalid-fields','status injection');
  perform pg_temp.t18_error(pg_temp.t18_call(c.owner_id,format('select * from public.save_community_group_draft(%L,%L,%L::jsonb)',
    x,pg_temp.t18_version(x),f||'{"planned_participants":2.5}')),'invalid-fields','fractional count');
  perform pg_temp.t18_error(pg_temp.t18_call(c.owner_id,format('select * from public.save_community_group_draft(%L,%L,%L::jsonb)',
    x,pg_temp.t18_version(x),f||'{"planned_participants":1}')),'invalid-participant-count','count below two');
  perform pg_temp.t18_error(pg_temp.t18_call(c.owner_id,format('select * from public.save_community_group_draft(%L,%L,%L::jsonb)',
    x,pg_temp.t18_version(x),f||'{"planned_participants":16}')),'invalid-participant-count','count above fifteen');
  perform pg_temp.t18_error(pg_temp.t18_call(c.owner_id,format('select * from public.save_community_group_draft(%L,%L,%L::jsonb)',
    x,pg_temp.t18_version(x),f||'{"representative_stays":"false"}')),'invalid-fields','boolean must be JSON boolean');
  perform pg_temp.t18_error(pg_temp.t18_call(c.owner_id,format('select * from public.save_community_group_draft(%L,%L,%L::jsonb)',
    x,pg_temp.t18_version(x),f||jsonb_build_object('group_name',repeat('あ',121)))),'field-too-long','Unicode name limit');
  perform pg_temp.t18_error(pg_temp.t18_call(c.owner_id,format('select * from public.save_community_group_draft(%L,%L,%L::jsonb)',
    x,pg_temp.t18_version(x),f||'{"start_date":"2026-02-30"}')),'invalid-period','real date validation');
  perform pg_temp.t18_ok(pg_temp.t18_call(c.owner_id,format('select * from public.save_community_group_draft(%L,%L,%L::jsonb)',
    x,pg_temp.t18_version(x),f)),'restore fields'); before_value:=pg_temp.t18_snapshot(x);
  perform pg_temp.t18_error(pg_temp.t18_call(c.other_id,format('select * from public.save_community_group_draft(%L,%L,%L::jsonb)',
    x,pg_temp.t18_version(x),f)),'not-found','other user cannot save');
  perform pg_temp.t18_error(pg_temp.t18_call(c.other_id,format('select public.get_community_group(%L)',x)),'not-found','other user cannot read');
  perform pg_temp.t18_error(pg_temp.t18_call(c.disabled_id,format('select public.get_community_group(%L)',x)),null,'disabled user denied','42501');
  perform pg_temp.t18_error(pg_temp.t18_call(null,format('select public.get_community_group(%L)',x)),null,'anonymous denied','42501');
  perform pg_temp.t18_check(pg_temp.t18_snapshot(x)=before_value,'rejected operations make no changes');
  foreach q in array array['insert into public.group_applications(representative_user_id) values(gen_random_uuid()) returning id',
    'update public.group_applications set status=''approved'' returning id','delete from public.group_status_events returning id',
    'select private.lock_group_user()'] loop
    perform pg_temp.t18_error(pg_temp.t18_call(c.staff_id,q),null,'direct write or private function denied','42501');
  end loop;
end; $$;

-- Exact initial window and duration boundaries.
do $$ declare c pg_temp.t18_context%rowtype; starts_on date; days integer; expected text; x uuid;
begin
  select * into c from pg_temp.t18_context;
  for starts_on,days,expected in select * from (values
    (c.today+13,2,'start-too-soon'),(c.today+14,2,null::text),(c.today+59,2,null::text),
    (c.today+60,2,'end-too-late'),(c.today+30,1,'invalid-duration'),(c.today+32,15,null::text),
    (c.today+30,16,'invalid-duration')) t(s,d,e) loop
    if expected='invalid-duration' then
      x:=gen_random_uuid();
      perform pg_temp.t18_error(pg_temp.t18_call(c.other_id,format('select * from public.create_community_group_draft(%L,%L::jsonb)',
        x,pg_temp.t18_fields(starts_on,starts_on+days-1))),'invalid-duration','invalid structural duration');
    else
      x:=pg_temp.t18_draft(c.other_id,starts_on,starts_on+days-1);
      if expected is null then perform pg_temp.t18_ok(pg_temp.t18_start(x),'valid boundary');
      else perform pg_temp.t18_error(pg_temp.t18_start(x),expected,'invalid boundary'); end if;
    end if;
    if expected is null then
      update public.group_applications set status='cancelled' where id=x;
    end if;
  end loop;
end; $$;

-- Group claims are exclusive against groups, individuals, camps and blocked periods; failed starts are atomic.
do $$ declare c pg_temp.t18_context%rowtype; base_id uuid; candidate uuid; individual_id uuid; camp_id uuid; block_id uuid;
  before_value jsonb; rows_value jsonb;
begin
  select * into c from pg_temp.t18_context;
  base_id:=pg_temp.t18_draft(c.owner_id,c.today+40,c.today+42);
  perform pg_temp.t18_ok(pg_temp.t18_start(base_id),'base group');
  candidate:=pg_temp.t18_draft(c.other_id,c.today+41,c.today+43); before_value:=pg_temp.t18_snapshot(candidate);
  perform pg_temp.t18_error(pg_temp.t18_start(candidate),'calendar-unavailable','group versus group');
  perform pg_temp.t18_check(pg_temp.t18_snapshot(candidate)=before_value,'group conflict rolls back all writes');
  perform pg_temp.t18_check((select availability='unavailable' from public.get_public_calendar(date_trunc('month',c.today+41)::date)
    where date=c.today+41),'public calendar hides group details and closes date');
  rows_value:=pg_temp.t18_ok(pg_temp.t18_call(c.staff_id,
    format('select * from public.get_staff_calendar_day(%L)',c.today+41)),'staff day');
  perform pg_temp.t18_check((select count(*)=1 from jsonb_array_elements(rows_value) item
    where item->>'entry_type'='group'),'staff calendar identifies group');
  update public.group_applications set status='cancelled' where id=base_id;

  individual_id:=gen_random_uuid();
  perform pg_temp.t18_ok(pg_temp.t18_call(c.owner_id,format('select * from public.create_community_application_draft(%L,%L::jsonb)',
    individual_id,pg_temp.t18_individual_fields(c.today+43,c.today+44))),'individual conflict fixture');
  perform pg_temp.t18_ok(pg_temp.t18_call(c.owner_id,format('select * from public.submit_community_application(%L,(select updated_at from public.applications where id=%L),%L,true)',
    individual_id,individual_id,gen_random_uuid())),'submit individual fixture');
  candidate:=pg_temp.t18_draft(c.other_id,c.today+43,c.today+44);
  perform pg_temp.t18_error(pg_temp.t18_start(candidate),'calendar-unavailable','group versus individual');

  insert into public.camps(name,start_date,end_date,application_deadline) values('架空競合キャンプ',c.today+46,c.today+47,
    clock_timestamp()+interval '1 day') returning id into camp_id;
  candidate:=pg_temp.t18_draft(c.other_id,c.today+46,c.today+47);
  perform pg_temp.t18_error(pg_temp.t18_start(candidate),'calendar-unavailable','group versus camp');
  insert into public.blocked_periods(start_date,end_date,internal_reason) values(c.today+49,c.today+50,'架空停止') returning id into block_id;
  candidate:=pg_temp.t18_draft(c.other_id,c.today+49,c.today+50);
  perform pg_temp.t18_error(pg_temp.t18_start(candidate),'calendar-unavailable','group versus blocked period');

  -- Reverse direction: a new individual cannot enter an existing group claim.
  candidate:=pg_temp.t18_draft(c.other_id,c.today+52,c.today+53);
  perform pg_temp.t18_ok(pg_temp.t18_start(candidate),'group for reverse conflict');
  individual_id:=gen_random_uuid();
  perform pg_temp.t18_ok(pg_temp.t18_call(c.owner_id,format('select * from public.create_community_application_draft(%L,%L::jsonb)',
    individual_id,pg_temp.t18_individual_fields(c.today+52,c.today+53))),'individual reverse fixture');
  perform pg_temp.t18_error(pg_temp.t18_call(c.owner_id,format('select * from public.submit_community_application(%L,(select updated_at from public.applications where id=%L),%L,true)',
    individual_id,individual_id,gen_random_uuid())),'calendar-unavailable','individual versus group');
end; $$;

-- Fail closed when an active source row has lost its claim.
do $$ declare c pg_temp.t18_context%rowtype; base_id uuid; candidate uuid; before_value jsonb;
begin
  select * into c from pg_temp.t18_context;
  base_id:=pg_temp.t18_draft(c.owner_id,c.today+55,c.today+56); perform pg_temp.t18_ok(pg_temp.t18_start(base_id),'inconsistency fixture');
  delete from public.calendar_claims where group_id=base_id;
  candidate:=pg_temp.t18_draft(c.other_id,c.today+55,c.today+56); before_value:=pg_temp.t18_snapshot(candidate);
  perform pg_temp.t18_error(pg_temp.t18_start(candidate),'calendar-inconsistent','missing group claim fails closed');
  perform pg_temp.t18_check(pg_temp.t18_snapshot(candidate)=before_value,'inconsistent calendar failure is atomic');
end; $$;

select count(*)::integer as passed_checks,bool_and(passed) as all_passed from pg_temp.t18_results;
rollback;
