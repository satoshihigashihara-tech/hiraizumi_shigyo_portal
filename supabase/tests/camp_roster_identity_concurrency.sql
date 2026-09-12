-- A1 separate-session races. The local harness calls worker_a and worker_b together.
begin;
create schema a1_roster_concurrency_test;
create table a1_roster_concurrency_test.context(
  camp_contested uuid not null,camp_same_user uuid not null,eligible_contested uuid not null,eligible_same_user uuid not null,
  user_a uuid not null,user_b uuid not null,shared_user uuid not null,email_contested text not null,email_shared text not null
);
create table a1_roster_concurrency_test.results(worker text primary key,backend integer not null,
  contested_ok boolean not null,contested_message text,same_ok boolean not null,same_id uuid);
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
declare staff uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); shared uuid:=gen_random_uuid();
  c1 uuid:=gen_random_uuid(); c2 uuid:=gen_random_uuid(); e1 uuid:=gen_random_uuid(); e2 uuid:=gen_random_uuid();
begin
  insert into auth.users(id,email,email_confirmed_at) values
    (staff,'a1-concurrency-staff@example.invalid',clock_timestamp()),
    (a,'a1-contested@example.invalid',clock_timestamp()),(b,'a1-contested@example.invalid',clock_timestamp()),
    (shared,'a1-shared@example.invalid',clock_timestamp());
  insert into public.staff_roles(user_id) values(staff);
  insert into public.camps(id,name,start_date,end_date,application_deadline,created_by) values
    (c1,'A1 contested fictional camp',current_date+100,current_date+102,clock_timestamp()+interval '90 days',staff),
    (c2,'A1 same-user fictional camp',current_date+110,current_date+112,clock_timestamp()+interval '90 days',staff);
  insert into public.camp_eligible_users(id,camp_id,email_normalized,management_name) values
    (e1,c1,'a1-contested@example.invalid','架空競合対象'),(e2,c2,'a1-shared@example.invalid','架空同時対象');
  perform set_config('private.camp_mode_migration','allowed',true);
  update public.camps set room_assignment_mode='eligible_roster' where id in(c1,c2);
  insert into a1_roster_concurrency_test.context values(c1,c2,e1,e2,a,b,shared,
    'a1-contested@example.invalid','a1-shared@example.invalid');
end $$;
commit;

create procedure a1_roster_concurrency_test.worker(worker_name text,actor_selector text)
language plpgsql as $$
declare c a1_roster_concurrency_test.context%rowtype; actor uuid; first_result jsonb; second_result jsonb;
begin
  select * into c from a1_roster_concurrency_test.context;
  actor:=case when actor_selector='a' then c.user_a else c.user_b end;
  first_result:=a1_roster_concurrency_test.call_as(actor,c.email_contested,
    format('select public.create_camp_application_draft(%L) id',c.camp_contested));
  perform pg_sleep(0.2);
  second_result:=a1_roster_concurrency_test.call_as(c.shared_user,c.email_shared,
    format('select public.create_camp_application_draft(%L) id',c.camp_same_user));
  insert into a1_roster_concurrency_test.results values(worker_name,pg_backend_pid(),
    (first_result->>'ok')::boolean,first_result->>'message',(second_result->>'ok')::boolean,
    (second_result#>>'{rows,0,id}')::uuid);
end $$;
create procedure a1_roster_concurrency_test.worker_a() language plpgsql as $$ begin
  call a1_roster_concurrency_test.worker('a','a'); end $$;
create procedure a1_roster_concurrency_test.worker_b() language plpgsql as $$ begin
  call a1_roster_concurrency_test.worker('b','b'); end $$;

create function a1_roster_concurrency_test.verify()
returns table(case_name text,passed boolean,backend_a integer,backend_b integer) language plpgsql as $$
declare c a1_roster_concurrency_test.context%rowtype; ra a1_roster_concurrency_test.results%rowtype;
  rb a1_roster_concurrency_test.results%rowtype;
begin
  select * into c from a1_roster_concurrency_test.context;
  select * into ra from a1_roster_concurrency_test.results where worker='a';
  select * into rb from a1_roster_concurrency_test.results where worker='b';
  backend_a:=ra.backend; backend_b:=rb.backend;
  case_name:='one auth account wins the first binding';
  passed:=ra.backend<>rb.backend and ra.contested_ok<>rb.contested_ok
    and coalesce(case when ra.contested_ok then rb.contested_message else ra.contested_message end,'')='このキャンプの申請対象者ではありません。'
    and (select count(*)=1 from public.applications where camp_id=c.camp_contested)
    and (select linked_user_id in(c.user_a,c.user_b) from public.camp_eligible_users where id=c.eligible_contested);
  return next;
  case_name:='same owner receives one active draft';
  passed:=ra.same_ok and rb.same_ok and ra.same_id=rb.same_id
    and (select count(*)=1 from public.applications where camp_id=c.camp_same_user and status not in('rejected','cancelled'));
  return next;
end $$;

create function a1_roster_concurrency_test.cleanup() returns void language plpgsql as $$
declare c a1_roster_concurrency_test.context%rowtype; user_ids uuid[];
begin
  select * into c from a1_roster_concurrency_test.context;
  user_ids:=array[c.user_a,c.user_b,c.shared_user];
  delete from public.audit_logs where entity_id in(c.eligible_contested,c.eligible_same_user) or actor_user_id=any(user_ids);
  delete from public.applications where camp_id in(c.camp_contested,c.camp_same_user);
  delete from public.calendar_claims where camp_id in(c.camp_contested,c.camp_same_user);
  delete from public.camps where id in(c.camp_contested,c.camp_same_user);
  delete from auth.users where id=any(user_ids) or email='a1-concurrency-staff@example.invalid';
end $$;
