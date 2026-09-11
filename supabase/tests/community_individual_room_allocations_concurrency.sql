-- SQL 014 multi-connection regression. ISOLATED TEST PROJECT WITHOUT TRAFFIC.
-- Requires 001-014 and empty days 14-60. This file PREPARES and COMMITS fixtures.
-- Then start A and B in DISTINCT connections, while A is still running:
--   call t12i_concurrency_test.worker_a();
--   call t12i_concurrency_test.worker_b();
-- Each CALL alone, outside BEGIN. After BOTH finish:
--   select count(*) as checked_cases, bool_and(passed) as all_passed from t12i_concurrency_test.verify();
-- Expected: 20 / true. pg_blocking_pids and connection IDs prove real waiting.
-- After success OR failure, stop both workers before cleanup:
--   begin; select t12i_concurrency_test.cleanup(); drop schema t12i_concurrency_test cascade; commit;
--   select to_regnamespace('t12i_concurrency_test') is null as cleanup_completed;
-- Do not rerun a worker alone. No real Auth/Storage API or secrets. Counters remain.
begin;
set local lock_timeout='3s';
set local statement_timeout='60s';
set local timezone='UTC';
do $$ begin
  if current_user<>'postgres' or to_regprocedure('public.assign_community_application_room(uuid,uuid,timestamptz,text)') is null then raise exception 'Run as postgres after 001-014.'; end if;
  if to_regnamespace('t12i_concurrency_test') is not null then raise exception 'Existing run: stop workers and clean up before retrying.'; end if;
  if exists(select 1 from public.calendar_claims where start_date<=(clock_timestamp() at time zone 'Asia/Tokyo')::date+60
    and end_date>=(clock_timestamp() at time zone 'Asia/Tokyo')::date+14 and (released_from is null or released_from>start_date)) then
    raise exception 'Use an isolated test project with no claims in the 14-60 day window.'; end if;
end; $$;
create schema t12i_concurrency_test;
revoke all on schema t12i_concurrency_test from public, anon, authenticated, service_role;

create table t12i_concurrency_test.run (
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
create table t12i_concurrency_test.fixtures (
  kind text not null check (kind in ('user', 'camp', 'application', 'blocked')),
  id uuid not null,
  primary key (kind, id)
);
create table t12i_concurrency_test.cases (
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
create table t12i_concurrency_test.observations (
  case_no integer not null references t12i_concurrency_test.cases(case_no),
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
alter table t12i_concurrency_test.run enable row level security;
alter table t12i_concurrency_test.fixtures enable row level security;
alter table t12i_concurrency_test.cases enable row level security;
alter table t12i_concurrency_test.observations enable row level security;
revoke all on all tables in schema t12i_concurrency_test
from public, anon, authenticated, service_role;

create function t12i_concurrency_test.check_true(condition boolean, label text)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if current_user <> 'postgres' then raise exception 'Run as postgres.'; end if;
  if condition is distinct from true then raise exception 'FAIL: %', label; end if;
end;
$$;

create function t12i_concurrency_test.fixture_user(is_staff boolean default false)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  new_id uuid := gen_random_uuid();
  run_token uuid := (select token from t12i_concurrency_test.run where id = 1);
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  ) values (
    new_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    't12i-concurrency-' || new_id::text || '@example.invalid', '', clock_timestamp(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('t12i_concurrency_run', run_token), clock_timestamp(), clock_timestamp()
  );
  insert into t12i_concurrency_test.fixtures values ('user', new_id);
  if is_staff then insert into public.staff_roles (user_id) values (new_id); end if;
  return new_id;
end;
$$;

-- Role changes must happen in an INVOKER helper, not a definer function.
-- Errors roll back the RPC's subtransaction; the worker records their exact code.
create function t12i_concurrency_test.call_as(actor_id uuid, query_text text, role_name text default 'authenticated')
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
  perform t12i_concurrency_test.check_true(current_user = 'postgres', 'postgres test caller required');
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

create function t12i_concurrency_test.snapshot(app_value uuid)
returns jsonb language sql security invoker set search_path = '' as $$
  with users as (select id from t12i_concurrency_test.fixtures where kind = 'user'),
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

create function t12i_concurrency_test.peer_tag(token_value uuid, worker_value text, case_value integer)
returns text language sql immutable security invoker set search_path = '' as $$
  select 't12ic:' || token_value::text || ':' || worker_value || ':' || case_value::text;
$$;

create function t12i_concurrency_test.wait_for_peer(
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
create function t12i_concurrency_test.wait_for_b_result(case_value integer, stop_at timestamptz)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  loop
    if clock_timestamp() >= stop_at then
      raise exception 'B did not finish its case before timeout. Clean up before retrying.';
    end if;
    if exists (select 1 from t12i_concurrency_test.observations o
      where o.case_no = case_value and o.worker = 'b' and o.b_after is not null) then return; end if;
    perform pg_sleep(0.1);
  end loop;
end;
$$;

create function t12i_concurrency_test.expect_success(result_value jsonb)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  perform t12i_concurrency_test.check_true(
    result_value ->> 'ok' = 'true' and jsonb_array_length(result_value -> 'rows') = 1,
    'RPC must succeed with one result: ' || coalesce(result_value::text, 'NULL')
  );
end;
$$;


create function t12i_concurrency_test.fields(starts_on date,ends_on date) returns jsonb language sql as $$ select jsonb_build_object(
 'start_date',starts_on,'end_date',ends_on,'user_name','架空同時更新利用者','user_address','架空住所','user_phone','000-0000-0000',
 'emergency_name','架空連絡先','emergency_address','架空住所','emergency_phone','000-0000-0000',
 'purpose','架空検証','local_activity','架空地域活動','usage_place','common_and_second_floor','requires_guardian_consent',false); $$;
create function t12i_concurrency_test.draft(actor uuid,starts_on date,ends_on date) returns uuid language plpgsql as $$ declare x uuid:=gen_random_uuid(); begin
 perform t12i_concurrency_test.expect_success(t12i_concurrency_test.call_as(actor,format('select * from public.create_community_application_draft(%L,%L::jsonb)',x,t12i_concurrency_test.fields(starts_on,ends_on))));
 insert into t12i_concurrency_test.fixtures values('application',x); return x;
end; $$;
create function t12i_concurrency_test.submit_sql(x uuid,key_value uuid default gen_random_uuid()) returns text language sql as $$
 select format('select * from public.submit_community_application(%L,%L,%L,true)',x,a.updated_at,key_value) from public.applications a where id=x; $$;
create function t12i_concurrency_test.save_sql(x uuid) returns text language sql as $$
 select format('select * from public.save_community_application_draft(%L,%L,%L::jsonb)',x,a.updated_at,t12i_concurrency_test.fields(a.start_date,a.end_date)||jsonb_build_object('purpose','架空修正')) from public.applications a where id=x; $$;
create function t12i_concurrency_test.review_sql(x uuid,operation text) returns text language sql as $$
 select format('select * from public.review_community_application(%L,%L,%L,%L)',x,operation,a.updated_at,'架空審査') from public.applications a where id=x; $$;

create function t12i_concurrency_test.assign_sql(x uuid,room uuid,reason_value text default null)
returns text language sql as $$ select format('select * from public.assign_community_application_room(%L,%L,%L,%L)',
 x,room,a.updated_at,reason_value) from public.applications a where id=x; $$;
create function t12i_concurrency_test.reviewed(starts_on date,ends_on date)
returns uuid language plpgsql as $$ declare x uuid; actor uuid:=t12i_concurrency_test.fixture_user(); staff uuid:=(select staff_a from t12i_concurrency_test.run where id=1); begin
 x:=t12i_concurrency_test.draft(actor,starts_on,ends_on);
 perform t12i_concurrency_test.expect_success(t12i_concurrency_test.call_as(actor,t12i_concurrency_test.submit_sql(x)));
 perform t12i_concurrency_test.expect_success(t12i_concurrency_test.call_as(staff,t12i_concurrency_test.review_sql(x,'start_review')));
 return x;
end; $$;
insert into t12i_concurrency_test.run(id,base_date) values(1,(clock_timestamp() at time zone 'Asia/Tokyo')::date+14);
do $$ declare c t12i_concurrency_test.run%rowtype; n integer; j integer; d date; aa uuid; ab uuid; extra uuid; ua uuid; ub uuid;
 kiri uuid:=(select id from public.rooms where name='桐'); fuji uuid:=(select id from public.rooms where name='藤');
 qa text; qb text; label_value text; expected text; state_value text; block_id uuid; version_value timestamptz;
begin
 update t12i_concurrency_test.run set staff_a=t12i_concurrency_test.fixture_user(true),staff_b=t12i_concurrency_test.fixture_user(true) where id=1 returning * into c;
 for n in 1..20 loop
  d:=c.base_date+(n-1)*2; ua:=c.staff_a; ub:=c.staff_b; state_value:='P0001'; expected:='stale-update';
  aa:=t12i_concurrency_test.reviewed(case when n=10 then d-1 else d end,case when n=10 then d else d+1 end); ab:=aa;
  if n not in(1,15,18) then
   perform t12i_concurrency_test.expect_success(t12i_concurrency_test.call_as(c.staff_a,t12i_concurrency_test.assign_sql(aa,case when n=10 then fuji else kiri end)));
  end if;
  qa:=t12i_concurrency_test.assign_sql(aa,fuji,'架空の同時変更'); qb:=t12i_concurrency_test.review_sql(ab,'approve');
  if n=1 then
   label_value:='last room place: one staff assignment succeeds'; ab:=t12i_concurrency_test.reviewed(d,d+1);
   qa:=t12i_concurrency_test.assign_sql(aa,kiri); qb:=t12i_concurrency_test.assign_sql(ab,kiri); expected:='room-capacity-full';
  elsif n=2 then label_value:='room change invalidates waiting approval';
  elsif n=3 then label_value:='approval invalidates waiting room change'; qa:=t12i_concurrency_test.review_sql(aa,'approve'); qb:=t12i_concurrency_test.assign_sql(aa,fuji,'古い変更');
  elsif n=4 then label_value:='simultaneous approvals create exactly one stay'; qa:=t12i_concurrency_test.review_sql(aa,'approve'); qb:=qa;
  elsif n=5 then label_value:='two pre-approval room changes cannot overwrite'; qb:=qa;
  elsif n=6 then label_value:='approval invalidates waiting rejection'; qa:=t12i_concurrency_test.review_sql(aa,'approve'); qb:=t12i_concurrency_test.review_sql(aa,'reject');
  elsif n=7 then label_value:='rejection invalidates waiting approval'; qa:=t12i_concurrency_test.review_sql(aa,'reject');
  elsif n=8 then label_value:='revision request invalidates waiting approval'; qa:=t12i_concurrency_test.review_sql(aa,'request_revision');
  elsif n=9 then label_value:='approval invalidates waiting revision request'; qa:=t12i_concurrency_test.review_sql(aa,'approve'); qb:=t12i_concurrency_test.review_sql(aa,'request_revision');
  elsif n=10 then
   label_value:='released old period can be reassigned once';
   perform t12i_concurrency_test.expect_success(t12i_concurrency_test.call_as(c.staff_a,t12i_concurrency_test.review_sql(aa,'request_revision')));
   extra:=(select user_id from public.applications where id=aa);
   perform t12i_concurrency_test.expect_success(t12i_concurrency_test.call_as(extra,format('select * from public.save_community_application_draft(%L,%L,%L::jsonb)',aa,(select updated_at from public.applications where id=aa),t12i_concurrency_test.fields(d,d+1))));
   perform t12i_concurrency_test.expect_success(t12i_concurrency_test.call_as(extra,t12i_concurrency_test.submit_sql(aa)));
   perform t12i_concurrency_test.expect_success(t12i_concurrency_test.call_as(c.staff_a,t12i_concurrency_test.review_sql(aa,'start_review')));
   qa:=t12i_concurrency_test.assign_sql(aa,fuji,'日程変更の再割当'); qb:=qa;
  elsif n=11 then label_value:='rejection invalidates waiting room change'; qa:=t12i_concurrency_test.review_sql(aa,'reject'); qb:=t12i_concurrency_test.assign_sql(aa,fuji,'拒否後の古い変更');
  elsif n=12 then label_value:='same-room current-version saves are both no-ops'; qa:=t12i_concurrency_test.assign_sql(aa,kiri); qb:=qa; expected:=null; state_value:=null;
  elsif n=13 then
   label_value:='assigned applicant plus fourteen reservations still caps at fifteen';
   for j in 1..13 loop perform t12i_concurrency_test.reviewed(d,d+1); end loop;
   ua:=t12i_concurrency_test.fixture_user(); ub:=t12i_concurrency_test.fixture_user();
   aa:=t12i_concurrency_test.draft(ua,d,d+1); ab:=t12i_concurrency_test.draft(ub,d,d+1);
   qa:=t12i_concurrency_test.submit_sql(aa); qb:=t12i_concurrency_test.submit_sql(ab); expected:='capacity-full';
  elsif n=14 then label_value:='repeatable-read rejects stale room/approval snapshot'; state_value:='40001'; expected:=null;
  elsif n=15 then label_value:='staff disabled while assignment waits'; ub:=t12i_concurrency_test.fixture_user(true); qa:=null;
   qb:=t12i_concurrency_test.assign_sql(aa,kiri); state_value:='42501'; expected:='staff-required';
  elsif n=16 then label_value:='staff role removed while approval waits'; ub:=t12i_concurrency_test.fixture_user(true); qa:=null;
   qb:=t12i_concurrency_test.review_sql(aa,'approve'); state_value:='42501'; expected:='staff-required';
  elsif n=17 then label_value:='revision deadline expires while assigned applicant resubmits';
   perform t12i_concurrency_test.expect_success(t12i_concurrency_test.call_as(c.staff_a,t12i_concurrency_test.review_sql(aa,'request_revision')));
   ub:=(select user_id from public.applications where id=aa); qa:=null; qb:=t12i_concurrency_test.submit_sql(aa); expected:='revision-expired';
  elsif n=18 then label_value:='room assignment and conflicting camp creation serialize'; qa:=t12i_concurrency_test.assign_sql(aa,kiri);
   qb:=format('select public.create_staff_camp(%L,%L,%L,%L)','T12I concurrency '||c.token::text||' case '||n,d,d+1,d::timestamp at time zone 'Asia/Tokyo'); expected:='date-conflict';
  elsif n=19 then label_value:='approval and conflicting stop update serialize';
   insert into public.blocked_periods(start_date,end_date,internal_reason,created_by) values(d+100,d+101,'T12I concurrency '||c.token::text||' case '||n,c.staff_a) returning id,updated_at into block_id,version_value;
   insert into t12i_concurrency_test.fixtures values('blocked',block_id);
   qa:=t12i_concurrency_test.review_sql(aa,'approve');
   qb:=format('select * from public.save_staff_blocked_period(%L,%L,%L,%L,%L,%L)',block_id,d,d+1,'T12I concurrency '||c.token::text||' case '||n,version_value,'架空日程変更'); expected:='date-conflict';
  else label_value:='two post-approval room changes cannot overwrite';
   perform t12i_concurrency_test.expect_success(t12i_concurrency_test.call_as(c.staff_a,t12i_concurrency_test.review_sql(aa,'approve')));
   qa:=t12i_concurrency_test.assign_sql(aa,fuji,'許可後の変更'); qb:=qa;
  end if;
  insert into t12i_concurrency_test.cases(case_no,test_name,app_a,app_b,actor_a,actor_b,a_query,b_query,expected_state,expected_message)
  values(n,label_value,aa,ab,ua,ub,qa,qb,state_value,expected);
 end loop;
end; $$;

-- A procedure with transaction control cannot be DEFINER or have a SET clause.
-- All object/function names below are qualified; COMMIT is outside exception
-- blocks. Integer loops avoid cursors being materialized across commits.
create procedure t12i_concurrency_test.worker_a()
language plpgsql security invoker as $$
declare
  context t12i_concurrency_test.run%rowtype;
  test_case t12i_concurrency_test.cases%rowtype;
  case_number integer;
  stop_at timestamptz := pg_catalog.clock_timestamp() + interval '50 seconds';
  started_at_value timestamptz;
  observed_at_value timestamptz;
  peer_pid_value integer;
  result_value jsonb;
begin
  perform t12i_concurrency_test.check_true(current_user = 'postgres', 'postgres worker required');
  update t12i_concurrency_test.run set a_pid = pg_catalog.pg_backend_pid(),
    a_backend_start = (select backend_start from pg_catalog.pg_stat_activity where pid = pg_catalog.pg_backend_pid())
  where id = 1 and a_pid is null returning * into context;
  perform t12i_concurrency_test.check_true(found, 'A already attempted: clean up before retrying');
  commit;
  for case_number in 1..20 loop
    -- Loop expressions can acquire a snapshot. SET must directly follow COMMIT.
    commit;
    set transaction isolation level read committed;
    perform pg_catalog.set_config('lock_timeout', '3s', true);
    select * into strict test_case from t12i_concurrency_test.cases where case_no = case_number;

    if case_number=17 then
      -- Publish both deadline and expected version before B can start its RPC.
      update public.applications set revision_due_at=pg_catalog.clock_timestamp()+interval '4 seconds'
        where id=test_case.app_a returning revision_due_at into test_case.deadline;
      update t12i_concurrency_test.cases set deadline=test_case.deadline,b_query=t12i_concurrency_test.submit_sql(test_case.app_a) where case_no=case_number;
      commit;
      set transaction isolation level read committed;
    end if;
    started_at_value := pg_catalog.clock_timestamp();
    if case_number in(15,16,17) then
      update public.facility_guard set id=id where id=1;
      perform t12i_concurrency_test.check_true(found,'facility guard exists');
      if case_number=15 then update public.profiles set account_state='disabled' where id=test_case.actor_b; end if;
      if case_number=16 then delete from public.staff_roles where user_id=test_case.actor_b; end if;
      result_value:='{"ok":true,"test_guard":true}'::jsonb;
    else
      result_value:=t12i_concurrency_test.call_as(test_case.actor_a,test_case.a_query,test_case.a_role);
      perform t12i_concurrency_test.expect_success(result_value);
    end if;

    -- Advertise only AFTER A holds the facility lock and has performed its RPC.
    perform pg_catalog.set_config('application_name', t12i_concurrency_test.peer_tag(context.token, 'a', case_number), true);
    peer_pid_value := t12i_concurrency_test.wait_for_peer(
      t12i_concurrency_test.peer_tag(context.token, 'b', case_number), stop_at, true);
    observed_at_value := pg_catalog.clock_timestamp();
    if case_number=17 then
      perform t12i_concurrency_test.check_true(observed_at_value<test_case.deadline,'B blocked before deadline');
      while pg_catalog.clock_timestamp()<=test_case.deadline loop perform pg_catalog.pg_sleep(0.05); end loop;
    end if;
    insert into t12i_concurrency_test.observations (
      case_no, worker, backend_pid, peer_pid, started_at, observed_at, isolation_level, rpc_result, a_after, b_after
    ) values (case_number, 'a', pg_catalog.pg_backend_pid(), peer_pid_value,
      started_at_value, observed_at_value, pg_catalog.current_setting('transaction_isolation'), result_value,
      t12i_concurrency_test.snapshot(test_case.app_a), t12i_concurrency_test.snapshot(test_case.app_b));
    commit;
    set transaction isolation level read committed;
    perform t12i_concurrency_test.wait_for_b_result(case_number, stop_at);
    commit;
  end loop;
  update t12i_concurrency_test.run set a_finished_at = pg_catalog.clock_timestamp() where id = 1;
  commit;
end;
$$;

create procedure t12i_concurrency_test.worker_b()
language plpgsql security invoker as $$
declare
  context t12i_concurrency_test.run%rowtype;
  test_case t12i_concurrency_test.cases%rowtype;
  case_number integer;
  stop_at timestamptz := pg_catalog.clock_timestamp() + interval '50 seconds';
  started_at_value timestamptz;
  peer_pid_value integer;
  result_value jsonb;
begin
  perform t12i_concurrency_test.check_true(current_user = 'postgres', 'postgres worker required');
  update t12i_concurrency_test.run set b_pid = pg_catalog.pg_backend_pid(),
    b_backend_start = (select backend_start from pg_catalog.pg_stat_activity where pid = pg_catalog.pg_backend_pid())
  where id = 1 and b_pid is null returning * into context;
  perform t12i_concurrency_test.check_true(found, 'B already attempted: clean up before retrying');
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
    perform t12i_concurrency_test.check_true(
      pg_catalog.current_setting('transaction_isolation') =
        case when case_number = 14 then 'repeatable read' else 'read committed' end,
      'B transaction isolation for case ' || case_number::text);
    perform pg_catalog.set_config('lock_timeout', '45s', true);
    perform pg_catalog.set_config('application_name', t12i_concurrency_test.peer_tag(context.token, 'b', case_number), true);
    peer_pid_value := t12i_concurrency_test.wait_for_peer(
      t12i_concurrency_test.peer_tag(context.token, 'a', case_number), stop_at, false);
    select * into strict test_case from t12i_concurrency_test.cases where case_no = case_number;
    started_at_value := pg_catalog.clock_timestamp();
    if case_number=17 then perform t12i_concurrency_test.check_true(started_at_value<test_case.deadline,'B starts before deadline'); end if;
    result_value := t12i_concurrency_test.call_as(test_case.actor_b, test_case.b_query);
    if test_case.expected_state is null then
      perform t12i_concurrency_test.expect_success(result_value);
    else
      perform t12i_concurrency_test.check_true(result_value ->> 'ok' = 'false'
        and result_value ->> 'sqlstate' = test_case.expected_state
        and (test_case.expected_message is null or result_value ->> 'message' = test_case.expected_message),
        'unexpected B result in case ' || case_number::text || ': ' || result_value::text);
    end if;
    -- Do not update A's row or inspect its committed data in REPEATABLE READ.
    -- Final state verification happens in a fresh transaction after both CALLs.
    insert into t12i_concurrency_test.observations (
      case_no, worker, backend_pid, peer_pid, started_at, observed_at, isolation_level, rpc_result
    ) values (case_number, 'b', pg_catalog.pg_backend_pid(), peer_pid_value,
      started_at_value, pg_catalog.clock_timestamp(), pg_catalog.current_setting('transaction_isolation'), result_value);
    commit;
    set transaction isolation level read committed;
    update t12i_concurrency_test.observations set b_after = t12i_concurrency_test.snapshot(null)
    where case_no = case_number and worker = 'b';
    commit;
  end loop;
  update t12i_concurrency_test.run set b_finished_at = pg_catalog.clock_timestamp() where id = 1;
  commit;
end;
$$;


create function t12i_concurrency_test.verify()
returns table(case_no integer,test_name text,passed boolean,backend_a integer,backend_b integer,rejected_sqlstate text)
language plpgsql security invoker set search_path='' as $$
declare c t12i_concurrency_test.run%rowtype; tc t12i_concurrency_test.cases%rowtype; oa t12i_concurrency_test.observations%rowtype; ob t12i_concurrency_test.observations%rowtype; n integer;
begin
 perform t12i_concurrency_test.check_true(current_user='postgres','postgres verifier');
 perform id from public.facility_guard where id=1 for update;
 select * into strict c from t12i_concurrency_test.run where id=1;
 perform t12i_concurrency_test.check_true(c.a_finished_at is not null and c.b_finished_at is not null and c.a_pid<>c.b_pid,'both distinct workers finished');
 perform t12i_concurrency_test.check_true((select count(*)=40 from t12i_concurrency_test.observations),'all twenty pairs');
 for n in 1..20 loop
  select * into strict tc from t12i_concurrency_test.cases t where t.case_no=n;
  select * into strict oa from t12i_concurrency_test.observations o where o.case_no=n and o.worker='a';
  select * into strict ob from t12i_concurrency_test.observations o where o.case_no=n and o.worker='b';
  perform t12i_concurrency_test.check_true(oa.backend_pid=c.a_pid and ob.backend_pid=c.b_pid and oa.peer_pid=ob.backend_pid and ob.peer_pid=oa.backend_pid
    and ob.started_at<=oa.observed_at and oa.observed_at<=ob.observed_at,'proven blocking and connection identities');
  perform t12i_concurrency_test.check_true(oa.isolation_level='read committed' and ob.isolation_level=case when n=14 then 'repeatable read' else 'read committed' end,'isolation recorded');
  perform t12i_concurrency_test.check_true(oa.rpc_result->>'ok'='true','A succeeded');
  if tc.expected_state is null then
   perform t12i_concurrency_test.check_true(n=12 and oa.rpc_result=ob.rpc_result,'same retry returns same response');
  else
   perform t12i_concurrency_test.check_true(ob.rpc_result->>'ok'='false' and ob.rpc_result->>'sqlstate'=tc.expected_state
    and (tc.expected_message is null or ob.rpc_result->>'message'=tc.expected_message),'expected rejection');
  end if;
  perform t12i_concurrency_test.check_true(oa.a_after=ob.b_after,'B made no partial writes, including successful idempotent retry');
  if n=13 then perform t12i_concurrency_test.check_true(private.community_occupancy(c.base_date+(n-1)*2)=15,'exactly fifteen people'); end if;
  if n in(3,4,6,9,19,20) then
   perform t12i_concurrency_test.check_true((select count(*)=1 from public.stays where application_id=tc.app_a)
    and (select count(*)=1 from public.application_status_events where application_id=tc.app_a and to_status='approved'), 'one stay and one approval event');
  end if;
  if n=1 then perform t12i_concurrency_test.check_true((select count(*)=1 from public.room_allocations where application_id in(tc.app_a,tc.app_b)), 'only one final room place assigned'); end if;
  if n in(7,11) then perform t12i_concurrency_test.check_true((select released_from=start_date from public.room_allocations where application_id=tc.app_a)
    and (select released_from=start_date from public.calendar_claims where application_id=tc.app_a), 'rejection released both reservations'); end if;
  if n=10 then perform t12i_concurrency_test.check_true((select count(*)=1 from public.audit_logs where entity_id=tc.app_a and action='reassign_room'), 'one reassignment only'); end if;
  if n=17 then perform t12i_concurrency_test.check_true(ob.started_at<tc.deadline and oa.observed_at<tc.deadline and ob.observed_at>=tc.deadline
    and (select status='revision_requested' from public.applications where id=tc.app_a),'expiry crossed while blocked, original claim retained'); end if;
  return query select tc.case_no,tc.test_name,true,oa.backend_pid,ob.backend_pid,ob.rpc_result->>'sqlstate';
 end loop;
 update t12i_concurrency_test.run set verified_at=clock_timestamp() where id=1;
end; $$;
-- Available after failed runs too. Stop both workers first. Source UUIDs, actor
-- UUIDs and run markers must all agree before any cleanup deletion is allowed.
create function t12i_concurrency_test.cleanup()
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare ctx t12i_concurrency_test.run%rowtype; user_ids uuid[]; camp_ids uuid[]; block_ids uuid[]; app_ids uuid[];
begin
  perform t12i_concurrency_test.check_true(current_user='postgres','postgres cleanup required');
  perform set_config('lock_timeout','3s',true);
  perform g.id from public.facility_guard g where g.id=1 for update;
  select * into strict ctx from t12i_concurrency_test.run where id=1 for update;
  perform pg_stat_clear_snapshot();
  perform t12i_concurrency_test.check_true(not exists(select 1 from pg_stat_activity a where a.pid<>pg_backend_pid()
    and a.state is distinct from 'idle' and ((a.pid=ctx.a_pid and a.backend_start=ctx.a_backend_start)
      or (a.pid=ctx.b_pid and a.backend_start=ctx.b_backend_start))),'stop/wait for both workers');
  select coalesce(array_agg(id),'{}'::uuid[]) into user_ids from t12i_concurrency_test.fixtures where kind='user';
  perform t12i_concurrency_test.check_true((select count(*)=cardinality(user_ids) from auth.users u where u.id=any(user_ids)
    and u.email='t12i-concurrency-'||u.id::text||'@example.invalid' and u.raw_user_meta_data->>'t12i_concurrency_run'=ctx.token::text
    and coalesce(u.encrypted_password,'')='' and u.last_sign_in_at is null),'marked unused users');
  select coalesce(array_agg(id),'{}'::uuid[]) into camp_ids from public.camps
  where created_by=any(user_ids) and name like 'T12I concurrency '||ctx.token::text||' case %';
  select coalesce(array_agg(id),'{}'::uuid[]) into block_ids from public.blocked_periods
  where created_by=any(user_ids) and internal_reason like 'T12I concurrency '||ctx.token::text||' case %';
  select coalesce(array_agg(id),'{}'::uuid[]) into app_ids from public.applications where user_id=any(user_ids) and usage_type='community_individual';
  perform t12i_concurrency_test.check_true(not exists(select 1 from public.camps where created_by=any(user_ids) and not(id=any(camp_ids)))
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
  perform t12i_concurrency_test.check_true(not exists(select 1 from public.camps where id=any(camp_ids))
    and not exists(select 1 from public.blocked_periods where id=any(block_ids))
    and not exists(select 1 from public.calendar_claims where camp_id=any(camp_ids) or blocked_period_id=any(block_ids))
    and not exists(select 1 from public.applications where id=any(app_ids))
    and not exists(select 1 from auth.users where id=any(user_ids)),'fixture cleanup complete');
  return jsonb_build_object('removed_users',cardinality(user_ids),'removed_camps',cardinality(camp_ids),
    'removed_blocks',cardinality(block_ids),'removed_applications',cardinality(app_ids),'receipt_counters','preserved');
end;
$$;

revoke all on all functions in schema t12i_concurrency_test from public,anon,authenticated,service_role;
revoke all on all procedures in schema t12i_concurrency_test from public,anon,authenticated,service_role;
commit;
select token as run_token,'Prepared only; run both workers, verify, then clean up.' as status,
  'call t12i_concurrency_test.worker_a();' as connection_a,
  'call t12i_concurrency_test.worker_b();' as connection_b,
  'select * from t12i_concurrency_test.verify();' as verification_sql,
  'begin; select t12i_concurrency_test.cleanup(); drop schema t12i_concurrency_test cascade; commit;' as cleanup_sql
from t12i_concurrency_test.run where id=1;
