-- T09 single-connection regression, Supabase TEST project, postgres role.
-- Requires 001-013. Fictional records only; run the WHOLE file without traffic.
-- Final ROLLBACK removes fixtures and failure-injection triggers. On failure,
-- issue ROLLBACK in the same connection before retrying. No Auth/Storage API.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '60s';
set local timezone = 'UTC';
do $$ begin
  if current_user <> 'postgres' or to_regprocedure('public.get_public_calendar(date)') is null then
    raise exception 'Run as postgres after migrations 001-012 in a test project.';
  end if;
end; $$;

create temporary table t09_results (test_no integer generated always as identity, test_name text, passed boolean) on commit drop;
create temporary table t09_context (staff_id uuid, user_id uuid, disabled_id uuid, base_date date, today date) on commit drop;

create function pg_temp.t09_check(ok boolean, label text)
returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %', label; end if;
  insert into pg_temp.t09_results(test_name, passed) values(label, true);
end; $$;

create function pg_temp.t09_user(kind text)
returns uuid language plpgsql as $$ declare uid uuid := gen_random_uuid(); begin
  insert into auth.users(id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values(uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    't09-' || uid::text || '@example.invalid', '', clock_timestamp(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, clock_timestamp(), clock_timestamp());
  if kind in ('staff', 'disabled') then insert into public.staff_roles(user_id) values(uid); end if;
  if kind = 'disabled' then update public.profiles set account_state = 'disabled' where id = uid; end if;
  return uid;
end; $$;

insert into pg_temp.t09_context select pg_temp.t09_user('staff'), pg_temp.t09_user('user'), pg_temp.t09_user('disabled'),
  greatest((clock_timestamp() at time zone 'Asia/Tokyo')::date + 100,
    (select max(end_date) + 30 from public.camps), (select max(end_date) + 30 from public.blocked_periods),
    (select max(end_date) + 30 from public.applications)),
  (clock_timestamp() at time zone 'Asia/Tokyo')::date;

create function pg_temp.t09_call(actor uuid, query_text text)
returns jsonb language plpgsql security invoker as $$
declare row_value record; rows_value jsonb := '[]'::jsonb; result_value jsonb;
  state_value text; message_value text; detail_value text;
  previous_sub text := coalesce(current_setting('request.jwt.claim.sub', true), '');
  previous_email text := coalesce(current_setting('request.jwt.claim.email', true), '');
  previous_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  actor_email text := (select email from auth.users where id = actor);
begin
  begin
    if actor is null then set local role anon; else set local role authenticated; end if;
    perform set_config('request.jwt.claim.sub', coalesce(actor::text, ''), true);
    perform set_config('request.jwt.claim.email', coalesce(actor_email, ''), true);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', actor, 'email', actor_email,
      'role', case when actor is null then 'anon' else 'authenticated' end)::text, true);
    for row_value in execute query_text loop rows_value := rows_value || jsonb_build_array(to_jsonb(row_value)); end loop;
    result_value := jsonb_build_object('ok', true, 'rows', rows_value);
  exception when others then
    get stacked diagnostics state_value = returned_sqlstate, message_value = message_text, detail_value = pg_exception_detail;
    result_value := jsonb_build_object('ok', false, 'sqlstate', state_value, 'message', message_value, 'details', detail_value);
  end;
  set local role postgres;
  perform set_config('request.jwt.claim.sub', previous_sub, true);
  perform set_config('request.jwt.claim.email', previous_email, true);
  perform set_config('request.jwt.claims', previous_claims, true);
  return result_value;
end; $$;

create function pg_temp.t09_ok(result_value jsonb)
returns jsonb language plpgsql as $$ begin
  if result_value ->> 'ok' is distinct from 'true' then raise exception 'FAIL RPC: %', result_value; end if;
  return result_value -> 'rows';
end; $$;

create function pg_temp.t09_error(result_value jsonb, expected_message text, label text, expected_state text default 'P0001')
returns void language plpgsql as $$ begin
  perform pg_temp.t09_check(result_value ->> 'ok' = 'false' and result_value ->> 'sqlstate' = expected_state
    and (expected_message is null or result_value ->> 'message' = expected_message), label || ': ' || result_value::text);
end; $$;

create function pg_temp.t09_camp(starts_on date, ends_on date)
returns uuid language plpgsql as $$ declare rows_value jsonb; begin
  rows_value := pg_temp.t09_ok(pg_temp.t09_call((select staff_id from pg_temp.t09_context), format(
    'select public.create_staff_camp(%L,%L::date,%L::date,%L::timestamptz)',
    'T09 fictional camp', starts_on, ends_on, (starts_on::timestamp at time zone 'Asia/Tokyo') - interval '1 day')));
  return (rows_value #>> '{0,create_staff_camp}')::uuid;
end; $$;

create function pg_temp.t09_block(starts_on date, ends_on date)
returns uuid language plpgsql as $$ declare rows_value jsonb; begin
  rows_value := pg_temp.t09_ok(pg_temp.t09_call((select staff_id from pg_temp.t09_context), format(
    'select * from public.save_staff_blocked_period(null,%L::date,%L::date,%L)', starts_on, ends_on, 'T09 fictional maintenance')));
  return (rows_value #>> '{0,result_id}')::uuid;
end; $$;

create function pg_temp.t09_update_camp(target_id uuid, starts_on date, ends_on date, reason_value text default 'T09 fictional change')
returns jsonb language plpgsql as $$ declare c public.camps%rowtype; begin
  select * into strict c from public.camps where id = target_id;
  return pg_temp.t09_call((select staff_id from pg_temp.t09_context), format(
    'select * from public.update_staff_camp(%L::uuid,%L,%L::date,%L::date,%L::timestamptz,%L::timestamptz,%L)',
    c.id, c.name, starts_on, ends_on, c.application_deadline, c.updated_at, reason_value));
end; $$;

do $$
declare ctx pg_temp.t09_context%rowtype; c uuid; b uuid; adjacent uuid; row_value jsonb; baseline jsonb;
  before_value jsonb; old_version timestamptz; count_before bigint; shifted_date date;
begin
  select * into strict ctx from pg_temp.t09_context;
  perform pg_temp.t09_check(isfinite(ctx.base_date), 'finite fixture dates');
  c := pg_temp.t09_camp(ctx.base_date, ctx.base_date + 2);
  perform pg_temp.t09_check((select count(*) = 1 from public.calendar_claims where camp_id = c
    and claim_type = 'camp' and start_date = ctx.base_date and end_date = ctx.base_date + 2
    and released_from is null), 'camp creates exactly one full-period claim');
  perform pg_temp.t09_check((select count(*) = 1 from public.audit_logs where entity_id = c
    and action = 'create_camp' and actor_user_id = ctx.staff_id and before_data = '{}'::jsonb), 'camp creation audit');
  b := pg_temp.t09_block(ctx.base_date + 10, ctx.base_date + 12);
  perform pg_temp.t09_check((select count(*) = 1 from public.calendar_claims where blocked_period_id = b), 'block creates one claim');
  perform pg_temp.t09_check((select count(*) = 1 from public.audit_logs where entity_id = b and action = 'create_blocked_period'), 'block creation audit');

  for shifted_date in select d from unnest(array[ctx.base_date - 1, ctx.base_date, ctx.base_date + 2]) d loop
    perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, format(
      'select * from public.save_staff_blocked_period(null,%L::date,%L::date,%L)', shifted_date, shifted_date + 1, 'T09 conflict')),
      'date-conflict', 'camp/blocked inclusive overlap');
  end loop;
  perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, format(
    'select public.create_staff_camp(%L,%L::date,%L::date,%L::timestamptz)', 'T09 overlap', ctx.base_date + 12,
    ctx.base_date + 13, (ctx.base_date::timestamp at time zone 'Asia/Tokyo') - interval '1 day')),
    'date-conflict', 'blocked/camp reverse overlap');
  perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, format(
    'select * from public.save_staff_blocked_period(null,%L::date,%L::date,%L)', ctx.base_date + 12, ctx.base_date + 14, 'T09 overlap')),
    'date-conflict', 'blocked/blocked overlap');
  adjacent := pg_temp.t09_block(ctx.base_date + 13, ctx.base_date + 14);
  perform pg_temp.t09_check(adjacent is not null, 'day after inclusive end is available');

  perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, 'select * from public.save_staff_blocked_period(null,null,null,''x'')'), 'invalid-period', 'null dates');
  perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, 'select * from public.save_staff_blocked_period(null,''infinity'',''infinity'',''x'')'), 'invalid-period', 'infinite dates');
  perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, 'select * from public.save_staff_blocked_period(null,''2028-03-02'',''2028-03-01'',''x'')'), 'invalid-period', 'reverse dates');
  perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, 'select * from public.save_staff_blocked_period(null,''2028-03-01'',''2028-03-02'','' '')'), 'reason-required', 'blank internal reason');
  perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, 'select * from public.save_staff_blocked_period(null,''2028-03-01'',''2028-03-02'',repeat(''x'',2001))'), 'reason-too-long', 'long internal reason');
  perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, format(
    'select public.create_staff_camp(''T09 bad deadline'',%L::date,%L::date,%L::timestamptz)', ctx.base_date + 30,
    ctx.base_date + 32, ((ctx.base_date + 30)::timestamp at time zone 'Asia/Tokyo') + interval '1 microsecond')),
    'invalid-deadline', 'deadline cannot exceed camp start midnight');

  before_value := private.calendar_snapshot('blocked', b);
  select updated_at into old_version from public.blocked_periods where id = b;
  select count(*) into count_before from public.audit_logs where entity_id = b;
  row_value := pg_temp.t09_ok(pg_temp.t09_call(ctx.staff_id, format(
    'select * from public.save_staff_blocked_period(%L::uuid,%L::date,%L::date,%L,%L::timestamptz)',
    b, ctx.base_date + 10, ctx.base_date + 12, 'T09 fictional maintenance', old_version)));
  perform pg_temp.t09_check((row_value #>> '{0,result_updated_at}')::timestamptz = old_version, 'same block returns same version');
  perform pg_temp.t09_check(private.calendar_snapshot('blocked', b) = before_value
    and (select count(*) = count_before from public.audit_logs where entity_id = b), 'same block has no writes/history');
  perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, format(
    'select * from public.save_staff_blocked_period(%L::uuid,%L::date,%L::date,%L,%L::timestamptz)',
    b, ctx.base_date + 10, ctx.base_date + 11, 'T09 changed', old_version)), 'reason-required', 'update requires reason');
  perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, format(
    'select * from public.delete_staff_blocked_period(%L::uuid,null,''x'')', b)), 'invalid-version', 'missing version');
  perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, format(
    'select * from public.delete_staff_blocked_period(%L::uuid,%L::timestamptz,''x'')', b, old_version + interval '1 microsecond')),
    'stale-update', 'microsecond-only mismatch');
  perform pg_temp.t09_ok(pg_temp.t09_call(ctx.staff_id, format(
    'select * from public.save_staff_blocked_period(%L::uuid,%L::date,%L::date,%L,%L::timestamptz,''T09 reason'')',
    b, ctx.base_date + 10, ctx.base_date + 11, 'T09 changed', old_version)));
  perform pg_temp.t09_check((select updated_at > old_version from public.blocked_periods where id = b), 'block version advances within one transaction');
  perform pg_temp.t09_check((select end_date = ctx.base_date + 11 from public.calendar_claims where blocked_period_id = b), 'edited block and claim agree');
  perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, format(
    'select * from public.delete_staff_blocked_period(%L::uuid,%L::timestamptz,''T09 reason'')', b, old_version)),
    'stale-update', 'stale delete rejected');
  select updated_at into old_version from public.blocked_periods where id = b;
  perform pg_temp.t09_ok(pg_temp.t09_call(ctx.staff_id, format(
    'select * from public.delete_staff_blocked_period(%L::uuid,%L::timestamptz,''T09 reason'')', b, old_version)));
  perform pg_temp.t09_check((select deleted_at is not null from public.blocked_periods where id = b), 'block deletion retains source');
  perform pg_temp.t09_check((select released_from = start_date from public.calendar_claims where blocked_period_id = b), 'block deletion releases all days');
  perform pg_temp.t09_check((select count(*) = 3 from public.audit_logs where entity_id = b), 'create/change/delete audit retained');
  perform pg_temp.t09_check(pg_temp.t09_block(ctx.base_date + 10, ctx.base_date + 11) is not null, 'deleted block period can be reused');

  -- Public reads have a fixed two-column shape, including for staff callers.
  row_value := pg_temp.t09_ok(pg_temp.t09_call(null, 'select * from public.get_public_calendar(''2028-02-01'')'));
  perform pg_temp.t09_check(jsonb_array_length(row_value) = 29, 'leap February has 29 days');
  perform pg_temp.t09_check(not exists(select 1 from jsonb_array_elements(row_value) r
    where (select count(*) from jsonb_object_keys(r)) <> 2 or not (r ? 'date' and r ? 'availability')),
    'public response has only date and availability');
  row_value := pg_temp.t09_ok(pg_temp.t09_call(null, 'select * from public.get_public_calendar(''2100-02-01'')'));
  perform pg_temp.t09_check(jsonb_array_length(row_value) = 28, 'century non-leap February');
  row_value := pg_temp.t09_ok(pg_temp.t09_call(null, 'select * from public.get_public_calendar(''9999-12-01'')'));
  perform pg_temp.t09_check(jsonb_array_length(row_value) = 31, 'upper calendar year December');
  perform pg_temp.t09_error(pg_temp.t09_call(null, 'select * from public.get_public_calendar(''2028-02-02'')'), 'invalid-month', 'non-first month date');
  perform pg_temp.t09_error(pg_temp.t09_call(null, 'select * from public.get_public_calendar(''infinity'')'), 'invalid-month', 'infinite month');
  perform pg_temp.t09_error(pg_temp.t09_call(null, 'select * from public.get_public_calendar(null)'), 'invalid-month', 'null month');
  for shifted_date in select d from unnest(array[ctx.today + 13, ctx.today + 14, ctx.today + 60, ctx.today + 61]) d loop
    row_value := pg_temp.t09_ok(pg_temp.t09_call(null, format(
      'select * from public.get_public_calendar(%L::date) where date = %L::date', date_trunc('month', shifted_date)::date, shifted_date)));
    perform pg_temp.t09_check(row_value #>> '{0,availability}' = case
      when shifted_date > ctx.today + 60 then 'not_yet_open'
      when shifted_date < ctx.today + 14 then 'unavailable'
      when exists(select 1 from public.calendar_claims q where q.claim_type in ('camp','blocked') and shifted_date between q.start_date and q.end_date
        and (q.released_from is null or shifted_date < q.released_from)) or private.community_occupancy(shifted_date)>=15 then 'unavailable'
      else 'available' end, 'JST boundary ' || (shifted_date - ctx.today)::text);
  end loop;
  baseline := pg_temp.t09_ok(pg_temp.t09_call(null, format('select * from public.get_public_calendar(%L::date)', date_trunc('month', ctx.today + 20)::date)));
  perform set_config('timezone', 'America/Los_Angeles', true);
  row_value := pg_temp.t09_ok(pg_temp.t09_call(null, format('select * from public.get_public_calendar(%L::date)', date_trunc('month', ctx.today + 20)::date)));
  perform pg_temp.t09_check(row_value = baseline, 'public calendar independent of session timezone');
  perform set_config('timezone', 'UTC', true);
  -- An admin fixture may overlap other test-project records; it is not a valid RPC write.
  insert into public.blocked_periods(start_date, end_date, internal_reason)
  values(ctx.today + 20, ctx.today + 20, 'T09 private reason') returning id into b;
  row_value := pg_temp.t09_ok(pg_temp.t09_call(null, format(
    'select * from public.get_public_calendar(%L::date) where date = %L::date', date_trunc('month', ctx.today + 20)::date, ctx.today + 20)));
  perform pg_temp.t09_check(row_value #>> '{0,availability}' = 'unavailable' and position('T09 private' in row_value::text) = 0,
    'blocked public day hides its reason');
  select updated_at into old_version from public.blocked_periods where id = b;
  perform pg_temp.t09_ok(pg_temp.t09_call(ctx.staff_id, format(
    'select * from public.delete_staff_blocked_period(%L::uuid,%L::timestamptz,''T09 reason'')', b, old_version)));
  row_value := pg_temp.t09_ok(pg_temp.t09_call(null, format('select * from public.get_public_calendar(%L::date)', date_trunc('month', ctx.today + 20)::date)));
  perform pg_temp.t09_check(row_value = baseline, 'deletion restores prior public availability');
  count_before := (select count(*) from public.audit_logs);
  perform pg_temp.t09_ok(pg_temp.t09_call(ctx.staff_id, format('select * from public.get_staff_calendar(%L::date)', date_trunc('month', ctx.base_date)::date)));
  row_value := pg_temp.t09_ok(pg_temp.t09_call(ctx.staff_id, format('select * from public.get_staff_calendar_day(%L::date)', ctx.base_date)));
  perform pg_temp.t09_check(exists(select 1 from jsonb_array_elements(row_value) r where r ->> 'entry_id' = c::text), 'staff sees camp day entry');
  perform pg_temp.t09_check((select count(*) = count_before from public.audit_logs), 'calendar reads append no audit');
end;
$$;

do $$
declare ctx pg_temp.t09_context%rowtype; actor uuid; query_text text; rows_value jsonb;
begin
  select * into strict ctx from pg_temp.t09_context;
  foreach actor in array array[null::uuid, ctx.user_id, ctx.disabled_id] loop
    foreach query_text in array array[
      'select * from public.get_staff_calendar(''2030-01-01'')',
      'select * from public.get_staff_calendar_day(''2030-01-01'')',
      'select public.create_staff_camp(''x'',''2030-01-01'',''2030-01-02'',''2029-12-31T00:00:00+09:00'')',
      'select * from public.save_staff_blocked_period(null,''2030-01-01'',''2030-01-02'',''x'')',
      'select * from public.delete_staff_blocked_period(gen_random_uuid(),clock_timestamp(),''x'')',
      'select * from public.delete_staff_camp(gen_random_uuid(),clock_timestamp(),''x'')',
      'select * from public.update_staff_camp(gen_random_uuid(),''x'',''2030-01-01'',''2030-01-02'',''2029-12-31'',clock_timestamp(),''x'')'
    ] loop
      perform pg_temp.t09_error(pg_temp.t09_call(actor, query_text), null, 'unauthorized staff RPC', '42501');
    end loop;
  end loop;
  foreach actor in array array[ctx.user_id, ctx.disabled_id] loop
    foreach query_text in array array['select * from public.calendar_claims', 'select * from public.blocked_periods', 'select * from public.audit_logs'] loop
      rows_value := pg_temp.t09_ok(pg_temp.t09_call(actor, query_text));
      perform pg_temp.t09_check(rows_value = '[]'::jsonb, 'RLS hides calendar/internal records');
    end loop;
  end loop;
  foreach query_text in array array[
    'select * from public.calendar_claims', 'select * from public.blocked_periods',
    'select private.lock_calendar_facility()', 'select private.calendar_snapshot(''camp'',gen_random_uuid())'
  ] loop
    perform pg_temp.t09_error(pg_temp.t09_call(null, query_text), null, 'anonymous direct/internal read denied', '42501');
  end loop;
  foreach query_text in array array[
    'insert into public.blocked_periods(start_date,end_date,internal_reason) values(''2030-01-01'',''2030-01-02'',''x'') returning id',
    'update public.camps set deleted_at = clock_timestamp() returning id', 'delete from public.calendar_claims returning id',
    'update public.calendar_claims set released_from = start_date returning id',
    'insert into public.calendar_claims(claim_type,start_date,end_date) values(''camp'',''2030-01-01'',''2030-01-02'') returning id',
    'select private.lock_calendar_facility()'
  ] loop
    perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, query_text), null, 'even staff cannot directly write or call internal helpers', '42501');
  end loop;
end;
$$;

do $$
declare ctx pg_temp.t09_context%rowtype; c uuid; draft_id uuid; c_deleted uuid; d_deleted uuid;
  rows_value jsonb; result_value jsonb; old_version timestamptz; before_value jsonb; count_before bigint;
begin
  select * into strict ctx from pg_temp.t09_context;
  c := pg_temp.t09_camp(ctx.base_date + 40, ctx.base_date + 42);
  perform pg_temp.t09_ok(pg_temp.t09_call(ctx.staff_id, format('select public.add_camp_eligible_users(%L::uuid,array[%L])',
    c, (select email from auth.users where id = ctx.user_id))));
  rows_value := pg_temp.t09_ok(pg_temp.t09_call(ctx.user_id, format('select public.create_camp_application_draft(%L::uuid)', c)));
  draft_id := (rows_value #>> '{0,create_camp_application_draft}')::uuid;
  select updated_at into old_version from public.applications where id = draft_id;
  perform pg_temp.t09_ok(pg_temp.t09_update_camp(c, ctx.base_date + 41, ctx.base_date + 43));
  perform pg_temp.t09_check((select start_date = ctx.base_date + 41 and end_date = ctx.base_date + 43
    and updated_at > old_version and status = 'draft' from public.applications where id = draft_id), 'camp change updates draft dates and version');
  perform pg_temp.t09_check((select start_date = ctx.base_date + 41 and end_date = ctx.base_date + 43
    from public.calendar_claims where camp_id = c), 'camp edit synchronizes its claim');
  perform pg_temp.t09_check(not exists(select 1 from public.reception_numbers where application_id = draft_id)
    and not exists(select 1 from public.application_charges where application_id = draft_id)
    and not exists(select 1 from public.room_allocations where application_id = draft_id), 'draft reschedule reserves no personal place/charge/number');
  perform pg_temp.t09_check((select count(*) = 1 from public.audit_logs where entity_id = draft_id and action = 'camp_dates_changed'), 'draft date synchronization audited');
  before_value := private.calendar_snapshot('camp', c);
  perform pg_temp.t09_error(pg_temp.t09_update_camp(c, ctx.base_date + 42, ctx.base_date + 44, null), 'reason-required', 'camp edit requires reason');
  perform pg_temp.t09_check(private.calendar_snapshot('camp', c) = before_value, 'failed camp edit preserves camp and claim');
  count_before := (select count(*) from public.audit_logs where entity_id = c);
  perform pg_temp.t09_ok(pg_temp.t09_update_camp(c, ctx.base_date + 41, ctx.base_date + 43, null));
  perform pg_temp.t09_check(private.calendar_snapshot('camp', c) = before_value
    and (select count(*) = count_before from public.audit_logs where entity_id = c), 'same camp save no-op');

  perform pg_temp.t09_ok(pg_temp.t09_call(ctx.user_id, format(
    'select public.save_camp_application_draft(%L::uuid,''架空利用者'',''架空住所'',''000-0000-0000'',''架空連絡先'',''架空住所'',''000-0000-0000'',''架空キャンプ'',null,false,''shared_ok'')', draft_id)));
  perform pg_temp.t09_ok(pg_temp.t09_call(ctx.user_id, format('select * from public.submit_camp_application(%L::uuid)', draft_id)));
  result_value := pg_temp.t09_update_camp(c, ctx.base_date + 42, ctx.base_date + 44);
  perform pg_temp.t09_error(result_value, 'camp-has-applications', 'submitted application prevents camp date change');
  perform pg_temp.t09_check(exists(select 1 from jsonb_array_elements((result_value ->> 'details')::jsonb) r
    where r ->> 'id' = draft_id::text and r ->> 'receptionNumber' is not null), 'staff conflict contains application and receipt');
  select updated_at into old_version from public.camps where id = c;
  perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, format(
    'select * from public.delete_staff_camp(%L::uuid,%L::timestamptz,''T09 delete'')', c, old_version)),
    'camp-has-applications', 'submitted application prevents camp deletion');
  rows_value := pg_temp.t09_ok(pg_temp.t09_call(ctx.staff_id, format('select * from public.get_staff_calendar_day(%L::date)', ctx.base_date + 42)));
  perform pg_temp.t09_check(exists(select 1 from jsonb_array_elements(rows_value) r where r ->> 'entry_id' = draft_id::text
    and r ->> 'reception_number' is not null and r ->> 'people_count' = '1'), 'staff day includes application summary');
  perform pg_temp.t09_check(not exists(select 1 from jsonb_array_elements(rows_value) r where r ? 'user_address'
    or r ? 'user_phone' or r ? 'email_snapshot' or r ? 'emergency_name'), 'staff calendar omits detailed personal fields');
  perform pg_temp.t09_check((select count(*) = 1 from public.calendar_claims where camp_id = c), 'submission does not create a second calendar claim');

  before_value := (select to_jsonb(a) from public.applications a where id = draft_id);
  perform pg_temp.t09_ok(pg_temp.t09_call(ctx.staff_id, format(
    'select * from public.update_staff_camp(%L::uuid,''T09 renamed'',%L::date,%L::date,%L::timestamptz,%L::timestamptz,''期限延長'')',
    c, ctx.base_date + 41, ctx.base_date + 43,
    ((ctx.base_date + 41)::timestamp at time zone 'Asia/Tokyo'), old_version)));
  perform pg_temp.t09_check((select to_jsonb(a) = before_value from public.applications a where id = draft_id),
    'camp name/deadline edit leaves submitted application unchanged');
  perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, format(
    'select * from public.delete_staff_camp(%L::uuid,%L::timestamptz,''T09 stale'')', c, old_version)),
    'stale-update', 'old camp version rejected after name/deadline edit');

  -- Deleted camps retain drafts/history, but no new draft/submit/eligibility write.
  c_deleted := pg_temp.t09_camp(ctx.base_date + 50, ctx.base_date + 52);
  perform pg_temp.t09_ok(pg_temp.t09_call(ctx.staff_id, format('select public.add_camp_eligible_users(%L::uuid,array[%L])',
    c_deleted, (select email from auth.users where id = ctx.user_id))));
  rows_value := pg_temp.t09_ok(pg_temp.t09_call(ctx.user_id, format('select public.create_camp_application_draft(%L::uuid)', c_deleted)));
  d_deleted := (rows_value #>> '{0,create_camp_application_draft}')::uuid;
  select updated_at into old_version from public.camps where id = c_deleted;
  perform pg_temp.t09_ok(pg_temp.t09_call(ctx.staff_id, format('select * from public.delete_staff_camp(%L::uuid,%L::timestamptz,''T09 delete'')', c_deleted, old_version)));
  perform pg_temp.t09_check((select released_from = start_date from public.calendar_claims where camp_id = c_deleted), 'deleted camp releases its claim');
  perform pg_temp.t09_check(exists(select 1 from public.applications where id = d_deleted), 'deleted camp retains draft');
  rows_value := pg_temp.t09_ok(pg_temp.t09_call(ctx.staff_id, format('select id from public.camps where id = %L::uuid', c_deleted)));
  perform pg_temp.t09_check(jsonb_array_length(rows_value) = 1, 'staff can read deleted camp history');
  rows_value := pg_temp.t09_ok(pg_temp.t09_call(ctx.user_id, format('select id from public.camps where id = %L::uuid', c_deleted)));
  perform pg_temp.t09_check(rows_value = '[]'::jsonb, 'eligible user cannot read deleted camp');
  perform pg_temp.t09_error(pg_temp.t09_call(ctx.user_id, format('select public.create_camp_application_draft(%L::uuid)', c_deleted)),
    '対象のキャンプが見つかりません。', 'deleted camp draft entry rejected');
  perform pg_temp.t09_error(pg_temp.t09_call(ctx.user_id, format('select * from public.submit_camp_application(%L::uuid)', d_deleted)),
    '対象のキャンプが見つかりません。', 'deleted camp submission rejected');
  perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, format('select public.add_camp_eligible_users(%L::uuid,array[''t09@example.invalid''])', c_deleted)),
    '対象のキャンプが見つかりません。', 'deleted camp eligibility rejected');
end;
$$;

-- Failure injection checks include claims, source records, drafts and audits.
create temporary table t09_rollback_target on commit drop as
select pg_temp.t09_camp(base_date + 60, base_date + 62) as camp_id from pg_temp.t09_context;
do $$
declare ctx pg_temp.t09_context%rowtype; target_id uuid := (select camp_id from pg_temp.t09_rollback_target);
begin
  select * into strict ctx from pg_temp.t09_context;
  perform pg_temp.t09_ok(pg_temp.t09_call(ctx.staff_id, format('select public.add_camp_eligible_users(%L::uuid,array[%L])',
    target_id, (select email from auth.users where id = ctx.user_id))));
  perform pg_temp.t09_ok(pg_temp.t09_call(ctx.user_id, format('select public.create_camp_application_draft(%L::uuid)', target_id)));
end; $$;
create function pg_temp.t09_fail_audit() returns trigger language plpgsql as $$ begin
  if new.entity_type in ('camp', 'blocked') then raise exception 't09-audit-failure'; end if;
  return new;
end; $$;
create trigger t09_fail_audit before insert on public.audit_logs for each row execute function pg_temp.t09_fail_audit();
do $$
declare ctx pg_temp.t09_context%rowtype; count_sources bigint; count_claims bigint; count_audits bigint;
  target_id uuid := (select camp_id from pg_temp.t09_rollback_target); camp_before jsonb; draft_before jsonb;
begin
  select * into strict ctx from pg_temp.t09_context;
  select count(*) into count_sources from public.blocked_periods;
  select count(*) into count_claims from public.calendar_claims;
  select count(*) into count_audits from public.audit_logs;
  perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, format(
    'select * from public.save_staff_blocked_period(null,%L::date,%L::date,''T09 rollback'')', ctx.base_date + 70, ctx.base_date + 72)),
    't09-audit-failure', 'audit insertion failure is propagated');
  perform pg_temp.t09_check((select count(*) = count_sources from public.blocked_periods)
    and (select count(*) = count_claims from public.calendar_claims)
    and (select count(*) = count_audits from public.audit_logs), 'audit failure rolls back source and claim');
  camp_before := private.calendar_snapshot('camp', target_id);
  select to_jsonb(a) into strict draft_before from public.applications a where camp_id = target_id;
  perform pg_temp.t09_error(pg_temp.t09_update_camp(target_id, ctx.base_date + 61, ctx.base_date + 63),
    't09-audit-failure', 'final camp audit failure is propagated after draft sync');
  perform pg_temp.t09_check(private.calendar_snapshot('camp', target_id) = camp_before
    and (select to_jsonb(a) = draft_before from public.applications a where camp_id = target_id)
    and (select count(*) = count_audits from public.audit_logs), 'final audit failure rolls back camp, claim, draft version and draft audit');
end; $$;
drop trigger t09_fail_audit on public.audit_logs;

create function pg_temp.t09_fail_claim() returns trigger language plpgsql as $$ begin raise exception 't09-claim-failure'; end; $$;
create trigger t09_fail_claim before insert on public.calendar_claims for each row execute function pg_temp.t09_fail_claim();
do $$
declare ctx pg_temp.t09_context%rowtype; source_count bigint; audit_count bigint;
begin
  select * into strict ctx from pg_temp.t09_context;
  select count(*) into source_count from public.camps;
  select count(*) into audit_count from public.audit_logs;
  perform pg_temp.t09_error(pg_temp.t09_call(ctx.staff_id, format(
    'select public.create_staff_camp(''T09 rollback'',%L::date,%L::date,%L::timestamptz)',
    ctx.base_date + 80, ctx.base_date + 82, (ctx.base_date::timestamp at time zone 'Asia/Tokyo'))),
    't09-claim-failure', 'claim insertion failure is propagated');
  perform pg_temp.t09_check((select count(*) = source_count from public.camps)
    and (select count(*) = audit_count from public.audit_logs), 'claim failure rolls back camp and audit');
end; $$;
drop trigger t09_fail_claim on public.calendar_claims;

select * from pg_temp.t09_results order by test_no;
select count(*) as passed_checks, 'Single connection; fictional changes rolled back.' as scope from pg_temp.t09_results;
rollback;
