-- A2 single-connection regression. Run after SQL 031; all fictional data rolls back.
begin;
set local timezone='UTC';
set local statement_timeout='60s';

create temporary table a2_results(test_no integer generated always as identity,test_name text,passed boolean) on commit drop;
create function pg_temp.a2_check(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  insert into pg_temp.a2_results(test_name,passed) values(label,true);
end $$;
create function pg_temp.a2_user(email_value text,is_staff boolean default false) returns uuid language plpgsql as $$
declare x uuid:=gen_random_uuid(); begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',email_value,'',clock_timestamp(),'{"provider":"email","providers":["email"]}','{}',clock_timestamp(),clock_timestamp());
  if is_staff then insert into public.staff_roles(user_id) values(x); end if; return x;
end $$;
create function pg_temp.a2_call(actor uuid,sql_text text) returns jsonb language plpgsql as $$
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
declare staff uuid:=pg_temp.a2_user('a2-staff@example.invalid',true); stopped_staff uuid:=pg_temp.a2_user('a2-stopped@example.invalid',true);
  user_id uuid:=pg_temp.a2_user('a2-user@example.invalid'); replacement uuid; roster_camp uuid:=gen_random_uuid(); legacy_camp uuid:=gen_random_uuid(); other_camp uuid:=gen_random_uuid();
  eligible uuid; other_eligible uuid:=gen_random_uuid(); version_value timestamptz; r jsonb; profile_name text:='正本プロフィール';
begin
  update public.profiles set full_name=profile_name where id=user_id;
  update public.profiles set account_state='disabled' where id=stopped_staff;
  insert into public.camps(id,name,start_date,end_date,application_deadline,created_by) values
    (roster_camp,'A2 roster',current_date+100,current_date+102,clock_timestamp()+interval '90 days',staff),
    (legacy_camp,'A2 legacy',current_date+110,current_date+112,clock_timestamp()+interval '90 days',staff),
    (other_camp,'A2 other',current_date+120,current_date+122,clock_timestamp()+interval '90 days',staff);
  perform set_config('private.camp_mode_migration','allowed',true);
  update public.camps set room_assignment_mode='eligible_roster' where id in(roster_camp,other_camp);

  r:=pg_temp.a2_call(user_id,format('select * from public.create_camp_roster_eligible_user(%L,%L,%L)',roster_camp,'架空対象者','a2@example.invalid'));
  perform pg_temp.a2_check(r->>'state'='42501','ordinary user cannot create roster user');
  r:=pg_temp.a2_call(stopped_staff,format('select * from public.create_camp_roster_eligible_user(%L,%L,%L)',roster_camp,'架空対象者','a2@example.invalid'));
  perform pg_temp.a2_check(r->>'state'='42501','stopped staff cannot create roster user');
  r:=pg_temp.a2_call(staff,format('select * from public.create_camp_roster_eligible_user(%L,%L,%L)',legacy_camp,'架空対象者','a2@example.invalid'));
  perform pg_temp.a2_check(r->>'message'='eligible-roster-required','legacy camp is rejected by roster RPC');
  r:=pg_temp.a2_call(staff,format('select * from public.add_camp_eligible_users(%L,array[%L])',roster_camp,'a2@example.invalid'));
  perform pg_temp.a2_check(r->>'message'='eligible-roster-required','legacy bulk RPC is rejected by roster camp');

  r:=pg_temp.a2_call(staff,format('select * from public.create_camp_roster_eligible_user(%L,%L,%L)',roster_camp,'架空対象者','A2@example.invalid'));
  eligible:=(r#>>'{rows,0,result_id}')::uuid;
  perform pg_temp.a2_check(r->>'ok'='true' and (select management_name='架空対象者' and email_normalized='a2@example.invalid' and disabled_at is null and participation_status='participating' from public.camp_eligible_users where id=eligible),'staff creates named active roster user');
  perform pg_temp.a2_check((select count(*)=1 from public.audit_logs where entity_id=eligible and action='create_camp_roster_eligible_user'),'creation is audited');
  update public.camp_eligible_users set disabled_at=clock_timestamp() where id=eligible;
  r:=pg_temp.a2_call(staff,format('select * from public.create_camp_roster_eligible_user(%L,%L,%L)',roster_camp,'別名','a2@example.invalid'));
  perform pg_temp.a2_check(r->>'message'='eligible-email-exists' and (select disabled_at is not null and management_name='架空対象者' from public.camp_eligible_users where id=eligible),'disabled duplicate is not revived or overwritten');
  update public.camp_eligible_users set disabled_at=null where id=eligible;
  insert into public.camp_eligible_users(id,camp_id,management_name,email_normalized) values(other_eligible,other_camp,'別キャンプ','a2@example.invalid');
  version_value:=(select updated_at from public.camp_eligible_users where id=eligible);
  r:=pg_temp.a2_call(staff,format('select * from public.update_camp_roster_eligible_user(%L,%L,%L,%L,%L,null)',other_camp,eligible,'改ざん','x@example.invalid',version_value));
  perform pg_temp.a2_check(r->>'message'='not-found','different camp ID cannot edit roster user');
  r:=pg_temp.a2_call(staff,format('select * from public.update_camp_roster_eligible_user(%L,%L,%L,%L,%L,null)',roster_camp,eligible,'更新名','a2-new@example.invalid',version_value));
  perform pg_temp.a2_check(r->>'ok'='true' and (select management_name='更新名' and email_normalized='a2-new@example.invalid' from public.camp_eligible_users where id=eligible),'unlinked name and email edit succeeds');
  perform pg_temp.a2_check((select full_name=profile_name from public.profiles where id=user_id),'management edit does not change profile name');
  r:=pg_temp.a2_call(staff,format('select * from public.update_camp_roster_eligible_user(%L,%L,%L,%L,%L,null)',roster_camp,eligible,'古い版','a2-old@example.invalid',version_value));
  perform pg_temp.a2_check(r->>'message'='stale-update','stale roster edit is rejected');

  update public.camp_eligible_users set linked_user_id=user_id,linked_at=clock_timestamp(),linked_email_normalized='a2-user@example.invalid' where id=eligible;
  version_value:=(select updated_at from public.camp_eligible_users where id=eligible);
  r:=pg_temp.a2_call(staff,format('select * from public.update_camp_roster_eligible_user(%L,%L,%L,%L,%L,null)',roster_camp,eligible,'結合済み','a2-linked@example.invalid',version_value));
  perform pg_temp.a2_check(r->>'message'='reason-required','linked email change requires reason');
  r:=pg_temp.a2_call(staff,format('select * from public.update_camp_roster_eligible_user(%L,%L,%L,%L,%L,%L)',roster_camp,eligible,'結合済み','a2-linked@example.invalid',version_value,'架空の訂正理由'));
  perform pg_temp.a2_check(r->>'ok'='true' and (select linked_user_id=user_id from public.camp_eligible_users where id=eligible),'linked email change preserves owner UUID');
  delete from auth.users where id=user_id;
  replacement:=pg_temp.a2_user('a2-user@example.invalid');
  perform pg_temp.a2_check((select linked_user_id=user_id from public.camp_eligible_users where id=eligible),'auth deletion preserves historical binding');
  r:=pg_temp.a2_call(replacement,format('select public.create_camp_application_draft(%L)',roster_camp));
  perform pg_temp.a2_check(r->>'ok'='false','same-email replacement auth user cannot take binding');
end $$;

select count(*)::integer passed_checks,bool_and(passed) all_passed from pg_temp.a2_results;
rollback;
