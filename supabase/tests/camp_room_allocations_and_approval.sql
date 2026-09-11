-- SQL 009 / 010 / 011 / 012 regression checks for a Supabase TEST database.
-- Prerequisite: migrations 001 through 012, run as the postgres SQL Editor role.
-- Run this WHOLE file in one connection. It creates only fictional records,
-- temporary helpers, and a failure-injection trigger, then ROLLS BACK everything.
-- Do not run selected fragments or change the final ROLLBACK to COMMIT.
-- On any unexpected error, the transaction is aborted: execute ROLLBACK before
-- retrying. No Auth API, Storage API, email, or real credentials are used.
-- The facility lock is held until rollback. Run in a test project without traffic.
-- These are single-connection tests. They do NOT prove concurrent execution;
-- the separate multi-connection acceptance cases are listed at the end.

begin;
set local lock_timeout = '3s';
set local statement_timeout = '60s';
set local timezone = 'UTC';

do $$
begin
  if current_user <> 'postgres' then
    raise exception 'Run this file as postgres in a Supabase test database.';
  end if;
  if to_regprocedure('public.assign_camp_application_room(uuid,uuid,timestamptz,text)') is null
    or to_regprocedure('public.review_camp_application(uuid,text,timestamptz,text)') is null
    or to_regclass('public.audit_logs') is null
    or to_regclass('public.calendar_claims') is null then
    raise exception 'Apply migrations 001 through 012 before running this file.';
  end if;
end;
$$;

create temporary table test_results (
  test_no integer generated always as identity,
  test_name text not null unique,
  passed boolean not null
) on commit drop;
create temporary sequence test_camp_offsets;
create temporary table test_context (
  staff_id uuid,
  second_staff_id uuid,
  disabled_staff_id uuid,
  base_date date
) on commit drop;

create function pg_temp.check_true(condition boolean, label text)
returns void language plpgsql as $$
begin
  if condition is distinct from true then
    raise exception 'FAIL: %', label;
  end if;
  insert into pg_temp.test_results (test_name, passed) values (label, true);
end;
$$;

create function pg_temp.expect_ok(result jsonb, label text)
returns void language plpgsql as $$
begin
  if result ->> 'ok' is distinct from 'true' then
    raise exception 'FAIL: %; result=%', label, result;
  end if;
  perform pg_temp.check_true(true, label);
end;
$$;

create function pg_temp.expect_error(
  result jsonb, expected_message text, label text, expected_state text default 'P0001'
)
returns void language plpgsql as $$
begin
  if result ->> 'ok' is distinct from 'false'
    or result ->> 'sqlstate' is distinct from expected_state
    or (expected_message is not null
      and result ->> 'message' is distinct from expected_message) then
    raise exception 'FAIL: %; result=%; expected=(%, %)',
      label, result, expected_state, expected_message;
  end if;
  perform pg_temp.check_true(true, label);
end;
$$;

create function pg_temp.fixture_user(user_kind text default 'user')
returns uuid language plpgsql as $$
declare
  new_id uuid := gen_random_uuid();
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  ) values (
    new_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    't12-' || new_id::text || '@example.invalid', '', clock_timestamp(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
    clock_timestamp(), clock_timestamp()
  );
  if user_kind in ('staff', 'disabled_staff') then
    insert into public.staff_roles (user_id) values (new_id);
  end if;
  if user_kind = 'disabled_staff' then
    update public.profiles set account_state = 'disabled' where id = new_id;
  end if;
  return new_id;
end;
$$;

insert into pg_temp.test_context
select pg_temp.fixture_user('staff'), pg_temp.fixture_user('staff'),
  pg_temp.fixture_user('disabled_staff'), greatest(
    (clock_timestamp() at time zone 'Asia/Tokyo')::date + 30,
    (select max(end_date) + 30 from public.camps),
  (select max(end_date) + 30 from public.blocked_periods),
    (select max(end_date) + 30 from public.applications),
    (select max(end_date) + 30 from public.room_allocations)
  );

do $$
begin
  perform pg_temp.check_true(
    (select isfinite(base_date) from pg_temp.test_context), 'finite fixture dates'
  );
end;
$$;

create function pg_temp.fixture_camp(
  starts_on date default null, ends_on date default null
)
returns uuid language plpgsql as $$
declare
  new_id uuid;
  start_value date;
begin
  select coalesce(starts_on, base_date + nextval('pg_temp.test_camp_offsets')::integer * 10)
  into start_value from pg_temp.test_context;
  insert into public.camps (name, start_date, end_date, application_deadline, created_by)
  select 'T12 regression ' || gen_random_uuid()::text,
    start_value, coalesce(ends_on, start_value + 1), clock_timestamp() + interval '1 hour', staff_id
  from pg_temp.test_context returning id into new_id;
  return new_id;
end;
$$;

-- Direct inserts here are fixture setup, not a simulated successful submission.
-- The lifecycle and resubmission cases below explicitly call the public submit RPC.
create function pg_temp.fixture_application(
  camp_id_value uuid, status_value text default 'under_review', guardian_required boolean default false
)
returns uuid language plpgsql as $$
declare
  new_id uuid;
  owner_id uuid := pg_temp.fixture_user();
  owner_email text;
begin
  select email into owner_email from auth.users where id = owner_id;
  insert into public.camp_eligible_users (camp_id, email_normalized)
  values (camp_id_value, owner_email);
  insert into public.applications (
    user_id, camp_id, status, start_date, end_date, user_name, user_address, user_phone,
    email_snapshot, emergency_name, emergency_address, emergency_phone, usage_place,
    purpose, requires_guardian_consent, room_preference,
    submitted_at, last_submitted_at, revision_due_at
  )
  select owner_id, camp.id, status_value, camp.start_date, camp.end_date,
    '架空テスト利用者', '架空テスト住所', '000-0000-0000', owner_email,
    '架空テスト連絡先', '架空テスト住所', '000-0000-0000', 'common_and_second_floor',
    '架空キャンプの検証', guardian_required, 'shared_ok',
    case when status_value <> 'draft' then clock_timestamp() end,
    case when status_value <> 'draft' then clock_timestamp() end,
    case when status_value = 'revision_requested' then clock_timestamp() + interval '1 hour' end
  from public.camps as camp where camp.id = camp_id_value returning id into new_id;
  return new_id;
end;
$$;

-- SECURITY INVOKER is intentional. Only the test connection's postgres session
-- can SET ROLE. The query itself runs as authenticated/anon, so RLS and GRANTs
-- apply. This simulates DB claims, not JWT signature verification or Auth login.
create function pg_temp.call_as(
  actor_id uuid, query_text text, database_role text default 'authenticated'
)
returns jsonb language plpgsql security invoker as $$
declare
  actor_email text;
  result_rows jsonb;
  result_record record;
  result_value jsonb;
  error_state text;
  error_message text;
begin
  select email into actor_email from auth.users where id = actor_id;
  begin
    execute format('set local role %I', database_role);
    perform set_config('request.jwt.claim.sub', coalesce(actor_id::text, ''), true);
    perform set_config('request.jwt.claim.email', coalesce(actor_email, ''), true);
    perform set_config('request.jwt.claims', jsonb_build_object(
      'sub', actor_id, 'email', actor_email, 'role', database_role
    )::text, true);
    result_rows := '[]'::jsonb;
    -- Keep the query at top level: data-modifying WITH statements cannot be
    -- nested inside a SELECT subquery. This also retains every returned row.
    for result_record in execute query_text loop
      result_rows := result_rows || jsonb_build_array(to_jsonb(result_record));
    end loop;
    result_value := jsonb_build_object('ok', true, 'rows', result_rows);
  exception when others then
    get stacked diagnostics error_state = returned_sqlstate, error_message = message_text;
    result_value := jsonb_build_object('ok', false, 'sqlstate', error_state, 'message', error_message);
  end;
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.email', '', true);
  perform set_config('request.jwt.claims', '{}', true);
  return result_value;
end;
$$;

create function pg_temp.version_of(application_id_value uuid)
returns timestamptz language sql as $$
  select updated_at from public.applications where id = application_id_value;
$$;

create function pg_temp.assign_room(
  application_id_value uuid, room_id_value uuid, reason_value text default null,
  version_value timestamptz default null, actor_id uuid default null
)
returns jsonb language sql as $$
  select pg_temp.call_as(coalesce(actor_id, context.staff_id), format(
    'select * from public.assign_camp_application_room(%L::uuid,%L::uuid,%L::timestamptz,%L::text)',
    application_id_value, room_id_value,
    coalesce(version_value, pg_temp.version_of(application_id_value)), reason_value
  )) from pg_temp.test_context as context;
$$;

create function pg_temp.review(
  application_id_value uuid, action_value text, reason_value text default null,
  version_value timestamptz default null, actor_id uuid default null
)
returns jsonb language sql as $$
  select pg_temp.call_as(coalesce(actor_id, context.staff_id), format(
    'select * from public.review_camp_application(%L::uuid,%L::text,%L::timestamptz,%L::text)',
    application_id_value, action_value,
    coalesce(version_value, pg_temp.version_of(application_id_value)), reason_value
  )) from pg_temp.test_context as context;
$$;

create function pg_temp.submit(application_id_value uuid)
returns jsonb language sql as $$
  select pg_temp.call_as(application.user_id, format(
    'select * from public.submit_camp_application(%L::uuid)', application_id_value
  )) from public.applications as application where application.id = application_id_value;
$$;

create function pg_temp.snapshot(application_id_value uuid)
returns jsonb language sql as $$
  select jsonb_build_object(
    'application', (select to_jsonb(a) from public.applications a where a.id = application_id_value),
    'room', (select to_jsonb(r) from public.room_allocations r where r.application_id = application_id_value),
    'stay', (select to_jsonb(s) from public.stays s where s.application_id = application_id_value),
    'events', (select jsonb_agg(to_jsonb(e) order by e.id) from public.application_status_events e where e.application_id = application_id_value),
    'audit', (select jsonb_agg(to_jsonb(l) order by l.id) from public.audit_logs l where l.entity_type = 'application' and l.entity_id = application_id_value),
    'charge', (select to_jsonb(c) from public.application_charges c where c.application_id = application_id_value),
    'months', (select jsonb_agg(to_jsonb(m) order by m.id) from public.charge_months m join public.application_charges c on c.id = m.charge_id where c.application_id = application_id_value),
    'number', (select to_jsonb(n) from public.reception_numbers n where n.application_id = application_id_value)
  );
$$;

-- 1. Full submit -> explicit review -> room -> approval lifecycle and history.
do $$
declare
  camp uuid := pg_temp.fixture_camp();
  application uuid := pg_temp.fixture_application(camp, 'draft');
  room uuid := (select id from public.rooms where name = '桐');
  other_room uuid := (select id from public.rooms where name = '藤');
  before_value jsonb;
  first_version timestamptz;
  room_version timestamptz;
  charge_before jsonb;
  stay_before jsonb;
begin
  before_value := pg_temp.snapshot(application);
  perform pg_temp.expect_error(pg_temp.review(application, 'approve'), 'invalid-status', 'draft cannot be approved');
  perform pg_temp.expect_error(pg_temp.assign_room(application, room), 'invalid-status', 'draft cannot receive a room');
  perform pg_temp.check_true(pg_temp.snapshot(application) = before_value, 'draft denial leaves all records unchanged');
  perform pg_temp.expect_ok(pg_temp.submit(application), 'initial submission succeeds');
  perform pg_temp.check_true((select count(*) = 1 from public.reception_numbers where application_id = application), 'initial submission issues one reception number');
  perform pg_temp.check_true((select total_amount = 600 from public.application_charges where application_id = application), 'two-day camp charge is 600 yen');
  perform pg_temp.expect_error(pg_temp.review(application, 'approve'), 'invalid-status', 'submitted cannot bypass explicit review');
  perform pg_temp.expect_ok(pg_temp.review(application, 'start_review'), 'explicit review succeeds');
  before_value := pg_temp.snapshot(application);
  perform pg_temp.expect_error(pg_temp.review(application, 'approve'), 'room-required', 'approval requires a room');
  perform pg_temp.check_true(pg_temp.snapshot(application) = before_value, 'missing-room failure creates no stay or history');

  first_version := pg_temp.version_of(application);
  perform pg_temp.expect_ok(pg_temp.assign_room(application, room), 'initial room assignment succeeds');
  room_version := pg_temp.version_of(application);
  perform pg_temp.check_true(room_version > first_version, 'room assignment advances parent version in same transaction');
  perform pg_temp.check_true((select people_count = 1 and released_from is null
    and start_date = (select start_date from public.camps where id = camp)
    and end_date = (select end_date from public.camps where id = camp)
    from public.room_allocations where application_id = application), 'room covers one person and entire fixed camp');
  perform pg_temp.expect_error(pg_temp.review(application, 'approve', null, first_version), 'stale-update', 'approval rejects pre-assignment screen');
  perform pg_temp.expect_error(pg_temp.assign_room(application, other_room, '競合の検証', room_version - interval '1 microsecond'), 'stale-update', 'one-microsecond version mismatch rejected');
  before_value := pg_temp.snapshot(application);
  perform pg_temp.expect_ok(pg_temp.assign_room(application, room), 'same-room save succeeds');
  perform pg_temp.check_true(pg_temp.snapshot(application) = before_value, 'same-room save is a complete no-op');
  perform pg_temp.expect_error(pg_temp.assign_room(application, other_room), 'reason-required', 'pre-approval room change requires a reason');

  perform pg_temp.expect_ok(pg_temp.review(application, 'approve', '架空の許可コメント'), 'approval succeeds');
  perform pg_temp.check_true((select status = 'approved' and approval_comment = '架空の許可コメント'
    and revision_due_at is null from public.applications where id = application), 'approval state and comment saved');
  perform pg_temp.check_true((select status = 'before_move_in' and checked_in_at is null and checked_out_at is null
    from public.stays where application_id = application), 'approval initializes before_move_in');
  perform pg_temp.check_true((select count(*) = 1 from public.application_status_events
    where application_id = application and from_status = 'under_review' and to_status = 'approved'
      and public_reason = '架空の許可コメント'), 'one public approval event');
  perform pg_temp.check_true((select count(*) = 1 from public.audit_logs
    where entity_id = application and action = 'approve'
      and before_data #>> '{application,status}' = 'under_review'
      and after_data #>> '{application,status}' = 'approved'
      and after_data #>> '{stay,status}' = 'before_move_in'
      and actor_kind = 'staff' and actor_user_id = (select staff_id from pg_temp.test_context)), 'approval audit records before-after and actor');
  before_value := pg_temp.snapshot(application);
  perform pg_temp.expect_error(pg_temp.review(application, 'approve', null, room_version), 'stale-update', 'approval retry rejects old version');
  perform pg_temp.expect_error(pg_temp.review(application, 'approve'), 'invalid-status', 'approval retry rejects already-approved state');
  perform pg_temp.check_true(pg_temp.snapshot(application) = before_value, 'approval retries do not duplicate any records');

  charge_before := before_value -> 'charge';
  stay_before := before_value -> 'stay';
  perform pg_temp.expect_error(pg_temp.assign_room(application, other_room), 'reason-required', 'approved room change requires reason');
  perform pg_temp.expect_ok(pg_temp.assign_room(application, other_room, '職員だけに見せる架空理由'), 'approved room change succeeds with reason');
  perform pg_temp.check_true((pg_temp.snapshot(application) -> 'charge') = charge_before
    and (pg_temp.snapshot(application) -> 'stay') = stay_before, 'room change preserves charges and stay');
  perform pg_temp.check_true((select count(*) = 1 from public.audit_logs where entity_id = application and action = 'change_room'
    and reason = '職員だけに見せる架空理由' and before_data #>> '{room_allocation,room_id}' = room::text
    and after_data #>> '{room_allocation,room_id}' = other_room::text and occurred_at is not null), 'room-change audit retains reason and both rooms');
  perform pg_temp.check_true(not exists(select 1 from public.application_status_events
    where application_id = application and public_reason = '職員だけに見せる架空理由'), 'internal room reason absent from public events');

  update public.stays set status = 'staying', checked_in_at = clock_timestamp() where application_id = application;
  perform pg_temp.expect_ok(pg_temp.assign_room(application, room, '滞在中の架空変更'), 'staying room change allowed');
  update public.stays set status = 'moved_out', checked_out_at = clock_timestamp() where application_id = application;
  before_value := pg_temp.snapshot(application);
  perform pg_temp.expect_error(pg_temp.assign_room(application, other_room, '退去後の架空変更'), 'stay-completed', 'moved-out room change rejected');
  perform pg_temp.check_true(pg_temp.snapshot(application) = before_value, 'moved-out history unchanged');
end;
$$;

-- 2. GRANTs, RPC authorization and RLS, exercised as real database roles.
do $$
declare
  application uuid := pg_temp.fixture_application(pg_temp.fixture_camp());
  room uuid := (select id from public.rooms where name = '桐');
  owner_id uuid := (select user_id from public.applications where id = application);
  outsider_id uuid := pg_temp.fixture_user();
  staff_id_value uuid := (select staff_id from pg_temp.test_context);
  disabled_id uuid := (select disabled_staff_id from pg_temp.test_context);
  query_text text;
  result jsonb;
  before_value jsonb := pg_temp.snapshot(application);
  table_name text;
  operation_name text;
begin
  query_text := format('select * from public.assign_camp_application_room(%L::uuid,%L::uuid,%L::timestamptz)',
    application, room, pg_temp.version_of(application));
  perform pg_temp.expect_error(pg_temp.call_as(null, query_text, 'anon'), null, 'anon cannot call assignment RPC', '42501');
  perform pg_temp.expect_error(pg_temp.call_as(null, query_text), 'staff-required', 'missing identity cannot assign', '42501');
  perform pg_temp.expect_error(pg_temp.call_as(owner_id, query_text), 'staff-required', 'owner cannot assign own room', '42501');
  perform pg_temp.expect_error(pg_temp.call_as(outsider_id, query_text), 'staff-required', 'other user cannot assign room', '42501');
  perform pg_temp.expect_error(pg_temp.call_as(disabled_id, query_text), 'staff-required', 'disabled staff cannot assign room', '42501');
  query_text := format('select * from public.review_camp_application(%L::uuid,''approve'',%L::timestamptz)',
    application, pg_temp.version_of(application));
  perform pg_temp.expect_error(pg_temp.call_as(null, query_text, 'anon'), null, 'anon cannot call review RPC', '42501');
  perform pg_temp.expect_error(pg_temp.call_as(owner_id, query_text), 'staff-required', 'owner cannot approve', '42501');
  perform pg_temp.expect_error(pg_temp.call_as(disabled_id, query_text), 'staff-required', 'disabled staff cannot approve', '42501');
  perform pg_temp.check_true(pg_temp.snapshot(application) = before_value, 'unauthorized RPCs leave records unchanged');

  perform pg_temp.check_true(to_regprocedure('public.review_camp_application(uuid,text,text)') is null, 'unversioned review RPC removed');
  perform pg_temp.expect_error(pg_temp.call_as(staff_id_value, format(
    'select * from public.review_camp_application(%L::uuid,''approve'',null::timestamptz)', application
  )), 'invalid-version', 'null version rejected by DB');
  perform pg_temp.expect_error(pg_temp.call_as(staff_id_value, format(
    'select * from public.review_camp_application(%L::uuid,''approve'',''infinity''::timestamptz)', application
  )), 'invalid-version', 'infinite version rejected by DB');
  perform pg_temp.expect_error(pg_temp.call_as(staff_id_value, format(
    'select * from public.assign_camp_application_room(%L::uuid,%L::uuid,now())', gen_random_uuid(), room
  )), 'not-found', 'nonexistent application rejected');
  perform pg_temp.expect_error(pg_temp.assign_room(application, gen_random_uuid()), 'invalid-room', 'nonexistent room rejected');
  perform pg_temp.expect_error(pg_temp.review(application, null), 'invalid-action', 'null review action rejected');
  perform pg_temp.expect_error(pg_temp.review(application, 'unknown'), 'invalid-action', 'unknown review action rejected');
  perform pg_temp.expect_error(pg_temp.review(application, 'reject', ' '), 'reason-required', 'blank rejection reason rejected by DB');
  perform pg_temp.expect_error(pg_temp.review(application, 'request_revision', ''), 'reason-required', 'blank revision reason rejected by DB');
  perform pg_temp.expect_error(pg_temp.review(application, 'approve', repeat('字', 2001)), 'reason-too-long', 'oversized approval comment rejected by DB');
  perform pg_temp.expect_error(pg_temp.assign_room(application, room, repeat('字', 2001)), 'reason-too-long', 'oversized room reason rejected by DB');

  -- An UPDATE of zero rows would still require the privilege: these must error.
  foreach table_name in array array['applications','room_allocations','stays','application_status_events','audit_logs'] loop
    foreach operation_name in array array['INSERT','UPDATE','DELETE','TRUNCATE'] loop
      perform pg_temp.check_true(not has_table_privilege('authenticated', 'public.' || table_name, operation_name),
        'no authenticated ' || operation_name || ' grant on ' || table_name);
    end loop;
    perform pg_temp.expect_error(pg_temp.call_as(staff_id_value, format(
      'with changed as (delete from public.%I where false returning id) select * from changed', table_name
    )), null, 'direct staff deletion forbidden: ' || table_name, '42501');
  end loop;
  perform pg_temp.expect_error(pg_temp.call_as(staff_id_value, format(
    'with changed as (update public.applications set status=''approved'' where id=%L::uuid returning id) select * from changed', application
  )), null, 'direct state update forbidden', '42501');
  perform pg_temp.expect_error(pg_temp.call_as(staff_id_value, format(
    'insert into public.room_allocations(application_id,room_id,start_date,end_date) values (%L::uuid,%L::uuid,current_date,current_date+1) returning id',
    application, room
  )), null, 'direct room insertion forbidden', '42501');
  perform pg_temp.expect_error(pg_temp.call_as(owner_id, format(
    'with changed as (update public.room_allocations set room_id=%L::uuid where application_id=%L::uuid returning id) select * from changed', room, application
  )), null, 'direct applicant room update forbidden', '42501');
  perform pg_temp.expect_error(pg_temp.call_as(staff_id_value, format(
    'select private.check_camp_room_capacity(%L::uuid,%L::uuid)', application, room
  )), null, 'internal capacity helper cannot be called directly', '42501');
  perform pg_temp.expect_error(pg_temp.call_as(owner_id, format(
    'select * from private.submit_camp_application(%L::uuid)', application
  )), null, 'internal submission cannot bypass consent wrapper', '42501');

  perform pg_temp.expect_ok(pg_temp.assign_room(application, room), 'authorized assignment for RLS fixture');
  query_text := format('select id from public.audit_logs where entity_id=%L::uuid and actor_kind=''staff''', application);
  result := pg_temp.call_as(staff_id_value, query_text);
  perform pg_temp.check_true(result ->> 'ok' = 'true' and jsonb_array_length(result -> 'rows') = 1, 'active staff can read audit');
  result := pg_temp.call_as(owner_id, query_text);
  perform pg_temp.check_true(result ->> 'ok' = 'true' and result -> 'rows' = '[]'::jsonb, 'owner cannot read internal audit via RLS');
  result := pg_temp.call_as(disabled_id, query_text);
  perform pg_temp.check_true(result ->> 'ok' = 'true' and result -> 'rows' = '[]'::jsonb, 'disabled staff cannot read audit via RLS');
  query_text := format('select room_id from public.room_allocations where application_id=%L::uuid', application);
  result := pg_temp.call_as(owner_id, query_text);
  perform pg_temp.check_true(result ->> 'ok' = 'true' and jsonb_array_length(result -> 'rows') = 1, 'owner can read own room');
  result := pg_temp.call_as(outsider_id, query_text);
  perform pg_temp.check_true(result ->> 'ok' = 'true' and result -> 'rows' = '[]'::jsonb, 'other user cannot read room');
  result := pg_temp.call_as(outsider_id, format('select id from public.applications where id=%L::uuid', application));
  perform pg_temp.check_true(result ->> 'ok' = 'true' and result -> 'rows' = '[]'::jsonb, 'other user cannot read application');
end;
$$;

-- Non-review states cannot acquire rooms or bypass the review transition.
do $$
declare
  status_value text;
  target uuid;
  room uuid := (select id from public.rooms where name = '桐');
  before_value jsonb;
begin
  foreach status_value in array array['revision_requested','rejected','cancelled','cancellation_requested'] loop
    target := pg_temp.fixture_application(pg_temp.fixture_camp(), status_value);
    before_value := pg_temp.snapshot(target);
    perform pg_temp.expect_error(pg_temp.assign_room(target, room), 'invalid-status', status_value || ' cannot assign room');
    perform pg_temp.expect_error(pg_temp.review(target, 'approve'), 'invalid-status', status_value || ' cannot approve');
    perform pg_temp.check_true(pg_temp.snapshot(target) = before_value, status_value || ' denials preserve records');
  end loop;
end;
$$;

-- 3. Every room, not just one example. Exceeding capacity must leave no changes.
do $$
declare
  room_record record;
  camp uuid;
  application uuid;
  i integer;
  before_value jsonb;
begin
  perform pg_temp.check_true((select count(*) = 8 and sum(capacity) = 15 from public.rooms), 'fixed room master totals eight rooms and fifteen people');
  for room_record in select id, name, capacity from public.rooms order by name loop
    camp := pg_temp.fixture_camp();
    for i in 1..room_record.capacity loop
      application := pg_temp.fixture_application(camp);
      perform pg_temp.expect_ok(pg_temp.assign_room(application, room_record.id),
        format('room %s accepts occupant %s of %s', room_record.name, i, room_record.capacity));
    end loop;
    application := pg_temp.fixture_application(camp);
    before_value := pg_temp.snapshot(application);
    perform pg_temp.expect_error(pg_temp.assign_room(application, room_record.id), 'room-capacity-full',
      format('room %s refuses next occupant', room_record.name));
    perform pg_temp.check_true(pg_temp.snapshot(application) = before_value,
      format('room %s overflow leaves no partial changes', room_record.name));
  end loop;
end;
$$;

-- 4. Facility reservations count even when unassigned, across camp IDs.
-- Directly inserting a 16th claim intentionally creates an invalid fixture;
-- normal submissions should never be able to create this state.
do $$
declare
  camp uuid := pg_temp.fixture_camp();
  target uuid := pg_temp.fixture_application(camp);
  room uuid := (select id from public.rooms where name = '桐');
  other_room uuid := (select id from public.rooms where name = '藤');
  statuses text[] := array['submitted','under_review','revision_requested','approved','cancellation_requested'];
  extra uuid;
  cross_camp uuid;
  before_value jsonb;
  i integer;
begin
  for i in 1..14 loop
    perform pg_temp.fixture_application(camp, statuses[(i - 1) % 5 + 1]);
  end loop;
  perform pg_temp.fixture_application(camp, 'draft');
  perform pg_temp.fixture_application(camp, 'rejected');
  perform pg_temp.fixture_application(camp, 'cancelled');
  perform pg_temp.expect_ok(pg_temp.assign_room(target, room), 'exactly fifteen active reservations allowed; terminal states ignored');
  extra := pg_temp.fixture_application(camp);
  before_value := pg_temp.snapshot(extra);
  perform pg_temp.expect_error(pg_temp.assign_room(extra, other_room), 'facility-capacity-full', 'sixteenth unassigned reservation prevents room assignment');
  perform pg_temp.check_true(pg_temp.snapshot(extra) = before_value, 'facility overflow leaves extra applicant unchanged');
  before_value := pg_temp.snapshot(target);
  perform pg_temp.expect_error(pg_temp.review(target, 'approve'), 'facility-capacity-full', 'approval rechecks facility capacity after assignment');
  perform pg_temp.check_true(pg_temp.snapshot(target) = before_value, 'facility overflow approval creates no stay or history');
  update public.applications set status = 'cancelled' where id = extra;
  perform pg_temp.expect_ok(pg_temp.review(target, 'approve'), 'approval succeeds after active count returns to fifteen');

  cross_camp := pg_temp.fixture_camp(
    (select start_date from public.camps where id = camp),
    (select end_date from public.camps where id = camp)
  );
  extra := pg_temp.fixture_application(cross_camp);
  perform pg_temp.expect_error(pg_temp.assign_room(extra, other_room), 'facility-capacity-full', 'facility count includes other camps on same dates');
end;
$$;

-- 5. Inclusive day boundaries, room recheck at approval, inconsistent records.
do $$
declare
  camp uuid := pg_temp.fixture_camp();
  target uuid := pg_temp.fixture_application(camp);
  overlap_camp uuid;
  later_camp uuid;
  extra uuid;
  room uuid := (select id from public.rooms where name = '桐');
  other_room uuid := (select id from public.rooms where name = '藤');
  before_value jsonb;
begin
  perform pg_temp.expect_ok(pg_temp.assign_room(target, room), 'date-boundary fixture assigned');
  overlap_camp := pg_temp.fixture_camp((select end_date from public.camps where id = camp));
  extra := pg_temp.fixture_application(overlap_camp);
  perform pg_temp.expect_error(pg_temp.assign_room(extra, room), 'room-capacity-full', 'end day and next applicant start day overlap');
  later_camp := pg_temp.fixture_camp((select end_date + 1 from public.camps where id = camp));
  extra := pg_temp.fixture_application(later_camp);
  perform pg_temp.expect_ok(pg_temp.assign_room(extra, room), 'day after end permits same room');

  -- Deliberately invalid fixture after an otherwise valid room assignment.
  extra := pg_temp.fixture_application(camp);
  insert into public.room_allocations (application_id, room_id, start_date, end_date)
  select extra, room, start_date, end_date from public.camps where id = camp;
  before_value := pg_temp.snapshot(target);
  perform pg_temp.expect_error(pg_temp.review(target, 'approve'), 'room-capacity-full', 'approval rechecks room capacity');
  perform pg_temp.check_true(pg_temp.snapshot(target) = before_value, 'room-overflow approval is atomic');
  update public.room_allocations set released_from = start_date where application_id = extra;
  perform pg_temp.expect_ok(pg_temp.assign_room(target, room), 'released allocation no longer consumes room capacity');

  update public.room_allocations set end_date = start_date where application_id = target;
  before_value := pg_temp.snapshot(target);
  perform pg_temp.expect_error(pg_temp.review(target, 'approve'), 'invalid-allocation', 'partial-period room cannot be approved');
  perform pg_temp.check_true(pg_temp.snapshot(target) = before_value, 'partial-period approval failure unchanged');
  update public.room_allocations set end_date = (select end_date from public.camps where id = camp),
    released_from = start_date where application_id = target;
  perform pg_temp.expect_error(pg_temp.review(target, 'approve'), 'invalid-allocation', 'released room cannot be approved');
  update public.room_allocations set released_from = null where application_id = target;
  update public.camps set end_date = end_date + 1 where id = camp;
  perform pg_temp.expect_error(pg_temp.review(target, 'approve'), 'camp-dates-changed', 'changed camp dates cannot be silently approved');
  perform pg_temp.expect_error(pg_temp.assign_room(target, other_room, '日程差異の検証'), 'camp-dates-changed', 'changed camp dates cannot be silently reassigned');
  update public.camps set end_date = end_date - 1, deleted_at = clock_timestamp() where id = camp;
  perform pg_temp.expect_error(pg_temp.review(target, 'approve'), 'camp-unavailable', 'deleted camp cannot be approved');
  update public.camps set deleted_at = null where id = camp;
  insert into public.stays (application_id) values (target);
  before_value := pg_temp.snapshot(target);
  perform pg_temp.expect_error(pg_temp.review(target, 'approve'), 'invalid-stay', 'review cannot reset existing stay');
  perform pg_temp.check_true(pg_temp.snapshot(target) = before_value, 'existing stay survives failed approval');
end;
$$;

-- 6. Real correction workflow after the initial deadline; room holds/releases.
do $$
declare
  camp uuid := pg_temp.fixture_camp();
  target uuid := pg_temp.fixture_application(camp, 'draft');
  extra uuid;
  owner_id uuid := (select user_id from public.applications where id = target);
  room uuid := (select id from public.rooms where name = '桐');
  number_before jsonb;
  result jsonb;
  before_value jsonb;
  original_submitted_at timestamptz;
begin
  perform pg_temp.expect_ok(pg_temp.submit(target), 'correction fixture first submission');
  number_before := pg_temp.snapshot(target) -> 'number';
  select submitted_at into original_submitted_at from public.applications where id = target;
  perform pg_temp.expect_ok(pg_temp.review(target, 'start_review'), 'correction fixture review starts');
  perform pg_temp.expect_ok(pg_temp.assign_room(target, room), 'correction fixture room assigned');
  perform pg_temp.expect_ok(pg_temp.review(target, 'request_revision', '架空の修正依頼'), 'revision requested with deadline');
  perform pg_temp.check_true((select status = 'revision_requested' and revision_due_at =
    (((clock_timestamp() at time zone 'Asia/Tokyo')::date + 4)::timestamp at time zone 'Asia/Tokyo')
    from public.applications where id = target), 'revision deadline is end of third following Japan day');
  perform pg_temp.check_true((select released_from is null from public.room_allocations where application_id = target), 'revision retains allocation');
  extra := pg_temp.fixture_application(camp);
  perform pg_temp.expect_error(pg_temp.assign_room(extra, room), 'room-capacity-full', 'revision allocation still consumes room capacity');

  -- Expired even for old implementations using the transaction start time.
  update public.camps set application_deadline = transaction_timestamp() - interval '1 second' where id = camp;
  result := pg_temp.call_as(owner_id, format(
    'select public.save_camp_application_draft(%L::uuid,%L,%L,%L,%L,%L,%L,%L,%L,false,%L)',
    target, '架空修正後の氏名', '架空住所', '000-0000-0000', '架空連絡先', '架空住所',
    '000-0000-0000', '架空キャンプ修正', '', 'shared_ok'
  ));
  perform pg_temp.expect_ok(result, 'correction can be saved after initial deadline');
  perform pg_temp.expect_ok(pg_temp.submit(target), 'correction resubmits after initial deadline within revision deadline');
  perform pg_temp.check_true((select status = 'submitted' and revision_due_at is null
    and submitted_at = original_submitted_at and last_submitted_at >= submitted_at
    from public.applications where id = target), 'resubmission returns to submitted and keeps initial submission time');
  perform pg_temp.check_true((pg_temp.snapshot(target) -> 'number') = number_before, 'resubmission keeps reception number');
  perform pg_temp.check_true((select total_amount = 600 from public.application_charges where application_id = target), 'resubmission keeps correct charge');
  perform pg_temp.check_true((select count(*) = 1 from public.application_status_events
    where application_id = target and from_status = 'revision_requested' and to_status = 'submitted'), 'resubmission adds exactly one status event');
  before_value := pg_temp.snapshot(target);
  perform pg_temp.expect_ok(pg_temp.submit(target), 'duplicate resubmission returns existing result');
  perform pg_temp.check_true(pg_temp.snapshot(target) = before_value, 'duplicate non-consent submission leaves all records unchanged');

  perform pg_temp.expect_ok(pg_temp.review(target, 'start_review'), 'resubmitted review starts');
  perform pg_temp.expect_ok(pg_temp.review(target, 'reject', '架空の不許可理由'), 'rejection succeeds');
  perform pg_temp.check_true((select released_from = start_date from public.room_allocations where application_id = target), 'rejection retains allocation row but releases all days');
  perform pg_temp.check_true((select count(*) = 1 from public.audit_logs where entity_id = target and action = 'reject'
    and before_data #>> '{application,status}' = 'under_review'
    and after_data #>> '{application,status}' = 'rejected'
    and after_data #>> '{room_allocation,released_from}' is not null), 'rejection audit includes release');
  perform pg_temp.expect_ok(pg_temp.assign_room(extra, room), 'released room accepts another applicant');
  perform pg_temp.check_true((select deleted_at is null from public.camps where id = camp), 'rejection does not delete or open the camp period');
end;
$$;

-- 7. Draft entry, deadline failure paths, and the consent wrapper.
-- A draft must still be created/reused before the deadline, without submission
-- side effects. These calls exercise the public entry RPC, not fixture inserts.
do $$
declare
  camp uuid := pg_temp.fixture_camp();
  owner_id uuid := pg_temp.fixture_user();
  other_id uuid := pg_temp.fixture_user();
  target uuid;
  result jsonb;
  before_value jsonb;
begin
  insert into public.camp_eligible_users (camp_id, email_normalized)
  select camp, email from auth.users where id = owner_id;
  perform pg_temp.expect_error(pg_temp.call_as(null, format(
    'select public.create_camp_application_draft(%L::uuid)', camp
  ), 'anon'), 'permission denied for function create_camp_application_draft', 'anonymous draft entry is denied', '42501');
  perform pg_temp.expect_error(pg_temp.call_as(other_id, format(
    'select public.create_camp_application_draft(%L::uuid)', camp
  )), 'このキャンプの申請対象者ではありません。', 'draft entry still requires camp eligibility');
  update public.profiles set account_state = 'disabled' where id = owner_id;
  perform pg_temp.expect_error(pg_temp.call_as(owner_id, format(
    'select public.create_camp_application_draft(%L::uuid)', camp
  )), 'このアカウントでは申請できません。', 'disabled applicant cannot create a draft');
  update public.profiles set account_state = 'active' where id = owner_id;

  result := pg_temp.call_as(owner_id, format(
    'select public.create_camp_application_draft(%L::uuid)', camp
  ));
  perform pg_temp.expect_ok(result, 'draft entry succeeds before initial deadline');
  target := (result #>> '{rows,0,create_camp_application_draft}')::uuid;
  perform pg_temp.check_true((select a.user_id = owner_id and a.status = 'draft'
    and a.start_date = c.start_date and a.end_date = c.end_date
    from public.applications a join public.camps c on c.id = a.camp_id
    where a.id = target and c.id = camp), 'draft entry stores owner and fixed camp dates');
  perform pg_temp.check_true(not exists (select 1 from public.reception_numbers where application_id = target)
    and not exists (select 1 from public.application_charges where application_id = target)
    and not exists (select 1 from public.room_allocations where application_id = target)
    and not exists (select 1 from public.stays where application_id = target), 'draft entry creates no number, charge, allocation or stay');
  perform pg_temp.check_true((select count(*) = 1 from public.application_status_events
    where application_id = target and from_status is null and to_status = 'draft'
    and actor_user_id = owner_id), 'draft entry records its initial status event');
  before_value := pg_temp.snapshot(target);
  result := pg_temp.call_as(owner_id, format(
    'select public.create_camp_application_draft(%L::uuid)', camp
  ));
  perform pg_temp.expect_ok(result, 'repeated draft entry succeeds before deadline');
  perform pg_temp.check_true((result #>> '{rows,0,create_camp_application_draft}')::uuid = target
    and pg_temp.snapshot(target) = before_value, 'repeated draft entry reuses the same record without extra history');
end;
$$;

-- Exact clock_timestamp equality cannot be forced from an external connection.
-- Here a deadline set to the current instant must reject once the RPC runs;
-- the before/after deadline tests use a margin rather than a timing race.
do $$
declare
  camp uuid := pg_temp.fixture_camp();
  target uuid := pg_temp.fixture_application(camp, 'draft');
  fresh uuid;
  before_value jsonb;
  owner_id uuid := (select user_id from public.applications where id = target);
  new_owner_id uuid := pg_temp.fixture_user();
  today_japan date := (clock_timestamp() at time zone 'Asia/Tokyo')::date;
begin
  insert into public.camp_eligible_users (camp_id, email_normalized)
  select camp, email from auth.users where id = new_owner_id;
  update public.camps set application_deadline = clock_timestamp() where id = camp;
  before_value := pg_temp.snapshot(target);
  perform pg_temp.expect_error(pg_temp.submit(target), 'このキャンプの申請期限を過ぎています。', 'first submission at expired initial boundary rejected');
  perform pg_temp.check_true(pg_temp.snapshot(target) = before_value, 'late initial submission allocates no number or charge');
  perform pg_temp.expect_error(pg_temp.call_as(owner_id, format(
    'select public.create_camp_application_draft(%L::uuid)', camp
  )), 'このキャンプの申請期限を過ぎています。', 'new draft entry stays closed after initial deadline');
  perform pg_temp.check_true(pg_temp.snapshot(target) = before_value, 'expired draft entry preserves the existing draft');
  perform pg_temp.expect_error(pg_temp.call_as(new_owner_id, format(
    'select public.create_camp_application_draft(%L::uuid)', camp
  )), 'このキャンプの申請期限を過ぎています。', 'applicant without a draft cannot create one after deadline');
  perform pg_temp.check_true(not exists (select 1 from public.applications
    where camp_id = camp and user_id = new_owner_id), 'expired new draft entry creates no application');

  update public.applications set status = 'revision_requested', revision_due_at = clock_timestamp() where id = target;
  before_value := pg_temp.snapshot(target);
  perform pg_temp.expect_error(pg_temp.submit(target), '修正期限を過ぎています。', 'revision at expired revision boundary rejected');
  perform pg_temp.check_true(pg_temp.snapshot(target) = before_value, 'expired revision changes nothing');
  update public.applications set revision_due_at = null where id = target;
  perform pg_temp.expect_error(pg_temp.submit(target), '修正期限が設定されていません。町へお問い合わせください。', 'missing revision deadline is not unlimited');
  update public.applications set revision_due_at = clock_timestamp() + interval '1 hour' where id = target;
  update public.camps set end_date = end_date + 1 where id = camp;
  before_value := pg_temp.snapshot(target);
  perform pg_temp.expect_error(pg_temp.submit(target), 'キャンプ期間が変更されているため再提出できません。町へお問い合わせください。', 'correction refuses changed camp dates');
  perform pg_temp.check_true(pg_temp.snapshot(target) = before_value, 'changed-date correction preserves original submission');

  camp := pg_temp.fixture_camp();
  target := pg_temp.fixture_application(camp, 'draft', true);
  before_value := pg_temp.snapshot(target);
  perform pg_temp.expect_error(pg_temp.submit(target), '保護者同意書を添付してください。', 'consent metadata still required');
  perform pg_temp.check_true(pg_temp.snapshot(target) = before_value, 'missing consent changes no flags or records');
  -- This tests metadata enforcement only, NOT Storage upload or file validity.
  insert into public.consent_documents (application_id, object_path, mime_type, size_bytes)
  values (target, 'applications/' || target::text || '/' || gen_random_uuid()::text, 'application/pdf', 100);
  perform pg_temp.expect_ok(pg_temp.submit(target), 'consent metadata permits initial submission');
  perform pg_temp.expect_ok(pg_temp.review(target, 'start_review'), 'consent fixture review starts');
  perform pg_temp.expect_ok(pg_temp.review(target, 'request_revision', '架空の同意書修正依頼'), 'consent fixture revision requested');
  update public.camps set application_deadline = transaction_timestamp() - interval '1 second' where id = camp;
  before_value := pg_temp.snapshot(target) -> 'number';
  perform pg_temp.expect_ok(pg_temp.submit(target), 'consent-required correction succeeds after initial deadline');
  perform pg_temp.check_true((select requires_guardian_consent from public.applications where id = target), 'consent wrapper restores required flag');
  perform pg_temp.check_true((pg_temp.snapshot(target) -> 'number') = before_value, 'consent correction retains reception number');
  perform pg_temp.expect_ok(pg_temp.review(target, 'start_review'), 'consent fixture second review starts');
  perform pg_temp.expect_ok(pg_temp.review(target, 'request_revision', '架空の再修正依頼'), 'consent fixture second revision requested');
  delete from public.consent_documents where application_id = target;
  before_value := pg_temp.snapshot(target);
  perform pg_temp.expect_error(pg_temp.submit(target), '保護者同意書を添付してください。', 'correction cannot bypass missing consent');
  perform pg_temp.check_true(pg_temp.snapshot(target) = before_value, 'failed consent correction preserves state and required flag');

  camp := pg_temp.fixture_camp(today_japan + 1, today_japan + 2);
  fresh := pg_temp.fixture_application(camp);
  perform pg_temp.expect_ok(pg_temp.review(fresh, 'request_revision', '利用開始日前の架空修正'), 'revision request near start succeeds');
  perform pg_temp.check_true((select revision_due_at = ((today_japan + 1)::timestamp at time zone 'Asia/Tokyo')
    from public.applications where id = fresh), 'revision deadline capped at camp start in Japan');
  camp := pg_temp.fixture_camp(today_japan, today_japan + 1);
  fresh := pg_temp.fixture_application(camp);
  perform pg_temp.expect_error(pg_temp.review(fresh, 'request_revision', '開始後の架空修正'), 'start-date-passed', 'revision request after Japan start boundary rejected');
end;
$$;

-- 8. Force the final audit write to fail after the RPC has changed its other
-- records. This trigger and function are test-only and rolled back at the end.
create function pg_temp.fail_target_audit()
returns trigger language plpgsql as $$
begin
  if new.entity_id::text = current_setting('test.fail_audit_for', true) then
    raise exception using message = 'test-audit-write-failed';
  end if;
  return new;
end;
$$;
create trigger t12_regression_fail_audit
before insert on public.audit_logs
for each row execute function pg_temp.fail_target_audit();

do $$
declare
  target uuid := pg_temp.fixture_application(pg_temp.fixture_camp());
  room uuid := (select id from public.rooms where name = '桐');
  before_value jsonb;
begin
  before_value := pg_temp.snapshot(target);
  perform set_config('test.fail_audit_for', target::text, true);
  perform pg_temp.expect_error(pg_temp.assign_room(target, room), 'test-audit-write-failed', 'forced audit failure rejects assignment');
  perform pg_temp.check_true(pg_temp.snapshot(target) = before_value, 'audit failure rolls back room and parent version');
  perform set_config('test.fail_audit_for', '', true);
  perform pg_temp.expect_ok(pg_temp.assign_room(target, room), 'assignment succeeds after removing forced failure');
  before_value := pg_temp.snapshot(target);
  perform set_config('test.fail_audit_for', target::text, true);
  perform pg_temp.expect_error(pg_temp.review(target, 'approve'), 'test-audit-write-failed', 'forced audit failure rejects approval');
  perform pg_temp.check_true(pg_temp.snapshot(target) = before_value, 'audit failure rolls back approval, stay and public event');
  perform set_config('test.fail_audit_for', '', true);
end;
$$;

select test_no, test_name, passed from pg_temp.test_results order by test_no;
select count(*) as passed_checks, 'Single connection only; all fixtures are rolled back.' as scope
from pg_temp.test_results;
rollback;

-- Multi-connection follow-up (NOT executed or proven by this file):
-- A separate executable harness is camp_room_allocations_concurrency.sql.
-- Read its setup/worker/cleanup instructions; it commits fictional fixtures.
-- Use an isolated test database with committed fictional fixtures and two real
-- connections. Temporary tables from this file are not shared across sessions.
-- 1. Both staff connections read two under_review applications' updated_at.
--    A begins, assigns the final available room place and leaves its transaction
--    open. B begins and requests the same place for the other application. B must
--    wait. After A COMMITs, B must fail room-capacity-full; then B ROLLBACKs.
--    Check one allocation and its audit, with no B-side partial writes.
-- 2. Both read the SAME application's updated_at. A changes its room, then
--    COMMITs; B's pending approval/change must fail stale-update. Check no extra
--    stay, approval event or audit. Also repeat with B under REPEATABLE READ:
--    an old snapshot must fail with SQLSTATE 40001 (serialization failure)
--    rather than necessarily the application-level stale-update message.
-- 3. A holds facility_guard, while B attempts a correction just before its
--    revision_due_at. Release A only after the deadline. B must reject the
--    correction, without changing receipt, charge, application or history.
-- In case 1, rolling A back would let B succeed; that is not evidence of a bug.
-- Clean up only those separately prepared fictional fixtures after confirming
-- results. This script never commits shared fixtures or configures dblink.
