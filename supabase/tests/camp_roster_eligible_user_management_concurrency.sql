-- A2 separate-session race. Run worker_a and worker_b concurrently after SQL 031.
begin;
create schema a2_roster_management_concurrency_test;
create table a2_roster_management_concurrency_test.context(camp_id uuid not null,staff_a uuid not null,staff_b uuid not null);
create table a2_roster_management_concurrency_test.results(worker text primary key,backend integer not null,started_at timestamptz not null,finished_at timestamptz not null,ok boolean not null,state text,message text);
create function a2_roster_management_concurrency_test.call_as(actor uuid,sql_text text) returns jsonb language plpgsql as $$
declare row_value record; rows_value jsonb:='[]'; state_value text; message_value text; actor_email text:=(select email from auth.users where id=actor);
begin
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'email',actor_email,'role','authenticated')::text,true);
    for row_value in execute sql_text loop rows_value:=rows_value||jsonb_build_array(to_jsonb(row_value)); end loop;
    set local role postgres; return jsonb_build_object('ok',true,'rows',rows_value);
  exception when others then
    get stacked diagnostics state_value=returned_sqlstate,message_value=message_text;
    set local role postgres; return jsonb_build_object('ok',false,'state',state_value,'message',message_value);
  end;
end $$;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); camp uuid:=gen_random_uuid(); begin
  insert into auth.users(id,email,email_confirmed_at) values(a,'a2-race-a@example.invalid',clock_timestamp()),(b,'a2-race-b@example.invalid',clock_timestamp());
  insert into public.staff_roles(user_id) values(a),(b);
  insert into public.camps(id,name,start_date,end_date,application_deadline,created_by) values(camp,'A2 concurrent roster',current_date+100,current_date+102,clock_timestamp()+interval '90 days',a);
  perform set_config('private.camp_mode_migration','allowed',true);
  update public.camps set room_assignment_mode='eligible_roster' where id=camp;
  insert into a2_roster_management_concurrency_test.context values(camp,a,b);
end $$;
commit;

create procedure a2_roster_management_concurrency_test.run_worker(worker_name text,actor uuid,delay_seconds numeric) language plpgsql as $$
declare c a2_roster_management_concurrency_test.context%rowtype; result_value jsonb; started_value timestamptz;
begin
  select * into c from a2_roster_management_concurrency_test.context;
  perform pg_sleep(delay_seconds); started_value:=clock_timestamp();
  result_value:=a2_roster_management_concurrency_test.call_as(actor,format('select * from public.create_camp_roster_eligible_user(%L,%L,%L)',c.camp_id,'同時登録','a2-concurrent@example.invalid'));
  insert into a2_roster_management_concurrency_test.results values(worker_name,pg_backend_pid(),started_value,clock_timestamp(),(result_value->>'ok')::boolean,result_value->>'state',result_value->>'message');
end $$;
create procedure a2_roster_management_concurrency_test.worker_a() language plpgsql as $$
declare actor uuid; begin
  select staff_a into actor from a2_roster_management_concurrency_test.context;
  call a2_roster_management_concurrency_test.run_worker('a',actor,0);
end $$;
create procedure a2_roster_management_concurrency_test.worker_b() language plpgsql as $$
declare actor uuid; begin
  select staff_b into actor from a2_roster_management_concurrency_test.context;
  call a2_roster_management_concurrency_test.run_worker('b',actor,0.05);
end $$;
create function a2_roster_management_concurrency_test.verify() returns table(case_name text,passed boolean,backend_a integer,backend_b integer) language plpgsql as $$
declare c a2_roster_management_concurrency_test.context%rowtype; a a2_roster_management_concurrency_test.results%rowtype; b a2_roster_management_concurrency_test.results%rowtype;
begin
  select * into c from a2_roster_management_concurrency_test.context;
  select * into a from a2_roster_management_concurrency_test.results where worker='a'; select * into b from a2_roster_management_concurrency_test.results where worker='b';
  case_name:='same camp and email creates exactly one stable roster record'; backend_a:=a.backend; backend_b:=b.backend;
  passed:=a.backend<>b.backend and ((a.ok and not b.ok and b.message='eligible-email-exists') or (b.ok and not a.ok and a.message='eligible-email-exists'))
    and (select count(*)=1 from public.camp_eligible_users where camp_id=c.camp_id and email_normalized='a2-concurrent@example.invalid');
  return next;
end $$;
create function a2_roster_management_concurrency_test.cleanup() returns void language plpgsql as $$
declare c a2_roster_management_concurrency_test.context%rowtype; begin
  select * into c from a2_roster_management_concurrency_test.context;
  delete from public.audit_logs where actor_user_id in(c.staff_a,c.staff_b) or entity_id in(select id from public.camp_eligible_users where camp_id=c.camp_id);
  delete from public.camp_eligible_users where camp_id=c.camp_id; delete from public.calendar_claims where camp_id=c.camp_id;
  delete from public.camps where id=c.camp_id; delete from auth.users where id in(c.staff_a,c.staff_b);
end $$;
