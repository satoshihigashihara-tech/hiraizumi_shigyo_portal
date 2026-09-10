-- T10 multi-connection regression. ISOLATED TEST PROJECT WITHOUT USER TRAFFIC ONLY.
-- Requires 001-013 and an empty day 14-60 calendar. This whole file PREPARES and
-- COMMITS fictional fixtures. Do not use a production project.
-- In distinct connections, start A and immediately B (each CALL outside BEGIN):
--   call t10_concurrency_test.worker_a();
--   call t10_concurrency_test.worker_b();
-- After BOTH finish: select * from t10_concurrency_test.verify();
-- After success/failure, stop both workers, then clean up in a separate operation:
--   begin; select t10_concurrency_test.cleanup(); drop schema t10_concurrency_test cascade; commit;
-- Real blocking is proven by pg_blocking_pids; timeout is a failure.
-- Role/JWT simulation only, no real Auth/Storage APIs. Receipt counters remain.
-- The single-connection tests cover approved/cancellation_requested fixtures;
-- no approval or cancellation operation is added to the T10 product.
begin;
set local lock_timeout='3s';
set local statement_timeout='60s';
set local timezone='UTC';
do $$ begin
  if current_user<>'postgres' or to_regprocedure('public.get_community_application(uuid)') is null then raise exception 'Run as postgres after 001-013.'; end if;
  if to_regnamespace('t10_concurrency_test') is not null then raise exception 'Existing run: stop workers and clean up before retrying.'; end if;
  if exists(select 1 from public.calendar_claims where start_date<=(clock_timestamp() at time zone 'Asia/Tokyo')::date+60
    and end_date>=(clock_timestamp() at time zone 'Asia/Tokyo')::date+14 and (released_from is null or released_from>start_date)) then
    raise exception 'Use an isolated test project with no claims in the 14-60 day window.'; end if;
end; $$;
create schema t10_concurrency_test;
revoke all on schema t10_concurrency_test from public, anon, authenticated, service_role;

create table t10_concurrency_test.run (
  id integer primary key check (id = 1),
  token uuid not null default gen_random_uuid(),
  base_date date not null,
  staff_a uuid,
  staff_b uuid,
  a_pid integer,
  b_pid integer,
  a_backend_start timestamptz,
  b_backend_start timestamptz,
  a_finished_at timestamptz,
  b_finished_at timestamptz,
  verified_at timestamptz
);
create table t10_concurrency_test.fixtures (
  kind text not null check (kind in ('user', 'camp', 'application', 'blocked')),
  id uuid not null,
  primary key (kind, id)
);
create table t10_concurrency_test.cases (
  case_no integer primary key check (case_no between 1 and 20),
  test_name text not null,
  camp_id uuid,
  app_a uuid not null,
  app_b uuid not null,
  actor_a uuid not null,
  actor_b uuid not null,
  a_query text,
  a_role text not null default 'authenticated',
  b_query text not null,
  expected_state text,
  expected_message text,
  deadline timestamptz
);
create table t10_concurrency_test.observations (
  case_no integer not null references t10_concurrency_test.cases(case_no),
  worker text not null check (worker in ('a', 'b')),
  backend_pid integer not null,
  peer_pid integer not null,
  started_at timestamptz not null,
  observed_at timestamptz not null,
  isolation_level text not null,
  rpc_result jsonb not null,
  a_after jsonb,
  b_after jsonb,
  primary key (case_no, worker)
);
alter table t10_concurrency_test.run enable row level security;
alter table t10_concurrency_test.fixtures enable row level security;
alter table t10_concurrency_test.cases enable row level security;
alter table t10_concurrency_test.observations enable row level security;
revoke all on all tables in schema t10_concurrency_test
from public, anon, authenticated, service_role;

create function t10_concurrency_test.check_true(condition boolean, label text)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if current_user <> 'postgres' then raise exception 'Run as postgres.'; end if;
  if condition is distinct from true then raise exception 'FAIL: %', label; end if;
end;
$$;

create function t10_concurrency_test.fixture_user(is_staff boolean default false)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  new_id uuid := gen_random_uuid();
  run_token uuid := (select token from t10_concurrency_test.run where id = 1);
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  ) values (
    new_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    't10-concurrency-' || new_id::text || '@example.invalid', '', clock_timestamp(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('t10_concurrency_run', run_token), clock_timestamp(), clock_timestamp()
  );
  insert into t10_concurrency_test.fixtures values ('user', new_id);
  if is_staff then insert into public.staff_roles (user_id) values (new_id); end if;
  return new_id;
end;
$$;

-- Role changes must happen in an INVOKER helper, not a definer function.
-- Errors roll back the RPC's subtransaction; the worker records their exact code.
create function t10_concurrency_test.call_as(actor_id uuid, query_text text, role_name text default 'authenticated')
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  actor_email text := (select email from auth.users where id = actor_id);
  row_value record;
  rows_value jsonb := '[]'::jsonb;
  result_value jsonb;
  error_state text;
  error_message text;
  old_sub text := coalesce(current_setting('request.jwt.claim.sub', true), '');
  old_email text := coalesce(current_setting('request.jwt.claim.email', true), '');
  old_claims text := coalesce(current_setting('request.jwt.claims', true), '');
begin
  perform t10_concurrency_test.check_true(current_user = 'postgres', 'postgres test caller required');
  begin
    execute format('set local role %I',role_name);
    perform set_config('request.jwt.claim.sub', actor_id::text, true);
    perform set_config('request.jwt.claim.email', actor_email, true);
    perform set_config('request.jwt.claims', jsonb_build_object(
      'sub', actor_id, 'email', actor_email, 'role', 'authenticated'
    )::text, true);
    for row_value in execute query_text loop
      rows_value := rows_value || jsonb_build_array(to_jsonb(row_value));
    end loop;
    result_value := jsonb_build_object('ok', true, 'rows', rows_value);
  exception when others then
    get stacked diagnostics error_state = returned_sqlstate, error_message = message_text;
    result_value := jsonb_build_object('ok', false, 'sqlstate', error_state, 'message', error_message);
  end;
  set local role postgres;
  perform set_config('request.jwt.claim.sub', old_sub, true);
  perform set_config('request.jwt.claim.email', old_email, true);
  perform set_config('request.jwt.claims', old_claims, true);
  return result_value;
end;
$$;

create function t10_concurrency_test.snapshot(app_value uuid)
returns jsonb language sql security invoker set search_path = '' as $$
  with users as (select id from t10_concurrency_test.fixtures where kind = 'user'),
  apps as (select a.* from public.applications a where a.user_id in (select id from users)),
  camps as (select c.* from public.camps c where c.created_by in (select id from users)),
  blocks as (select b.* from public.blocked_periods b where b.created_by in (select id from users))
  select jsonb_build_object(
    'profiles', (select jsonb_agg(to_jsonb(p) order by p.id) from public.profiles p where p.id in (select id from users)),
    'camps', (select jsonb_agg(to_jsonb(c) order by c.id) from camps c),
    'blocks', (select jsonb_agg(to_jsonb(b) order by b.id) from blocks b),
    'claims', (select jsonb_agg(to_jsonb(q) order by q.id) from public.calendar_claims q where q.camp_id in (select id from camps) or q.blocked_period_id in (select id from blocks) or q.application_id in (select id from apps)),
    'applications', (select jsonb_agg(to_jsonb(a) order by a.id) from apps a),
    'rooms', (select jsonb_agg(to_jsonb(r) order by r.id) from public.room_allocations r where r.application_id in (select id from apps)),
    'stays', (select jsonb_agg(to_jsonb(t) order by t.id) from public.stays t where t.application_id in (select id from apps)),
    'events', (select jsonb_agg(to_jsonb(e) order by e.id) from public.application_status_events e where e.application_id in (select id from apps)),
    'audit', (select jsonb_agg(to_jsonb(l) order by l.id) from public.audit_logs l where l.actor_user_id in (select id from users)),
    'charges', (select jsonb_agg(to_jsonb(c) order by c.id) from public.application_charges c where c.application_id in (select id from apps)),
    'months', (select jsonb_agg(to_jsonb(m) order by m.id) from public.charge_months m join public.application_charges c on c.id = m.charge_id where c.application_id in (select id from apps)),
    'consents', (select jsonb_agg(to_jsonb(d) order by d.id) from public.consent_documents d where d.application_id in (select id from apps)),
    'numbers', (select jsonb_agg(to_jsonb(n) order by n.id) from public.reception_numbers n where n.application_id in (select id from apps)),
    'counters', (select jsonb_agg(to_jsonb(n) order by n.fiscal_year) from public.reception_counters n)
  );
$$;

create function t10_concurrency_test.peer_tag(token_value uuid, worker_value text, case_value integer)
returns text language sql immutable security invoker set search_path = '' as $$
  select 't10c:' || token_value::text || ':' || worker_value || ':' || case_value::text;
$$;

create function t10_concurrency_test.wait_for_peer(
  tag_value text, stop_at timestamptz, require_blocked_by_me boolean
)
returns integer language plpgsql security invoker set search_path = '' as $$
declare
  peer_pid integer;
begin
  loop
    if clock_timestamp() >= stop_at then
      raise exception 'No proven overlap before timeout. Stop both workers, clean up and retry.';
    end if;
    perform pg_stat_clear_snapshot();
    select a.pid into peer_pid from pg_stat_activity a
    where a.datid = (select oid from pg_database where datname = current_database())
      and a.pid <> pg_backend_pid() and a.application_name = tag_value and a.state = 'active'
      and (not require_blocked_by_me or pg_backend_pid() = any(pg_blocking_pids(a.pid)))
    limit 1;
    if peer_pid is not null then return peer_pid; end if;
    perform pg_sleep(0.1);
  end loop;
end;
$$;

-- A must not acquire the next case's facility lock until B has committed its
-- previous result. Otherwise A could itself block B from reaching the next case.
create function t10_concurrency_test.wait_for_b_result(case_value integer, stop_at timestamptz)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  loop
    if clock_timestamp() >= stop_at then
      raise exception 'B did not finish its case before timeout. Clean up before retrying.';
    end if;
    if exists (select 1 from t10_concurrency_test.observations o
      where o.case_no = case_value and o.worker = 'b' and o.b_after is not null) then return; end if;
    perform pg_sleep(0.1);
  end loop;
end;
$$;

create function t10_concurrency_test.expect_success(result_value jsonb)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  perform t10_concurrency_test.check_true(
    result_value ->> 'ok' = 'true' and jsonb_array_length(result_value -> 'rows') = 1,
    'RPC must succeed with one result: ' || coalesce(result_value::text, 'NULL')
  );
end;
$$;


create function t10_concurrency_test.fields(starts_on date,ends_on date) returns jsonb language sql as $$ select jsonb_build_object(
 'start_date',starts_on,'end_date',ends_on,'user_name','架空同時更新利用者','user_address','架空住所','user_phone','000-0000-0000',
 'emergency_name','架空連絡先','emergency_address','架空住所','emergency_phone','000-0000-0000',
 'purpose','架空検証','local_activity','架空地域活動','usage_place','common_and_second_floor','requires_guardian_consent',false); $$;
create function t10_concurrency_test.draft(actor uuid,starts_on date,ends_on date) returns uuid language plpgsql as $$ declare x uuid:=gen_random_uuid(); begin
 perform t10_concurrency_test.expect_success(t10_concurrency_test.call_as(actor,format('select * from public.create_community_application_draft(%L,%L::jsonb)',x,t10_concurrency_test.fields(starts_on,ends_on))));
 insert into t10_concurrency_test.fixtures values('application',x); return x;
end; $$;
create function t10_concurrency_test.submit_sql(x uuid,key_value uuid default gen_random_uuid()) returns text language sql as $$
 select format('select * from public.submit_community_application(%L,%L,%L,true)',x,a.updated_at,key_value) from public.applications a where id=x; $$;
create function t10_concurrency_test.save_sql(x uuid) returns text language sql as $$
 select format('select * from public.save_community_application_draft(%L,%L,%L::jsonb)',x,a.updated_at,t10_concurrency_test.fields(a.start_date,a.end_date)||jsonb_build_object('purpose','架空修正')) from public.applications a where id=x; $$;
create function t10_concurrency_test.review_sql(x uuid,operation text) returns text language sql as $$
 select format('select * from public.review_community_application(%L,%L,%L,%L)',x,operation,a.updated_at,'架空審査') from public.applications a where id=x; $$;
insert into t10_concurrency_test.run(id,base_date) values(1,(clock_timestamp() at time zone 'Asia/Tokyo')::date+14);

do $$ declare c t10_concurrency_test.run%rowtype; n integer; j integer; d date; ua uuid; ub uuid; aa uuid; ab uuid; extra uuid; camp uuid; block_id uuid;
 qa text; qb text; cq text; bq text; name_value text; marker text; expected text; state_value text; version_value timestamptz; role_value text;
begin
 update t10_concurrency_test.run set staff_a=t10_concurrency_test.fixture_user(true),staff_b=t10_concurrency_test.fixture_user(true) where id=1 returning * into c;
 for n in 1..20 loop
  d:=c.base_date+(n-1)*2; marker:='T10 concurrency '||c.token::text||' case '||n;
  ua:=t10_concurrency_test.fixture_user(); ub:=t10_concurrency_test.fixture_user(); camp:=null; block_id:=null; role_value:='authenticated';
  if n=2 then ub:=ua; end if;
  aa:=t10_concurrency_test.draft(ua,d,d+1); ab:=t10_concurrency_test.draft(ub,d,d+1);
  if n in(1,14) then
   for j in 1..14 loop
    extra:=t10_concurrency_test.draft(t10_concurrency_test.fixture_user(),d,d+1);
    perform t10_concurrency_test.expect_success(t10_concurrency_test.call_as((select user_id from public.applications where id=extra),t10_concurrency_test.submit_sql(extra)));
   end loop;
  end if;
  if n in(5,16,17,19,20) then
   perform t10_concurrency_test.expect_success(t10_concurrency_test.call_as(ua,t10_concurrency_test.submit_sql(aa)));
   perform t10_concurrency_test.expect_success(t10_concurrency_test.call_as(c.staff_a,t10_concurrency_test.review_sql(aa,'start_review')));
   if n in(5,17,20) then perform t10_concurrency_test.expect_success(t10_concurrency_test.call_as(c.staff_a,t10_concurrency_test.review_sql(aa,'request_revision'))); end if;
  end if;
  qa:=t10_concurrency_test.submit_sql(aa); qb:=t10_concurrency_test.submit_sql(ab); state_value:='P0001'; expected:='calendar-unavailable';
  cq:=format('select public.create_staff_camp(%L,%L::date,%L::date,%L::timestamptz)',marker,d,d+1,d::timestamp at time zone 'Asia/Tokyo');
  bq:=format('select * from public.save_staff_blocked_period(null,%L::date,%L::date,%L)',d,d+1,marker);
  if n in(10,11) then
   insert into public.camps(name,start_date,end_date,application_deadline,created_by)
    values(marker,d+100,d+101,d::timestamp at time zone 'Asia/Tokyo',c.staff_a) returning id,updated_at into camp,version_value;
   insert into t10_concurrency_test.fixtures values('camp',camp);
   cq:=format('select * from public.update_staff_camp(%L,%L,%L::date,%L::date,%L::timestamptz,%L::timestamptz,%L)',camp,marker,d,d+1,d::timestamp at time zone 'Asia/Tokyo',version_value,'架空変更');
  end if;
  if n in(12,13) then
   insert into public.blocked_periods(start_date,end_date,internal_reason,created_by) values(d+100,d+101,marker,c.staff_a) returning id,updated_at into block_id,version_value;
   insert into t10_concurrency_test.fixtures values('blocked',block_id);
   bq:=format('select * from public.save_staff_blocked_period(%L,%L::date,%L::date,%L,%L::timestamptz,%L)',block_id,d,d+1,marker,version_value,'架空変更');
  end if;
  if n=1 then name_value:='last capacity slot: only one of two submissions succeeds'; expected:='capacity-full';
  elsif n=2 then name_value:='same owner cannot submit overlapping stays'; expected:='duplicate-stay';
  elsif n=3 then name_value:='same key and version retries exactly once'; ab:=aa; ub:=ua; qb:=qa; expected:=null; state_value:=null;
  elsif n=4 then name_value:='same draft version cannot be saved twice'; ab:=aa; ub:=ua; qa:=t10_concurrency_test.save_sql(aa); qb:=qa; expected:='stale-update';
  elsif n=5 then name_value:='revision save invalidates waiting resubmission'; ab:=aa; ub:=ua; qa:=t10_concurrency_test.save_sql(aa); qb:=t10_concurrency_test.submit_sql(aa); expected:='stale-update';
  elsif n in(6,10) then name_value:='individual submission precedes camp create/update'; qb:=cq; ub:=c.staff_b; expected:='date-conflict';
  elsif n in(7,11) then name_value:='camp create/update precedes individual submission'; qa:=cq; ua:=c.staff_a;
  elsif n in(8,12) then name_value:='individual submission precedes blocked create/update'; qb:=bq; ub:=c.staff_b; expected:='date-conflict';
  elsif n in(9,13) then name_value:='blocked create/update precedes individual submission'; qa:=bq; ua:=c.staff_a;
  elsif n=14 then name_value:='repeatable read cannot accept stale capacity'; state_value:='40001'; expected:=null;
  elsif n=15 then name_value:='owner disabled while submission waits'; qa:=null; expected:='active-user-required'; state_value:='42501';
  elsif n=16 then name_value:='staff disabled while review waits'; qa:=null; qb:=t10_concurrency_test.review_sql(aa,'request_revision'); ub:=c.staff_b; expected:=null; state_value:='42501';
  elsif n=17 then name_value:='revision starts before deadline and expires while blocked'; qa:=null; ab:=aa; ub:=ua; qb:=t10_concurrency_test.submit_sql(aa); expected:='revision-expired';
  elsif n=18 then name_value:='consent replacement invalidates waiting confirmation'; ab:=aa; ub:=ua; role_value:='service_role';
   qa:=format('select * from public.register_community_guardian_consent_document(%L,%L,%L,%L,%L,32)',aa,ua,(select updated_at from public.applications where id=aa),'applications/'||aa::text||'/'||c.token::text,'application/pdf');
   qb:=t10_concurrency_test.submit_sql(aa); expected:='stale-update';
  elsif n=19 then name_value:='two staff decisions cannot overwrite each other'; ab:=aa; ua:=c.staff_a; ub:=c.staff_a;
   qa:=t10_concurrency_test.review_sql(aa,'request_revision'); qb:=t10_concurrency_test.review_sql(aa,'reject'); expected:='stale-update';
  elsif n=20 then name_value:='resubmission invalidates waiting revision save'; ab:=aa; ub:=ua; qb:=t10_concurrency_test.save_sql(aa); expected:='stale-update';
  end if;
  insert into t10_concurrency_test.cases(case_no,test_name,camp_id,app_a,app_b,actor_a,actor_b,a_query,a_role,b_query,expected_state,expected_message)
   values(n,name_value,camp,aa,ab,ua,ub,qa,role_value,qb,state_value,expected);
 end loop;
end; $$;
-- A procedure with transaction control cannot be DEFINER or have a SET clause.
-- All object/function names below are qualified; COMMIT is outside exception
-- blocks. Integer loops avoid cursors being materialized across commits.
create procedure t10_concurrency_test.worker_a()
language plpgsql security invoker as $$
declare
  context t10_concurrency_test.run%rowtype;
  test_case t10_concurrency_test.cases%rowtype;
  case_number integer;
  stop_at timestamptz := pg_catalog.clock_timestamp() + interval '50 seconds';
  started_at_value timestamptz;
  observed_at_value timestamptz;
  peer_pid_value integer;
  result_value jsonb;
begin
  perform t10_concurrency_test.check_true(current_user = 'postgres', 'postgres worker required');
  update t10_concurrency_test.run set a_pid = pg_catalog.pg_backend_pid(),
    a_backend_start = (select backend_start from pg_catalog.pg_stat_activity where pid = pg_catalog.pg_backend_pid())
  where id = 1 and a_pid is null returning * into context;
  perform t10_concurrency_test.check_true(found, 'A already attempted: clean up before retrying');
  commit;
  for case_number in 1..20 loop
    -- Loop expressions can acquire a snapshot. SET must directly follow COMMIT.
    commit;
    set transaction isolation level read committed;
    perform pg_catalog.set_config('lock_timeout', '3s', true);
    select * into strict test_case from t10_concurrency_test.cases where case_no = case_number;

    if case_number=17 then
      -- Publish both deadline and expected version before B can start its RPC.
      update public.applications set revision_due_at=pg_catalog.clock_timestamp()+interval '4 seconds'
        where id=test_case.app_a returning revision_due_at into test_case.deadline;
      update t10_concurrency_test.cases set deadline=test_case.deadline,b_query=t10_concurrency_test.submit_sql(test_case.app_a) where case_no=case_number;
      commit;
      set transaction isolation level read committed;
    end if;
    started_at_value := pg_catalog.clock_timestamp();
    if case_number in(15,16,17) then
      update public.facility_guard set id=id where id=1;
      perform t10_concurrency_test.check_true(found,'facility guard exists');
      if case_number in(15,16) then update public.profiles set account_state='disabled' where id=test_case.actor_b; end if;
      result_value:='{"ok":true,"test_guard":true}'::jsonb;
    else
      result_value:=t10_concurrency_test.call_as(test_case.actor_a,test_case.a_query,test_case.a_role);
      perform t10_concurrency_test.expect_success(result_value);
    end if;

    -- Advertise only AFTER A holds the facility lock and has performed its RPC.
    perform pg_catalog.set_config('application_name', t10_concurrency_test.peer_tag(context.token, 'a', case_number), true);
    peer_pid_value := t10_concurrency_test.wait_for_peer(
      t10_concurrency_test.peer_tag(context.token, 'b', case_number), stop_at, true);
    observed_at_value := pg_catalog.clock_timestamp();
    if case_number=17 then
      perform t10_concurrency_test.check_true(observed_at_value<test_case.deadline,'B blocked before deadline');
      while pg_catalog.clock_timestamp()<=test_case.deadline loop perform pg_catalog.pg_sleep(0.05); end loop;
    end if;
    insert into t10_concurrency_test.observations (
      case_no, worker, backend_pid, peer_pid, started_at, observed_at, isolation_level, rpc_result, a_after, b_after
    ) values (case_number, 'a', pg_catalog.pg_backend_pid(), peer_pid_value,
      started_at_value, observed_at_value, pg_catalog.current_setting('transaction_isolation'), result_value,
      t10_concurrency_test.snapshot(test_case.app_a), t10_concurrency_test.snapshot(test_case.app_b));
    commit;
    set transaction isolation level read committed;
    perform t10_concurrency_test.wait_for_b_result(case_number, stop_at);
    commit;
  end loop;
  update t10_concurrency_test.run set a_finished_at = pg_catalog.clock_timestamp() where id = 1;
  commit;
end;
$$;

create procedure t10_concurrency_test.worker_b()
language plpgsql security invoker as $$
declare
  context t10_concurrency_test.run%rowtype;
  test_case t10_concurrency_test.cases%rowtype;
  case_number integer;
  stop_at timestamptz := pg_catalog.clock_timestamp() + interval '50 seconds';
  started_at_value timestamptz;
  peer_pid_value integer;
  result_value jsonb;
begin
  perform t10_concurrency_test.check_true(current_user = 'postgres', 'postgres worker required');
  update t10_concurrency_test.run set b_pid = pg_catalog.pg_backend_pid(),
    b_backend_start = (select backend_start from pg_catalog.pg_stat_activity where pid = pg_catalog.pg_backend_pid())
  where id = 1 and b_pid is null returning * into context;
  perform t10_concurrency_test.check_true(found, 'B already attempted: clean up before retrying');
  commit;
  for case_number in 1..20 loop
    -- Evaluating IF can acquire a snapshot even without a table SELECT.
    -- Choose the branch first, then COMMIT immediately before the static SET.
    -- Do not move COMMIT above IF or insert an expression between COMMIT/SET.
    if case_number = 14 then
      commit;
      set transaction isolation level repeatable read;
    else
      commit;
      set transaction isolation level read committed;
    end if;
    perform t10_concurrency_test.check_true(
      pg_catalog.current_setting('transaction_isolation') =
        case when case_number = 14 then 'repeatable read' else 'read committed' end,
      'B transaction isolation for case ' || case_number::text);
    perform pg_catalog.set_config('lock_timeout', '45s', true);
    perform pg_catalog.set_config('application_name', t10_concurrency_test.peer_tag(context.token, 'b', case_number), true);
    peer_pid_value := t10_concurrency_test.wait_for_peer(
      t10_concurrency_test.peer_tag(context.token, 'a', case_number), stop_at, false);
    select * into strict test_case from t10_concurrency_test.cases where case_no = case_number;
    started_at_value := pg_catalog.clock_timestamp();
    if case_number=17 then perform t10_concurrency_test.check_true(started_at_value<test_case.deadline,'B starts before deadline'); end if;
    result_value := t10_concurrency_test.call_as(test_case.actor_b, test_case.b_query);
    if test_case.expected_state is null then
      perform t10_concurrency_test.expect_success(result_value);
    else
      perform t10_concurrency_test.check_true(result_value ->> 'ok' = 'false'
        and result_value ->> 'sqlstate' = test_case.expected_state
        and (test_case.expected_message is null or result_value ->> 'message' = test_case.expected_message),
        'unexpected B result in case ' || case_number::text || ': ' || result_value::text);
    end if;
    -- Do not update A's row or inspect its committed data in REPEATABLE READ.
    -- Final state verification happens in a fresh transaction after both CALLs.
    insert into t10_concurrency_test.observations (
      case_no, worker, backend_pid, peer_pid, started_at, observed_at, isolation_level, rpc_result
    ) values (case_number, 'b', pg_catalog.pg_backend_pid(), peer_pid_value,
      started_at_value, pg_catalog.clock_timestamp(), pg_catalog.current_setting('transaction_isolation'), result_value);
    commit;
    set transaction isolation level read committed;
    update t10_concurrency_test.observations set b_after = t10_concurrency_test.snapshot(null)
    where case_no = case_number and worker = 'b';
    commit;
  end loop;
  update t10_concurrency_test.run set b_finished_at = pg_catalog.clock_timestamp() where id = 1;
  commit;
end;
$$;


create function t10_concurrency_test.verify()
returns table(case_no integer,test_name text,passed boolean,backend_a integer,backend_b integer,rejected_sqlstate text)
language plpgsql security invoker set search_path='' as $$
declare c t10_concurrency_test.run%rowtype; tc t10_concurrency_test.cases%rowtype; oa t10_concurrency_test.observations%rowtype; ob t10_concurrency_test.observations%rowtype; n integer;
begin
 perform t10_concurrency_test.check_true(current_user='postgres','postgres verifier');
 perform id from public.facility_guard where id=1 for update;
 select * into strict c from t10_concurrency_test.run where id=1;
 perform t10_concurrency_test.check_true(c.a_finished_at is not null and c.b_finished_at is not null and c.a_pid<>c.b_pid,'both distinct workers finished');
 perform t10_concurrency_test.check_true((select count(*)=40 from t10_concurrency_test.observations),'all twenty pairs');
 for n in 1..20 loop
  select * into strict tc from t10_concurrency_test.cases t where t.case_no=n;
  select * into strict oa from t10_concurrency_test.observations o where o.case_no=n and o.worker='a';
  select * into strict ob from t10_concurrency_test.observations o where o.case_no=n and o.worker='b';
  perform t10_concurrency_test.check_true(oa.backend_pid=c.a_pid and ob.backend_pid=c.b_pid and oa.peer_pid=ob.backend_pid and ob.peer_pid=oa.backend_pid
    and ob.started_at<=oa.observed_at and oa.observed_at<=ob.observed_at,'proven blocking and connection identities');
  perform t10_concurrency_test.check_true(oa.isolation_level='read committed' and ob.isolation_level=case when n=14 then 'repeatable read' else 'read committed' end,'isolation recorded');
  perform t10_concurrency_test.check_true(oa.rpc_result->>'ok'='true','A succeeded');
  if tc.expected_state is null then
   perform t10_concurrency_test.check_true(n=3 and oa.rpc_result=ob.rpc_result,'same retry returns same response');
  else
   perform t10_concurrency_test.check_true(ob.rpc_result->>'ok'='false' and ob.rpc_result->>'sqlstate'=tc.expected_state
    and (tc.expected_message is null or ob.rpc_result->>'message'=tc.expected_message),'expected rejection');
  end if;
  perform t10_concurrency_test.check_true(oa.a_after=ob.b_after,'B made no partial writes, including successful idempotent retry');
  if n in(1,14) then perform t10_concurrency_test.check_true(private.community_occupancy(c.base_date+(n-1)*2)=15,'exactly fifteen people'); end if;
  if n=3 then perform t10_concurrency_test.check_true((select count(*)=1 from public.reception_numbers where application_id=tc.app_a)
    and (select count(*)=1 from public.application_status_events where application_id=tc.app_a and to_status='submitted'),'single receipt and submission event'); end if;
  if n=17 then perform t10_concurrency_test.check_true(ob.started_at<tc.deadline and oa.observed_at<tc.deadline and ob.observed_at>=tc.deadline
    and (select status='revision_requested' from public.applications where id=tc.app_a),'expiry crossed while blocked, original claim retained'); end if;
  return query select tc.case_no,tc.test_name,true,oa.backend_pid,ob.backend_pid,ob.rpc_result->>'sqlstate';
 end loop;
 update t10_concurrency_test.run set verified_at=clock_timestamp() where id=1;
end; $$;
-- Available after failed runs too. Stop both workers first. Source UUIDs, actor
-- UUIDs and run markers must all agree before any cleanup deletion is allowed.
create function t10_concurrency_test.cleanup()
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare ctx t10_concurrency_test.run%rowtype; user_ids uuid[]; camp_ids uuid[]; block_ids uuid[]; app_ids uuid[];
begin
  perform t10_concurrency_test.check_true(current_user='postgres','postgres cleanup required');
  perform set_config('lock_timeout','3s',true);
  perform g.id from public.facility_guard g where g.id=1 for update;
  select * into strict ctx from t10_concurrency_test.run where id=1 for update;
  perform pg_stat_clear_snapshot();
  perform t10_concurrency_test.check_true(not exists(select 1 from pg_stat_activity a where a.pid<>pg_backend_pid()
    and a.state is distinct from 'idle' and ((a.pid=ctx.a_pid and a.backend_start=ctx.a_backend_start)
      or (a.pid=ctx.b_pid and a.backend_start=ctx.b_backend_start))),'stop/wait for both workers');
  select coalesce(array_agg(id),'{}'::uuid[]) into user_ids from t10_concurrency_test.fixtures where kind='user';
  perform t10_concurrency_test.check_true((select count(*)=cardinality(user_ids) from auth.users u where u.id=any(user_ids)
    and u.email='t10-concurrency-'||u.id::text||'@example.invalid' and u.raw_user_meta_data->>'t10_concurrency_run'=ctx.token::text
    and coalesce(u.encrypted_password,'')='' and u.last_sign_in_at is null),'marked unused users');
  select coalesce(array_agg(id),'{}'::uuid[]) into camp_ids from public.camps
  where created_by=any(user_ids) and name like 'T10 concurrency '||ctx.token::text||' case %';
  select coalesce(array_agg(id),'{}'::uuid[]) into block_ids from public.blocked_periods
  where created_by=any(user_ids) and internal_reason like 'T10 concurrency '||ctx.token::text||' case %';
  select coalesce(array_agg(id),'{}'::uuid[]) into app_ids from public.applications where user_id=any(user_ids) and usage_type='community_individual';
  perform t10_concurrency_test.check_true(not exists(select 1 from public.camps where created_by=any(user_ids) and not(id=any(camp_ids)))
    and not exists(select 1 from public.blocked_periods where created_by=any(user_ids) and not(id=any(block_ids)))
    and not exists(select 1 from public.applications where (camp_id=any(camp_ids) or user_id=any(user_ids) or original_application_id=any(app_ids))
      and not(id=any(app_ids)))
    and not exists(select 1 from public.consent_documents d join public.applications a on a.id=d.application_id where d.application_id=any(app_ids) and d.object_path<>'applications/'||a.id::text||'/'||ctx.token::text)
    and not exists(select 1 from public.audit_logs where actor_user_id=any(user_ids)
      and not((entity_type='application' and entity_id=any(app_ids)) or (entity_type='camp' and entity_id=any(camp_ids))
        or (entity_type='blocked' and entity_id=any(block_ids))))
    and not exists(select 1 from public.application_status_events where actor_user_id=any(user_ids) and not(application_id=any(app_ids)))
    and not exists(select 1 from public.camp_eligible_users e where e.camp_id=any(camp_ids)
      and not exists(select 1 from auth.users u where u.id=any(user_ids) and u.email=e.email_normalized)),
    'no unexpected references, attachments, or records');
  delete from public.audit_logs where actor_user_id=any(user_ids);
  delete from public.calendar_claims where application_id=any(app_ids);
  delete from public.applications where id=any(app_ids);
  delete from public.calendar_claims where camp_id=any(camp_ids) or blocked_period_id=any(block_ids);
  delete from public.camps where id=any(camp_ids);
  delete from public.blocked_periods where id=any(block_ids);
  delete from auth.users where id=any(user_ids);
  perform t10_concurrency_test.check_true(not exists(select 1 from public.camps where id=any(camp_ids))
    and not exists(select 1 from public.blocked_periods where id=any(block_ids))
    and not exists(select 1 from public.calendar_claims where camp_id=any(camp_ids) or blocked_period_id=any(block_ids))
    and not exists(select 1 from public.applications where id=any(app_ids))
    and not exists(select 1 from auth.users where id=any(user_ids)),'fixture cleanup complete');
  return jsonb_build_object('removed_users',cardinality(user_ids),'removed_camps',cardinality(camp_ids),
    'removed_blocks',cardinality(block_ids),'removed_applications',cardinality(app_ids),'receipt_counters','preserved');
end;
$$;

revoke all on all functions in schema t10_concurrency_test from public,anon,authenticated,service_role;
revoke all on all procedures in schema t10_concurrency_test from public,anon,authenticated,service_role;
commit;
select token as run_token,'Prepared only; run both workers, verify, then clean up.' as status,
  'call t10_concurrency_test.worker_a();' as connection_a,
  'call t10_concurrency_test.worker_b();' as connection_b,
  'select * from t10_concurrency_test.verify();' as verification_sql,
  'begin; select t10_concurrency_test.cleanup(); drop schema t10_concurrency_test cascade; commit;' as cleanup_sql
from t10_concurrency_test.run where id=1;
