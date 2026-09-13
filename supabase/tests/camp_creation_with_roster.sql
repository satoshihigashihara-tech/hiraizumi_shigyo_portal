-- New staff camp creation with an initial roster. Fictional data is rolled back.
begin;
set local timezone='UTC';
set local statement_timeout='60s';

create temporary table camp_create_results(test_no integer generated always as identity,test_name text,passed boolean) on commit drop;
create function pg_temp.camp_create_check(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  insert into pg_temp.camp_create_results(test_name,passed) values(label,true);
end $$;
create function pg_temp.camp_create_user(email_value text,is_staff boolean default false) returns uuid language plpgsql as $$
declare x uuid:=gen_random_uuid(); begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',email_value,'',clock_timestamp(),'{"provider":"email","providers":["email"]}','{}',clock_timestamp(),clock_timestamp());
  if is_staff then insert into public.staff_roles(user_id) values(x); end if; return x;
end $$;
create function pg_temp.camp_create_call(actor uuid,sql_text text) returns jsonb language plpgsql as $$
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
declare staff uuid:=pg_temp.camp_create_user('camp-create-staff@example.invalid',true);
  ordinary uuid:=pg_temp.camp_create_user('camp-create-user@example.invalid');
  r jsonb; created_camp_id uuid; before_camps bigint; before_users bigint;
  start_value date:=current_date+200; end_value date:=current_date+202;
  roster jsonb:='[{"management_name":" 架空 太郎 ","email":"TARO@example.invalid"},{"management_name":"架空 花子","email":"hanako@example.invalid"}]';
begin
  perform pg_temp.camp_create_check(has_function_privilege('authenticated','public.create_staff_camp_with_roster(text,date,date,timestamp with time zone,jsonb)','EXECUTE'),'authenticated can execute RPC');
  perform pg_temp.camp_create_check(not has_function_privilege('anon','public.create_staff_camp_with_roster(text,date,date,timestamp with time zone,jsonb)','EXECUTE'),'anon cannot execute RPC');

  r:=pg_temp.camp_create_call(ordinary,format('select public.create_staff_camp_with_roster(%L,%L,%L,clock_timestamp()+interval ''100 days'',%L::jsonb)',
    '架空権限外',start_value,end_value,roster));
  perform pg_temp.camp_create_check(r->>'state'='42501','ordinary user cannot create camp');

  r:=pg_temp.camp_create_call(staff,format('select public.create_staff_camp_with_roster(%L,%L,%L,clock_timestamp()+interval ''100 days'',%L::jsonb) id',
    ' 架空名簿キャンプ ',start_value,end_value,roster));
  created_camp_id:=(r#>>'{rows,0,id}')::uuid;
  perform pg_temp.camp_create_check(r->>'ok'='true' and created_camp_id is not null,'staff creates camp and roster');
  perform pg_temp.camp_create_check((select name='架空名簿キャンプ' and room_assignment_mode='eligible_roster' and roster_version=2 and roster_label_version=2 from public.camps where id=created_camp_id),'camp is roster mode with versioned roster');
  perform pg_temp.camp_create_check((select count(*)=2 and bool_and(management_name in('架空 太郎','架空 花子')) and bool_and(email_normalized in('taro@example.invalid','hanako@example.invalid')) from public.camp_eligible_users where camp_id=created_camp_id),'paired names and normalized emails are saved');
  perform pg_temp.camp_create_check((select count(*)=1 from public.audit_logs where entity_id=created_camp_id and action='create_camp_with_roster'),'creation is audited once');

  select count(*) into before_camps from public.camps;
  select count(*) into before_users from public.camp_eligible_users;
  r:=pg_temp.camp_create_call(staff,format('select public.create_staff_camp_with_roster(%L,%L,%L,clock_timestamp()+interval ''110 days'',%L::jsonb)',
    '架空重複',start_value+10,end_value+10,'[{"management_name":"一","email":"SAME@example.invalid"},{"management_name":"二","email":"same@example.invalid"}]'));
  perform pg_temp.camp_create_check(r->>'message'='duplicate-eligible-email','case-insensitive duplicate is rejected');
  perform pg_temp.camp_create_check((select count(*)=before_camps from public.camps) and (select count(*)=before_users from public.camp_eligible_users),'duplicate failure is atomic');

  r:=pg_temp.camp_create_call(staff,format('select public.create_staff_camp_with_roster(%L,%L,%L,clock_timestamp()+interval ''120 days'',%L::jsonb)',
    '架空氏名なし',start_value+20,end_value+20,'[{"management_name":" ","email":"valid@example.invalid"}]'));
  perform pg_temp.camp_create_check(r->>'message'='invalid-management-name','blank name is rejected');
  perform pg_temp.camp_create_check((select count(*)=before_camps from public.camps),'invalid roster leaves no camp');
end $$;

select count(*)::integer passed_checks,bool_and(passed) all_passed from pg_temp.camp_create_results;
rollback;
