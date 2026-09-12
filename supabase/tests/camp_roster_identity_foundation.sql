-- A1 single-connection regression. Fictional rows are removed by ROLLBACK.
begin;
set local timezone='UTC';
set local statement_timeout='60s';

create temporary table a1_results(test_no integer generated always as identity,test_name text,passed boolean) on commit drop;
create function pg_temp.a1_check(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  insert into pg_temp.a1_results(test_name,passed) values(label,true);
end $$;
create function pg_temp.a1_user(email_value text,is_staff boolean default false) returns uuid language plpgsql as $$
declare x uuid:=gen_random_uuid(); begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',email_value,'',clock_timestamp(),
    '{"provider":"email","providers":["email"]}','{}',clock_timestamp(),clock_timestamp());
  if is_staff then insert into public.staff_roles(user_id) values(x); end if; return x;
end $$;
create function pg_temp.a1_call(actor uuid,sql_text text) returns jsonb language plpgsql as $$
declare rows_value jsonb:='[]'; row_value record; state_value text; message_value text;
  actor_email text:=(select email from auth.users where id=actor);
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
declare staff_id uuid:=pg_temp.a1_user('a1-staff@example.invalid',true);
  legacy_user uuid:=pg_temp.a1_user('a1-legacy@example.invalid'); roster_user uuid:=pg_temp.a1_user('a1-roster@example.invalid');
  replacement_user uuid; camp_legacy uuid:=gen_random_uuid(); camp_roster uuid:=gen_random_uuid();
  eligible_legacy uuid:=gen_random_uuid(); eligible_roster uuid:=gen_random_uuid(); legacy_app uuid; roster_app uuid;
  diagnostic_camp uuid:=gen_random_uuid(); diagnostic_user uuid:=pg_temp.a1_user('a1-diagnostic@example.invalid');
  diagnostic_eligible uuid:=gen_random_uuid(); diagnostic_app uuid:=gen_random_uuid(); r jsonb; before_version bigint;
begin
  perform pg_temp.a1_check(exists(select 1 from pg_constraint where conname='camp_eligible_users_camp_id_id_uq')
    and exists(select 1 from pg_constraint where conname='applications_camp_eligible_user_fk')
    and exists(select 1 from pg_indexes where indexname='applications_one_active_camp_per_eligible_user'),
    'composite identity constraints exist');
  perform pg_temp.a1_check(exists(select 1 from pg_constraint where conname='applications_status_check'
    and pg_get_constraintdef(oid) like '%cancellation_requested%'),'eight-state application check is preserved');

  insert into public.camps(id,name,start_date,end_date,application_deadline,created_by) values
    (camp_legacy,'A1 fictional legacy camp',current_date+100,current_date+102,clock_timestamp()+interval '90 days',staff_id),
    (camp_roster,'A1 fictional roster camp',current_date+110,current_date+112,clock_timestamp()+interval '90 days',staff_id),
    (diagnostic_camp,'A1 fictional diagnostic camp',current_date+120,current_date+122,clock_timestamp()+interval '90 days',staff_id);
  perform pg_temp.a1_check((select room_assignment_mode='legacy_application' and roster_version=0
    and room_plan_version=0 and saved_roster_version is null and roster_label_version=0
    from public.camps where id=camp_legacy),'existing camp defaults are legacy and versioned');
  insert into public.camp_eligible_users(id,camp_id,email_normalized,management_name) values
    (eligible_legacy,camp_legacy,'a1-legacy@example.invalid',null),
    (eligible_roster,camp_roster,'a1-roster@example.invalid','架空対象者'),
    (diagnostic_eligible,diagnostic_camp,'a1-diagnostic@example.invalid',null);
  perform pg_temp.a1_check((select management_name is null and participation_status='participating'
    and linked_user_id is null from public.camp_eligible_users where id=eligible_legacy),
    'legacy null management name remains valid');

  r:=pg_temp.a1_call(legacy_user,format('select public.create_camp_application_draft(%L) id',camp_legacy));
  legacy_app:=(r#>>'{rows,0,id}')::uuid;
  perform pg_temp.a1_check(r->>'ok'='true' and (select camp_eligible_user_id is null from public.applications where id=legacy_app),
    'legacy draft contract remains email based and unlinked');

  perform set_config('private.camp_mode_migration','allowed',true);
  update public.camps set room_assignment_mode='eligible_roster' where id=camp_roster;
  r:=pg_temp.a1_call(roster_user,format('select public.create_camp_application_draft(%L) id',camp_roster));
  roster_app:=(r#>>'{rows,0,id}')::uuid;
  perform pg_temp.a1_check(r->>'ok'='true' and (select camp_eligible_user_id=eligible_roster and user_id=roster_user
    from public.applications where id=roster_app),'roster draft stores stable eligible id');
  perform pg_temp.a1_check((select linked_user_id=roster_user and linked_email_normalized='a1-roster@example.invalid'
    and linked_at is not null from public.camp_eligible_users where id=eligible_roster),'first draft binds verified owner');
  before_version:=(select input_version from public.applications where id=roster_app);
  update public.applications set purpose='架空入力' where id=roster_app;
  perform pg_temp.a1_check((select input_version=before_version+1 from public.applications where id=roster_app),
    'roster input change advances input version');

  r:=pg_temp.a1_call(staff_id,format('select public.get_staff_camp_roster(%L) value',camp_roster));
  perform pg_temp.a1_check(r->>'ok'='true' and r#>>'{rows,0,value,eligible_users,0,id}'=eligible_roster::text
    and r#>>'{rows,0,value,eligible_users,0,application_id}'=roster_app::text,'staff roster getter uses stable ids');

  delete from auth.users where id=roster_user;
  perform pg_temp.a1_check((select linked_user_id=roster_user from public.camp_eligible_users where id=eligible_roster)
    and (select user_id is null and camp_eligible_user_id=eligible_roster from public.applications where id=roster_app),
    'auth deletion preserves binding and eligible application id');
  replacement_user:=pg_temp.a1_user('a1-roster@example.invalid');
  r:=pg_temp.a1_call(replacement_user,format('select public.create_camp_application_draft(%L)',camp_roster));
  perform pg_temp.a1_check(r->>'ok'='false' and r->>'message'='このキャンプの申請対象者ではありません。',
    'same email on another auth account cannot take binding');

  begin
    insert into public.applications(user_id,usage_type,camp_eligible_user_id,status)
      values(replacement_user,'community_individual',eligible_roster,'draft');
    set constraints all immediate; raise exception 'expected community scope failure';
  exception when check_violation then null; end;
  perform pg_temp.a1_check(true,'community application cannot carry camp eligible id');

  insert into public.applications(id,user_id,usage_type,camp_id,status,start_date,end_date,email_snapshot)
    values(diagnostic_app,diagnostic_user,'camp',diagnostic_camp,'draft',current_date+120,current_date+122,
      'a1-diagnostic@example.invalid');
  r:=pg_temp.a1_call(staff_id,format('select public.diagnose_camp_roster_migration(%L) value',diagnostic_camp));
  perform pg_temp.a1_check(r->>'ok'='true'
    and r#>>'{rows,0,value,mode_changed}'='false'
    and r#>>'{rows,0,value,applications,0,classification}'='auto_link_candidate'
    and (select room_assignment_mode='legacy_application' from public.camps where id=diagnostic_camp),
    'diagnostic classifies without linking or changing mode');

  update public.applications set email_snapshot=null where id=diagnostic_app;
  r:=pg_temp.a1_call(staff_id,format('select public.diagnose_camp_roster_migration(%L) value',diagnostic_camp));
  perform pg_temp.a1_check(r#>>'{rows,0,value,applications,0,classification}'='conditional_link_candidate'
    and r#>>'{rows,0,value,applications,0,reason_codes,0}'='empty-draft-current-confirmed-email',
    'empty draft candidate records current confirmed email evidence');

  update public.applications set status='approved' where id=diagnostic_app;
  insert into public.stays(application_id,status,checked_in_at) values(diagnostic_app,'staying',clock_timestamp());
  r:=pg_temp.a1_call(staff_id,format('select public.diagnose_camp_roster_migration(%L) value',diagnostic_camp));
  perform pg_temp.a1_check(r#>>'{rows,0,value,disposition}'='switch_blocked'
    and (r#>'{rows,0,value,blocking_reason_codes}') ? 'stay-started-or-completed',
    'started stay blocks mode switch without repair');

  r:=pg_temp.a1_call(replacement_user,format('select public.get_staff_camp_roster(%L)',camp_roster));
  perform pg_temp.a1_check(r->>'state'='42501','non-staff diagnostics are denied');
end $$;

select count(*)::integer passed_checks,bool_and(passed) all_passed from pg_temp.a1_results;
rollback;
