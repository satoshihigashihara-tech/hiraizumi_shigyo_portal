-- SQL 009 / 010 / 011 concurrency checks. TEST PROJECT WITHOUT USER TRAFFIC ONLY.
-- Run this whole file ONCE as postgres to prepare fictional, COMMITTED fixtures.
-- It does not run the workers. Then prepare two separate SQL Editor tabs:
--   A: call t12_concurrency_test.worker_a();
--   B: call t12_concurrency_test.worker_b();
-- Run A, then immediately run B while A is still running (within 30 seconds).
-- Each CALL must be the only command in its query: do not wrap it in BEGIN.
-- Workers commit between cases and finish within their 50-second time budget.
-- A records pg_blocking_pids evidence before committing; a missed overlap fails.
-- If the editor serializes queries or wraps CALL in a transaction, these tests
-- cannot run there. Do not count that environment failure as a concurrency pass.
-- After BOTH workers finish, run: select * from t12_concurrency_test.verify();
-- Save the result, then run the cleanup query printed by the setup result.
-- On failure, run ROLLBACK in the failed connection, stop/wait for both workers,
-- and use cleanup before retrying this entire file. Never rerun one worker alone.
--
-- All helpers are SECURITY INVOKER, restricted to postgres, in a private test
-- schema. RLS is enabled on its tables. Actual RPCs run as authenticated with
-- fictional claims. No Auth/Storage API, email, password or extension is used.
-- Fixtures survive a failed worker and require explicit cleanup. Cleanup checks
-- their UUIDs and marker, refuses unexpected references, then removes only them.
-- Receipt counters are NOT reset; numbers consumed by tests become unused gaps.
-- Business functions, RLS policies, room masters and existing records are not
-- replaced or deleted. This file is a test harness, NOT a production migration.
-- References: https://www.postgresql.org/docs/current/plpgsql-transactions.html
-- https://www.postgresql.org/docs/current/sql-set-transaction.html
-- https://www.postgresql.org/docs/current/functions-info.html
-- https://www.postgresql.org/docs/current/monitoring-stats.html

begin;
set local lock_timeout = '3s';
set local statement_timeout = '60s';
set local timezone = 'UTC';

do $$
begin
  if current_user <> 'postgres' then raise exception 'Run as postgres.'; end if;
  if to_regnamespace('t12_concurrency_test') is not null then
    raise exception 'A test run already exists. Verify/clean it up before retrying.';
  end if;
  if to_regprocedure('public.assign_camp_application_room(uuid,uuid,timestamptz,text)') is null
    or to_regprocedure('public.review_camp_application(uuid,text,timestamptz,text)') is null then
    raise exception 'Apply migrations 001 through 011 first.';
  end if;
end;
$$;

create schema t12_concurrency_test;
revoke all on schema t12_concurrency_test from public, anon, authenticated, service_role;

create table t12_concurrency_test.run (
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
create table t12_concurrency_test.fixtures (
  kind text not null check (kind in ('user', 'camp', 'application')),
  id uuid not null,
  primary key (kind, id)
);
create table t12_concurrency_test.cases (
  case_no integer primary key check (case_no between 1 and 7),
  test_name text not null,
  camp_id uuid not null,
  app_a uuid not null,
  app_b uuid not null,
  actor_a uuid not null,
  actor_b uuid not null,
  a_query text,
  b_query text not null,
  expected_state text not null,
  expected_message text,
  deadline timestamptz
);
create table t12_concurrency_test.observations (
  case_no integer not null references t12_concurrency_test.cases(case_no),
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
alter table t12_concurrency_test.run enable row level security;
alter table t12_concurrency_test.fixtures enable row level security;
alter table t12_concurrency_test.cases enable row level security;
alter table t12_concurrency_test.observations enable row level security;
revoke all on all tables in schema t12_concurrency_test
from public, anon, authenticated, service_role;

create function t12_concurrency_test.check_true(condition boolean, label text)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if current_user <> 'postgres' then raise exception 'Run as postgres.'; end if;
  if condition is distinct from true then raise exception 'FAIL: %', label; end if;
end;
$$;

create function t12_concurrency_test.fixture_user(is_staff boolean default false)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  new_id uuid := gen_random_uuid();
  run_token uuid := (select token from t12_concurrency_test.run where id = 1);
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  ) values (
    new_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    't12-concurrency-' || new_id::text || '@example.invalid', '', clock_timestamp(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('t12_concurrency_run', run_token), clock_timestamp(), clock_timestamp()
  );
  insert into t12_concurrency_test.fixtures values ('user', new_id);
  if is_staff then insert into public.staff_roles (user_id) values (new_id); end if;
  return new_id;
end;
$$;

create function t12_concurrency_test.fixture_application(camp_value uuid, status_value text)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  new_id uuid;
  owner_id uuid := t12_concurrency_test.fixture_user();
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
  insert into t12_concurrency_test.fixtures values ('application', new_id);
  return new_id;
end;
$$;

-- Role changes must happen in an INVOKER helper, not a definer function.
-- Errors roll back the RPC's subtransaction; the worker records their exact code.
create function t12_concurrency_test.call_as(actor_id uuid, query_text text)
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
  perform t12_concurrency_test.check_true(current_user = 'postgres', 'postgres test caller required');
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

create function t12_concurrency_test.snapshot(app_value uuid)
returns jsonb language sql security invoker set search_path = '' as $$
  select jsonb_build_object(
    'application', (select to_jsonb(a) from public.applications a where a.id = app_value),
    'room', (select to_jsonb(r) from public.room_allocations r where r.application_id = app_value),
    'stay', (select to_jsonb(s) from public.stays s where s.application_id = app_value),
    'events', (select jsonb_agg(to_jsonb(e) order by e.id) from public.application_status_events e where e.application_id = app_value),
    'audit', (select jsonb_agg(to_jsonb(l) order by l.id) from public.audit_logs l where l.entity_type = 'application' and l.entity_id = app_value),
    'charge', (select to_jsonb(c) from public.application_charges c where c.application_id = app_value),
    'months', (select jsonb_agg(to_jsonb(m) order by m.id) from public.charge_months m join public.application_charges c on c.id = m.charge_id where c.application_id = app_value),
    'number', (select to_jsonb(n) from public.reception_numbers n where n.application_id = app_value)
  );
$$;

create function t12_concurrency_test.peer_tag(token_value uuid, worker_value text, case_value integer)
returns text language sql immutable security invoker set search_path = '' as $$
  select 't12c:' || token_value::text || ':' || worker_value || ':' || case_value::text;
$$;

create function t12_concurrency_test.wait_for_peer(
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
create function t12_concurrency_test.wait_for_b_result(case_value integer, stop_at timestamptz)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  loop
    if clock_timestamp() >= stop_at then
      raise exception 'B did not finish its case before timeout. Clean up before retrying.';
    end if;
    if exists (select 1 from t12_concurrency_test.observations o
      where o.case_no = case_value and o.worker = 'b') then return; end if;
    perform pg_sleep(0.1);
  end loop;
end;
$$;

create function t12_concurrency_test.assign_sql(app_value uuid, room_value uuid, reason_value text default null)
returns text language sql security invoker set search_path = '' as $$
  select format('select * from public.assign_camp_application_room(%L::uuid,%L::uuid,%L::timestamptz,%L::text)',
    app_value, room_value, a.updated_at, reason_value)
  from public.applications a where a.id = app_value;
$$;

create function t12_concurrency_test.review_sql(app_value uuid, action_value text, reason_value text default null)
returns text language sql security invoker set search_path = '' as $$
  select format('select * from public.review_camp_application(%L::uuid,%L::text,%L::timestamptz,%L::text)',
    app_value, action_value, a.updated_at, reason_value)
  from public.applications a where a.id = app_value;
$$;

create function t12_concurrency_test.expect_success(result_value jsonb)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  perform t12_concurrency_test.check_true(
    result_value ->> 'ok' = 'true' and jsonb_array_length(result_value -> 'rows') = 1,
    'RPC must succeed with one result: ' || coalesce(result_value::text, 'NULL')
  );
end;
$$;

insert into t12_concurrency_test.run (id, base_date)
select 1, greatest(
  (clock_timestamp() at time zone 'Asia/Tokyo')::date + 30,
  (select max(end_date) + 30 from public.camps),
  (select max(end_date) + 30 from public.applications),
  (select max(end_date) + 30 from public.room_allocations)
);

do $$
declare
  context t12_concurrency_test.run%rowtype;
  case_number integer;
  camp_value uuid;
  app_a_value uuid;
  app_b_value uuid;
  actor_a_value uuid;
  actor_b_value uuid;
  room_kiri uuid := (select id from public.rooms where name = '桐' and capacity = 1);
  room_fuji uuid := (select id from public.rooms where name = '藤' and capacity = 1);
  query_a text;
  query_b text;
  state_value text;
  message_value text;
  name_value text;
begin
  perform guard.id from public.facility_guard guard where guard.id = 1 for update;
  perform t12_concurrency_test.check_true(found, 'facility guard exists');
  select * into strict context from t12_concurrency_test.run where id = 1;
  perform t12_concurrency_test.check_true(isfinite(context.base_date), 'finite fixture dates');
  perform t12_concurrency_test.check_true(room_kiri is not null and room_fuji is not null, 'expected one-person room masters');
  update t12_concurrency_test.run set staff_a = t12_concurrency_test.fixture_user(true),
    staff_b = t12_concurrency_test.fixture_user(true) where id = 1 returning * into context;

  for case_number in 1..7 loop
    insert into public.camps (name, start_date, end_date, application_deadline, created_by)
    values ('T12 concurrency ' || context.token::text || ' case ' || case_number::text,
      context.base_date + case_number * 10, context.base_date + case_number * 10 + 1,
      clock_timestamp() + interval '1 day', context.staff_a) returning id into camp_value;
    insert into t12_concurrency_test.fixtures values ('camp', camp_value);
    app_a_value := t12_concurrency_test.fixture_application(camp_value,
      case when case_number in (4, 6) then 'draft' else 'under_review' end);
    app_b_value := case when case_number in (1, 4)
      then t12_concurrency_test.fixture_application(camp_value,
        case when case_number = 4 then 'draft' else 'under_review' end)
      else app_a_value end;
    actor_a_value := context.staff_a;
    actor_b_value := context.staff_b;
    query_a := null;
    state_value := 'P0001';

    if case_number in (2, 3, 5) then
      perform t12_concurrency_test.expect_success(t12_concurrency_test.call_as(
        context.staff_a, t12_concurrency_test.assign_sql(app_a_value, room_kiri)));
    end if;

    if case_number = 1 then
      name_value := 'last room place: one assignment succeeds';
      query_a := t12_concurrency_test.assign_sql(app_a_value, room_kiri);
      query_b := t12_concurrency_test.assign_sql(app_b_value, room_kiri);
      message_value := 'room-capacity-full';
    elsif case_number in (2, 5) then
      name_value := case when case_number = 2 then 'room change invalidates pending approval'
        else 'repeatable-read snapshot rejects competing change' end;
      query_a := t12_concurrency_test.assign_sql(app_a_value, room_fuji, '架空の同時変更理由');
      query_b := t12_concurrency_test.review_sql(app_b_value, 'approve');
      state_value := case when case_number = 5 then '40001' else 'P0001' end;
      message_value := case when case_number = 5 then null else 'stale-update' end;
    elsif case_number = 3 then
      name_value := 'simultaneous approvals create one stay and one approval event';
      query_a := t12_concurrency_test.review_sql(app_a_value, 'approve');
      query_b := t12_concurrency_test.review_sql(app_b_value, 'approve');
      message_value := 'stale-update';
    elsif case_number = 4 then
      name_value := 'last facility place: 14 plus two simultaneous submissions';
      -- These 14 rows are capacity fixtures, not simulated successful submissions.
      for occupant in 1..14 loop
        perform t12_concurrency_test.fixture_application(camp_value, 'submitted');
      end loop;
      select user_id into actor_a_value from public.applications where id = app_a_value;
      select user_id into actor_b_value from public.applications where id = app_b_value;
      query_a := format('select * from public.submit_camp_application(%L::uuid)', app_a_value);
      query_b := format('select * from public.submit_camp_application(%L::uuid)', app_b_value);
      message_value := '施設の定員15人に達しています。';
    elsif case_number = 6 then
      name_value := 'revision starts before its deadline but expires while blocked';
      select user_id into actor_b_value from public.applications where id = app_b_value;
      query_b := format('select * from public.submit_camp_application(%L::uuid)', app_b_value);
      perform t12_concurrency_test.expect_success(t12_concurrency_test.call_as(actor_b_value, query_b));
      perform t12_concurrency_test.expect_success(t12_concurrency_test.call_as(
        context.staff_a, t12_concurrency_test.review_sql(app_a_value, 'start_review')));
      perform t12_concurrency_test.expect_success(t12_concurrency_test.call_as(
        context.staff_a, t12_concurrency_test.assign_sql(app_a_value, room_kiri)));
      perform t12_concurrency_test.expect_success(t12_concurrency_test.call_as(
        context.staff_a, t12_concurrency_test.review_sql(app_a_value, 'request_revision', '架空の修正依頼')));
      update public.camps set application_deadline = transaction_timestamp() - interval '1 second'
      where id = camp_value;
      message_value := '修正期限を過ぎています。';
    else
      name_value := 'staff disabled while waiting cannot assign a room';
      query_b := t12_concurrency_test.assign_sql(app_b_value, room_kiri);
      state_value := '42501';
      message_value := 'staff-required';
    end if;
    insert into t12_concurrency_test.cases (
      case_no, test_name, camp_id, app_a, app_b, actor_a, actor_b,
      a_query, b_query, expected_state, expected_message
    ) values (case_number, name_value, camp_value, app_a_value, app_b_value,
      actor_a_value, actor_b_value, query_a, query_b, state_value, message_value);
  end loop;
end;
$$;

-- A procedure with transaction control cannot be DEFINER or have a SET clause.
-- All object/function names below are qualified; COMMIT is outside exception
-- blocks. Integer loops avoid cursors being materialized across commits.
create procedure t12_concurrency_test.worker_a()
language plpgsql security invoker as $$
declare
  context t12_concurrency_test.run%rowtype;
  test_case t12_concurrency_test.cases%rowtype;
  case_number integer;
  stop_at timestamptz := pg_catalog.clock_timestamp() + interval '50 seconds';
  started_at_value timestamptz;
  observed_at_value timestamptz;
  peer_pid_value integer;
  result_value jsonb;
begin
  perform t12_concurrency_test.check_true(current_user = 'postgres', 'postgres worker required');
  update t12_concurrency_test.run set a_pid = pg_catalog.pg_backend_pid(),
    a_backend_start = (select backend_start from pg_catalog.pg_stat_activity where pid = pg_catalog.pg_backend_pid())
  where id = 1 and a_pid is null returning * into context;
  perform t12_concurrency_test.check_true(found, 'A already attempted: clean up before retrying');
  commit;
  for case_number in 1..7 loop
    -- Loop expressions can acquire a snapshot. SET must directly follow COMMIT.
    commit;
    set transaction isolation level read committed;
    perform pg_catalog.set_config('lock_timeout', '3s', true);
    select * into strict test_case from t12_concurrency_test.cases where case_no = case_number;

    if case_number = 6 then
      -- Publish the deadline before acquiring the lock B must wait on.
      perform guard.id from public.facility_guard guard where guard.id = 1 for update;
      update public.applications set revision_due_at = pg_catalog.clock_timestamp() + interval '5 seconds'
      where id = test_case.app_a returning revision_due_at into test_case.deadline;
      update t12_concurrency_test.cases set deadline = test_case.deadline where case_no = case_number;
      commit;
      set transaction isolation level read committed;
      perform pg_catalog.set_config('lock_timeout', '3s', true);
    end if;

    started_at_value := pg_catalog.clock_timestamp();
    if case_number in (6, 7) then
      update public.facility_guard set id = id where id = 1;
      perform t12_concurrency_test.check_true(found, 'facility guard exists');
      if case_number = 7 then
        update public.profiles set account_state = 'disabled' where id = context.staff_b;
      end if;
      result_value := '{"ok":true,"test_guard":true}'::jsonb;
    else
      result_value := t12_concurrency_test.call_as(test_case.actor_a, test_case.a_query);
      perform t12_concurrency_test.expect_success(result_value);
    end if;

    -- Advertise only AFTER A holds the facility lock and has performed its RPC.
    perform pg_catalog.set_config('application_name', t12_concurrency_test.peer_tag(context.token, 'a', case_number), true);
    peer_pid_value := t12_concurrency_test.wait_for_peer(
      t12_concurrency_test.peer_tag(context.token, 'b', case_number), stop_at, true);
    observed_at_value := pg_catalog.clock_timestamp();
    if case_number = 6 then
      perform t12_concurrency_test.check_true(observed_at_value < test_case.deadline,
        'revision must actually be blocked before deadline');
      while pg_catalog.clock_timestamp() <= test_case.deadline loop
        perform t12_concurrency_test.check_true(pg_catalog.clock_timestamp() < stop_at, 'worker time budget exceeded');
        perform pg_catalog.pg_sleep(0.05);
      end loop;
    end if;
    insert into t12_concurrency_test.observations (
      case_no, worker, backend_pid, peer_pid, started_at, observed_at, isolation_level, rpc_result, a_after, b_after
    ) values (case_number, 'a', pg_catalog.pg_backend_pid(), peer_pid_value,
      started_at_value, observed_at_value, pg_catalog.current_setting('transaction_isolation'), result_value,
      t12_concurrency_test.snapshot(test_case.app_a), t12_concurrency_test.snapshot(test_case.app_b));
    commit;
    set transaction isolation level read committed;
    perform t12_concurrency_test.wait_for_b_result(case_number, stop_at);
    commit;
  end loop;
  update t12_concurrency_test.run set a_finished_at = pg_catalog.clock_timestamp() where id = 1;
  commit;
end;
$$;

create procedure t12_concurrency_test.worker_b()
language plpgsql security invoker as $$
declare
  context t12_concurrency_test.run%rowtype;
  test_case t12_concurrency_test.cases%rowtype;
  case_number integer;
  stop_at timestamptz := pg_catalog.clock_timestamp() + interval '50 seconds';
  started_at_value timestamptz;
  peer_pid_value integer;
  result_value jsonb;
begin
  perform t12_concurrency_test.check_true(current_user = 'postgres', 'postgres worker required');
  update t12_concurrency_test.run set b_pid = pg_catalog.pg_backend_pid(),
    b_backend_start = (select backend_start from pg_catalog.pg_stat_activity where pid = pg_catalog.pg_backend_pid())
  where id = 1 and b_pid is null returning * into context;
  perform t12_concurrency_test.check_true(found, 'B already attempted: clean up before retrying');
  commit;
  for case_number in 1..7 loop
    -- Evaluating IF can acquire a snapshot even without a table SELECT.
    -- Choose the branch first, then COMMIT immediately before the static SET.
    -- Do not move COMMIT above IF or insert an expression between COMMIT/SET.
    if case_number = 5 then
      commit;
      set transaction isolation level repeatable read;
    else
      commit;
      set transaction isolation level read committed;
    end if;
    perform t12_concurrency_test.check_true(
      pg_catalog.current_setting('transaction_isolation') =
        case when case_number = 5 then 'repeatable read' else 'read committed' end,
      'B transaction isolation for case ' || case_number::text);
    perform pg_catalog.set_config('lock_timeout', '45s', true);
    perform pg_catalog.set_config('application_name', t12_concurrency_test.peer_tag(context.token, 'b', case_number), true);
    peer_pid_value := t12_concurrency_test.wait_for_peer(
      t12_concurrency_test.peer_tag(context.token, 'a', case_number), stop_at, false);
    select * into strict test_case from t12_concurrency_test.cases where case_no = case_number;
    started_at_value := pg_catalog.clock_timestamp();
    if case_number = 6 then
      perform t12_concurrency_test.check_true(started_at_value < test_case.deadline,
        'revision RPC must start before deadline');
    end if;
    result_value := t12_concurrency_test.call_as(test_case.actor_b, test_case.b_query);
    perform t12_concurrency_test.check_true(result_value ->> 'ok' = 'false'
      and result_value ->> 'sqlstate' = test_case.expected_state
      and (test_case.expected_message is null or result_value ->> 'message' = test_case.expected_message),
      'unexpected B result in case ' || case_number::text || ': ' || result_value::text);
    -- Do not update A's row or inspect its committed data in REPEATABLE READ.
    -- Final state verification happens in a fresh transaction after both CALLs.
    insert into t12_concurrency_test.observations (
      case_no, worker, backend_pid, peer_pid, started_at, observed_at, isolation_level, rpc_result
    ) values (case_number, 'b', pg_catalog.pg_backend_pid(), peer_pid_value,
      started_at_value, pg_catalog.clock_timestamp(), pg_catalog.current_setting('transaction_isolation'), result_value);
    commit;
  end loop;
  update t12_concurrency_test.run set b_finished_at = pg_catalog.clock_timestamp() where id = 1;
  commit;
end;
$$;

create function t12_concurrency_test.verify()
returns table (case_no integer, test_name text, passed boolean, backend_a integer, backend_b integer, rejected_sqlstate text)
language plpgsql security invoker set search_path = '' as $$
declare
  context t12_concurrency_test.run%rowtype;
  test_case t12_concurrency_test.cases%rowtype;
  observation_a t12_concurrency_test.observations%rowtype;
  observation_b t12_concurrency_test.observations%rowtype;
  case_number integer;
begin
  perform t12_concurrency_test.check_true(current_user = 'postgres', 'postgres verifier required');
  perform set_config('lock_timeout', '3s', true);
  perform guard.id from public.facility_guard guard where guard.id = 1 for update;
  select * into strict context from t12_concurrency_test.run where id = 1;
  perform t12_concurrency_test.check_true(context.a_finished_at is not null
    and context.b_finished_at is not null, 'both workers must finish before verification');
  perform t12_concurrency_test.check_true(context.a_pid <> context.b_pid, 'two separate backend connections required');
  perform t12_concurrency_test.check_true((select count(*) = 14 from t12_concurrency_test.observations), 'all seven worker pairs recorded');

  for case_number in 1..7 loop
    select * into strict test_case from t12_concurrency_test.cases c where c.case_no = case_number;
    select * into strict observation_a from t12_concurrency_test.observations o where o.case_no = case_number and o.worker = 'a';
    select * into strict observation_b from t12_concurrency_test.observations o where o.case_no = case_number and o.worker = 'b';
    perform t12_concurrency_test.check_true(observation_a.isolation_level = 'read committed'
      and observation_b.isolation_level =
        case when case_number = 5 then 'repeatable read' else 'read committed' end,
      'recorded transaction isolation for case ' || case_number::text);
    perform t12_concurrency_test.check_true(observation_a.backend_pid = context.a_pid
      and observation_b.backend_pid = context.b_pid
      and observation_a.peer_pid = observation_b.backend_pid
      and observation_b.peer_pid = observation_a.backend_pid
      and observation_a.observed_at >= observation_b.started_at
      and observation_a.observed_at <= observation_b.observed_at,
      'matching blocked backends/timestamps for case ' || case_number::text);
    perform t12_concurrency_test.check_true(observation_a.rpc_result ->> 'ok' = 'true'
      and observation_b.rpc_result ->> 'ok' = 'false'
      and observation_b.rpc_result ->> 'sqlstate' = test_case.expected_state
      and (test_case.expected_message is null or observation_b.rpc_result ->> 'message' = test_case.expected_message),
      'expected RPC outcomes for case ' || case_number::text);
    perform t12_concurrency_test.check_true(
      t12_concurrency_test.snapshot(test_case.app_a) = observation_a.a_after
      and t12_concurrency_test.snapshot(test_case.app_b) = observation_a.b_after,
      'B failure leaves applications, rooms, stays, receipts, charges and history unchanged in case ' || case_number::text);

    if case_number = 1 then
      perform t12_concurrency_test.check_true((select count(*) = 1 from public.room_allocations r
        join public.applications a on a.id = r.application_id where a.camp_id = test_case.camp_id)
        and exists (select 1 from public.room_allocations r join public.rooms room on room.id = r.room_id
          where r.application_id = test_case.app_a and room.name = '桐' and r.people_count = 1)
        and not exists (select 1 from public.room_allocations r where r.application_id = test_case.app_b),
        'only A receives the last room place');
    elsif case_number in (2, 5) then
      perform t12_concurrency_test.check_true(exists (select 1 from public.applications a
        join public.room_allocations r on r.application_id = a.id join public.rooms room on room.id = r.room_id
        where a.id = test_case.app_a and a.status = 'under_review' and room.name = '藤')
        and not exists (select 1 from public.stays s where s.application_id = test_case.app_a)
        and (select count(*) = 1 from public.audit_logs l where l.entity_id = test_case.app_a and l.action = 'change_room'),
        'room change persists without an approval or stay');
    elsif case_number = 3 then
      perform t12_concurrency_test.check_true((select a.status = 'approved' from public.applications a where a.id = test_case.app_a)
        and (select count(*) = 1 from public.stays s where s.application_id = test_case.app_a and s.status = 'before_move_in')
        and (select count(*) = 1 from public.application_status_events e where e.application_id = test_case.app_a
          and e.from_status = 'under_review' and e.to_status = 'approved')
        and (select count(*) = 1 from public.audit_logs l where l.entity_id = test_case.app_a and l.action = 'approve'),
        'exactly one approval, stay and audit');
    elsif case_number = 4 then
      perform t12_concurrency_test.check_true((select count(*) = 15 from public.applications a
        where a.camp_id = test_case.camp_id and a.status in ('submitted','under_review','revision_requested','approved','cancellation_requested'))
        and (select a.status = 'submitted' from public.applications a where a.id = test_case.app_a)
        and (select a.status = 'draft' from public.applications a where a.id = test_case.app_b)
        and exists (select 1 from public.reception_numbers n where n.application_id = test_case.app_a)
        and (select c.total_amount = 600 from public.application_charges c where c.application_id = test_case.app_a)
        and not exists (select 1 from public.reception_numbers n where n.application_id = test_case.app_b)
        and not exists (select 1 from public.application_charges c where c.application_id = test_case.app_b),
        'facility remains at 15; rejected submission receives no number or charge');
    elsif case_number = 6 then
      perform t12_concurrency_test.check_true(observation_b.started_at < test_case.deadline
        and observation_a.observed_at < test_case.deadline and observation_b.observed_at >= test_case.deadline
        and (select a.status = 'revision_requested' and a.revision_due_at = test_case.deadline
          from public.applications a where a.id = test_case.app_b)
        and exists (select 1 from public.reception_numbers n where n.application_id = test_case.app_b)
        and (select c.total_amount = 600 from public.application_charges c where c.application_id = test_case.app_b),
        'revision crossed its deadline while blocked and retained its earlier submission');
    else
      perform t12_concurrency_test.check_true((select p.account_state = 'disabled' from public.profiles p where p.id = context.staff_b)
        and not exists (select 1 from public.room_allocations r where r.application_id = test_case.app_b)
        and not exists (select 1 from public.audit_logs l where l.entity_id = test_case.app_b),
        'staff deactivation prevents the waiting operation and history write');
    end if;
    return query select test_case.case_no, test_case.test_name, true,
      observation_a.backend_pid, observation_b.backend_pid, observation_b.rpc_result ->> 'sqlstate';
  end loop;
  update t12_concurrency_test.run set verified_at = clock_timestamp() where id = 1;
end;
$$;

-- Also available after a FAILED run. Never require a pass before cleanup.
-- Call inside the explicit cleanup transaction printed at the end of this file.
create function t12_concurrency_test.cleanup()
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  context t12_concurrency_test.run%rowtype;
  user_ids uuid[];
  camp_ids uuid[];
  app_ids uuid[];
begin
  perform t12_concurrency_test.check_true(current_user = 'postgres', 'postgres cleanup required');
  perform set_config('lock_timeout', '3s', true);
  perform guard.id from public.facility_guard guard where guard.id = 1 for update;
  -- Block a new worker from registering between the activity check and removal.
  select * into strict context from t12_concurrency_test.run where id = 1 for update;
  perform pg_stat_clear_snapshot();
  perform t12_concurrency_test.check_true(not exists (select 1 from pg_stat_activity a
    where a.pid <> pg_backend_pid() and a.state is distinct from 'idle'
      and ((a.pid = context.a_pid and a.backend_start = context.a_backend_start)
        or (a.pid = context.b_pid and a.backend_start = context.b_backend_start))),
    'stop/wait for both workers before cleanup');
  select array_agg(f.id) filter (where f.kind = 'user'),
    array_agg(f.id) filter (where f.kind = 'camp'), array_agg(f.id) filter (where f.kind = 'application')
  into user_ids, camp_ids, app_ids from t12_concurrency_test.fixtures f;

  perform t12_concurrency_test.check_true((select count(*) = cardinality(user_ids) from auth.users u
    where u.id = any(user_ids) and u.email = 't12-concurrency-' || u.id::text || '@example.invalid'
      and u.raw_user_meta_data ->> 't12_concurrency_run' = context.token::text
      and coalesce(u.encrypted_password, '') = '' and u.last_sign_in_at is null),
    'all cleanup users must still be unused marked fixtures');
  perform t12_concurrency_test.check_true((select count(*) = cardinality(camp_ids) from public.camps c
    where c.id = any(camp_ids) and c.name like 'T12 concurrency ' || context.token::text || ' case %'),
    'all cleanup camps must still match the run marker');
  perform t12_concurrency_test.check_true((select count(*) = cardinality(app_ids) from public.applications a
    where a.id = any(app_ids) and a.camp_id = any(camp_ids) and a.user_id = any(user_ids)),
    'all cleanup applications must belong to this run');
  perform t12_concurrency_test.check_true(not exists (select 1 from public.applications a
    where (a.camp_id = any(camp_ids) or a.user_id = any(user_ids) or a.original_application_id = any(app_ids))
      and not (a.id = any(app_ids)))
    and not exists (select 1 from public.camps c where c.created_by = any(user_ids) and not (c.id = any(camp_ids)))
    and not exists (select 1 from public.application_status_events e
      where e.actor_user_id = any(user_ids) and not (e.application_id = any(app_ids)))
    and not exists (select 1 from public.audit_logs l where l.actor_user_id = any(user_ids)
      and not (l.entity_type = 'application' and l.entity_id = any(app_ids)))
    and not exists (select 1 from public.camp_eligible_users e where e.camp_id = any(camp_ids)
      and not exists (select 1 from auth.users u where u.id = any(user_ids) and u.email = e.email_normalized))
    and not exists (select 1 from public.consent_documents d where d.application_id = any(app_ids)),
    'unexpected references or attachments: inspect before cleanup');

  delete from public.audit_logs where entity_type = 'application' and entity_id = any(app_ids);
  -- Related room/stay/charge/month/receipt/event rows cascade from these UUIDs.
  delete from public.applications where id = any(app_ids);
  delete from public.camps where id = any(camp_ids);
  delete from auth.users where id = any(user_ids);
  perform t12_concurrency_test.check_true(not exists (select 1 from public.applications a where a.id = any(app_ids))
    and not exists (select 1 from public.camps c where c.id = any(camp_ids))
    and not exists (select 1 from auth.users u where u.id = any(user_ids))
    and not exists (select 1 from public.audit_logs l where l.entity_type = 'application' and l.entity_id = any(app_ids)),
    'fixture cleanup completed');
  return jsonb_build_object('removed_users', cardinality(user_ids), 'removed_camps', cardinality(camp_ids),
    'removed_applications', cardinality(app_ids), 'receipt_counters', 'preserved; no number reuse');
end;
$$;

revoke all on all functions in schema t12_concurrency_test from public, anon, authenticated, service_role;
revoke all on procedure t12_concurrency_test.worker_a() from public, anon, authenticated, service_role;
revoke all on procedure t12_concurrency_test.worker_b() from public, anon, authenticated, service_role;
commit;

select token as test_run,
  'Prepared only; run A and B in separate connections, then verify and clean up.' as status,
  'call t12_concurrency_test.worker_a();' as worker_a_sql,
  'call t12_concurrency_test.worker_b();' as worker_b_sql,
  'select * from t12_concurrency_test.verify();' as verification_sql,
  'begin; select t12_concurrency_test.cleanup(); drop schema t12_concurrency_test cascade; commit;' as cleanup_sql
from t12_concurrency_test.run where id = 1;
