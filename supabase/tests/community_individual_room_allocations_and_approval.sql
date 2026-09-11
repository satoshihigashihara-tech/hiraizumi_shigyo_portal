-- SQL 014 single-connection regression. ISOLATED TEST PROJECT WITHOUT TRAFFIC.
-- Run this WHOLE file as postgres after 001-014. All fictional records and
-- temporary helpers roll back. No real Auth login, Storage API or secrets.
-- On failure ROLLBACK in the same connection. Never replace ROLLBACK with COMMIT.
begin;
set local lock_timeout='3s';
set local statement_timeout='60s';
set local timezone='UTC';
do $$ begin
  if current_user<>'postgres' or to_regprocedure('public.assign_community_application_room(uuid,uuid,timestamptz,text)') is null then raise exception 'Run as postgres after 001-014.'; end if;
  if exists(select 1 from public.calendar_claims where start_date<=(clock_timestamp() at time zone 'Asia/Tokyo')::date+60
    and end_date>=(clock_timestamp() at time zone 'Asia/Tokyo')::date+14 and (released_from is null or released_from>start_date)) then
    raise exception 'Use an isolated test project with no existing claims in the 14-60 day window.'; end if;
end; $$;
create temporary table t12i_results(n integer generated always as identity,label text,passed boolean) on commit drop;
create temporary table t12i_context(owner_id uuid,other_id uuid,staff_id uuid,disabled_id uuid,today date) on commit drop;
create function pg_temp.t12i_check(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  insert into pg_temp.t12i_results(label,passed) values(label,true);
end; $$;
create function pg_temp.t12i_user(kind text default 'user') returns uuid language plpgsql as $$ declare x uuid:=gen_random_uuid(); begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','t12i-'||x::text||'@example.invalid','',clock_timestamp(),
    '{"provider":"email","providers":["email"]}','{}',clock_timestamp(),clock_timestamp());
  if kind='staff' then insert into public.staff_roles(user_id) values(x); end if;
  if kind='disabled' then update public.profiles set account_state='disabled' where id=x; end if;
  return x;
end; $$;
insert into pg_temp.t12i_context select pg_temp.t12i_user(),pg_temp.t12i_user(),pg_temp.t12i_user('staff'),pg_temp.t12i_user('disabled'),(clock_timestamp() at time zone 'Asia/Tokyo')::date;
create function pg_temp.t12i_call(actor uuid,query_text text,role_name text default 'authenticated') returns jsonb language plpgsql security invoker as $$
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
create function pg_temp.t12i_ok(r jsonb,label text) returns jsonb language plpgsql as $$ begin
  perform pg_temp.t12i_check(r->>'ok'='true',label||': '||r::text); return r->'rows';
end; $$;
create function pg_temp.t12i_error(r jsonb,message_value text,label text,state_value text default 'P0001') returns void language plpgsql as $$ begin
  perform pg_temp.t12i_check(r->>'ok'='false' and r->>'code'=state_value and (message_value is null or r->>'message'=message_value),label||': '||r::text);
end; $$;
create function pg_temp.t12i_fields(starts_on date,ends_on date) returns jsonb language sql as $$ select jsonb_build_object(
  'start_date',starts_on,'end_date',ends_on,'user_name','架空利用者','user_address','架空住所','user_phone','000-0000-0000',
  'emergency_name','架空連絡先','emergency_address','架空住所','emergency_phone','000-0000-0000',
  'purpose','地域の調査','local_activity','平泉町内で文化を調査する','special_notes',null,
  'usage_place','common_and_second_floor','requires_guardian_consent',false); $$;
create function pg_temp.t12i_version(x uuid) returns timestamptz language sql as $$ select updated_at from public.applications where id=x; $$;
create function pg_temp.t12i_draft(actor uuid,starts_on date,ends_on date) returns uuid language plpgsql as $$ declare x uuid:=gen_random_uuid(); begin
  perform pg_temp.t12i_ok(pg_temp.t12i_call(actor,format('select * from public.create_community_application_draft(%L,%L::jsonb)',x,pg_temp.t12i_fields(starts_on,ends_on))),'create draft'); return x;
end; $$;
create function pg_temp.t12i_submit(x uuid,version_value timestamptz default null,key_value uuid default null,confirm_value boolean default true) returns jsonb language sql as $$
  select pg_temp.t12i_call(a.user_id,format('select * from public.submit_community_application(%L,%L,%L,%L)',x,
    coalesce(version_value,a.updated_at),coalesce(key_value,gen_random_uuid()),confirm_value)) from public.applications a where id=x;
$$;
create function pg_temp.t12i_save(x uuid,f jsonb,version_value timestamptz default null) returns jsonb language sql as $$
  select pg_temp.t12i_call(a.user_id,format('select * from public.save_community_application_draft(%L,%L,%L::jsonb)',x,coalesce(version_value,a.updated_at),f)) from public.applications a where id=x;
$$;
create function pg_temp.t12i_review(x uuid,operation text,reason_value text default '架空の理由',due_at timestamptz default null) returns jsonb language sql as $$
  select pg_temp.t12i_call(c.staff_id,format('select * from public.review_community_application(%L,%L,%L,%L,%L)',x,operation,pg_temp.t12i_version(x),reason_value,due_at)) from pg_temp.t12i_context c;
$$;
create function pg_temp.t12i_snapshot(x uuid) returns jsonb language sql as $$ select jsonb_build_object(
  'content',private.community_snapshot(x),'room',(select to_jsonb(r) from public.room_allocations r where application_id=x),
  'events',(select jsonb_agg(to_jsonb(e) order by id) from public.application_status_events e where application_id=x),
  'audit',(select jsonb_agg(to_jsonb(l) order by id) from public.audit_logs l where entity_type='application' and entity_id=x),
  'number',(select to_jsonb(n) from public.reception_numbers n where application_id=x)); $$;


create function pg_temp.t12i_assign(x uuid, room uuid, reason_value text default null, version_value timestamptz default null)
returns jsonb language sql as $$
  select pg_temp.t12i_call(c.staff_id,format('select * from public.assign_community_application_room(%L,%L,%L,%L)',
    x,room,coalesce(version_value,pg_temp.t12i_version(x)),reason_value)) from pg_temp.t12i_context c;
$$;
create function pg_temp.t12i_application(starts_on date default null, ends_on date default null)
returns uuid language plpgsql as $$ declare x uuid; d date := (select today+20 from pg_temp.t12i_context); begin
  x:=pg_temp.t12i_draft(pg_temp.t12i_user(),coalesce(starts_on,d),coalesce(ends_on,d+2));
  perform pg_temp.t12i_ok(pg_temp.t12i_submit(x),'real submission');
  perform pg_temp.t12i_ok(pg_temp.t12i_review(x,'start_review'),'real review');
  return x;
end; $$;
-- Isolate the next scenario by ending only this transaction's marked fixtures.
-- This is fixture manipulation, never a product cancellation or checkout API.
create function pg_temp.t12i_clear() returns void language sql as $$
  update public.applications set status='rejected' where usage_type='community_individual'
    and user_id in (select id from auth.users where email like 't12i-%@example.invalid');
$$;

-- Full lifecycle, current-version no-op, permission boundaries and immutable money.
do $$ declare c pg_temp.t12i_context%rowtype; x uuid; owner_id uuid; kiri uuid; fuji uuid;
  before_value jsonb; r jsonb; v timestamptz; room_version timestamptz; money jsonb; stay_value jsonb;
begin
  select * into c from pg_temp.t12i_context;
  select id into kiri from public.rooms where name='桐'; select id into fuji from public.rooms where name='藤';
  x:=pg_temp.t12i_draft(c.owner_id,c.today+20,c.today+22);
  perform pg_temp.t12i_error(pg_temp.t12i_assign(x,kiri),'invalid-status','draft cannot receive room');
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'invalid-status','draft cannot approve');
  perform pg_temp.t12i_ok(pg_temp.t12i_submit(x),'submit before review');
  perform pg_temp.t12i_error(pg_temp.t12i_assign(x,kiri),'invalid-status','submitted cannot receive room');
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'invalid-status','submitted cannot approve');
  perform pg_temp.t12i_ok(pg_temp.t12i_review(x,'start_review'),'explicit review');
  before_value:=pg_temp.t12i_snapshot(x);
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'room-required','missing room');
  perform pg_temp.t12i_check(pg_temp.t12i_snapshot(x)=before_value,'missing room creates nothing');
  v:=pg_temp.t12i_version(x);
  perform pg_temp.t12i_ok(pg_temp.t12i_assign(x,kiri),'initial assignment without reason');
  room_version:=pg_temp.t12i_version(x);
  perform pg_temp.t12i_check(room_version>v,'parent version advances');
  perform pg_temp.t12i_check((select people_count=1 and start_date=c.today+20 and end_date=c.today+22 and released_from is null
    from public.room_allocations where application_id=x),'one person entire inclusive period');
  perform pg_temp.t12i_check(private.community_occupancy(c.today+21)=1,'room does not double-count facility place');
  perform pg_temp.t12i_error(pg_temp.t12i_assign(x,kiri,null,v),'stale-update','even same room rejects stale version');
  perform pg_temp.t12i_error(pg_temp.t12i_assign(x,kiri,null,room_version-interval '1 microsecond'),'stale-update','microsecond mismatch');
  before_value:=pg_temp.t12i_snapshot(x);
  perform pg_temp.t12i_ok(pg_temp.t12i_assign(x,kiri),'same room no-op');
  perform pg_temp.t12i_check(pg_temp.t12i_snapshot(x)=before_value,'no-op preserves all rows and history');
  perform pg_temp.t12i_error(pg_temp.t12i_assign(x,fuji),'reason-required','pre-approval change requires reason');
  perform pg_temp.t12i_error(pg_temp.t12i_assign(x,fuji,repeat('字',2001)),'reason-too-long','oversized change reason');
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve',repeat('字',2001)),'reason-too-long','oversized approval comment');
  money:=before_value#>'{content,charge}';
  perform pg_temp.t12i_ok(pg_temp.t12i_review(x,'approve',null),'approval comment is optional');
  perform pg_temp.t12i_check((select status='approved' and approval_comment is null and revision_due_at is null from public.applications where id=x),'approval status');
  perform pg_temp.t12i_check((select status='before_move_in' and checked_in_at is null and checked_out_at is null from public.stays where application_id=x),'one before-move-in stay');
  perform pg_temp.t12i_check((pg_temp.t12i_snapshot(x)#>'{content,charge}')=money,'approval preserves fee and unpaid state');
  perform pg_temp.t12i_check((select count(*)=1 from public.application_status_events where application_id=x and to_status='approved'),'one approval event');
  perform pg_temp.t12i_check((select count(*)=1 from public.audit_logs where entity_id=x and action='approve'
    and before_data#>>'{application,status}'='under_review' and after_data#>>'{stay,status}'='before_move_in'
    and actor_user_id=c.staff_id and actor_kind='staff'),'approval snapshot includes stay and staff');
  before_value:=pg_temp.t12i_snapshot(x); stay_value:=before_value#>'{content,stay}';
  perform pg_temp.t12i_error(pg_temp.t12i_call(c.staff_id,format('select * from public.review_community_application(%L,''approve'',%L)',x,room_version)),
    'stale-update','old approval retry');
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'invalid-status','fresh version cannot approve twice');
  perform pg_temp.t12i_check(pg_temp.t12i_snapshot(x)=before_value,'duplicate approval makes no writes');
  perform pg_temp.t12i_error(pg_temp.t12i_assign(x,fuji),'reason-required','approved change requires reason');
  perform pg_temp.t12i_ok(pg_temp.t12i_assign(x,fuji,'STAFF-ONLY-ROOM-REASON'),'approved room change');
  perform pg_temp.t12i_check((pg_temp.t12i_snapshot(x)#>'{content,charge}')=money
    and (pg_temp.t12i_snapshot(x)#>'{content,stay}')=stay_value,'room change keeps money and stay');
  perform pg_temp.t12i_check((select count(*)=1 from public.audit_logs where entity_id=x and action='change_room'
    and reason='STAFF-ONLY-ROOM-REASON' and before_data#>>'{room,room_id}'=kiri::text
    and after_data#>>'{room,room_id}'=fuji::text and occurred_at is not null),'change before after reason timestamp');
  r:=pg_temp.t12i_ok(pg_temp.t12i_call(c.owner_id,format('select public.get_community_application(%L) as data',x)),'owner result');
  perform pg_temp.t12i_check(r#>>'{0,data,room_allocation,room_id}'=fuji::text
    and r#>>'{0,data,room_allocation,is_current}'='true' and r#>>'{0,data,stay,status}'='before_move_in','owner sees current room and stay');
  perform pg_temp.t12i_check(r::text not like '%STAFF-ONLY-ROOM-REASON%' and r::text not like '%actor_user_id%','owner cannot see internal history');
  before_value:=pg_temp.t12i_snapshot(x);
  r:=pg_temp.t12i_ok(pg_temp.t12i_call(c.staff_id,format('select public.get_staff_community_application_room_context(%L) as data',x)),'staff context');
  perform pg_temp.t12i_check(jsonb_array_length(r#>'{0,data,rooms}')=8 and r#>>'{0,data,updated_at}' is not null,'staff context has choices and version');
  perform pg_temp.t12i_check(pg_temp.t12i_snapshot(x)=before_value,'GET has no mutations');
  update public.stays set status='staying',checked_in_at=clock_timestamp() where application_id=x;
  perform pg_temp.t12i_ok(pg_temp.t12i_assign(x,kiri,'架空の滞在中変更'),'staying room change only');
  update public.stays set status='moved_out',checked_out_at=clock_timestamp() where application_id=x;
  before_value:=pg_temp.t12i_snapshot(x);
  perform pg_temp.t12i_error(pg_temp.t12i_assign(x,fuji,'架空の退去後変更'),'stay-completed','completed stay cannot change');
  perform pg_temp.t12i_check(pg_temp.t12i_snapshot(x)=before_value,'completed history untouched');
end; $$;
select pg_temp.t12i_clear();

-- Real date-changing and unchanged resubmissions with a previously assigned room.
do $$ declare c pg_temp.t12i_context%rowtype; x uuid; room uuid; before_value jsonb; saved_room jsonb; allocation_id uuid; block_id uuid; f jsonb; r jsonb;
begin
  select * into c from pg_temp.t12i_context; select id into room from public.rooms where name='桐';
  x:=pg_temp.t12i_application();
  perform pg_temp.t12i_ok(pg_temp.t12i_assign(x,room),'revision fixture room');
  select to_jsonb(a),id into saved_room,allocation_id from public.room_allocations a where application_id=x;
  perform pg_temp.t12i_ok(pg_temp.t12i_review(x,'request_revision'),'request revision without deadline');
  perform pg_temp.t12i_error(pg_temp.t12i_assign(x,room),'invalid-status','no room change during correction');
  f:=pg_temp.t12i_fields(c.today+24,c.today+27);
  perform pg_temp.t12i_ok(pg_temp.t12i_save(x,f),'stage new dates');
  perform pg_temp.t12i_check((select to_jsonb(a) from public.room_allocations a where application_id=x)=saved_room
    and (select start_date=c.today+20 from public.calendar_claims where application_id=x),'save retains old room and claim');
  insert into public.blocked_periods(start_date,end_date,internal_reason) values(c.today+24,c.today+27,'T12I fixture stop') returning id into block_id;
  before_value:=pg_temp.t12i_snapshot(x);
  perform pg_temp.t12i_error(pg_temp.t12i_submit(x),'calendar-unavailable','failed resubmit');
  perform pg_temp.t12i_check(pg_temp.t12i_snapshot(x)=before_value,'failed resubmit retains room claim fees and audit');
  delete from public.calendar_claims where blocked_period_id=block_id; delete from public.blocked_periods where id=block_id;
  perform pg_temp.t12i_ok(pg_temp.t12i_submit(x),'date-changing resubmit');
  perform pg_temp.t12i_check((select id=allocation_id and released_from=start_date and start_date=c.today+20
    from public.room_allocations where application_id=x),'old room fully released with old period preserved');
  r:=pg_temp.t12i_ok(pg_temp.t12i_call((select user_id from public.applications where id=x),format('select public.get_community_application(%L) as data',x)),'released owner result');
  perform pg_temp.t12i_check(r#>>'{0,data,room_allocation,is_current}'='false','released room is not current');
  perform pg_temp.t12i_ok(pg_temp.t12i_review(x,'start_review'),'review changed dates');
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'invalid-allocation','released room cannot permit new period');
  perform pg_temp.t12i_error(pg_temp.t12i_assign(x,room),'reason-required','same-room reallocation needs reason');
  perform pg_temp.t12i_ok(pg_temp.t12i_assign(x,room,'日程変更後に再割当'),'explicit new-period allocation');
  perform pg_temp.t12i_check((select id=allocation_id and start_date=c.today+24 and end_date=c.today+27 and released_from is null
    from public.room_allocations where application_id=x),'same allocation row covers new period');
  perform pg_temp.t12i_check((select count(*)=1 from public.audit_logs where entity_id=x and action='reassign_room'
    and before_data#>>'{room,released_from}' is not null and after_data#>>'{room,released_from}' is null),'reassignment audit');
  select to_jsonb(a) into saved_room from public.room_allocations a where application_id=x;
  perform pg_temp.t12i_ok(pg_temp.t12i_review(x,'request_revision'),'same period correction');
  perform pg_temp.t12i_ok(pg_temp.t12i_save(x,f||'{"purpose":"修正した目的"}'),'same period save');
  perform pg_temp.t12i_ok(pg_temp.t12i_submit(x),'same period resubmit');
  perform pg_temp.t12i_check((select to_jsonb(a) from public.room_allocations a where application_id=x)=saved_room,'same dates preserve allocation exactly');
  perform pg_temp.t12i_ok(pg_temp.t12i_review(x,'start_review'),'review before reject');
  perform pg_temp.t12i_ok(pg_temp.t12i_review(x,'reject'),'reject assigned application');
  perform pg_temp.t12i_check((select released_from=start_date from public.room_allocations where application_id=x)
    and (select released_from=start_date from public.calendar_claims where application_id=x),'rejection releases both reservations');
  perform pg_temp.t12i_check(exists(select 1 from public.reception_numbers where application_id=x)
    and exists(select 1 from public.application_charges where application_id=x),'rejection retains money and number');
  x:=pg_temp.t12i_application(c.today+24,c.today+27);
  perform pg_temp.t12i_ok(pg_temp.t12i_assign(x,room),'released room reusable');
  perform pg_temp.t12i_ok(pg_temp.t12i_review(x,'approve','架空の許可コメント'),'permit after reuse');
  perform pg_temp.t12i_check((select approval_comment='架空の許可コメント' from public.applications where id=x),'public approval comment');
end; $$;
select pg_temp.t12i_clear();

-- Every room at capacity, then one extra. Failed assignments are atomic.
do $$ declare room record; n integer; x uuid; extra uuid; before_value jsonb;
begin
  for room in select id,name,capacity from public.rooms order by name loop
    for n in 1..room.capacity loop
      x:=pg_temp.t12i_application();
      perform pg_temp.t12i_ok(pg_temp.t12i_assign(x,room.id),'room '||room.name||' place '||n);
    end loop;
    extra:=pg_temp.t12i_application(); before_value:=pg_temp.t12i_snapshot(extra);
    perform pg_temp.t12i_error(pg_temp.t12i_assign(extra,room.id),'room-capacity-full','overflow '||room.name);
    perform pg_temp.t12i_check(pg_temp.t12i_snapshot(extra)=before_value,'overflow leaves no partial writes '||room.name);
    perform pg_temp.t12i_clear();
  end loop;
end; $$;

-- Daily boundaries and an intermediate day (not merely start/end checks).
do $$ declare c pg_temp.t12i_context%rowtype; x uuid; y uuid; room uuid; other_room uuid;
begin
  select * into c from pg_temp.t12i_context; select id into room from public.rooms where name='桐';
  select id into other_room from public.rooms where name='藤';
  x:=pg_temp.t12i_application(c.today+22,c.today+23);
  perform pg_temp.t12i_ok(pg_temp.t12i_assign(x,room),'short middle stay');
  y:=pg_temp.t12i_application(c.today+20,c.today+25);
  perform pg_temp.t12i_error(pg_temp.t12i_assign(y,room),'room-capacity-full','middle days overflow');
  perform pg_temp.t12i_ok(pg_temp.t12i_assign(y,other_room),'other room available');
  perform pg_temp.t12i_error(pg_temp.t12i_assign(y,room,'競合変更'),'room-capacity-full','failed change retains old room');
  perform pg_temp.t12i_check((select room_id=other_room from public.room_allocations where application_id=y),'old allocation preserved');
  y:=pg_temp.t12i_application(c.today+23,c.today+24);
  perform pg_temp.t12i_error(pg_temp.t12i_assign(y,room),'room-capacity-full','inclusive end/start collide');
  y:=pg_temp.t12i_application(c.today+24,c.today+25);
  perform pg_temp.t12i_ok(pg_temp.t12i_assign(y,room),'next day allowed');
end; $$;
select pg_temp.t12i_clear();

-- Facility reservations include people without rooms and pending statuses.
do $$ declare c pg_temp.t12i_context%rowtype; ids uuid[]:='{}'; x uuid; room uuid; i integer; before_value jsonb;
begin
  select * into c from pg_temp.t12i_context; select id into room from public.rooms where name='桐';
  for i in 1..15 loop x:=pg_temp.t12i_application(); ids:=array_append(ids,x); end loop;
  update public.applications set status='submitted' where id=ids[2];
  update public.applications set status='revision_requested' where id=ids[3];
  update public.applications set status='cancellation_requested' where id=ids[4]; -- fixture only
  perform pg_temp.t12i_ok(pg_temp.t12i_assign(ids[1],room),'fifteen reservations may assign existing person');
  perform pg_temp.t12i_ok(pg_temp.t12i_review(ids[1],'approve'),'fifteen reservations may approve existing person');
  perform pg_temp.t12i_ok(pg_temp.t12i_assign(ids[5],(select id from public.rooms where name='藤')),'second assigned application before overflow');
  perform pg_temp.t12i_check(private.community_occupancy(c.today+21)=15,'approval does not create a sixteenth person');
  x:=pg_temp.t12i_draft(pg_temp.t12i_user(),c.today+20,c.today+22);
  perform pg_temp.t12i_error(pg_temp.t12i_submit(x),'capacity-full','sixteenth submission rejected');
  -- Invalid fixture lets us prove assignment/approval recheck capacity too.
  update public.applications set status='submitted',submitted_at=clock_timestamp() where id=x;
  before_value:=pg_temp.t12i_snapshot(ids[5]);
  perform pg_temp.t12i_error(pg_temp.t12i_assign(ids[5],room),'capacity-full','assignment checks facility overflow');
  perform pg_temp.t12i_check(pg_temp.t12i_snapshot(ids[5])=before_value,'overflow assignment atomic');
  perform pg_temp.t12i_error(pg_temp.t12i_review(ids[5],'approve'),'capacity-full','approval rechecks facility overflow');
  perform pg_temp.t12i_check(pg_temp.t12i_snapshot(ids[5])=before_value,'facility overflow approval creates no stay or history');
  perform pg_temp.t12i_error(pg_temp.t12i_assign(ids[1],room),'capacity-full','no-op still checks consistency');
  delete from public.calendar_claims where application_id=ids[6];
  perform pg_temp.t12i_error(pg_temp.t12i_assign(ids[5],room),'calendar-inconsistent','missing other claim never counted as free');
end; $$;
select pg_temp.t12i_clear();

-- Authorization, direct writes and cross-type/extension boundaries.
do $$ declare c pg_temp.t12i_context%rowtype; x uuid; room uuid; actor uuid; q text; before_value jsonb; r jsonb; camp uuid; camp_app uuid; state_value text;
begin
  select * into c from pg_temp.t12i_context; select id into room from public.rooms where name='桐'; x:=pg_temp.t12i_application();
  insert into public.staff_roles(user_id) values(c.disabled_id);
  before_value:=pg_temp.t12i_snapshot(x);
  foreach actor in array array[c.owner_id,c.other_id,c.disabled_id,null::uuid] loop
    foreach q in array array[
      format('select * from public.assign_community_application_room(%L,%L,%L)',x,room,pg_temp.t12i_version(x)),
      format('select * from public.review_community_application(%L,''approve'',%L)',x,pg_temp.t12i_version(x)),
      format('select public.get_staff_community_application_room_context(%L)',x)] loop
      perform pg_temp.t12i_error(pg_temp.t12i_call(actor,q),'staff-required','nonstaff/disabled/anonymous denied','42501');
    end loop;
  end loop;
  foreach q in array array[
    format('select * from public.assign_community_application_room(%L,%L,%L)',x,room,pg_temp.t12i_version(x)),
    format('select public.get_staff_community_application_room_context(%L)',x),
    'select private.community_room_result(null)',
    'select private.check_community_room_capacity(null,null)'] loop
    perform pg_temp.t12i_error(pg_temp.t12i_call(c.staff_id,q,'service_role'),null,'service cannot bypass staff RPC grants','42501');
    perform pg_temp.t12i_error(pg_temp.t12i_call(null,q,'anon'),null,'anon execute grant denied','42501');
  end loop;
  foreach q in array array[
    'update public.room_allocations set people_count=1 returning id',
    'insert into public.stays(application_id) values('''||x||''') returning id',
    'update public.applications set status=''approved'' returning id',
    'delete from public.audit_logs returning id',
    'delete from public.calendar_claims returning id'] loop
    perform pg_temp.t12i_error(pg_temp.t12i_call(c.staff_id,q),null,'direct writes denied','42501');
  end loop;
  perform pg_temp.t12i_error(pg_temp.t12i_call(c.staff_id,format('select * from public.assign_community_application_room(%L,%L,null)',x,room)),'invalid-version','version required in DB');
  perform pg_temp.t12i_error(pg_temp.t12i_call(c.staff_id,format('select * from public.assign_community_application_room(%L,%L,''infinity'')',x,room)),'invalid-version','finite version required');
  perform pg_temp.t12i_error(pg_temp.t12i_assign(x,gen_random_uuid()),'invalid-room','unknown room');
  perform pg_temp.t12i_error(pg_temp.t12i_assign(x,null),'invalid-room','null room');
  perform pg_temp.t12i_check(pg_temp.t12i_snapshot(x)=before_value,'unauthorized/invalid requests make no writes');
  insert into public.camps(name,start_date,end_date,application_deadline) values('T12I distant camp',c.today+100,c.today+101,clock_timestamp()) returning id into camp;
  insert into public.applications(user_id,usage_type,camp_id,status,start_date,end_date) values(c.owner_id,'camp',camp,'under_review',c.today+100,c.today+101) returning id into camp_app;
  perform pg_temp.t12i_error(pg_temp.t12i_assign(camp_app,room),'not-found','community API cannot assign camp');
  perform pg_temp.t12i_error(pg_temp.t12i_review(camp_app,'approve'),'not-found','community API cannot approve camp');
  perform pg_temp.t12i_error(pg_temp.t12i_call(c.staff_id,format('select * from public.assign_camp_application_room(%L,%L,%L)',x,room,pg_temp.t12i_version(x))),'not-found','camp API cannot assign community');
  perform pg_temp.t12i_error(pg_temp.t12i_call(c.staff_id,format('select * from public.review_camp_application(%L,''approve'',%L)',x,pg_temp.t12i_version(x))),'not-found','camp API cannot approve community');
  if to_regprocedure('public.create_community_application_extension(uuid,uuid,date,text)') is null then
    update public.applications set original_application_id=camp_app where id=x;
    perform pg_temp.t12i_error(pg_temp.t12i_assign(x,room),'not-found','legacy extension records outside T12 scope');
    update public.applications set original_application_id=null where id=x;
  end if;
  foreach state_value in array array['draft','submitted','revision_requested','rejected','cancelled','cancellation_requested'] loop
    update public.applications set status=state_value where id=x;
    perform pg_temp.t12i_error(pg_temp.t12i_assign(x,room),'invalid-status','assign rejects '||state_value);
    perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'invalid-status','approve rejects '||state_value);
  end loop;
  update public.applications set status='rejected' where id=camp_app;
  -- Owner may read own room/stay, another owner sees no rows, audits staff-only.
  x:=pg_temp.t12i_application(); perform pg_temp.t12i_ok(pg_temp.t12i_assign(x,room),'RLS fixture');
  perform pg_temp.t12i_ok(pg_temp.t12i_review(x,'approve'),'RLS approved fixture');
  actor:=(select user_id from public.applications where id=x);
  foreach q in array array[format('select * from public.room_allocations where application_id=%L',x),format('select * from public.stays where application_id=%L',x)] loop
    r:=pg_temp.t12i_ok(pg_temp.t12i_call(actor,q),'owner RLS');
    perform pg_temp.t12i_check(jsonb_array_length(r)=1,'owner sees own row');
    r:=pg_temp.t12i_ok(pg_temp.t12i_call(c.other_id,q),'other RLS');
    perform pg_temp.t12i_check(jsonb_array_length(r)=0,'other sees no row');
  end loop;
  r:=pg_temp.t12i_ok(pg_temp.t12i_call(actor,format('select * from public.audit_logs where entity_id=%L',x)),'owner audit RLS');
  perform pg_temp.t12i_check(jsonb_array_length(r)=0,'audit restricted to staff');
end; $$;
select pg_temp.t12i_clear();

-- Recheck corrupt state at approval rather than repairing it silently.
do $$ declare c pg_temp.t12i_context%rowtype; x uuid; y uuid; room uuid; other_room uuid; before_value jsonb; q_saved jsonb; block_id uuid; camp uuid;
  field_value text; saved_field text;
begin
  select * into c from pg_temp.t12i_context; select id into room from public.rooms where name='桐'; select id into other_room from public.rooms where name='藤';
  x:=pg_temp.t12i_application(); perform pg_temp.t12i_ok(pg_temp.t12i_assign(x,room),'consistency fixture');
  update public.room_allocations set end_date=start_date where application_id=x;
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'invalid-allocation','partial room period rejected');
  update public.room_allocations set end_date=c.today+22,released_from=c.today+21 where application_id=x;
  perform pg_temp.t12i_error(pg_temp.t12i_assign(x,other_room,'不正な部分解放'),'invalid-allocation','partial release cannot be reactivated');
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'invalid-allocation','released allocation rejected');
  update public.room_allocations set released_from=null where application_id=x;
  update public.calendar_claims set released_from=start_date where application_id=x;
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'calendar-inconsistent','released facility claim rejected');
  update public.calendar_claims set released_from=null,end_date=end_date+1 where application_id=x;
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'calendar-inconsistent','wrong claim period rejected');
  update public.calendar_claims set end_date=c.today+22 where application_id=x;
  insert into public.stays(application_id) values(x);
  before_value:=pg_temp.t12i_snapshot(x);
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'invalid-stay','never reset an existing stay');
  perform pg_temp.t12i_error(pg_temp.t12i_assign(x,other_room,'不正な滞在'),'invalid-stay','unapproved stay cannot change rooms');
  perform pg_temp.t12i_check(pg_temp.t12i_snapshot(x)=before_value,'invalid stay remains unchanged');
  delete from public.stays where application_id=x;
  update public.applications set requires_guardian_consent=true where id=x;
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'guardian-consent','approval rechecks required consent');
  update public.applications set requires_guardian_consent=false,local_activity=null where id=x;
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'required-fields','approval rechecks submitted fields');
  update public.applications set local_activity='架空の地域活動',email_snapshot='bad' where id=x;
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'invalid-email','approval validates applicant snapshot email');
  update public.applications set email_snapshot='fixture@example.invalid' where id=x;
  update public.application_charges set total_amount=1 where application_id=x;
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'application-inconsistent','broken charge total rejected');
  update public.application_charges set total_amount=900,payment_status='paid',paid_at=clock_timestamp(),payment_due_date=c.today where application_id=x;
  -- Pending reservations already exclude new stops/camps, before and after approval.
  perform pg_temp.t12i_error(pg_temp.t12i_call(c.staff_id,format('select * from public.save_staff_blocked_period(null,%L,%L,''架空の停止'')',c.today+22,c.today+23)),
    'date-conflict','new block conflicts with reviewed individual');
  perform pg_temp.t12i_error(pg_temp.t12i_call(c.staff_id,format('select public.create_staff_camp(''架空のキャンプ'',%L,%L,%L)',c.today+22,c.today+23,(c.today+21)::timestamp at time zone 'Asia/Tokyo')),
    'date-conflict','new camp conflicts with reviewed individual');
  insert into public.blocked_periods(start_date,end_date,internal_reason) values(c.today+21,c.today+22,'T12I inconsistent stop') returning id into block_id;
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'calendar-unavailable','approval rechecks stop overlap');
  delete from public.calendar_claims where blocked_period_id=block_id;
  perform pg_temp.t12i_error(pg_temp.t12i_assign(x,room),'calendar-unavailable','missing stop claim cannot bypass source');
  delete from public.blocked_periods where id=block_id;
  insert into public.camps(name,start_date,end_date,application_deadline) values('T12I inconsistent camp',c.today+22,c.today+23,clock_timestamp()) returning id into camp;
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'calendar-unavailable','approval rechecks camp endpoint');
  delete from public.calendar_claims where camp_id=camp;
  perform pg_temp.t12i_error(pg_temp.t12i_assign(x,room),'calendar-unavailable','missing camp claim cannot bypass source');
  delete from public.camps where id=camp;
  -- Corrupt overlapping allocation must also be rejected at approval.
  y:=pg_temp.t12i_application();
  insert into public.room_allocations(application_id,room_id,start_date,end_date) values(y,room,c.today+20,c.today+22);
  before_value:=pg_temp.t12i_snapshot(x);
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'room-capacity-full','approval rechecks room capacity');
  perform pg_temp.t12i_check(pg_temp.t12i_snapshot(x)=before_value,'overflow approval atomic');
  update public.room_allocations set released_from=start_date where application_id=y;
  -- Approval is not a new submission; original 14-day window is not reapplied.
  update public.applications set start_date=c.today+5,end_date=c.today+7 where id=x;
  update public.room_allocations set start_date=c.today+5,end_date=c.today+7 where application_id=x;
  before_value:=pg_temp.t12i_snapshot(x);
  perform pg_temp.t12i_ok(pg_temp.t12i_review(x,'approve','開始間近の審査完了'),'approval near start allowed');
  perform pg_temp.t12i_check((pg_temp.t12i_snapshot(x)#>'{content,charge}')=(before_value#>'{content,charge}'),'paid state deadline amount preserved');
end; $$;
select pg_temp.t12i_clear();

-- Force a final audit failure. The entire operation must roll back, including
-- status, room, stay, claims, version and public events. Helper is rollback-only.
create temporary table t12i_failure(action text) on commit drop;
create function pg_temp.t12i_fail_audit() returns trigger language plpgsql as $$ begin
  if exists(select 1 from pg_temp.t12i_failure where action=new.action) then raise exception 't12i-audit-failure'; end if;
  return new;
end; $$;
create trigger t12i_fail_audit before insert on public.audit_logs for each row execute function pg_temp.t12i_fail_audit();
do $$ declare x uuid; room uuid; other_room uuid; before_value jsonb; operation text;
begin
  select id into room from public.rooms where name='桐'; select id into other_room from public.rooms where name='藤';
  x:=pg_temp.t12i_application(); before_value:=pg_temp.t12i_snapshot(x);
  insert into pg_temp.t12i_failure values('assign_room');
  perform pg_temp.t12i_error(pg_temp.t12i_assign(x,room),'t12i-audit-failure','injected assignment failure');
  perform pg_temp.t12i_check(pg_temp.t12i_snapshot(x)=before_value,'assignment fully atomic');
  delete from pg_temp.t12i_failure;
  perform pg_temp.t12i_ok(pg_temp.t12i_assign(x,room),'assign after failure removed');
  before_value:=pg_temp.t12i_snapshot(x);
  insert into pg_temp.t12i_failure values('change_room');
  perform pg_temp.t12i_error(pg_temp.t12i_assign(x,other_room,'変更失敗'),'t12i-audit-failure','injected change failure');
  perform pg_temp.t12i_check(pg_temp.t12i_snapshot(x)=before_value,'room change fully atomic');
  delete from pg_temp.t12i_failure; insert into pg_temp.t12i_failure values('approve');
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'approve'),'t12i-audit-failure','injected approval failure');
  perform pg_temp.t12i_check(pg_temp.t12i_snapshot(x)=before_value,'approval fully atomic');
  delete from pg_temp.t12i_failure; insert into pg_temp.t12i_failure values('reject');
  perform pg_temp.t12i_error(pg_temp.t12i_review(x,'reject'),'t12i-audit-failure','injected rejection failure');
  perform pg_temp.t12i_check(pg_temp.t12i_snapshot(x)=before_value,'rejection fully atomic');
end; $$;
drop trigger t12i_fail_audit on public.audit_logs;
select count(*) as passed_checks,'Single connection; simulated auth; all fictional changes rolled back.' as scope from pg_temp.t12i_results;
rollback;
