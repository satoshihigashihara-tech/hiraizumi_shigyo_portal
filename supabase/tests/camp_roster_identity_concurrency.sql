-- A1 separate-session race. The local harness calls worker_a and worker_b together.
-- Auth emails are unique in production, so this test uses one real owner and one
-- initially unlinked eligible user. Worker A holds the same facility guard used by
-- draft creation long enough to prove that worker B waits on a separate connection.
begin;
create schema a1_roster_concurrency_test;
create table a1_roster_concurrency_test.context(
  camp_id uuid not null,eligible_id uuid not null,staff_user_id uuid not null,
  owner_user_id uuid not null,owner_email text not null
);
create table a1_roster_concurrency_test.results(
  worker text primary key,backend integer not null,started_at timestamptz not null,
  finished_at timestamptz not null,ok boolean not null,message text,application_id uuid
);
create function a1_roster_concurrency_test.call_as(actor uuid,email_value text,sql_text text)
returns jsonb language plpgsql as $$
declare row_value record; rows_value jsonb:='[]'; state_value text; message_value text;
begin
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'email',email_value,'role','authenticated')::text,true);
    for row_value in execute sql_text loop rows_value:=rows_value||jsonb_build_array(to_jsonb(row_value)); end loop;
    set local role postgres; return jsonb_build_object('ok',true,'rows',rows_value);
  exception when others then
    get stacked diagnostics state_value=returned_sqlstate,message_value=message_text;
    set local role postgres; return jsonb_build_object('ok',false,'state',state_value,'message',message_value);
  end;
end $$;
do $$
declare staff uuid:=gen_random_uuid(); owner_id uuid:=gen_random_uuid();
  target_camp uuid:=gen_random_uuid(); eligible uuid:=gen_random_uuid();
  owner_email_value text:='a1-concurrent-owner@example.invalid';
begin
  insert into auth.users(id,email,email_confirmed_at) values
    (staff,'a1-concurrency-staff@example.invalid',clock_timestamp()),
    (owner_id,owner_email_value,clock_timestamp());
  insert into public.staff_roles(user_id) values(staff);
  insert into public.camps(id,name,start_date,end_date,application_deadline,created_by) values
    (target_camp,'A1 same-owner fictional camp',current_date+100,current_date+102,
      clock_timestamp()+interval '90 days',staff);
  insert into public.camp_eligible_users(id,camp_id,email_normalized,management_name) values
    (eligible,target_camp,owner_email_value,'架空同時対象');
  perform set_config('private.camp_mode_migration','allowed',true);
  update public.camps set room_assignment_mode='eligible_roster' where id=target_camp;
  insert into a1_roster_concurrency_test.context
    values(target_camp,eligible,staff,owner_id,owner_email_value);
end $$;
commit;

create procedure a1_roster_concurrency_test.run_worker(worker_name text)
language plpgsql as $$
declare c a1_roster_concurrency_test.context%rowtype; result_value jsonb;
  started_value timestamptz;
begin
  select * into c from a1_roster_concurrency_test.context;
  started_value:=clock_timestamp();
  result_value:=a1_roster_concurrency_test.call_as(c.owner_user_id,c.owner_email,
    format('select public.create_camp_application_draft(%L) id',c.camp_id));
  insert into a1_roster_concurrency_test.results values(
    worker_name,pg_backend_pid(),started_value,clock_timestamp(),
    (result_value->>'ok')::boolean,result_value->>'message',
    (result_value#>>'{rows,0,id}')::uuid);
end $$;

create procedure a1_roster_concurrency_test.worker_a() language plpgsql as $$
declare guard_id integer;
begin
  select id into guard_id from public.facility_guard where id=1 for update;
  perform pg_sleep(0.4);
  call a1_roster_concurrency_test.run_worker('a');
end $$;

create procedure a1_roster_concurrency_test.worker_b() language plpgsql as $$
begin
  perform pg_sleep(0.05);
  call a1_roster_concurrency_test.run_worker('b');
end $$;

create function a1_roster_concurrency_test.verify()
returns table(case_name text,passed boolean,backend_a integer,backend_b integer) language plpgsql as $$
declare c a1_roster_concurrency_test.context%rowtype;
  ra a1_roster_concurrency_test.results%rowtype;
  rb a1_roster_concurrency_test.results%rowtype;
begin
  select * into c from a1_roster_concurrency_test.context;
  select * into ra from a1_roster_concurrency_test.results where worker='a';
  select * into rb from a1_roster_concurrency_test.results where worker='b';
  backend_a:=ra.backend; backend_b:=rb.backend;
  case_name:='same owner first binding and draft creation converge after a real wait';
  passed:=ra.backend<>rb.backend
    and ra.ok and rb.ok and ra.application_id=rb.application_id
    and rb.finished_at-rb.started_at>=interval '0.25 seconds'
    and (select count(*)=1 from public.applications a where a.camp_id=c.camp_id
      and a.status not in('rejected','cancelled'))
    and (select linked_user_id=c.owner_user_id from public.camp_eligible_users e where e.id=c.eligible_id)
    and (select count(*)=1 from public.audit_logs l where l.entity_id=c.eligible_id
      and l.action='link_camp_eligible_user')
    and (select count(*)=1 from public.application_status_events s
      where s.application_id=ra.application_id and s.to_status='draft');
  return next;
end $$;

create function a1_roster_concurrency_test.cleanup() returns void language plpgsql as $$
declare c a1_roster_concurrency_test.context%rowtype;
begin
  select * into c from a1_roster_concurrency_test.context;
  delete from public.audit_logs where entity_id=c.eligible_id
    or actor_user_id in(c.staff_user_id,c.owner_user_id);
  delete from public.applications where camp_id=c.camp_id;
  delete from public.calendar_claims where camp_id=c.camp_id;
  delete from public.camps where id=c.camp_id;
  delete from auth.users where id in(c.staff_user_id,c.owner_user_id);
end $$;
