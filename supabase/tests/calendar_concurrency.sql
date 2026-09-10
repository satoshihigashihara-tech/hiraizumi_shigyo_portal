-- T09 multi-connection regression. TEST PROJECT WITHOUT USER TRAFFIC ONLY.
-- Requires migrations 001-012; run the WHOLE file as postgres to PREPARE only.
-- Then in separate connections run A and immediately B while A is running:
--   call t09_concurrency_test.worker_a();
--   call t09_concurrency_test.worker_b();
-- Each CALL must stand alone, outside BEGIN. The workers prove real blocking
-- using pg_blocking_pids and record backend IDs and isolation levels.
-- After BOTH finish: select * from t09_concurrency_test.verify();
-- Cleanup (also after failure, once BOTH are stopped/rolled back):
--   begin; select t09_concurrency_test.cleanup(); drop schema t09_concurrency_test cascade; commit;
-- Setup COMMITS fictional fixtures. Cleanup is required; receipt counters stay.
-- No real accounts, passwords, Auth/Storage API, extensions or business-function
-- replacement. A missed overlap/timeout is a failure, not a concurrency pass.
-- Supabase SQL Editor must permit concurrent standalone CALLs with transaction
-- control; otherwise use two direct DB connections to the test project.

begin;
set local lock_timeout = '3s';
set local statement_timeout = '60s';
set local timezone = 'UTC';

do $$
begin
  if current_user <> 'postgres' then raise exception 'Run as postgres.'; end if;
  if to_regnamespace('t09_concurrency_test') is not null then
    raise exception 'A test run already exists. Verify/clean it up before retrying.';
  end if;
  if to_regprocedure('public.save_staff_blocked_period(uuid,date,date,text,timestamptz,text)') is null
    or to_regprocedure('public.assign_camp_application_room(uuid,uuid,timestamptz,text)') is null
    or to_regprocedure('public.review_camp_application(uuid,text,timestamptz,text)') is null then
    raise exception 'Apply migrations 001 through 012 first.';
  end if;
end;
$$;

create schema t09_concurrency_test;
revoke all on schema t09_concurrency_test from public, anon, authenticated, service_role;

create table t09_concurrency_test.run (
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
create table t09_concurrency_test.fixtures (
  kind text not null check (kind in ('user', 'camp', 'application', 'blocked')),
  id uuid not null,
  primary key (kind, id)
);
create table t09_concurrency_test.cases (
  case_no integer primary key check (case_no between 1 and 13),
  test_name text not null,
  camp_id uuid not null,
  app_a uuid not null,
  app_b uuid not null,
  actor_a uuid not null,
  actor_b uuid not null,
  a_query text,
  b_query text not null,
  expected_state text,
  expected_message text,
  deadline timestamptz
);
create table t09_concurrency_test.observations (
  case_no integer not null references t09_concurrency_test.cases(case_no),
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
alter table t09_concurrency_test.run enable row level security;
alter table t09_concurrency_test.fixtures enable row level security;
alter table t09_concurrency_test.cases enable row level security;
alter table t09_concurrency_test.observations enable row level security;
revoke all on all tables in schema t09_concurrency_test
from public, anon, authenticated, service_role;

create function t09_concurrency_test.check_true(condition boolean, label text)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if current_user <> 'postgres' then raise exception 'Run as postgres.'; end if;
  if condition is distinct from true then raise exception 'FAIL: %', label; end if;
end;
$$;

create function t09_concurrency_test.fixture_user(is_staff boolean default false)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  new_id uuid := gen_random_uuid();
  run_token uuid := (select token from t09_concurrency_test.run where id = 1);
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  ) values (
    new_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    't09-concurrency-' || new_id::text || '@example.invalid', '', clock_timestamp(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('t09_concurrency_run', run_token), clock_timestamp(), clock_timestamp()
  );
  insert into t09_concurrency_test.fixtures values ('user', new_id);
  if is_staff then insert into public.staff_roles (user_id) values (new_id); end if;
  return new_id;
end;
$$;

create function t09_concurrency_test.fixture_application(camp_value uuid, status_value text)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  new_id uuid;
  owner_id uuid := t09_concurrency_test.fixture_user();
  owner_email text := (select email from auth.users where id = owner_id);
begin
  insert into public.camp_eligible_users (camp_id, email_normalized) values (camp_value, owner_email);
  insert into public.applications (
    user_id, camp_id, status, start_date, end_date, user_name, user_address,
    user_phone, email_snapshot, emergency_name, emergency_address, emergency_phone,
    usage_place, purpose, requires_guardian_consent, room_preference,
    submitted_at, last_submitted_at
  ) select owner_id, c.id, status_value, c.start_date, c.end_date,
    '架空同時更新利用者', '架空住所', '000-0000-0000', owner_email,
    '架空連絡先', '架空住所', '000-0000-0000', 'common_and_second_floor',
    '架空同時更新検証', false, 'shared_ok',
    case when status_value <> 'draft' then clock_timestamp() end,
    case when status_value <> 'draft' then clock_timestamp() end
  from public.camps c where c.id = camp_value returning id into new_id;
  insert into t09_concurrency_test.fixtures values ('application', new_id);
  return new_id;
end;
$$;

-- Role changes must happen in an INVOKER helper, not a definer function.
-- Errors roll back the RPC's subtransaction; the worker records their exact code.
create function t09_concurrency_test.call_as(actor_id uuid, query_text text)
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
  perform t09_concurrency_test.check_true(current_user = 'postgres', 'postgres test caller required');
  begin
    set local role authenticated;
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

create function t09_concurrency_test.snapshot(app_value uuid)
returns jsonb language sql security invoker set search_path = '' as $$
  with users as (select id from t09_concurrency_test.fixtures where kind = 'user'),
  apps as (select a.* from public.applications a where a.user_id in (select id from users)),
  camps as (select c.* from public.camps c where c.created_by in (select id from users)),
  blocks as (select b.* from public.blocked_periods b where b.created_by in (select id from users))
  select jsonb_build_object(
    'profiles', (select jsonb_agg(to_jsonb(p) order by p.id) from public.profiles p where p.id in (select id from users)),
    'camps', (select jsonb_agg(to_jsonb(c) order by c.id) from camps c),
    'blocks', (select jsonb_agg(to_jsonb(b) order by b.id) from blocks b),
    'claims', (select jsonb_agg(to_jsonb(q) order by q.id) from public.calendar_claims q where q.camp_id in (select id from camps) or q.blocked_period_id in (select id from blocks)),
    'applications', (select jsonb_agg(to_jsonb(a) order by a.id) from apps a),
    'rooms', (select jsonb_agg(to_jsonb(r) order by r.id) from public.room_allocations r where r.application_id in (select id from apps)),
    'stays', (select jsonb_agg(to_jsonb(t) order by t.id) from public.stays t where t.application_id in (select id from apps)),
    'events', (select jsonb_agg(to_jsonb(e) order by e.id) from public.application_status_events e where e.application_id in (select id from apps)),
    'audit', (select jsonb_agg(to_jsonb(l) order by l.id) from public.audit_logs l where l.actor_user_id in (select id from users)),
    'charges', (select jsonb_agg(to_jsonb(c) order by c.id) from public.application_charges c where c.application_id in (select id from apps)),
    'months', (select jsonb_agg(to_jsonb(m) order by m.id) from public.charge_months m join public.application_charges c on c.id = m.charge_id where c.application_id in (select id from apps)),
    'numbers', (select jsonb_agg(to_jsonb(n) order by n.id) from public.reception_numbers n where n.application_id in (select id from apps)),
    'counters', (select jsonb_agg(to_jsonb(n) order by n.fiscal_year) from public.reception_counters n)
  );
$$;

create function t09_concurrency_test.peer_tag(token_value uuid, worker_value text, case_value integer)
returns text language sql immutable security invoker set search_path = '' as $$
  select 't09c:' || token_value::text || ':' || worker_value || ':' || case_value::text;
$$;

create function t09_concurrency_test.wait_for_peer(
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
create function t09_concurrency_test.wait_for_b_result(case_value integer, stop_at timestamptz)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  loop
    if clock_timestamp() >= stop_at then
      raise exception 'B did not finish its case before timeout. Clean up before retrying.';
    end if;
    if exists (select 1 from t09_concurrency_test.observations o
      where o.case_no = case_value and o.worker = 'b' and o.b_after is not null) then return; end if;
    perform pg_sleep(0.1);
  end loop;
end;
$$;

create function t09_concurrency_test.camp_update_sql(camp_value uuid, start_value date, end_value date, deadline_value timestamptz default null)
returns text language sql security invoker set search_path = '' as $$
  select format('select * from public.update_staff_camp(%L::uuid,%L,%L::date,%L::date,%L::timestamptz,%L::timestamptz,%L)',
    c.id, c.name, start_value, end_value, coalesce(deadline_value, c.application_deadline), c.updated_at, 'T09 fictional reschedule')
  from public.camps c where c.id = camp_value;
$$;
create function t09_concurrency_test.camp_delete_sql(camp_value uuid)
returns text language sql security invoker set search_path = '' as $$
  select format('select * from public.delete_staff_camp(%L::uuid,%L::timestamptz,%L)', c.id, c.updated_at, 'T09 fictional deletion')
  from public.camps c where c.id = camp_value;
$$;

create function t09_concurrency_test.expect_success(result_value jsonb)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  perform t09_concurrency_test.check_true(
    result_value ->> 'ok' = 'true' and jsonb_array_length(result_value -> 'rows') = 1,
    'RPC must succeed with one result: ' || coalesce(result_value::text, 'NULL')
  );
end;
$$;

insert into t09_concurrency_test.run (id, base_date)
select 1, greatest(
  (clock_timestamp() at time zone 'Asia/Tokyo')::date + 30,
  (select max(end_date) + 30 from public.camps),
  (select max(end_date) + 30 from public.blocked_periods),
  (select max(end_date) + 30 from public.applications),
  (select max(end_date) + 30 from public.room_allocations)
);

do $$
declare
  context t09_concurrency_test.run%rowtype; case_number integer; camp_value uuid;
  app_a_value uuid; app_b_value uuid; actor_a_value uuid; actor_b_value uuid;
  base_value date; query_a text; query_b text; block_query text; camp_query text;
  block_value uuid; version_value timestamptz; name_value text; marker text;
  state_value text; message_value text;
begin
  update t09_concurrency_test.run set staff_a = t09_concurrency_test.fixture_user(true),
    staff_b = t09_concurrency_test.fixture_user(true) where id = 1 returning * into context;
  perform t09_concurrency_test.check_true(isfinite(context.base_date), 'finite fixture base date');
  for case_number in 1..13 loop
    base_value := context.base_date + case_number * 100;
    marker := 'T09 concurrency ' || context.token::text || ' case ' || case_number::text;
    insert into public.camps(name,start_date,end_date,application_deadline,created_by)
    values(marker,base_value,base_value+2,(base_value::timestamp at time zone 'Asia/Tokyo') - interval '1 day',context.staff_a)
    returning id into camp_value;
    insert into t09_concurrency_test.fixtures values('camp',camp_value);
    app_a_value := t09_concurrency_test.fixture_application(camp_value,'draft');
    app_b_value := t09_concurrency_test.fixture_application(camp_value,'draft');
    actor_a_value := context.staff_a; actor_b_value := context.staff_b;
    state_value := 'P0001'; message_value := 'date-conflict';
    block_query := format('select * from public.save_staff_blocked_period(null,%L::date,%L::date,%L)',
      base_value+5,base_value+7,marker || ' maintenance');
    camp_query := format('select public.create_staff_camp(%L,%L::date,%L::date,%L::timestamptz)',
      marker || ' new camp',base_value+5,base_value+7,(base_value::timestamp at time zone 'Asia/Tokyo') - interval '1 day');
    if case_number = 1 then
      name_value := 'two blocked periods cannot reserve the same days'; query_a := block_query; query_b := block_query;
    elsif case_number in (2,11) then
      name_value := 'camp creation versus blocked period'; query_a := camp_query; query_b := block_query;
      if case_number = 11 then name_value := 'repeatable read rejects stale calendar snapshot'; state_value := '40001'; message_value := null; end if;
    elsif case_number = 3 then
      name_value := 'blocked period creation versus camp'; query_a := block_query; query_b := camp_query;
    elsif case_number = 4 then
      name_value := 'two edits cannot overwrite the same blocked period';
      insert into public.blocked_periods(start_date,end_date,internal_reason,created_by)
      values(base_value+5,base_value+7,marker || ' maintenance',context.staff_a) returning id,updated_at into block_value,version_value;
      insert into t09_concurrency_test.fixtures values('blocked',block_value);
      query_a := format('select * from public.save_staff_blocked_period(%L::uuid,%L::date,%L::date,%L,%L::timestamptz,%L)',
        block_value,base_value+5,base_value+8,marker || ' changed',version_value,'T09 change');
      query_b := format('select * from public.save_staff_blocked_period(%L::uuid,%L::date,%L::date,%L,%L::timestamptz,%L)',
        block_value,base_value+5,base_value+9,marker || ' changed again',version_value,'T09 change');
      message_value := 'stale-update';
    elsif case_number = 5 then
      name_value := 'camp edit invalidates stale deletion';
      query_a := t09_concurrency_test.camp_update_sql(camp_value,base_value+1,base_value+3);
      query_b := t09_concurrency_test.camp_delete_sql(camp_value); message_value := 'stale-update';
    elsif case_number = 6 then
      name_value := 'rescheduled camp claims its new period before competing block';
      query_a := t09_concurrency_test.camp_update_sql(camp_value,base_value+5,base_value+7); query_b := block_query;
    elsif case_number = 7 then
      name_value := 'submission protects camp from concurrent deletion';
      select user_id into actor_a_value from public.applications where id = app_a_value;
      query_a := format('select * from public.submit_camp_application(%L::uuid)',app_a_value);
      query_b := t09_concurrency_test.camp_delete_sql(camp_value); message_value := 'camp-has-applications';
    elsif case_number = 8 then
      name_value := 'camp deletion prevents waiting submission';
      query_a := t09_concurrency_test.camp_delete_sql(camp_value);
      select user_id into actor_b_value from public.applications where id = app_b_value;
      query_b := format('select * from public.submit_camp_application(%L::uuid)',app_b_value);
      message_value := '対象のキャンプが見つかりません。';
    elsif case_number in (9,13) then
      name_value := case when case_number = 9 then 'draft reuse after reschedule sees current dates' else 'new draft after reschedule sees current dates' end;
      query_a := t09_concurrency_test.camp_update_sql(camp_value,base_value+1,base_value+3);
      if case_number = 13 then
        actor_b_value := t09_concurrency_test.fixture_user(false);
        insert into public.camp_eligible_users(camp_id,email_normalized)
        select camp_value,email from auth.users where id = actor_b_value;
      else select user_id into actor_b_value from public.applications where id = app_b_value; end if;
      query_b := format('select public.create_camp_application_draft(%L::uuid)',camp_value);
      state_value := null; message_value := null;
    elsif case_number = 10 then
      name_value := 'submission rechecks changed deadline after waiting';
      query_a := t09_concurrency_test.camp_update_sql(camp_value,base_value,base_value+2,clock_timestamp()-interval '1 second');
      select user_id into actor_b_value from public.applications where id = app_b_value;
      query_b := format('select * from public.submit_camp_application(%L::uuid)',app_b_value);
      message_value := 'このキャンプの申請期限を過ぎています。';
    else
      name_value := 'staff disabled during calendar lock wait is rejected'; query_a := null; query_b := block_query;
      state_value := '42501'; message_value := 'staff-required';
    end if;
    insert into t09_concurrency_test.cases(case_no,test_name,camp_id,app_a,app_b,actor_a,actor_b,a_query,b_query,expected_state,expected_message)
    values(case_number,name_value,camp_value,app_a_value,app_b_value,actor_a_value,actor_b_value,query_a,query_b,state_value,message_value);
  end loop;
end;
$$;

-- A procedure with transaction control cannot be DEFINER or have a SET clause.
-- All object/function names below are qualified; COMMIT is outside exception
-- blocks. Integer loops avoid cursors being materialized across commits.
create procedure t09_concurrency_test.worker_a()
language plpgsql security invoker as $$
declare
  context t09_concurrency_test.run%rowtype;
  test_case t09_concurrency_test.cases%rowtype;
  case_number integer;
  stop_at timestamptz := pg_catalog.clock_timestamp() + interval '50 seconds';
  started_at_value timestamptz;
  observed_at_value timestamptz;
  peer_pid_value integer;
  result_value jsonb;
begin
  perform t09_concurrency_test.check_true(current_user = 'postgres', 'postgres worker required');
  update t09_concurrency_test.run set a_pid = pg_catalog.pg_backend_pid(),
    a_backend_start = (select backend_start from pg_catalog.pg_stat_activity where pid = pg_catalog.pg_backend_pid())
  where id = 1 and a_pid is null returning * into context;
  perform t09_concurrency_test.check_true(found, 'A already attempted: clean up before retrying');
  commit;
  for case_number in 1..13 loop
    -- Loop expressions can acquire a snapshot. SET must directly follow COMMIT.
    commit;
    set transaction isolation level read committed;
    perform pg_catalog.set_config('lock_timeout', '3s', true);
    select * into strict test_case from t09_concurrency_test.cases where case_no = case_number;

    started_at_value := pg_catalog.clock_timestamp();
    if case_number = 12 then
      update public.facility_guard set id = id where id = 1;
      perform t09_concurrency_test.check_true(found, 'facility guard exists');
      if case_number = 12 then
        update public.profiles set account_state = 'disabled' where id = context.staff_b;
      end if;
      result_value := '{"ok":true,"test_guard":true}'::jsonb;
    else
      result_value := t09_concurrency_test.call_as(test_case.actor_a, test_case.a_query);
      perform t09_concurrency_test.expect_success(result_value);
    end if;

    -- Advertise only AFTER A holds the facility lock and has performed its RPC.
    perform pg_catalog.set_config('application_name', t09_concurrency_test.peer_tag(context.token, 'a', case_number), true);
    peer_pid_value := t09_concurrency_test.wait_for_peer(
      t09_concurrency_test.peer_tag(context.token, 'b', case_number), stop_at, true);
    observed_at_value := pg_catalog.clock_timestamp();
    insert into t09_concurrency_test.observations (
      case_no, worker, backend_pid, peer_pid, started_at, observed_at, isolation_level, rpc_result, a_after, b_after
    ) values (case_number, 'a', pg_catalog.pg_backend_pid(), peer_pid_value,
      started_at_value, observed_at_value, pg_catalog.current_setting('transaction_isolation'), result_value,
      t09_concurrency_test.snapshot(test_case.app_a), t09_concurrency_test.snapshot(test_case.app_b));
    commit;
    set transaction isolation level read committed;
    perform t09_concurrency_test.wait_for_b_result(case_number, stop_at);
    commit;
  end loop;
  update t09_concurrency_test.run set a_finished_at = pg_catalog.clock_timestamp() where id = 1;
  commit;
end;
$$;

create procedure t09_concurrency_test.worker_b()
language plpgsql security invoker as $$
declare
  context t09_concurrency_test.run%rowtype;
  test_case t09_concurrency_test.cases%rowtype;
  case_number integer;
  stop_at timestamptz := pg_catalog.clock_timestamp() + interval '50 seconds';
  started_at_value timestamptz;
  peer_pid_value integer;
  result_value jsonb;
begin
  perform t09_concurrency_test.check_true(current_user = 'postgres', 'postgres worker required');
  update t09_concurrency_test.run set b_pid = pg_catalog.pg_backend_pid(),
    b_backend_start = (select backend_start from pg_catalog.pg_stat_activity where pid = pg_catalog.pg_backend_pid())
  where id = 1 and b_pid is null returning * into context;
  perform t09_concurrency_test.check_true(found, 'B already attempted: clean up before retrying');
  commit;
  for case_number in 1..13 loop
    -- Evaluating IF can acquire a snapshot even without a table SELECT.
    -- Choose the branch first, then COMMIT immediately before the static SET.
    -- Do not move COMMIT above IF or insert an expression between COMMIT/SET.
    if case_number = 11 then
      commit;
      set transaction isolation level repeatable read;
    else
      commit;
      set transaction isolation level read committed;
    end if;
    perform t09_concurrency_test.check_true(
      pg_catalog.current_setting('transaction_isolation') =
        case when case_number = 11 then 'repeatable read' else 'read committed' end,
      'B transaction isolation for case ' || case_number::text);
    perform pg_catalog.set_config('lock_timeout', '45s', true);
    perform pg_catalog.set_config('application_name', t09_concurrency_test.peer_tag(context.token, 'b', case_number), true);
    peer_pid_value := t09_concurrency_test.wait_for_peer(
      t09_concurrency_test.peer_tag(context.token, 'a', case_number), stop_at, false);
    select * into strict test_case from t09_concurrency_test.cases where case_no = case_number;
    started_at_value := pg_catalog.clock_timestamp();
    result_value := t09_concurrency_test.call_as(test_case.actor_b, test_case.b_query);
    if test_case.expected_state is null then
      perform t09_concurrency_test.expect_success(result_value);
    else
      perform t09_concurrency_test.check_true(result_value ->> 'ok' = 'false'
        and result_value ->> 'sqlstate' = test_case.expected_state
        and (test_case.expected_message is null or result_value ->> 'message' = test_case.expected_message),
        'unexpected B result in case ' || case_number::text || ': ' || result_value::text);
    end if;
    -- Do not update A's row or inspect its committed data in REPEATABLE READ.
    -- Final state verification happens in a fresh transaction after both CALLs.
    insert into t09_concurrency_test.observations (
      case_no, worker, backend_pid, peer_pid, started_at, observed_at, isolation_level, rpc_result
    ) values (case_number, 'b', pg_catalog.pg_backend_pid(), peer_pid_value,
      started_at_value, pg_catalog.clock_timestamp(), pg_catalog.current_setting('transaction_isolation'), result_value);
    commit;
    set transaction isolation level read committed;
    update t09_concurrency_test.observations set b_after = t09_concurrency_test.snapshot(null)
    where case_no = case_number and worker = 'b';
    commit;
  end loop;
  update t09_concurrency_test.run set b_finished_at = pg_catalog.clock_timestamp() where id = 1;
  commit;
end;
$$;

create function t09_concurrency_test.verify()
returns table (case_no integer,test_name text,passed boolean,backend_a integer,backend_b integer,rejected_sqlstate text)
language plpgsql security invoker set search_path = '' as $$
declare ctx t09_concurrency_test.run%rowtype; tc t09_concurrency_test.cases%rowtype;
  oa t09_concurrency_test.observations%rowtype; ob t09_concurrency_test.observations%rowtype; n integer; draft_value uuid;
begin
  perform t09_concurrency_test.check_true(current_user = 'postgres','postgres verifier required');
  perform g.id from public.facility_guard g where g.id = 1 for update;
  select * into strict ctx from t09_concurrency_test.run where id = 1;
  perform t09_concurrency_test.check_true(ctx.a_finished_at is not null and ctx.b_finished_at is not null
    and ctx.a_pid <> ctx.b_pid,'two workers finished on distinct connections');
  perform t09_concurrency_test.check_true((select count(*) = 26 from t09_concurrency_test.observations),'all 13 pairs recorded');
  for n in 1..13 loop
    select * into strict tc from t09_concurrency_test.cases c where c.case_no=n;
    select * into strict oa from t09_concurrency_test.observations o where o.case_no=n and o.worker='a';
    select * into strict ob from t09_concurrency_test.observations o where o.case_no=n and o.worker='b';
    perform t09_concurrency_test.check_true(oa.backend_pid=ctx.a_pid and ob.backend_pid=ctx.b_pid
      and oa.peer_pid=ob.backend_pid and ob.peer_pid=oa.backend_pid
      and ob.started_at<=oa.observed_at and oa.observed_at<=ob.observed_at,'proven overlapping worker IDs/times');
    perform t09_concurrency_test.check_true(oa.isolation_level='read committed' and ob.isolation_level=
      case when n=11 then 'repeatable read' else 'read committed' end,'recorded isolation levels');
    perform t09_concurrency_test.check_true(oa.rpc_result->>'ok'='true','A succeeded');
    if tc.expected_state is not null then
      perform t09_concurrency_test.check_true(ob.rpc_result->>'ok'='false' and ob.rpc_result->>'sqlstate'=tc.expected_state
        and (tc.expected_message is null or ob.rpc_result->>'message'=tc.expected_message),'B expected rejection');
      perform t09_concurrency_test.check_true(oa.a_after=ob.b_after,'failed B left source/claim/application/fee/audit unchanged');
    else
      perform t09_concurrency_test.check_true(ob.rpc_result->>'ok'='true','B draft entry succeeded');
      draft_value := (ob.rpc_result #>> '{rows,0,create_camp_application_draft}')::uuid;
      perform t09_concurrency_test.check_true(exists(select 1 from public.applications a join public.camps c on c.id=a.camp_id
        where a.id=draft_value and a.user_id=tc.actor_b and a.status='draft'
          and a.start_date=c.start_date and a.end_date=c.end_date),'draft has current committed camp dates');
      perform t09_concurrency_test.check_true(not exists(select 1 from public.reception_numbers where application_id=draft_value)
        and not exists(select 1 from public.application_charges where application_id=draft_value),'draft did not create number/fee');
    end if;
    return query select tc.case_no,tc.test_name,true,oa.backend_pid,ob.backend_pid,ob.rpc_result->>'sqlstate';
  end loop;
  perform t09_concurrency_test.check_true(not exists(select 1 from public.calendar_claims q join public.camps c on c.id=q.camp_id
    where c.created_by=ctx.staff_a and (q.start_date<>c.start_date or q.end_date<>c.end_date
      or q.released_from is distinct from case when c.deleted_at is not null then c.start_date end)),'camp/claim synchronization');
  update t09_concurrency_test.run set verified_at=clock_timestamp() where id=1;
end;
$$;

-- Available after failed runs too. Stop both workers first. Source UUIDs, actor
-- UUIDs and run markers must all agree before any cleanup deletion is allowed.
create function t09_concurrency_test.cleanup()
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare ctx t09_concurrency_test.run%rowtype; user_ids uuid[]; camp_ids uuid[]; block_ids uuid[]; app_ids uuid[];
begin
  perform t09_concurrency_test.check_true(current_user='postgres','postgres cleanup required');
  perform set_config('lock_timeout','3s',true);
  perform g.id from public.facility_guard g where g.id=1 for update;
  select * into strict ctx from t09_concurrency_test.run where id=1 for update;
  perform pg_stat_clear_snapshot();
  perform t09_concurrency_test.check_true(not exists(select 1 from pg_stat_activity a where a.pid<>pg_backend_pid()
    and a.state is distinct from 'idle' and ((a.pid=ctx.a_pid and a.backend_start=ctx.a_backend_start)
      or (a.pid=ctx.b_pid and a.backend_start=ctx.b_backend_start))),'stop/wait for both workers');
  select coalesce(array_agg(id),'{}'::uuid[]) into user_ids from t09_concurrency_test.fixtures where kind='user';
  perform t09_concurrency_test.check_true((select count(*)=cardinality(user_ids) from auth.users u where u.id=any(user_ids)
    and u.email='t09-concurrency-'||u.id::text||'@example.invalid' and u.raw_user_meta_data->>'t09_concurrency_run'=ctx.token::text
    and coalesce(u.encrypted_password,'')='' and u.last_sign_in_at is null),'marked unused users');
  select coalesce(array_agg(id),'{}'::uuid[]) into camp_ids from public.camps
  where created_by=any(user_ids) and name like 'T09 concurrency '||ctx.token::text||' case %';
  select coalesce(array_agg(id),'{}'::uuid[]) into block_ids from public.blocked_periods
  where created_by=any(user_ids) and internal_reason like 'T09 concurrency '||ctx.token::text||' case %';
  select coalesce(array_agg(id),'{}'::uuid[]) into app_ids from public.applications where camp_id=any(camp_ids) and user_id=any(user_ids);
  perform t09_concurrency_test.check_true(not exists(select 1 from public.camps where created_by=any(user_ids) and not(id=any(camp_ids)))
    and not exists(select 1 from public.blocked_periods where created_by=any(user_ids) and not(id=any(block_ids)))
    and not exists(select 1 from public.applications where (camp_id=any(camp_ids) or user_id=any(user_ids) or original_application_id=any(app_ids))
      and not(id=any(app_ids)))
    and not exists(select 1 from public.consent_documents where application_id=any(app_ids))
    and not exists(select 1 from public.audit_logs where actor_user_id=any(user_ids)
      and not((entity_type='application' and entity_id=any(app_ids)) or (entity_type='camp' and entity_id=any(camp_ids))
        or (entity_type='blocked' and entity_id=any(block_ids))))
    and not exists(select 1 from public.application_status_events where actor_user_id=any(user_ids) and not(application_id=any(app_ids)))
    and not exists(select 1 from public.camp_eligible_users e where e.camp_id=any(camp_ids)
      and not exists(select 1 from auth.users u where u.id=any(user_ids) and u.email=e.email_normalized)),
    'no unexpected references, attachments, or records');
  delete from public.audit_logs where actor_user_id=any(user_ids);
  delete from public.applications where id=any(app_ids);
  delete from public.calendar_claims where camp_id=any(camp_ids) or blocked_period_id=any(block_ids);
  delete from public.camps where id=any(camp_ids);
  delete from public.blocked_periods where id=any(block_ids);
  delete from auth.users where id=any(user_ids);
  perform t09_concurrency_test.check_true(not exists(select 1 from public.camps where id=any(camp_ids))
    and not exists(select 1 from public.blocked_periods where id=any(block_ids))
    and not exists(select 1 from public.calendar_claims where camp_id=any(camp_ids) or blocked_period_id=any(block_ids))
    and not exists(select 1 from public.applications where id=any(app_ids))
    and not exists(select 1 from auth.users where id=any(user_ids)),'fixture cleanup complete');
  return jsonb_build_object('removed_users',cardinality(user_ids),'removed_camps',cardinality(camp_ids),
    'removed_blocks',cardinality(block_ids),'removed_applications',cardinality(app_ids),'receipt_counters','preserved');
end;
$$;

revoke all on all functions in schema t09_concurrency_test from public,anon,authenticated,service_role;
revoke all on all procedures in schema t09_concurrency_test from public,anon,authenticated,service_role;
commit;
select token as run_token,'Prepared only; run both workers, verify, then clean up.' as status,
  'call t09_concurrency_test.worker_a();' as connection_a,
  'call t09_concurrency_test.worker_b();' as connection_b,
  'select * from t09_concurrency_test.verify();' as verification_sql,
  'begin; select t09_concurrency_test.cleanup(); drop schema t09_concurrency_test cascade; commit;' as cleanup_sql
from t09_concurrency_test.run where id=1;
