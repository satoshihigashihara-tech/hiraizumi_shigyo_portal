-- T19 invitation/join regression. Run whole file after SQL 022 on an isolated test project.
-- All fictional rows and temporary helpers are removed by the final ROLLBACK.
begin;
set local lock_timeout='3s';
set local statement_timeout='60s';
set local timezone='UTC';
do $$ begin
  if current_user<>'postgres' or to_regprocedure('public.join_community_group(text,text,uuid)') is null then
    raise exception 'Run as postgres after SQL 022.'; end if;
  if exists(select 1 from public.calendar_claims where start_date<=(clock_timestamp() at time zone 'Asia/Tokyo')::date+60
    and end_date>=(clock_timestamp() at time zone 'Asia/Tokyo')::date+14
    and (released_from is null or released_from>start_date)) then
    raise exception 'Use an isolated test project with no existing claims in the 14-60 day window.'; end if;
end; $$;

create temporary table t19_results(n integer generated always as identity,label text,passed boolean) on commit drop;
create temporary table t19_context(rep uuid,other_user uuid,third_user uuid,staff uuid,disabled uuid,today date) on commit drop;
create function pg_temp.t19_check(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  insert into pg_temp.t19_results(label,passed) values(label,true);
end; $$;
create function pg_temp.t19_user(kind text default 'user') returns uuid language plpgsql as $$
declare x uuid:=gen_random_uuid(); begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','t19-'||x||'@example.invalid','',clock_timestamp(),
    '{"provider":"email","providers":["email"]}','{}',clock_timestamp(),clock_timestamp());
  update public.profiles set full_name='架空参加者'||substr(x::text,1,4),address='架空住所',phone='000-0000-0000',
    emergency_name='架空連絡先',emergency_address='架空住所',emergency_phone='000-0000-0000' where id=x;
  if kind='staff' then insert into public.staff_roles(user_id) values(x); end if;
  if kind='disabled' then update public.profiles set account_state='disabled' where id=x; end if;
  return x;
end; $$;
insert into pg_temp.t19_context select pg_temp.t19_user(),pg_temp.t19_user(),pg_temp.t19_user(),pg_temp.t19_user('staff'),
  pg_temp.t19_user('disabled'),(clock_timestamp() at time zone 'Asia/Tokyo')::date;
create function pg_temp.t19_call(actor uuid,query_text text,role_name text default 'authenticated') returns jsonb language plpgsql as $$
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
create function pg_temp.t19_ok(r jsonb,label text) returns jsonb language plpgsql as $$ begin
  perform pg_temp.t19_check(r->>'ok'='true',label||': '||r::text); return r->'rows';
end; $$;
create function pg_temp.t19_error(r jsonb,message_value text,label text,state_value text default 'P0001') returns void language plpgsql as $$ begin
  perform pg_temp.t19_check(r->>'ok'='false' and r->>'code'=state_value
    and (message_value is null or r->>'message'=message_value),label||': '||r::text);
end; $$;
create function pg_temp.t19_group_fields(starts_on date,ends_on date,count_value integer,rep_stays boolean)
returns jsonb language sql as $$ select jsonb_build_object('group_name','架空招待団体','representative_name','架空代表者',
  'representative_address','架空住所','representative_phone','000-0000-0000','start_date',starts_on,'end_date',ends_on,
  'usage_place','common_and_second_floor','purpose','架空地域調査','local_activity','町内で架空調査',
  'special_notes',null,'planned_participants',count_value,'representative_stays',rep_stays); $$;
create function pg_temp.t19_group(actor uuid,starts_on date,ends_on date,count_value integer,rep_stays boolean)
returns uuid language plpgsql as $$ declare x uuid:=gen_random_uuid(); v timestamptz; begin
  perform pg_temp.t19_ok(pg_temp.t19_call(actor,format('select * from public.create_community_group_draft(%L,%L::jsonb)',
    x,pg_temp.t19_group_fields(starts_on,ends_on,count_value,rep_stays))),'create group');
  select updated_at into v from public.group_applications where id=x;
  perform pg_temp.t19_ok(pg_temp.t19_call(actor,format('select * from public.start_community_group_application(%L,%L,%L,true)',
    x,v,gen_random_uuid())),'start group'); return x;
end; $$;
create function pg_temp.t19_issue(actor uuid,x uuid,version_value timestamptz default null) returns jsonb language sql as $$
  select pg_temp.t19_call(actor,format('select * from public.issue_community_group_invite(%L,%L)',x,
    coalesce(version_value,(select updated_at from public.group_applications where id=x)))); $$;
create function pg_temp.t19_join(actor uuid,raw_value text,kind text,application_id uuid) returns jsonb language sql as $$
  select pg_temp.t19_call(actor,format('select * from public.join_community_group(%L,%L,%L)',raw_value,kind,application_id)); $$;

-- Issue, reissue, authenticated context, one-time raw values and privacy.
do $$ declare c pg_temp.t19_context%rowtype; x uuid; v timestamptz; first jsonb; second jsonb;
  token1 text; code1 text; token2 text; code2 text; due_value timestamptz; r jsonb;
begin
  select * into c from pg_temp.t19_context;
  x:=pg_temp.t19_group(c.rep,c.today+20,c.today+22,3,true); select updated_at,participant_due_at into v,due_value from public.group_applications where id=x;
  perform pg_temp.t19_error(pg_temp.t19_issue(c.other_user,x),'not-found','nonrepresentative cannot issue');
  perform pg_temp.t19_error(pg_temp.t19_issue(c.disabled,x),null,'disabled cannot issue','42501');
  first:=pg_temp.t19_ok(pg_temp.t19_issue(c.rep,x),'first invite');
  token1:=first#>>'{0,invite_token}'; code1:=first#>>'{0,invite_code}';
  perform pg_temp.t19_check(token1~'^[0-9a-f]{64}$' and code1~'^[A-HJ-NP-Z2-9]{16}$','raw entropy formats');
  perform pg_temp.t19_check((select count(*)=1 and bool_and(token_hash<>token1 and code_hash<>code1)
    from public.group_invites where group_id=x),'only hashes stored');
  perform pg_temp.t19_check((first#>>'{0,expires_at}')::timestamptz=due_value,'invite uses group deadline');
  perform pg_temp.t19_error(pg_temp.t19_issue(c.rep,x,v),'stale-update','old group version rejected');
  r:=pg_temp.t19_ok(pg_temp.t19_call(c.other_user,format('select public.get_community_group_invite(%L,''token'') as data',token1)),'authenticated token context');
  perform pg_temp.t19_check((r#>>'{0,data,group_id}')::uuid=x and not ((r#>'{0,data}') ? 'representative_name')
    and not ((r#>'{0,data}') ? 'representative_phone') and not ((r#>'{0,data}') ? 'special_notes'),'invite context privacy');
  perform pg_temp.t19_error(pg_temp.t19_call(null,format('select public.get_community_group_invite(%L,''token'')',token1)),null,
    'anonymous receives no group data','42501');
  perform pg_temp.t19_error(pg_temp.t19_call(c.other_user,'select public.get_community_group_invite(''bad'',''token'')'),
    'invalid-invite','invalid token generic');
  second:=pg_temp.t19_ok(pg_temp.t19_issue(c.rep,x),'reissue'); token2:=second#>>'{0,invite_token}'; code2:=second#>>'{0,invite_code}';
  perform pg_temp.t19_check(token2<>token1 and code2<>code1 and
    (select count(*)=1 from public.group_invites where group_id=x and revoked_at is not null)
    and (select count(*)=1 from public.group_invites where group_id=x and revoked_at is null),'reissue revokes exactly old invite');
  perform pg_temp.t19_error(pg_temp.t19_call(c.other_user,format('select public.get_community_group_invite(%L,''token'')',token1)),
    'invalid-invite','old token unusable');
  perform pg_temp.t19_ok(pg_temp.t19_call(c.other_user,format('select public.get_community_group_invite(%L,''code'')',
    lower(substr(code2,1,4)||'-'||substr(code2,5,4)||'-'||substr(code2,9,4)||'-'||substr(code2,13,4)))),'formatted code works');
end; $$;

-- Join creates one linked personal draft; duplicates return the existing draft without writes.
do $$ declare c pg_temp.t19_context%rowtype; x uuid; issued jsonb; token_value text; app uuid:=gen_random_uuid();
  retry_id uuid:=gen_random_uuid(); first_snapshot jsonb; rows_value jsonb; group_version timestamptz;
begin
  select * into c from pg_temp.t19_context;
  x:=pg_temp.t19_group(c.rep,c.today+25,c.today+27,3,true);
  issued:=pg_temp.t19_ok(pg_temp.t19_issue(c.rep,x),'join invite'); token_value:=issued#>>'{0,invite_token}';
  rows_value:=pg_temp.t19_ok(pg_temp.t19_join(c.other_user,token_value,'token',app),'participant joins');
  perform pg_temp.t19_check((rows_value#>>'{0,result_application_id}')::uuid=app,'join returns personal draft');
  perform pg_temp.t19_check((select usage_type='community_group' and group_id=x and status='draft'
    and start_date=(select start_date from public.group_applications where id=x)
    and end_date=(select end_date from public.group_applications where id=x)
    and user_name is not null and purpose is null and email_snapshot is null from public.applications where id=app),
    'personal draft uses profile but group owns common data');
  perform pg_temp.t19_check((select count(*)=1 from public.group_members where group_id=x and application_id=app and state='active')
    and (select count(*)=1 from public.application_status_events where application_id=app and to_status='draft')
    and (select count(*)=1 from public.audit_logs where entity_id=app and action='join_community_group'),'membership history and audit');
  set constraints all immediate; set constraints all deferred;
  select jsonb_build_object('group',to_jsonb(g),'member',(select to_jsonb(m) from public.group_members m where application_id=app),
    'application',(select to_jsonb(a) from public.applications a where id=app),'events',(select jsonb_agg(to_jsonb(e)) from public.application_status_events e where application_id=app),
    'audit',(select jsonb_agg(to_jsonb(l)) from public.audit_logs l where entity_id in (x,app))) into first_snapshot
    from public.group_applications g where id=x;
  perform pg_temp.t19_ok(pg_temp.t19_join(c.other_user,'0','token',app),'same application retry does not need invite');
  rows_value:=pg_temp.t19_ok(pg_temp.t19_join(c.other_user,token_value,'token',retry_id),'duplicate participant returns existing');
  perform pg_temp.t19_check((rows_value#>>'{0,result_application_id}')::uuid=app and not exists(select 1 from public.applications where id=retry_id),
    'duplicate join creates no second draft');
  perform pg_temp.t19_check((select jsonb_build_object('group',to_jsonb(g),'member',(select to_jsonb(m) from public.group_members m where application_id=app),
    'application',(select to_jsonb(a) from public.applications a where id=app),'events',(select jsonb_agg(to_jsonb(e)) from public.application_status_events e where application_id=app),
    'audit',(select jsonb_agg(to_jsonb(l)) from public.audit_logs l where entity_id in (x,app))) from public.group_applications g where id=x)=first_snapshot,
    'all join retries are read-only');
  rows_value:=pg_temp.t19_ok(pg_temp.t19_call(c.rep,format('select public.get_community_group_participants(%L) as data',x)),'representative summary');
  perform pg_temp.t19_check(jsonb_array_length(rows_value#>'{0,data,participants}')=1
    and not ((rows_value#>'{0,data,participants,0}') ? 'user_id')
    and not ((rows_value#>'{0,data,participants,0}') ? 'user_address')
    and not ((rows_value#>'{0,data,participants,0}') ? 'emergency_name'),'representative sees status not private fields');
  perform pg_temp.t19_error(pg_temp.t19_call(c.other_user,format('select public.get_community_group_participants(%L)',x)),
    'not-found','participant cannot list others');
end; $$;

-- Capacity, representative stay choice, deadline, state and overlapping personal stays.
do $$ declare c pg_temp.t19_context%rowtype; x uuid; issued jsonb; token_value text; first_app uuid:=gen_random_uuid();
  other_group uuid; other_token text; individual uuid:=gen_random_uuid(); fields jsonb;
begin
  select * into c from pg_temp.t19_context;
  x:=pg_temp.t19_group(c.rep,c.today+30,c.today+31,2,false);
  issued:=pg_temp.t19_ok(pg_temp.t19_issue(c.rep,x),'capacity invite'); token_value:=issued#>>'{0,invite_token}';
  perform pg_temp.t19_error(pg_temp.t19_join(c.rep,token_value,'token',gen_random_uuid()),'representative-not-staying','nonstaying representative rejected');
  perform pg_temp.t19_ok(pg_temp.t19_join(c.other_user,token_value,'token',first_app),'first of two');
  perform pg_temp.t19_ok(pg_temp.t19_join(c.third_user,token_value,'token',gen_random_uuid()),'second of two');
  perform pg_temp.t19_error(pg_temp.t19_join(c.staff,token_value,'token',gen_random_uuid()),'group-full','planned count enforced');

  other_group:=pg_temp.t19_group(c.rep,c.today+34,c.today+35,2,true);
  issued:=pg_temp.t19_ok(pg_temp.t19_issue(c.rep,other_group),'representative invite'); other_token:=issued#>>'{0,invite_token}';
  perform pg_temp.t19_ok(pg_temp.t19_join(c.rep,other_token,'token',gen_random_uuid()),'staying representative joins');
  update public.group_applications set participant_due_at=clock_timestamp()-interval '1 second' where id=other_group;
  perform pg_temp.t19_error(pg_temp.t19_call(c.third_user,format('select public.get_community_group_invite(%L,''token'')',other_token)),
    'invite-expired','expired context rejected');
  perform pg_temp.t19_error(pg_temp.t19_join(c.third_user,other_token,'token',gen_random_uuid()),'invite-expired','expired join rejected');

  other_group:=pg_temp.t19_group(c.rep,c.today+38,c.today+39,3,false);
  issued:=pg_temp.t19_ok(pg_temp.t19_issue(c.rep,other_group),'overlap invite'); other_token:=issued#>>'{0,invite_token}';
  fields:=jsonb_build_object('user_name','架空参加者','user_address','架空住所','user_phone','000-0000-0000',
    'emergency_name','架空連絡先','emergency_address','架空住所','emergency_phone','000-0000-0000',
    'purpose','架空個人調査','local_activity','町内で架空活動','usage_place','common_and_second_floor',
    'requires_guardian_consent',false,'start_date',c.today+38,'end_date',c.today+39);
  perform pg_temp.t19_ok(pg_temp.t19_call(c.third_user,format('select * from public.create_community_application_draft(%L,%L::jsonb)',individual,fields)),'individual overlap draft');
  -- Test-only corruption: normal submission correctly refuses this group period.
  -- Direct postgres update creates the pre-existing personal stay needed to exercise the join guard.
  update public.applications set status='submitted',submitted_at=clock_timestamp() where id=individual;
  perform pg_temp.t19_check((select status='submitted' from public.applications where id=individual),'overlap guard fixture');
  perform pg_temp.t19_error(pg_temp.t19_join(c.third_user,other_token,'token',gen_random_uuid()),'duplicate-stay','existing personal stay blocks join');

  update public.group_applications set status='under_review' where id=other_group;
  perform pg_temp.t19_error(pg_temp.t19_issue(c.rep,other_group),'invite-not-available','cannot issue after collecting');
end; $$;

-- Direct table writes/private helpers are denied; relationship constraints fail closed.
do $$ declare c pg_temp.t19_context%rowtype; q text; x uuid; bad_app uuid:=gen_random_uuid(); failed boolean:=false;
begin
  select * into c from pg_temp.t19_context;
  foreach q in array array['select * from public.group_invites','insert into public.group_members(group_id,application_id) values(gen_random_uuid(),gen_random_uuid()) returning id',
    'update public.group_members set state=''removed'' returning id','select private.new_group_invite_code()',
    'select private.group_invite_hash(''x'',''token'')'] loop
    perform pg_temp.t19_error(pg_temp.t19_call(c.staff,q),null,'direct invite/member/private access denied','42501');
  end loop;
  x:=pg_temp.t19_group(c.rep,c.today+44,c.today+45,2,false);
  begin
    insert into public.applications(id,user_id,usage_type,group_id,status,start_date,end_date)
      values(bad_app,c.other_user,'community_group',x,'draft',c.today+45,c.today+46);
    set constraints all immediate;
  exception when others then failed:=sqlerrm='group-member-inconsistent'; end;
  perform pg_temp.t19_check(failed and not exists(select 1 from public.applications where id=bad_app),
    'deferred consistency rejects missing member and wrong dates atomically');
  set constraints all deferred;
end; $$;

select count(*)::integer as passed_checks,bool_and(passed) as all_passed from pg_temp.t19_results;
rollback;
