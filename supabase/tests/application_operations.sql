-- SQL 015/016 operations tests. Phase 2 runner selects stays only. ISOLATED TEST PROJECT WITHOUT TRAFFIC.
-- Run this WHOLE file as postgres after 001-015. All fictional records and
-- temporary helpers roll back. No real Auth login, Storage API or secrets.
-- On failure ROLLBACK in the same connection. Never replace ROLLBACK with COMMIT.
begin;
set local lock_timeout='3s';
set local statement_timeout='60s';
set local timezone='UTC';
do $$ begin
  if current_user<>'postgres' or to_regprocedure('public.update_application_payment(uuid,timestamptz,text,date,text)') is null then raise exception 'Run as postgres after 001-015.'; end if;
  if exists(select 1 from public.calendar_claims where start_date<=(clock_timestamp() at time zone 'Asia/Tokyo')::date+60
    and end_date>=(clock_timestamp() at time zone 'Asia/Tokyo')::date+14 and (released_from is null or released_from>start_date)) then
    raise exception 'Use an isolated test project with no existing claims in the 14-60 day window.'; end if;
end; $$;
create temporary table t13_results(n integer generated always as identity,label text,passed boolean) on commit drop;
create temporary table t13_context(owner_id uuid,other_id uuid,staff_id uuid,disabled_id uuid,today date) on commit drop;
create function pg_temp.t13_check(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  insert into pg_temp.t13_results(label,passed) values(label,true);
end; $$;
create function pg_temp.t13_user(kind text default 'user') returns uuid language plpgsql as $$ declare x uuid:=gen_random_uuid(); begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','t12i-'||x::text||'@example.invalid','',clock_timestamp(),
    '{"provider":"email","providers":["email"]}','{}',clock_timestamp(),clock_timestamp());
  if kind='staff' then insert into public.staff_roles(user_id) values(x); end if;
  if kind='disabled' then update public.profiles set account_state='disabled' where id=x; end if;
  return x;
end; $$;
insert into pg_temp.t13_context select pg_temp.t13_user(),pg_temp.t13_user(),pg_temp.t13_user('staff'),pg_temp.t13_user('disabled'),(clock_timestamp() at time zone 'Asia/Tokyo')::date;
create function pg_temp.t13_call(actor uuid,query_text text,role_name text default 'authenticated') returns jsonb language plpgsql security invoker as $$
declare r record; rows_value jsonb:='[]'; result_value jsonb; code_value text; msg text; actor_email text:=(select email from auth.users where id=actor);
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
  set local role postgres;
  perform set_config('request.jwt.claim.sub','',true); perform set_config('request.jwt.claims','{}',true);
  return result_value;
end; $$;
create function pg_temp.t13_ok(r jsonb,label text) returns jsonb language plpgsql as $$ begin
  perform pg_temp.t13_check(r->>'ok'='true',label||': '||r::text); return r->'rows';
end; $$;
create function pg_temp.t13_error(r jsonb,message_value text,label text,state_value text default 'P0001') returns void language plpgsql as $$ begin
  perform pg_temp.t13_check(r->>'ok'='false' and r->>'code'=state_value and (message_value is null or r->>'message'=message_value),label||': '||r::text);
end; $$;
create function pg_temp.t13_fields(starts_on date,ends_on date) returns jsonb language sql as $$ select jsonb_build_object(
  'start_date',starts_on,'end_date',ends_on,'user_name','架空利用者','user_address','架空住所','user_phone','000-0000-0000',
  'emergency_name','架空連絡先','emergency_address','架空住所','emergency_phone','000-0000-0000',
  'purpose','地域の調査','local_activity','平泉町内で文化を調査する','special_notes',null,
  'usage_place','common_and_second_floor','requires_guardian_consent',false); $$;
create function pg_temp.t13_version(x uuid) returns timestamptz language sql as $$ select updated_at from public.applications where id=x; $$;
create function pg_temp.t13_draft(actor uuid,starts_on date,ends_on date) returns uuid language plpgsql as $$ declare x uuid:=gen_random_uuid(); begin
  perform pg_temp.t13_ok(pg_temp.t13_call(actor,format('select * from public.create_community_application_draft(%L,%L::jsonb)',x,pg_temp.t13_fields(starts_on,ends_on))),'create draft'); return x;
end; $$;
create function pg_temp.t13_submit(x uuid,version_value timestamptz default null,key_value uuid default null,confirm_value boolean default true) returns jsonb language sql as $$
  select pg_temp.t13_call(a.user_id,format('select * from public.submit_community_application(%L,%L,%L,%L)',x,
    coalesce(version_value,a.updated_at),coalesce(key_value,gen_random_uuid()),confirm_value)) from public.applications a where id=x;
$$;
create function pg_temp.t13_save(x uuid,f jsonb,version_value timestamptz default null) returns jsonb language sql as $$
  select pg_temp.t13_call(a.user_id,format('select * from public.save_community_application_draft(%L,%L,%L::jsonb)',x,coalesce(version_value,a.updated_at),f)) from public.applications a where id=x;
$$;
create function pg_temp.t13_review(x uuid,operation text,reason_value text default '架空の理由',due_at timestamptz default null) returns jsonb language sql as $$
  select pg_temp.t13_call(c.staff_id,format('select * from public.review_community_application(%L,%L,%L,%L,%L)',x,operation,pg_temp.t13_version(x),reason_value,due_at)) from pg_temp.t13_context c;
$$;
create function pg_temp.t13_snapshot(x uuid) returns jsonb language sql as $$ select jsonb_build_object(
  'content',private.community_snapshot(x),'room',(select to_jsonb(r) from public.room_allocations r where application_id=x),
  'events',(select jsonb_agg(to_jsonb(e) order by id) from public.application_status_events e where application_id=x),
  'audit',(select jsonb_agg(to_jsonb(l) order by id) from public.audit_logs l where entity_type='application' and entity_id=x),
  'number',(select to_jsonb(n) from public.reception_numbers n where application_id=x)); $$;

create function pg_temp.t13_payment(x uuid, state text, due date default null, why text default null,
  version_value timestamptz default null, actor uuid default null) returns jsonb language sql as $$
  select pg_temp.t13_call(coalesce(actor,c.staff_id),format('select * from public.update_application_payment(%L,%L,%L,%L,%L)',
    x,coalesce(version_value,pg_temp.t13_version(x)),state,due,why)) from pg_temp.t13_context c;
$$;
-- State unrelated to payment must remain byte-for-byte identical.
create function pg_temp.t13_protected(x uuid) returns jsonb language sql as $$
  select pg_temp.t13_snapshot(x) - 'audit' - 'content' || jsonb_build_object(
    'application',(select to_jsonb(a)-'updated_at' from public.applications a where id=x),
    'claim',(select to_jsonb(q) from public.calendar_claims q where application_id=x),
    'charge',(select to_jsonb(c)-'updated_at'-'payment_status'-'payment_due_date'-'paid_at' from public.application_charges c where application_id=x),
    'months',(select jsonb_agg(to_jsonb(m) order by m.id) from public.charge_months m join public.application_charges c on c.id=m.charge_id where c.application_id=x));
$$;
do $$ declare c pg_temp.t13_context%rowtype; x uuid; camp uuid; camp_app uuid; protected_value jsonb; snapshot_value jsonb;
  v timestamptz; paid_time timestamptz; n integer; r jsonb; kind text; a public.applications%rowtype;
begin
  if current_setting('test.operations_phase',true) in ('stays','audit-notes') then return; end if;
  select * into c from pg_temp.t13_context;
  x:=pg_temp.t13_draft(c.owner_id,c.today+20,c.today+22);
  perform pg_temp.t13_error(pg_temp.t13_payment(x,'paid'),'invalid-status','draft refused');
  perform pg_temp.t13_ok(pg_temp.t13_submit(x),'submit individual');
  -- Real camp creation and submission, outside the individual dates.
  r:=pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select public.create_staff_camp(%L,%L,%L,%L) as id',
    '架空納付キャンプ',c.today+100,c.today+102,clock_timestamp()+interval '1 day')),'create camp');
  camp:=(r->0->>'id')::uuid;
  perform pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select public.add_camp_eligible_users(%L,%L::text[])',camp,
    array[(select email from auth.users where id=c.owner_id)])),'eligible');
  r:=pg_temp.t13_ok(pg_temp.t13_call(c.owner_id,format('select public.create_camp_application_draft(%L) as id',camp)),'camp draft');
  camp_app:=(r->0->>'id')::uuid;
  perform pg_temp.t13_ok(pg_temp.t13_call(c.owner_id,format('select public.save_camp_application_draft(%L,%L,%L,%L,%L,%L,%L,%L,null,false,%L)',
    camp_app,'架空利用者','架空住所','0000000000','架空連絡先','架空住所','0000000000','架空目的','shared_ok')),'camp save');
  perform pg_temp.t13_ok(pg_temp.t13_call(c.owner_id,format('select * from public.submit_camp_application(%L)',camp_app)),'camp submit');
  perform pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select * from public.review_camp_application(%L,%L,%L)',
    camp_app,'start_review',pg_temp.t13_version(camp_app))),'camp review');
  perform pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select * from public.assign_camp_application_room(%L,%L,%L)',
    camp_app,(select id from public.rooms where name='桐'),pg_temp.t13_version(camp_app))),'camp room');
  perform pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select * from public.review_camp_application(%L,%L,%L)',
    camp_app,'approve',pg_temp.t13_version(camp_app))),'camp approved with real before_move_in stay');
  for a in select * from public.applications where id in (x,camp_app) loop
    protected_value:=pg_temp.t13_protected(a.id);
    snapshot_value:=pg_temp.t13_snapshot(a.id);
    perform pg_temp.t13_error(pg_temp.t13_payment(a.id,'paid',null,null,null,c.owner_id),'staff-required','owner cannot update','42501');
    perform pg_temp.t13_error(pg_temp.t13_payment(a.id,'paid',null,null,null,c.other_id),'staff-required','other cannot update','42501');
    perform pg_temp.t13_error(pg_temp.t13_payment(a.id,'paid',null,null,null,c.disabled_id),'staff-required','disabled denied','42501');
    perform pg_temp.t13_error(pg_temp.t13_call(null,format('select * from public.update_application_payment(%L,%L,%L,null)',a.id,a.updated_at,'paid'),'anon'),null,'anon denied','42501');
    perform pg_temp.t13_error(pg_temp.t13_payment(a.id,null),'invalid-payment-status','null state');
    perform pg_temp.t13_error(pg_temp.t13_payment(a.id,'overdue'),'invalid-payment-status','derived state not writable');
    perform pg_temp.t13_error(pg_temp.t13_payment(a.id,'unpaid','infinity'),'invalid-payment-deadline','infinite deadline');
    perform pg_temp.t13_error(pg_temp.t13_payment(a.id,'unpaid',null,repeat('あ',2001)),'reason-too-long','long reason');
    perform pg_temp.t13_error(pg_temp.t13_call(c.staff_id,format('select * from public.update_application_payment(%L,null,%L,null)',a.id,'paid')),'invalid-version','null version');
    perform pg_temp.t13_check(pg_temp.t13_snapshot(a.id)=snapshot_value,'all rejected calls leave no changes');
    v:=pg_temp.t13_version(a.id);
    perform pg_temp.t13_ok(pg_temp.t13_payment(a.id,'unpaid',c.today),'set deadline today');
    perform pg_temp.t13_check(pg_temp.t13_version(a.id)>v,'parent version increased');
    perform pg_temp.t13_error(pg_temp.t13_payment(a.id,'paid',c.today,null,v),'stale-update','old version');
    snapshot_value:=pg_temp.t13_snapshot(a.id);
    perform pg_temp.t13_ok(pg_temp.t13_payment(a.id,'unpaid',c.today),'latest identical no-op');
    perform pg_temp.t13_check(pg_temp.t13_snapshot(a.id)=snapshot_value,'no-op leaves audit and timestamps unchanged');
    perform pg_temp.t13_ok(pg_temp.t13_payment(a.id,'paid',c.today),'mark paid');
    select paid_at into paid_time from public.application_charges where application_id=a.id;
    perform pg_temp.t13_check(paid_time is not null,'paid timestamp');
    perform pg_temp.t13_ok(pg_temp.t13_payment(a.id,'paid',c.today-1),'change paid deadline');
    perform pg_temp.t13_check((select paid_at=paid_time from public.application_charges where application_id=a.id),'retain paid timestamp');
    snapshot_value:=pg_temp.t13_snapshot(a.id);
    perform pg_temp.t13_error(pg_temp.t13_payment(a.id,'unpaid',null,'  '),'reason-required','reversal reason');
    perform pg_temp.t13_check(pg_temp.t13_snapshot(a.id)=snapshot_value,'reversal failure atomic');
    perform pg_temp.t13_ok(pg_temp.t13_payment(a.id,'unpaid',null,'架空訂正理由'),'reverse and clear deadline');
    perform pg_temp.t13_check((select payment_status='unpaid' and paid_at is null and payment_due_date is null
      from public.application_charges where application_id=a.id),'unpaid fields consistent');
    perform pg_temp.t13_check(pg_temp.t13_protected(a.id)=protected_value,'fees months application room stay calendar receipt events unchanged');
    perform pg_temp.t13_check((select count(*)=4 and bool_and(actor_user_id=c.staff_id and actor_kind='staff') from public.audit_logs
      where entity_id=a.id and action='update_payment'),'one audit per actual change');
    perform pg_temp.t13_check(exists(select 1 from public.audit_logs where entity_id=a.id and action='update_payment'
      and reason='架空訂正理由' and before_data->'charge'->>'payment_status'='paid' and after_data->'charge'->>'payment_status'='unpaid'),'reversal audit before after reason');
    r:=pg_temp.t13_ok(pg_temp.t13_call(c.owner_id,format('select public.get_application_payment(%L) as data',a.id)),'owner read');
    perform pg_temp.t13_check(r->0->'data'->'charge'->>'payment_status'='unpaid' and not ((r->0->'data') ? 'audit_logs'),'read safe charge');
    perform pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select public.get_application_payment(%L)',a.id)),'staff read');
    perform pg_temp.t13_error(pg_temp.t13_call(c.other_id,format('select public.get_application_payment(%L)',a.id)),'not-found','other read denied');
    perform pg_temp.t13_error(pg_temp.t13_call(c.disabled_id,format('select public.get_application_payment(%L)',a.id)),'active-user-required','disabled read denied','42501');
    perform pg_temp.t13_error(pg_temp.t13_call(c.staff_id,format('update public.application_charges set payment_status=%L where application_id=%L returning id','paid',a.id)),null,'direct update denied','42501');
    r:=pg_temp.t13_ok(pg_temp.t13_call(c.owner_id,format('select count(*) as n from public.audit_logs where entity_id=%L',a.id)),'audit owner query');
    perform pg_temp.t13_check(r->0->>'n'='0','audit invisible to owner');
  end loop;
  -- Every existing post-submission status can retain payment records, including closed stays.
  foreach kind in array array['under_review','revision_requested','approved','rejected','cancelled','cancellation_requested'] loop
    update public.applications set status=kind where id=x;
    perform pg_temp.t13_ok(pg_temp.t13_payment(x,'unpaid',c.today),'post-submission status '||kind);
  end loop;
  -- Fixture-only stay states, not new check-in/check-out product operations.
  update public.stays set status='staying',checked_in_at=clock_timestamp() where application_id=camp_app;
  protected_value:=pg_temp.t13_protected(camp_app);
  perform pg_temp.t13_ok(pg_temp.t13_payment(camp_app,'paid',c.today),'payment while staying');
  perform pg_temp.t13_check(pg_temp.t13_protected(camp_app)=protected_value,'staying unchanged');
  update public.stays set status='moved_out',checked_out_at=clock_timestamp() where application_id=camp_app;
  protected_value:=pg_temp.t13_protected(camp_app);
  perform pg_temp.t13_ok(pg_temp.t13_payment(camp_app,'unpaid',c.today,'架空訂正'),'payment after moved out');
  perform pg_temp.t13_check(pg_temp.t13_protected(camp_app)=protected_value,'moved out unchanged');
  update public.applications set original_application_id=camp_app where id=x;
  perform pg_temp.t13_error(pg_temp.t13_payment(x,'paid'),'not-found','extensions excluded');
  update public.applications set original_application_id=null where id=x;
  delete from public.application_charges where application_id=x;
  perform pg_temp.t13_error(pg_temp.t13_payment(x,'paid'),'charge-not-found','missing charge not silently created');
end; $$;

-- Fault injection proves rollback even after stay, allocation and claim writes.
create function pg_temp.t14_fail_audit() returns trigger language plpgsql as $$ begin
  if new.action='check_out' and current_setting('test.fail_stay_audit',true)='on' then
    raise exception 'test-audit-failure';
  end if;
  return new;
end; $$;
create trigger t14_test_audit_failure before insert on public.audit_logs
for each row execute function pg_temp.t14_fail_audit();
-- Real approval APIs build the fixtures. Only test date relocation uses direct SQL,
-- because production entry windows cannot create a stay starting today.
create function pg_temp.t14_application(kind text, starts_on date, ends_on date) returns uuid language plpgsql as $$
declare owner_id uuid:=pg_temp.t13_user(); staff_id uuid:=(select c.staff_id from pg_temp.t13_context c);
  x uuid; camp uuid; r jsonb; d date:=(clock_timestamp() at time zone 'Asia/Tokyo')::date; room_id uuid;
  initial_camp_start date:=case when starts_on>d+2 then starts_on else d+50 end;
begin
  select id into room_id from public.rooms where name='桐';
  if kind='community_individual' then
    x:=pg_temp.t13_draft(owner_id,d+20,d+34);
    perform pg_temp.t13_ok(pg_temp.t13_submit(x),'stay fixture submit');
    perform pg_temp.t13_ok(pg_temp.t13_review(x,'start_review'),'stay fixture review');
    perform pg_temp.t13_ok(pg_temp.t13_call(staff_id,format('select * from public.assign_community_application_room(%L,%L,%L)',x,room_id,pg_temp.t13_version(x))),'stay fixture room');
    perform pg_temp.t13_ok(pg_temp.t13_review(x,'approve'),'stay fixture approval');
  else
    r:=pg_temp.t13_ok(pg_temp.t13_call(staff_id,format('select public.create_staff_camp(%L,%L,%L,%L) as id',
      '架空入退去キャンプ',initial_camp_start,initial_camp_start+2,clock_timestamp()+interval '1 day')),'stay camp fixture');
    camp:=(r->0->>'id')::uuid;
    perform pg_temp.t13_ok(pg_temp.t13_call(staff_id,format('select public.add_camp_eligible_users(%L,%L::text[])',camp,
      array[(select email from auth.users where id=owner_id)])),'stay eligible fixture');
    r:=pg_temp.t13_ok(pg_temp.t13_call(owner_id,format('select public.create_camp_application_draft(%L) as id',camp)),'stay camp draft');
    x:=(r->0->>'id')::uuid;
    perform pg_temp.t13_ok(pg_temp.t13_call(owner_id,format('select public.save_camp_application_draft(%L,%L,%L,%L,%L,%L,%L,%L,null,false,%L)',
      x,'架空利用者','架空住所','0000000000','架空連絡先','架空住所','0000000000','架空目的','shared_ok')),'stay camp save');
    perform pg_temp.t13_ok(pg_temp.t13_call(owner_id,format('select * from public.submit_camp_application(%L)',x)),'stay camp submit');
    perform pg_temp.t13_ok(pg_temp.t13_call(staff_id,format('select * from public.review_camp_application(%L,%L,%L)',x,'start_review',pg_temp.t13_version(x))),'stay camp review');
    perform pg_temp.t13_ok(pg_temp.t13_call(staff_id,format('select * from public.assign_camp_application_room(%L,%L,%L)',x,room_id,pg_temp.t13_version(x))),'stay camp room');
    perform pg_temp.t13_ok(pg_temp.t13_call(staff_id,format('select * from public.review_camp_application(%L,%L,%L)',x,'approve',pg_temp.t13_version(x))),'stay camp approval');
    update public.camps set start_date=starts_on,end_date=ends_on,application_deadline=starts_on::timestamp at time zone 'Asia/Tokyo' where id=camp;
  end if;
  update public.applications set start_date=starts_on,end_date=ends_on where id=x;
  update public.room_allocations set start_date=starts_on,end_date=ends_on where application_id=x;
  return x;
end; $$;
create function pg_temp.t14_stay(x uuid, op text, version_value timestamptz default null, actor uuid default null)
returns jsonb language sql as $$
  select pg_temp.t13_call(coalesce(actor,c.staff_id),format('select * from public.update_application_stay(%L,%L,%L)',
    x,coalesce(version_value,pg_temp.t13_version(x)),op)) from pg_temp.t13_context c;
$$;
create function pg_temp.t14_protected(x uuid) returns jsonb language sql as $$
  select jsonb_build_object('application',(select to_jsonb(a)-'updated_at' from public.applications a where id=x),
    'charge',(select to_jsonb(c) from public.application_charges c where application_id=x),
    'months',(select jsonb_agg(to_jsonb(m) order by m.id) from public.charge_months m join public.application_charges c on c.id=m.charge_id where c.application_id=x),
    'number',(select to_jsonb(n) from public.reception_numbers n where application_id=x),
    'events',(select jsonb_agg(to_jsonb(e) order by e.id) from public.application_status_events e where application_id=x));
$$;
do $$ declare c pg_temp.t13_context%rowtype; x uuid; kind text; r jsonb; v timestamptz; snap jsonb; protected_value jsonb;
  room_before jsonb; camp_before jsonb; owner_id uuid; candidate uuid; extra uuid; test_camp_id uuid; new_camp_app uuid; new_owner uuid; extras uuid[]:='{}'::uuid[];
begin
  if current_setting('test.operations_phase',true)='audit-notes' then return; end if;
  if to_regprocedure('public.update_application_stay(uuid,timestamptz,text)') is null then
    if current_setting('test.operations_phase',true)='stays' then raise exception 'Phase 2 requires SQL016'; end if;
    return;
  end if;
  select * into c from pg_temp.t13_context;
  foreach kind in array array['community_individual','camp'] loop
    x:=pg_temp.t14_application(kind,c.today,c.today+14);
    select a.user_id,a.camp_id into owner_id,test_camp_id from public.applications a where a.id=x;
    protected_value:=pg_temp.t14_protected(x); snap:=pg_temp.t13_snapshot(x);
    select to_jsonb(room_row) into room_before from public.room_allocations room_row where application_id=x;
    select to_jsonb(q) into camp_before from public.calendar_claims q where q.camp_id=test_camp_id;
    perform pg_temp.t13_error(pg_temp.t14_stay(x,'check_out'),'invalid-stay','cannot skip check in');
    perform pg_temp.t13_error(pg_temp.t14_stay(x,'reset'),'invalid-action','invalid operation');
    perform pg_temp.t13_error(pg_temp.t14_stay(x,'check_in',null,owner_id),'staff-required','owner cannot check in','42501');
    perform pg_temp.t13_error(pg_temp.t14_stay(x,'check_in',null,c.disabled_id),'staff-required','disabled denied','42501');
    perform pg_temp.t13_error(pg_temp.t13_call(null,format('select * from public.update_application_stay(%L,%L,%L)',x,pg_temp.t13_version(x),'check_in'),'anon'),null,'anon denied','42501');
    perform pg_temp.t13_error(pg_temp.t13_call(c.staff_id,format('select * from public.update_application_stay(%L,null,%L)',x,'check_in')),'invalid-version','missing version');
    perform pg_temp.t13_check(pg_temp.t13_snapshot(x)=snap,'failed requests have no mutations');
    v:=pg_temp.t13_version(x);
    perform pg_temp.t13_ok(pg_temp.t14_stay(x,'check_in'),'unpaid can check in');
    perform pg_temp.t13_check((select status='staying' and checked_in_at is not null and checked_out_at is null from public.stays where application_id=x),'check in timestamp shape');
    perform pg_temp.t13_check(pg_temp.t13_version(x)>v,'check in advances parent');
    perform pg_temp.t13_check((select to_jsonb(room_row)=room_before from public.room_allocations room_row where application_id=x),'check in preserves room');
    perform pg_temp.t13_error(pg_temp.t14_stay(x,'check_out',v),'stale-update','checkout with old version refused');
    perform pg_temp.t13_error(pg_temp.t14_stay(x,'check_in'),'invalid-stay','double check in refused');
    -- For individual capacity, fill the other fourteen spots without creating fake room occupancy.
    if kind='community_individual' then
      for n in 1..14 loop
        extra:=pg_temp.t13_draft(pg_temp.t13_user(),c.today+20,c.today+34);
        extras:=array_append(extras,extra);
        perform pg_temp.t13_ok(pg_temp.t13_submit(extra),'capacity fixture');
        update public.applications set start_date=c.today,end_date=c.today+14 where id=extra;
      end loop;
      perform pg_temp.t13_check(private.community_occupancy(c.today+14)=15,'before checkout facility full');
      perform pg_temp.t13_check((select availability='unavailable' from public.get_public_calendar(date_trunc('month',c.today+14)::date) where date=c.today+14),'public full before checkout');
    end if;
    snap:=pg_temp.t13_snapshot(x);
    perform set_config('test.fail_stay_audit','on',true);
    perform pg_temp.t13_error(pg_temp.t14_stay(x,'check_out'),'test-audit-failure','late transaction failure');
    perform set_config('test.fail_stay_audit','off',true);
    perform pg_temp.t13_check(pg_temp.t13_snapshot(x)=snap,'audit failure rolls back stay room claim and version');
    v:=pg_temp.t13_version(x);
    perform pg_temp.t13_ok(pg_temp.t14_stay(x,'check_out'),'same day early checkout');
    perform pg_temp.t13_check((select status='moved_out' and checked_out_at>=checked_in_at from public.stays where application_id=x),'checkout DB timestamp order');
    perform pg_temp.t13_check((select released_from=c.today+1 from public.room_allocations where application_id=x),'room release tomorrow');
    perform pg_temp.t13_check(pg_temp.t14_protected(x)=protected_value,'approval period fees receipt events unchanged');
    perform pg_temp.t13_check((select count(*)=2 and bool_and(actor_user_id=c.staff_id and actor_kind='staff') from public.audit_logs where entity_id=x and action in ('check_in','check_out')),'one audit per transition');
    perform pg_temp.t13_check(exists(select 1 from public.audit_logs where entity_id=x and action='check_out'
      and before_data->'stay'->>'status'='staying' and after_data->'stay'->>'status'='moved_out'),'audit before after');
    snap:=pg_temp.t13_snapshot(x);
    perform pg_temp.t13_error(pg_temp.t14_stay(x,'check_out',v),'stale-update','replayed checkout old version');
    perform pg_temp.t13_error(pg_temp.t14_stay(x,'check_out'),'stay-completed','double checkout');
    perform pg_temp.t13_error(pg_temp.t14_stay(x,'check_in'),'stay-completed','cannot reenter');
    perform pg_temp.t13_check(pg_temp.t13_snapshot(x)=snap,'rejected repeats keep history');
    r:=pg_temp.t13_ok(pg_temp.t13_call(owner_id,format('select public.get_application_stay(%L) as data',x)),'owner stay read');
    perform pg_temp.t13_check(r->0->'data'->'stay'->>'status'='moved_out' and r->0->'data'->>'end_date'=(c.today+14)::text,'detail keeps original end date');
    perform pg_temp.t13_check(not ((r->0->'data') ? 'audit_logs') and not ((r->0->'data'->'room_allocation') ? 'reason'),'no internal data');
    perform pg_temp.t13_error(pg_temp.t13_call(c.other_id,format('select public.get_application_stay(%L)',x)),'not-found','other read denied');
    perform pg_temp.t13_error(pg_temp.t13_call(c.disabled_id,format('select public.get_application_stay(%L)',x)),'active-user-required','disabled read denied','42501');
    r:=pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select * from public.get_staff_calendar_day(%L) where entry_id=%L',c.today,x)),'checkout day calendar');
    perform pg_temp.t13_check(jsonb_array_length(r)=1 and r->0->>'end_date'=c.today::text,'checkout day remains occupied and calendar clipped');
    r:=pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select * from public.get_staff_calendar_day(%L) where entry_id=%L',c.today+1,x)),'next day calendar');
    perform pg_temp.t13_check(jsonb_array_length(r)=0,'no entry after release');
    if kind='community_individual' then
      perform pg_temp.t13_check((select released_from=c.today+1 from public.calendar_claims where application_id=x),'individual claim release tomorrow');
      perform pg_temp.t13_check(private.community_occupancy(c.today)=15 and private.community_occupancy(c.today+14)=14,'release counts only following days');
      perform pg_temp.t13_check((select availability='available' from public.get_public_calendar(date_trunc('month',c.today+14)::date) where date=c.today+14),'public capacity reopened');
      r:=pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select * from public.get_staff_calendar(%L) where entry_id=%L',date_trunc('month',c.today)::date,x)),'month calendar');
      perform pg_temp.t13_check(r->0->>'end_date'=c.today::text,'month end clipped');
      -- Actual submission by same owner into the newly free capacity on D+14.
      candidate:=pg_temp.t13_draft(owner_id,c.today+14,c.today+15);
      extras:=array_append(extras,candidate);
      perform pg_temp.t13_ok(pg_temp.t13_submit(candidate),'same owner resubmits after release into last capacity');
      perform pg_temp.t13_check(private.community_occupancy(c.today+14)=15,'new submission counted once');
      update public.applications set status='rejected' where id=any(extras);
      -- Fixture-only historical claims: fifteen original periods overlap the new camp,
      -- but all are released before its start. Old camp capacity logic would count 16.
      update public.applications set status='approved' where id=any(extras) and start_date=c.today;
      update public.calendar_claims set released_from=c.today+1 where application_id=any(extras) and start_date=c.today;
      -- Released individual original dates no longer block a future camp or its room assignment.
      r:=pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select public.create_staff_camp(%L,%L,%L,%L) as id',
        '架空解放後キャンプ',c.today+1,c.today+2,(c.today+1)::timestamp at time zone 'Asia/Tokyo')),'new camp on released days');
      extra:=(r->0->>'id')::uuid;
      new_owner:=pg_temp.t13_user();
      perform pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select public.add_camp_eligible_users(%L,%L::text[])',extra,
        array[(select email from auth.users where id=new_owner)])),'released-day camp eligible');
      r:=pg_temp.t13_ok(pg_temp.t13_call(new_owner,format('select public.create_camp_application_draft(%L) as id',extra)),'released-day camp draft');
      new_camp_app:=(r->0->>'id')::uuid;
      perform pg_temp.t13_ok(pg_temp.t13_call(new_owner,format('select public.save_camp_application_draft(%L,%L,%L,%L,%L,%L,%L,%L,null,false,%L)',
        new_camp_app,'架空利用者','架空住所','0000000000','架空連絡先','架空住所','0000000000','架空目的','shared_ok')),'released-day camp save');
      perform pg_temp.t13_ok(pg_temp.t13_call(new_owner,format('select * from public.submit_camp_application(%L)',new_camp_app)),'released-day camp submit');
      perform pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select * from public.review_camp_application(%L,%L,%L)',new_camp_app,'start_review',pg_temp.t13_version(new_camp_app))),'released-day camp review');
      perform pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select * from public.assign_camp_application_room(%L,%L,%L)',new_camp_app,
        (select id from public.rooms where name='桐'),pg_temp.t13_version(new_camp_app))),'camp room ignores fifteen released individual periods');
      update public.applications set status='rejected' where id=new_camp_app or id=any(extras);
      perform pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select public.delete_staff_camp(%L,%L,%L)',extra,
        (select updated_at from public.camps where id=extra),'架空片付け')),'remove empty fixture camp');
    else
      perform pg_temp.t13_check((select to_jsonb(q)=camp_before from public.calendar_claims q where q.camp_id=test_camp_id),'camp-wide claim unchanged');
      perform pg_temp.t13_check((select availability='unavailable' from public.get_public_calendar(date_trunc('month',c.today+14)::date) where date=c.today+14),'camp remains unavailable despite last checkout');
      r:=pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select * from public.get_staff_calendar_day(%L) where entry_id=%L',c.today+1,test_camp_id)),'empty camp remains on calendar');
      perform pg_temp.t13_check(jsonb_array_length(r)=1 and r->0->>'people_count'='0','camp count released but block retained');
    end if;
    -- Fixture cleanup inside this rollback-only test, not product cancellation.
    update public.applications set status='rejected' where id=x;
    if test_camp_id is not null then update public.camps set deleted_at=clock_timestamp() where id=test_camp_id; end if;
  end loop;
  -- Entry date limits, corrupted metadata, final-day and overdue confirmation.
  x:=pg_temp.t14_application('community_individual',c.today+1,c.today+3);
  perform pg_temp.t13_error(pg_temp.t14_stay(x,'check_in'),'outside-stay-period','early entry refused');
  update public.applications set start_date=c.today-2,end_date=c.today where id=x;
  update public.room_allocations set start_date=c.today-2,end_date=c.today where application_id=x;
  update public.calendar_claims set released_from=c.today where application_id=x;
  perform pg_temp.t13_error(pg_temp.t14_stay(x,'check_in'),'calendar-inconsistent','pre-released claim refused');
  update public.calendar_claims set released_from=null where application_id=x;
  update public.room_allocations set released_from=c.today where application_id=x;
  perform pg_temp.t13_error(pg_temp.t14_stay(x,'check_in'),'invalid-allocation','pre-released room refused');
  update public.room_allocations set released_from=null where application_id=x;
  perform pg_temp.t13_ok(pg_temp.t14_stay(x,'check_in'),'last-day entry');
  perform pg_temp.t13_ok(pg_temp.t14_stay(x,'check_out'),'last-day checkout');
  perform pg_temp.t13_check((select released_from=c.today+1 from public.calendar_claims where application_id=x),'last-day release end+1');
  update public.applications set status='rejected' where id=x;
  x:=pg_temp.t14_application('community_individual',c.today-3,c.today-1);
  perform pg_temp.t13_error(pg_temp.t14_stay(x,'check_in'),'outside-stay-period','late entry refused');
  update public.stays set status='staying',checked_in_at=(c.today-2)::timestamp at time zone 'Asia/Tokyo' where application_id=x;
  protected_value:=pg_temp.t14_protected(x);
  perform pg_temp.t13_ok(pg_temp.t14_stay(x,'check_out'),'late confirmation');
  perform pg_temp.t13_check((select released_from=c.today from public.calendar_claims where application_id=x),'late confirmation clamped to original end+1');
  perform pg_temp.t13_check(pg_temp.t14_protected(x)=protected_value,'late checkout does not extend or recalculate');
end; $$;

create function pg_temp.t15_note(x uuid,body_value text,note_id uuid default null,version_value timestamptz default null,actor uuid default null)
returns jsonb language sql as $$ select pg_temp.t13_call(coalesce(actor,c.staff_id),format(
  'select * from public.save_application_staff_note(%L,%L,%L,%L)',x,coalesce(version_value,pg_temp.t13_version(x)),note_id,body_value)) from pg_temp.t13_context c; $$;
create function pg_temp.t15_fail_audit() returns trigger language plpgsql as $$ begin
  if new.entity_id::text=current_setting('test.fail_note_audit',true) then raise exception 'test-audit-failure'; end if;
  return new;
end; $$;
create trigger t15_test_audit_failure before insert on public.audit_logs for each row execute function pg_temp.t15_fail_audit();
do $$ declare c pg_temp.t13_context%rowtype; x uuid; other_app uuid; note_id uuid; kind text; r jsonb;
  v timestamptz; protected_value jsonb; snap jsonb; note_before jsonb; camp uuid; path1 text; path2 text; audit_count integer;
  future_start date;
begin
  if to_regprocedure('public.save_application_staff_note(uuid,timestamptz,uuid,text)') is null then
    if current_setting('test.operations_phase',true)='audit-notes' then raise exception 'Phase 3 requires SQL017'; end if; return;
  end if;
  select * into c from pg_temp.t13_context;
  select greatest(c.today+365,
    coalesce((select max(end_date)+30 from public.calendar_claims),c.today+365),
    coalesce((select max(end_date)+30 from public.applications),c.today+365),
    coalesce((select max(end_date)+30 from public.camps where deleted_at is null),c.today+365))
  into future_start;
  other_app:=pg_temp.t13_draft(c.other_id,c.today+40,c.today+42);
  foreach kind in array array['community_individual','camp'] loop
    if kind='community_individual' then x:=pg_temp.t13_draft(c.owner_id,c.today+20,c.today+22);
    else x:=pg_temp.t14_application('camp',future_start,future_start+2); end if;
    protected_value:=pg_temp.t14_protected(x); snap:=pg_temp.t13_snapshot(x);
    perform pg_temp.t13_error(pg_temp.t15_note(x,'秘密メモ',null,null,c.owner_id),'staff-required','owner cannot write note','42501');
    perform pg_temp.t13_error(pg_temp.t15_note(x,'秘密メモ',null,null,c.disabled_id),'staff-required','disabled cannot write note','42501');
    perform pg_temp.t13_error(pg_temp.t15_note(x,'  '),'note-required','empty note');
    perform pg_temp.t13_error(pg_temp.t15_note(x,repeat('あ',2001)),'note-too-long','note length');
    perform pg_temp.t13_check(pg_temp.t13_snapshot(x)=snap,'invalid note calls leave no effects');
    v:=pg_temp.t13_version(x);
    r:=pg_temp.t13_ok(pg_temp.t15_note(x,repeat('あ',2000)),'add max-length note'); note_id:=(r->0->>'result_note_id')::uuid;
    perform pg_temp.t13_check(pg_temp.t13_version(x)>v,'note advances parent version');
    perform pg_temp.t13_error(pg_temp.t15_note(x,'再送',null,v),'stale-update','double add with old parent version');
    perform pg_temp.t13_error(pg_temp.t15_note(other_app,'別申請',note_id),'note-not-found','cross-application note id');
    r:=pg_temp.t13_ok(pg_temp.t15_note(x,'内部メモ改訂',note_id),'edit note');
    snap:=pg_temp.t13_snapshot(x); select to_jsonb(n) into note_before from public.staff_notes n where id=note_id;
    perform pg_temp.t13_ok(pg_temp.t15_note(x,'内部メモ改訂',note_id),'same note no-op');
    perform pg_temp.t13_check(pg_temp.t13_snapshot(x)=snap and (select to_jsonb(n)=note_before from public.staff_notes n where id=note_id),'no-op changes no timestamps or audit');
    perform set_config('test.fail_note_audit',x::text,true);
    perform pg_temp.t13_error(pg_temp.t15_note(x,'失敗変更',note_id),'test-audit-failure','note audit failure');
    perform set_config('test.fail_note_audit','',true);
    perform pg_temp.t13_check(pg_temp.t13_snapshot(x)=snap and (select to_jsonb(n)=note_before from public.staff_notes n where id=note_id),'failed note rolls back body parent audit');
    perform pg_temp.t13_check(pg_temp.t14_protected(x)=protected_value,'notes preserve business state money stay rooms claims receipt');
    r:=pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select public.get_staff_application_notes(%L) as data',x)),'staff reads notes');
    perform pg_temp.t13_check(r->0->'data'->'notes'->0->>'body'='内部メモ改訂','staff sees edited body');
    perform pg_temp.t13_error(pg_temp.t13_call(c.owner_id,format('select public.get_staff_application_notes(%L)',x)),'staff-required','owner getter denied','42501');
    r:=pg_temp.t13_ok(pg_temp.t13_call(c.owner_id,format('select count(*) as n from public.staff_notes where application_id=%L',x)),'owner RLS read');
    perform pg_temp.t13_check(r->0->>'n'='0','notes hidden by RLS');
    perform pg_temp.t13_error(pg_temp.t13_call(c.staff_id,format('update public.staff_notes set body=%L where id=%L returning id','不正',note_id)),null,'direct note writes denied','42501');
    r:=pg_temp.t13_ok(pg_temp.t13_call((select user_id from public.applications where id=x),format('select public.get_application_payment(%L) as data',x)),'owner payment response');
    perform pg_temp.t13_check(not ((r->0->'data') ? 'notes'),'owner payment has no notes');
    perform pg_temp.t13_check((select count(*)=2 from public.audit_logs where entity_id=x and action in ('add_staff_note','edit_staff_note')),'one audit per note mutation');
  end loop;
  -- A separate camp exercises the unchanged user RPC signatures and service-only metadata API.
  r:=pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select public.create_staff_camp(%L,%L,%L,%L) as id',
    '架空監査キャンプ',future_start+10,future_start+12,clock_timestamp()+interval '1 day')),'audit camp');camp:=(r->0->>'id')::uuid;
  perform pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select public.add_camp_eligible_users(%L,%L::text[])',camp,
    array[(select email from auth.users where id=c.owner_id)])),'audit eligible');
  r:=pg_temp.t13_ok(pg_temp.t13_call(c.owner_id,format('select public.create_camp_application_draft(%L) as id',camp)),'audited create');x:=(r->0->>'id')::uuid;
  perform pg_temp.t13_ok(pg_temp.t13_call(c.owner_id,format('select public.create_camp_application_draft(%L)',camp)),'reuse draft');
  perform pg_temp.t13_check((select count(*)=1 from public.audit_logs where entity_id=x),'draft reuse no duplicate audit');
  perform pg_temp.t13_ok(pg_temp.t13_call(c.owner_id,format('select public.save_camp_application_draft(%L,%L,%L,%L,%L,%L,%L,%L,null,true,%L)',
    x,'架空監査秘密氏名','架空監査秘密住所','0000000000','架空監査秘密連絡先','架空監査秘密住所','0000000000','架空監査秘密目的','shared_ok')),'audited save');
  path1:='applications/'||x::text||'/'||gen_random_uuid()::text;path2:='applications/'||x::text||'/'||gen_random_uuid()::text;
  v:=pg_temp.t13_version(x);
  perform pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select public.register_guardian_consent_document(%L,%L,%L,%L,10)',x,c.owner_id,path1,'application/pdf'),'service_role'),'audited consent registration');
  perform pg_temp.t13_check(pg_temp.t13_version(x)>v,'camp consent advances parent');
  perform pg_temp.t13_ok(pg_temp.t13_call(c.owner_id,format('select * from public.submit_camp_application(%L)',x)),'audited submit');
  select count(*) into audit_count from public.audit_logs where entity_id=x;
  perform pg_temp.t13_ok(pg_temp.t13_call(c.owner_id,format('select * from public.submit_camp_application(%L)',x)),'submit replay');
  perform pg_temp.t13_check((select count(*)=audit_count from public.audit_logs where entity_id=x),'submission replay not duplicated');
  perform pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select * from public.review_camp_application(%L,%L,%L)',x,'start_review',pg_temp.t13_version(x))),'review existing audit');
  perform pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select * from public.review_camp_application(%L,%L,%L,%L)',x,'request_revision',pg_temp.t13_version(x),'架空修正理由')),'revision request');
  perform pg_temp.t13_ok(pg_temp.t13_call(c.owner_id,format('select public.save_camp_application_draft(%L,%L,%L,%L,%L,%L,%L,%L,null,true,%L)',
    x,'架空監査秘密氏名','架空監査秘密住所','0000000000','架空監査秘密連絡先','架空監査秘密住所','0000000000','架空監査秘密改訂目的','shared_ok')),'audited revision save');
  snap:=pg_temp.t13_snapshot(x);
  perform set_config('test.fail_note_audit',x::text,true);
  perform pg_temp.t13_error(pg_temp.t13_call(c.staff_id,format('select public.register_guardian_consent_document(%L,%L,%L,%L,20)',x,c.owner_id,path2,'application/pdf'),'service_role'),'test-audit-failure','consent audit failure');
  perform set_config('test.fail_note_audit','',true);
  perform pg_temp.t13_check(pg_temp.t13_snapshot(x)=snap,'consent metadata and parent roll back on audit failure');
  perform pg_temp.t13_ok(pg_temp.t13_call(c.staff_id,format('select public.register_guardian_consent_document(%L,%L,%L,%L,20)',x,c.owner_id,path2,'application/pdf'),'service_role'),'audited replacement');
  perform pg_temp.t13_ok(pg_temp.t13_call(c.owner_id,format('select * from public.submit_camp_application(%L)',x)),'audited resubmit');
  perform pg_temp.t13_check((select count(*)=7 from public.audit_logs where entity_id=x and actor_kind='user'),'create save consent submit replacement resubmit each once');
  perform pg_temp.t13_check((select count(*)=2 from public.audit_logs where entity_id=x and actor_kind='staff'),'existing staff audit not duplicated');
  perform pg_temp.t13_check((select bool_and(actor_user_id=c.owner_id) from public.audit_logs where entity_id=x and actor_kind='user'),'service metadata attributed to actual owner');
  perform pg_temp.t13_check(not exists(select 1 from public.audit_logs where entity_id=x and actor_kind='user'
    and (before_data::text||after_data::text like '%架空監査秘密%' or after_data::text like '%https://%')),'audit excludes personal contents and signed URLs');
  perform pg_temp.t13_check(exists(select 1 from public.audit_logs where entity_id=x and action='submit_camp_application'
    and before_data->'application'->>'status'='draft' and after_data->'application'->>'status'='submitted'
    and after_data->'application'->>'requires_guardian_consent'='true'),'audit final consent flag and status transition');
end; $$;
select count(*) as passed_checks, bool_and(passed) as all_passed from pg_temp.t13_results;
rollback;
