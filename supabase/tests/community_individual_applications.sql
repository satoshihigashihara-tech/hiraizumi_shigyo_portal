-- T10 single-connection regression; postgres, isolated Supabase TEST project, 001-014.
-- Run the WHOLE file. Fictional data, role/claim simulation, no Auth/Storage API.
-- Final ROLLBACK removes all fixtures, temporary helpers and injected failures.
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
create temporary table t10_results(n integer generated always as identity,label text,passed boolean) on commit drop;
create temporary table t10_context(owner_id uuid,other_id uuid,staff_id uuid,disabled_id uuid,today date) on commit drop;
create function pg_temp.t10_check(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  insert into pg_temp.t10_results(label,passed) values(label,true);
end; $$;
create function pg_temp.t10_user(kind text default 'user') returns uuid language plpgsql as $$ declare x uuid:=gen_random_uuid(); begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','t10-'||x::text||'@example.invalid','',clock_timestamp(),
    '{"provider":"email","providers":["email"]}','{}',clock_timestamp(),clock_timestamp());
  if kind='staff' then insert into public.staff_roles(user_id) values(x); end if;
  if kind='disabled' then update public.profiles set account_state='disabled' where id=x; end if;
  return x;
end; $$;
insert into pg_temp.t10_context select pg_temp.t10_user(),pg_temp.t10_user(),pg_temp.t10_user('staff'),pg_temp.t10_user('disabled'),(clock_timestamp() at time zone 'Asia/Tokyo')::date;
create function pg_temp.t10_call(actor uuid,query_text text,role_name text default 'authenticated') returns jsonb language plpgsql security invoker as $$
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
create function pg_temp.t10_ok(r jsonb,label text) returns jsonb language plpgsql as $$ begin
  perform pg_temp.t10_check(r->>'ok'='true',label||': '||r::text); return r->'rows';
end; $$;
create function pg_temp.t10_error(r jsonb,message_value text,label text,state_value text default 'P0001') returns void language plpgsql as $$ begin
  perform pg_temp.t10_check(r->>'ok'='false' and r->>'code'=state_value and (message_value is null or r->>'message'=message_value),label||': '||r::text);
end; $$;
create function pg_temp.t10_fields(starts_on date,ends_on date) returns jsonb language sql as $$ select jsonb_build_object(
  'start_date',starts_on,'end_date',ends_on,'user_name','架空利用者','user_address','架空住所','user_phone','000-0000-0000',
  'emergency_name','架空連絡先','emergency_address','架空住所','emergency_phone','000-0000-0000',
  'purpose','地域の調査','local_activity','平泉町内で文化を調査する','special_notes',null,
  'usage_place','common_and_second_floor','requires_guardian_consent',false); $$;
create function pg_temp.t10_version(x uuid) returns timestamptz language sql as $$ select updated_at from public.applications where id=x; $$;
create function pg_temp.t10_draft(actor uuid,starts_on date,ends_on date) returns uuid language plpgsql as $$ declare x uuid:=gen_random_uuid(); begin
  perform pg_temp.t10_ok(pg_temp.t10_call(actor,format('select * from public.create_community_application_draft(%L,%L::jsonb)',x,pg_temp.t10_fields(starts_on,ends_on))),'create draft'); return x;
end; $$;
create function pg_temp.t10_submit(x uuid,version_value timestamptz default null,key_value uuid default null,confirm_value boolean default true) returns jsonb language sql as $$
  select pg_temp.t10_call(a.user_id,format('select * from public.submit_community_application(%L,%L,%L,%L)',x,
    coalesce(version_value,a.updated_at),coalesce(key_value,gen_random_uuid()),confirm_value)) from public.applications a where id=x;
$$;
create function pg_temp.t10_save(x uuid,f jsonb,version_value timestamptz default null) returns jsonb language sql as $$
  select pg_temp.t10_call(a.user_id,format('select * from public.save_community_application_draft(%L,%L,%L::jsonb)',x,coalesce(version_value,a.updated_at),f)) from public.applications a where id=x;
$$;
create function pg_temp.t10_review(x uuid,operation text,reason_value text default '架空の理由',due_at timestamptz default null) returns jsonb language sql as $$
  select pg_temp.t10_call(c.staff_id,format('select * from public.review_community_application(%L,%L,%L,%L,%L)',x,operation,pg_temp.t10_version(x),reason_value,due_at)) from pg_temp.t10_context c;
$$;
create function pg_temp.t10_snapshot(x uuid) returns jsonb language sql as $$ select jsonb_build_object(
  'content',private.community_snapshot(x),'room',(select to_jsonb(r) from public.room_allocations r where application_id=x),
  'events',(select jsonb_agg(to_jsonb(e) order by id) from public.application_status_events e where application_id=x),
  'audit',(select jsonb_agg(to_jsonb(l) order by id) from public.audit_logs l where entity_type='application' and entity_id=x),
  'number',(select to_jsonb(n) from public.reception_numbers n where application_id=x)); $$;

-- Real lifecycle; revisions stage dates without reserving both periods.
do $$ declare c pg_temp.t10_context%rowtype; x uuid; f jsonb; v timestamptz; key_value uuid:=gen_random_uuid(); before_value jsonb; r jsonb; receipt text; first_at timestamptz; block_id uuid; charge_before jsonb; months_before jsonb;
begin
  select * into c from pg_temp.t10_context;
  update public.profiles set full_name='プロフィールの架空名' where id=c.owner_id;
  x:=gen_random_uuid();
  r:=pg_temp.t10_ok(pg_temp.t10_call(c.owner_id,format('select * from public.create_community_application_draft(%L)',x)),'empty draft and profile');
  perform pg_temp.t10_check((select user_name='プロフィールの架空名' and status='draft' and start_date is null from public.applications where id=x),'profile initial values');
  before_value:=pg_temp.t10_snapshot(x);
  perform pg_temp.t10_ok(pg_temp.t10_call(c.owner_id,format('select * from public.create_community_application_draft(%L)',x)),'creation retry');
  perform pg_temp.t10_check(pg_temp.t10_snapshot(x)=before_value,'creation retry has no writes');
  perform pg_temp.t10_check(not exists(select 1 from public.calendar_claims where application_id=x) and not exists(select 1 from public.reception_numbers where application_id=x)
    and not exists(select 1 from public.application_charges where application_id=x),'draft has no claim receipt or fee');
  perform pg_temp.t10_error(pg_temp.t10_submit(x),'invalid-period','incomplete draft rejected');
  f:=pg_temp.t10_fields(c.today+20,c.today+21); v:=pg_temp.t10_version(x);
  perform pg_temp.t10_ok(pg_temp.t10_save(x,f),'save');
  perform pg_temp.t10_error(pg_temp.t10_save(x,f,v),'stale-update','stale save');
  perform pg_temp.t10_check(pg_temp.t10_version(x)>v,'version monotonic');
  perform pg_temp.t10_error(pg_temp.t10_submit(x,null,null,false),'confirmation-required','confirmation required');
  v:=pg_temp.t10_version(x);
  perform pg_temp.t10_ok(pg_temp.t10_submit(x,v,key_value),'first submit');
  select submitted_at into first_at from public.applications where id=x;
  select display_number into receipt from public.reception_numbers where application_id=x;
  perform pg_temp.t10_check((select total_amount=600 and payment_status='unpaid' from public.application_charges where application_id=x),'two days cost 600');
  perform pg_temp.t10_check((select count(*)=1 from public.calendar_claims where application_id=x and released_from is null),'one personal claim');
  before_value:=pg_temp.t10_snapshot(x);
  perform pg_temp.t10_ok(pg_temp.t10_submit(x,v,key_value),'same submission retry');
  perform pg_temp.t10_check(pg_temp.t10_snapshot(x)=before_value,'retry does not change fee number history or version');
  perform pg_temp.t10_error(pg_temp.t10_submit(x,v,gen_random_uuid()),'stale-update','different stale submit');
  perform pg_temp.t10_error(pg_temp.t10_save(x,f),'not-editable','submitted cannot edit');
  perform pg_temp.t10_error(pg_temp.t10_review(x,'approve'),'invalid-status','submitted cannot bypass explicit review');
  perform pg_temp.t10_error(pg_temp.t10_review(x,'cancel'),'invalid-action','T17 cancellation unavailable');
  perform pg_temp.t10_ok(pg_temp.t10_review(x,'start_review'),'explicit review');
  perform pg_temp.t10_error(pg_temp.t10_review(x,'request_revision',''),'reason-required','revision needs reason');
  perform pg_temp.t10_error(pg_temp.t10_review(x,'request_revision','架空',clock_timestamp()-interval '1 second'),'invalid-deadline','past revision deadline');
  perform pg_temp.t10_ok(pg_temp.t10_review(x,'request_revision','架空',((c.today+3)::timestamp at time zone 'Asia/Tokyo')),'revision with optional deadline');
  f:=f||jsonb_build_object('user_name','修正後の架空名','start_date',c.today+22,'end_date',c.today+24);
  perform pg_temp.t10_ok(pg_temp.t10_save(x,f),'save proposed period');
  perform pg_temp.t10_check((select start_date=c.today+20 and revision_start_date=c.today+22 from public.applications where id=x)
    and (select start_date=c.today+20 and end_date=c.today+21 from public.calendar_claims where application_id=x)
    and (select total_amount=600 from public.application_charges where application_id=x),'revision save keeps original reservation and charge');
  insert into public.blocked_periods(start_date,end_date,internal_reason) values(c.today+22,c.today+24,'T10 test maintenance') returning id into block_id;
  before_value:=pg_temp.t10_snapshot(x);
  perform pg_temp.t10_error(pg_temp.t10_submit(x),'calendar-unavailable','changed dates conflict');
  perform pg_temp.t10_check(pg_temp.t10_snapshot(x)=before_value,'failed date change preserves old claim and fee');
  delete from public.calendar_claims where blocked_period_id=block_id; delete from public.blocked_periods where id=block_id;
  -- Fixture only: T10 must preserve existing payment information when repricing.
  update public.application_charges set payment_status='paid',paid_at=first_at,payment_due_date=c.today+10 where application_id=x;
  perform pg_temp.t10_ok(pg_temp.t10_submit(x),'changed dates resubmit');
  perform pg_temp.t10_check((select payment_status='paid' and paid_at=first_at and payment_due_date=c.today+10 from public.application_charges where application_id=x),'repricing preserves payment status date and deadline');
  perform pg_temp.t10_check((select start_date=c.today+22 and revision_start_date is null and submitted_at=first_at from public.applications where id=x)
    and (select total_amount=900 from public.application_charges where application_id=x)
    and (select display_number=receipt from public.reception_numbers where application_id=x),'resubmission updates period and fee but keeps first receipt/time');
  perform pg_temp.t10_ok(pg_temp.t10_review(x,'start_review'),'review again');
  perform pg_temp.t10_ok(pg_temp.t10_review(x,'request_revision'),'individual revision deadline can be unset');
  perform pg_temp.t10_check((select revision_due_at is null from public.applications where id=x),'no group deadline introduced');
  -- A prior successful submission can now be inside 14 days. Change fixtures only,
  -- then exercise the real save + submit RPCs without changing this accepted period.
  update public.applications set start_date=c.today+5,end_date=c.today+7 where id=x;
  f:=f||jsonb_build_object('start_date',c.today+5,'end_date',c.today+7);
  select to_jsonb(ch) into charge_before from public.application_charges ch where application_id=x;
  select jsonb_agg(to_jsonb(m) order by m.month) into months_before from public.charge_months m join public.application_charges ch on ch.id=m.charge_id where ch.application_id=x;
  perform pg_temp.t10_ok(pg_temp.t10_save(x,f),'save unchanged near-start dates');
  perform pg_temp.t10_ok(pg_temp.t10_submit(x),'same dates not subject to initial window');
  perform pg_temp.t10_check((select to_jsonb(ch) from public.application_charges ch where application_id=x)=charge_before
    and (select jsonb_agg(to_jsonb(m) order by m.month) from public.charge_months m join public.application_charges ch on ch.id=m.charge_id where ch.application_id=x)=months_before,
    'unchanged resubmission preserves all charge and month fields including calculation time');
  perform pg_temp.t10_ok(pg_temp.t10_review(x,'start_review'),'review before rejection');
  perform pg_temp.t10_ok(pg_temp.t10_review(x,'reject'),'reject');
  perform pg_temp.t10_check((select released_from=start_date from public.calendar_claims where application_id=x),'rejection frees personal reservation');
  perform pg_temp.t10_check(exists(select 1 from public.application_charges where application_id=x) and exists(select 1 from public.reception_numbers where application_id=x),'rejection retains financial history');
end; $$;

-- Exact boundary tests use a private pure date predicate, never a public clock override.
do $$ declare starts_on date; days integer; expected text; r jsonb; c pg_temp.t10_context%rowtype; x uuid; f jsonb;
begin
  select * into c from pg_temp.t10_context;
  for starts_on,days,expected in select * from (values
    (c.today+13,2,'start-too-soon'),(c.today+14,2,null::text),(c.today+59,2,null),(c.today+60,2,'end-too-late'),
    (c.today+30,2,null),(c.today+30,15,null),(c.today+30,1,'invalid-duration'),(c.today+30,16,'invalid-duration')) t(s,d,e) loop
    begin
      perform private.check_community_period(starts_on,starts_on+days-1,clock_timestamp(),true);
      r:=jsonb_build_object('ok',true);
    exception when others then r:=jsonb_build_object('ok',false,'code',sqlstate,'message',sqlerrm); end;
    if expected is null then perform pg_temp.t10_check(r->>'ok'='true','valid boundary '||starts_on||'/'||days);
    else perform pg_temp.t10_error(r,expected,'invalid boundary'); end if;
  end loop;
  perform private.check_community_period('2026-09-24','2026-09-25','2026-09-10T14:59:59Z',true);
  perform pg_temp.t10_check(true,'JST day before midnight');
  begin perform private.check_community_period('2026-09-24','2026-09-25','2026-09-10T15:00:00Z',true);
    raise exception 'expected start-too-soon'; exception when others then perform pg_temp.t10_check(sqlerrm='start-too-soon','JST exact midnight'); end;
  perform private.check_community_period('2028-02-28','2028-03-01','2028-02-01T00:00:00+09:00',true);
  perform private.check_community_period('2026-12-31','2027-01-02','2026-12-01T00:00:00+09:00',true);
  perform pg_temp.t10_check(true,'leap date and year boundary');
  x:=pg_temp.t10_draft(c.other_id,c.today+13,c.today+14);
  perform pg_temp.t10_error(pg_temp.t10_submit(x),'start-too-soon','real first submit rejects too soon');
  f:=pg_temp.t10_fields(c.today+59,c.today+60);
  perform pg_temp.t10_ok(pg_temp.t10_save(x,f),'save 60-day edge');
  perform pg_temp.t10_ok(pg_temp.t10_submit(x),'real submission includes 60th day');
  perform pg_temp.t10_ok(pg_temp.t10_review(x,'start_review'),'edge review');
  perform pg_temp.t10_ok(pg_temp.t10_review(x,'request_revision'),'edge revision');
  perform pg_temp.t10_ok(pg_temp.t10_save(x,pg_temp.t10_fields(c.today+60,c.today+61)),'save date candidate outside window');
  perform pg_temp.t10_error(pg_temp.t10_submit(x),'end-too-late','changed date window rechecked');
  update public.applications set revision_due_at=clock_timestamp()-interval '1 second' where id=x;
  perform pg_temp.t10_error(pg_temp.t10_save(x,f),'revision-expired','expired revision save');
  perform pg_temp.t10_error(pg_temp.t10_submit(x),'revision-expired','expired revision submit');
  perform pg_temp.t10_check((select status='revision_requested' from public.applications where id=x) and (select released_from is null from public.calendar_claims where application_id=x),'expiry does not cancel or free claim');
end; $$;

-- Required inputs, direct-RPC JSON validation, owner-only reads, legacy bypasses.
do $$ declare c pg_temp.t10_context%rowtype; x uuid; f jsonb; r jsonb; actor uuid; q text; field text; before_value jsonb;
begin
  select * into c from pg_temp.t10_context;
  x:=pg_temp.t10_draft(c.owner_id,c.today+30,c.today+31); f:=pg_temp.t10_fields(c.today+30,c.today+31);
  foreach field in array array['user_name','user_address','user_phone','emergency_name','emergency_address','emergency_phone','purpose','local_activity','usage_place','requires_guardian_consent'] loop
    perform pg_temp.t10_ok(pg_temp.t10_save(x,f||jsonb_build_object(field,null)),'partial save '||field);
    perform pg_temp.t10_error(pg_temp.t10_submit(x),'required-fields','required '||field);
  end loop;
  perform pg_temp.t10_error(pg_temp.t10_save(x,f||'{"status":"approved"}'),'invalid-fields','JSON status injection');
  perform pg_temp.t10_error(pg_temp.t10_save(x,f||'{"requires_guardian_consent":"false"}'),'invalid-fields','boolean type injection');
  perform pg_temp.t10_error(pg_temp.t10_save(x,f||'{"purpose":42}'),'invalid-fields','text type injection');
  perform pg_temp.t10_error(pg_temp.t10_save(x,f||jsonb_build_object('local_activity',repeat('あ',2001))),'field-too-long','Unicode limit');
  perform pg_temp.t10_error(pg_temp.t10_save(x,f||'{"start_date":"2026-02-30"}'),'invalid-period','invalid real date');
  perform pg_temp.t10_error(pg_temp.t10_save(x,f||'{"user_phone":"abc"}'),'invalid-phone','bad phone');
  perform pg_temp.t10_error(pg_temp.t10_save(x,f||'{"usage_place":"other"}'),'invalid-place','bad place');
  perform pg_temp.t10_ok(pg_temp.t10_save(x,f),'restore fields'); before_value:=pg_temp.t10_snapshot(x);
  foreach actor in array array[c.other_id,c.disabled_id,null::uuid] loop
    r:=pg_temp.t10_call(actor,format('select * from public.save_community_application_draft(%L,%L,%L::jsonb)',x,pg_temp.t10_version(x),f));
    perform pg_temp.t10_error(r,case when actor=c.other_id then 'not-found' else null end,'wrong actor save',case when actor=c.other_id then 'P0001' else '42501' end);
    r:=pg_temp.t10_call(actor,format('select public.get_community_application(%L)',x));
    perform pg_temp.t10_error(r,case when actor=c.other_id then 'not-found' else null end,'wrong actor read',case when actor=c.other_id then 'P0001' else '42501' end);
  end loop;
  perform pg_temp.t10_error(pg_temp.t10_call(c.other_id,format('select * from public.create_community_application_draft(%L)',x)),'not-found','cannot reuse someone else UUID');
  perform pg_temp.t10_error(pg_temp.t10_call(c.owner_id,format('select * from public.review_community_application(%L,''start_review'',%L)',x,pg_temp.t10_version(x))),null,'nonstaff review denied','42501');
  perform pg_temp.t10_error(pg_temp.t10_call(c.owner_id,format('select public.save_camp_application_draft(%L,''x'',''x'',''00000000'',''x'',''x'',''00000000'',''x'',null,false,''shared_ok'')',x)),null,'legacy camp save cannot edit community');
  perform pg_temp.t10_error(pg_temp.t10_call(c.owner_id,format('select * from public.submit_camp_application(%L)',x)),null,'legacy camp submit cannot submit community');
  perform pg_temp.t10_check(pg_temp.t10_snapshot(x)=before_value,'all rejected entries preserve data');
  foreach q in array array['update public.applications set status=''approved'' returning id','delete from public.calendar_claims returning id',
    'update public.application_charges set total_amount=0 returning id','select private.lock_community_user()'] loop
    perform pg_temp.t10_error(pg_temp.t10_call(c.staff_id,q),null,'direct writes/internal calls denied','42501');
  end loop;
  r:=pg_temp.t10_ok(pg_temp.t10_call(c.owner_id,format('select public.get_community_application(%L) as data',x)),'owner detail');
  perform pg_temp.t10_check(not ((r#>'{0,data}') ? 'user_id') and not ((r#>'{0,data}') ? 'last_submission_key')
    and not exists(select 1 from jsonb_array_elements(r#>'{0,data,events}') e where e ? 'actor_user_id'),'owner read excludes staff and retry internals');
  perform pg_temp.t10_check(pg_temp.t10_snapshot(x)=before_value,'GET makes no writes');
  -- Auth deletion leaves the record, never grants another active user ownership.
  update public.applications set user_id=null where id=x;
  perform pg_temp.t10_error(pg_temp.t10_call(c.owner_id,format('select * from public.save_community_application_draft(%L,%L,%L::jsonb)',x,pg_temp.t10_version(x),f)),'not-found','NULL owner is denied');
end; $$;

-- Verified metadata is service-only; changes invalidate saved forms and retain old submitted files.
do $$ declare c pg_temp.t10_context%rowtype; x uuid; v timestamptz; path1 text; path2 text; r jsonb; f jsonb;
begin
  select * into c from pg_temp.t10_context;
  x:=pg_temp.t10_draft(c.owner_id,c.today+32,c.today+33); f:=pg_temp.t10_fields(c.today+32,c.today+33)||'{"requires_guardian_consent":true}';
  perform pg_temp.t10_ok(pg_temp.t10_save(x,f),'requires consent');
  perform pg_temp.t10_error(pg_temp.t10_submit(x),'guardian-consent','missing consent');
  path1:='applications/'||x||'/'||gen_random_uuid(); path2:='applications/'||x||'/'||gen_random_uuid();v:=pg_temp.t10_version(x);
  perform pg_temp.t10_error(pg_temp.t10_call(c.owner_id,format('select * from public.register_community_guardian_consent_document(%L,%L,%L,%L,''application/pdf'',100)',x,c.owner_id,v,path1)),null,'direct consent registration denied','42501');
  perform pg_temp.t10_error(pg_temp.t10_call(null,format('select public.register_guardian_consent_document(%L,%L,%L,''application/pdf'',100)',x,c.owner_id,path1),'service_role'),null,'legacy registration denied for community');
  r:=pg_temp.t10_ok(pg_temp.t10_call(null,format('select * from public.register_community_guardian_consent_document(%L,%L,%L,%L,''application/pdf'',100)',x,c.owner_id,v,path1),'service_role'),'verified attachment');
  perform pg_temp.t10_check(pg_temp.t10_version(x)>v,'consent advances parent version');
  perform pg_temp.t10_error(pg_temp.t10_submit(x,v),'stale-update','stale confirmation after attachment');
  perform pg_temp.t10_ok(pg_temp.t10_submit(x),'consent submission');
  perform pg_temp.t10_ok(pg_temp.t10_review(x,'start_review'),'consent review');
  perform pg_temp.t10_ok(pg_temp.t10_review(x,'request_revision'),'consent revision');
  r:=pg_temp.t10_ok(pg_temp.t10_call(null,format('select * from public.register_community_guardian_consent_document(%L,%L,%L,%L,''image/png'',100)',x,c.owner_id,pg_temp.t10_version(x),path2),'service_role'),'replace submitted consent');
  perform pg_temp.t10_check(r#>>'{0,previous_object_path}'=path1 and r#>>'{0,delete_previous}'='false','submitted old file must be retained');
  perform pg_temp.t10_check(exists(select 1 from public.audit_logs where entity_id=x and before_data#>>'{consent,object_path}'=path1),'old path in staff-only history');
end; $$;

-- Day-by-day capacity, status holds, inclusive endpoints, public privacy and staff conflicts.
do $$ declare c pg_temp.t10_context%rowtype; x uuid; ids uuid[]:='{}'; actor uuid; i integer; q jsonb; camp_id uuid; version_value timestamptz; candidate uuid; day_value date;
begin
  select * into c from pg_temp.t10_context;
  for i in 1..15 loop
    actor:=pg_temp.t10_user(); x:=pg_temp.t10_draft(actor,c.today+40,c.today+41);
    perform pg_temp.t10_ok(pg_temp.t10_submit(x),'capacity submit '||i);ids:=array_append(ids,x);
    q:=pg_temp.t10_ok(pg_temp.t10_call(null,format('select * from public.get_public_calendar(%L) where date=%L',date_trunc('month',c.today+40)::date,c.today+40),'anon'),'public capacity');
    perform pg_temp.t10_check(q#>>'{0,availability}'=case when i=15 then 'unavailable' else 'available' end,'public threshold '||i);
    perform pg_temp.t10_check((select count(*)=2 from jsonb_object_keys(q->0)),'public only two fields');
  end loop;
  update public.applications set status='revision_requested' where id=ids[1];
  update public.applications set status='cancellation_requested' where id=ids[2]; -- fixture only, no cancellation RPC
  update public.applications set status='approved' where id=ids[3]; -- capacity fixture only; real approval is covered by T12
  x:=pg_temp.t10_draft(pg_temp.t10_user(),c.today+41,c.today+42);
  perform pg_temp.t10_error(pg_temp.t10_submit(x),'capacity-full','16th rejected on shared inclusive end day');
  select user_id into actor from public.applications where id=ids[4];
  candidate:=pg_temp.t10_draft(actor,c.today+40,c.today+41);
  perform pg_temp.t10_error(pg_temp.t10_submit(candidate),'duplicate-stay','same user overlapping application');
  perform pg_temp.t10_ok(pg_temp.t10_review(ids[4],'start_review'),'capacity review');
  perform pg_temp.t10_ok(pg_temp.t10_review(ids[4],'reject'),'capacity rejection');
  perform pg_temp.t10_ok(pg_temp.t10_submit(x),'released last place reusable');
  perform pg_temp.t10_error(pg_temp.t10_call(c.staff_id,format('select * from public.save_staff_blocked_period(null,%L,%L,''架空清掃'')',c.today+41,c.today+42)),'date-conflict','staff stop conflicts with individual');
  perform pg_temp.t10_error(pg_temp.t10_call(c.staff_id,format('select public.create_staff_camp(''架空キャンプ'',%L,%L,%L)',c.today+41,c.today+42,(c.today+40)::timestamp at time zone 'Asia/Tokyo')),'date-conflict','staff camp conflicts with individual');
  insert into public.camps(name,start_date,end_date,application_deadline) values('架空移動元',c.today+50,c.today+51,(c.today+49)::timestamp at time zone 'Asia/Tokyo') returning id,updated_at into camp_id,version_value;
  perform pg_temp.t10_error(pg_temp.t10_call(c.staff_id,format('select * from public.update_staff_camp(%L,''架空移動'',%L,%L,%L,%L,''架空変更'')',camp_id,c.today+40,c.today+41,(c.today+39)::timestamp at time zone 'Asia/Tokyo',version_value)),'date-conflict','camp reschedule handles NULL camp_id');
  candidate:=pg_temp.t10_draft(pg_temp.t10_user(),c.today+51,c.today+52);
  perform pg_temp.t10_error(pg_temp.t10_submit(candidate),'calendar-unavailable','individual conflicts with camp inclusive endpoint');
  q:=pg_temp.t10_ok(pg_temp.t10_call(c.staff_id,format('select * from public.get_staff_calendar_day(%L)',c.today+40)),'staff individual day');
  perform pg_temp.t10_check(exists(select 1 from jsonb_array_elements(q) r where r->>'entry_id'=ids[1]::text and r->>'camp_id' is null and r->>'people_count'='1'),'staff day individual shape');
  q:=pg_temp.t10_ok(pg_temp.t10_call(c.staff_id,format('select * from public.get_staff_calendar(%L)',date_trunc('month',c.today+40)::date)),'staff individual month');
  perform pg_temp.t10_check(exists(select 1 from jsonb_array_elements(q) r where r->>'entry_type'='individual'),'staff month type');
  -- Missing claim fails closed for writes, and still counts in public capacity.
  delete from public.calendar_claims where application_id=ids[5];
  perform pg_temp.t10_error(pg_temp.t10_submit(candidate),'calendar-unavailable','existing camp remains exclusive');
  candidate:=pg_temp.t10_draft(pg_temp.t10_user(),c.today+40,c.today+41);
  perform pg_temp.t10_error(pg_temp.t10_submit(candidate),'calendar-inconsistent','missing claim cannot bypass capacity');
  foreach day_value in array array[c.today+13,c.today+61] loop
    q:=pg_temp.t10_ok(pg_temp.t10_call(null,format('select * from public.get_public_calendar(%L) where date=%L',date_trunc('month',day_value)::date,day_value),'anon'),'public window');
    perform pg_temp.t10_check(q#>>'{0,availability}'=case when day_value=c.today+13 then 'unavailable' else 'not_yet_open' end,'public window precedence');
  end loop;
end; $$;

-- Long periods test the fee helper, not the 15-day community application rule.
do $$ begin
  perform pg_temp.t10_check((select sum(amount)=600 from private.community_charge_months('2026-08-01','2026-08-02')),'fee 600');
  perform pg_temp.t10_check((select sum(amount)=9600 from private.community_charge_months('2026-08-15','2026-09-15')),'fee month split 9600');
  perform pg_temp.t10_check((select sum(amount)=9000 from private.community_charge_months('2026-08-01','2026-08-31')),'fee cap 9000');
  perform pg_temp.t10_check((select sum(amount)=6000 from private.community_charge_months('2026-08-01','2026-08-20'))
    and (select sum(amount)=3300 from private.community_charge_months('2026-08-21','2026-08-31')),'separate applications have separate caps');
end; $$;

-- Failure at the final audit must undo status, claim, charge, receipt AND counter.
create temporary table t10_failure_target on commit drop as select pg_temp.t10_draft(owner_id,today+55,today+56) id from pg_temp.t10_context;
create function pg_temp.t10_fail_audit() returns trigger language plpgsql as $$ begin
  if new.action='submit_community_application' then raise exception 't10-audit-failure'; end if; return new;
end; $$;
create trigger t10_fail_audit before insert on public.audit_logs for each row execute function pg_temp.t10_fail_audit();
do $$ declare x uuid:=(select id from pg_temp.t10_failure_target); before_value jsonb:=pg_temp.t10_snapshot(x); counters jsonb;
begin
  select jsonb_agg(to_jsonb(c) order by fiscal_year) into counters from public.reception_counters c;
  perform pg_temp.t10_error(pg_temp.t10_submit(x),'t10-audit-failure','injected audit failure');
  perform pg_temp.t10_check(pg_temp.t10_snapshot(x)=before_value,'submission is fully atomic');
  perform pg_temp.t10_check((select jsonb_agg(to_jsonb(c) order by fiscal_year) from public.reception_counters c) is not distinct from counters,'failed transaction does not consume counter');
end; $$;
drop trigger t10_fail_audit on public.audit_logs;
select count(*) as passed_checks,'Single connection, simulated auth, fictional changes rolled back.' as scope from pg_temp.t10_results;
rollback;
