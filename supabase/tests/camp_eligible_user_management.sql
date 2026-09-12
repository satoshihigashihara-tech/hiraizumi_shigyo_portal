-- P06 single-connection regression. Run as postgres after migration 029.
-- Fictional changes are removed by the final ROLLBACK.
begin;
set local timezone = 'UTC';
set local statement_timeout = '60s';

create temporary table p06_results (test_no integer generated always as identity, test_name text, passed boolean) on commit drop;
create function pg_temp.p06_check(ok boolean, label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %', label; end if;
  insert into pg_temp.p06_results(test_name,passed) values(label,true);
end; $$;
create function pg_temp.p06_user(is_staff boolean) returns uuid language plpgsql as $$ declare uid uuid:=gen_random_uuid(); begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(uid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','p06-'||uid||'@example.invalid','',clock_timestamp(),'{"provider":"email","providers":["email"]}','{}',clock_timestamp(),clock_timestamp());
  if is_staff then insert into public.staff_roles(user_id) values(uid); end if; return uid;
end; $$;
create function pg_temp.p06_call(actor uuid, sql_text text) returns jsonb language plpgsql as $$
declare rows_value jsonb:='[]'; row_value record; state_value text; message_value text; actor_email text:=(select email from auth.users where id=actor);
begin
  begin
    set local role authenticated; perform set_config('request.jwt.claim.sub',actor::text,true);
    perform set_config('request.jwt.claim.email',actor_email,true);
    perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'email',actor_email,'role','authenticated')::text,true);
    for row_value in execute sql_text loop rows_value:=rows_value||jsonb_build_array(to_jsonb(row_value)); end loop;
    set local role postgres; return jsonb_build_object('ok',true,'rows',rows_value);
  exception when others then get stacked diagnostics state_value=returned_sqlstate,message_value=message_text;
    set local role postgres; return jsonb_build_object('ok',false,'state',state_value,'message',message_value);
  end;
end; $$;

do $$
declare staff_id uuid:=pg_temp.p06_user(true); user_id uuid:=pg_temp.p06_user(false);
  camp_value uuid:=gen_random_uuid(); first_id uuid:=gen_random_uuid(); second_id uuid:=gen_random_uuid(); old_version timestamptz; result jsonb;
begin
  insert into public.camps(id,name,start_date,end_date,application_deadline,created_by)
  values(camp_value,'P06 fictional camp',current_date+100,current_date+102,clock_timestamp()+interval '90 days',staff_id);
  insert into public.camp_eligible_users(id,camp_id,email_normalized) values
    (first_id,camp_value,'p06-first@example.invalid'),(second_id,camp_value,'p06-existing@example.invalid');
  select updated_at into old_version from public.camp_eligible_users where id=first_id;

  result:=pg_temp.p06_call(user_id,format('select * from public.update_camp_eligible_user(%L,%L,%L,%L,%L)',camp_value,first_id,'p06-new@example.invalid',old_version,'test'));
  perform pg_temp.p06_check(result->>'ok'='false' and result->>'state'='42501','non-staff update denied');
  result:=pg_temp.p06_call(staff_id,format('select * from public.update_camp_eligible_user(%L,%L,%L,%L,%L)',camp_value,first_id,'bad email',old_version,'test'));
  perform pg_temp.p06_check(result->>'message'='invalid-email','invalid email denied');
  result:=pg_temp.p06_call(staff_id,format('select * from public.update_camp_eligible_user(%L,%L,%L,%L,%L)',camp_value,first_id,'P06-NEW@example.invalid',old_version,'test update'));
  perform pg_temp.p06_check(result->>'ok'='true' and (select email_normalized='p06-new@example.invalid' from public.camp_eligible_users where id=first_id),'email normalized and updated');
  perform pg_temp.p06_check((select count(*)=1 from public.audit_logs where entity_id=first_id and action='update_camp_eligible_user'),'update audited');
  result:=pg_temp.p06_call(staff_id,format('select * from public.update_camp_eligible_user(%L,%L,%L,%L,%L)',camp_value,first_id,'p06-other@example.invalid',old_version - interval '1 microsecond','stale'));
  perform pg_temp.p06_check(result->>'message'='stale-update','stale update denied');

  select updated_at into old_version from public.camp_eligible_users where id=first_id;
  result:=pg_temp.p06_call(staff_id,format('select * from public.update_camp_eligible_user(%L,%L,%L,%L,%L)',camp_value,first_id,'p06-existing@example.invalid',old_version,'duplicate'));
  perform pg_temp.p06_check(result->>'message'='eligible-email-exists','duplicate email denied');

  insert into public.applications(user_id,camp_id,email_snapshot,status) values(user_id,camp_value,'p06-new@example.invalid','draft');
  result:=pg_temp.p06_call(staff_id,format('select * from public.disable_camp_eligible_user(%L,%L,%L,%L)',camp_value,first_id,old_version,'protected'));
  perform pg_temp.p06_check(result->>'message'='eligible-has-application' and (select disabled_at is null from public.camp_eligible_users where id=first_id),'application eligibility protected');
  delete from public.applications a where a.camp_id = camp_value and a.email_snapshot = 'p06-new@example.invalid';
  result:=pg_temp.p06_call(staff_id,format('select * from public.disable_camp_eligible_user(%L,%L,%L,%L)',camp_value,first_id,old_version,'disable test'));
  perform pg_temp.p06_check(result->>'ok'='true' and (select disabled_at is not null from public.camp_eligible_users where id=first_id),'unused eligibility disabled');
  perform pg_temp.p06_check((select count(*)=1 from public.audit_logs where entity_id=first_id and action='disable_camp_eligible_user'),'disable audited');
end; $$;

select * from pg_temp.p06_results order by test_no;
select count(*) as passed_checks, bool_and(passed) as all_passed from pg_temp.p06_results;
rollback;
