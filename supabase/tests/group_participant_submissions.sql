-- T19 participant form regression. Run after SQL 023; all fictional rows are rolled back.
begin;
set local timezone='UTC';
create temporary table t19p_results(n integer generated always as identity,label text,passed boolean) on commit drop;
create function pg_temp.t19p_check(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  insert into pg_temp.t19p_results(label,passed) values(label,true);
end; $$;
create function pg_temp.t19p_user() returns uuid language plpgsql as $$ declare x uuid:=gen_random_uuid(); begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','t19p-'||x||'@example.invalid','',clock_timestamp(),
    '{"provider":"email","providers":["email"]}','{}',clock_timestamp(),clock_timestamp());
  update public.profiles set full_name='架空参加者',address='架空住所',phone='000-0000-0000',emergency_name='架空連絡先',
    emergency_address='架空住所',emergency_phone='000-0000-0000' where id=x; return x;
end; $$;
create function pg_temp.t19p_call(actor uuid,query_text text,role_name text default 'authenticated') returns jsonb language plpgsql as $$
declare r record; rows_value jsonb:='[]'; result_value jsonb; code_value text; msg text; actor_email text:=(select email from auth.users where id=actor);
begin
  begin
    execute format('set local role %I',role_name); perform set_config('request.jwt.claim.sub',coalesce(actor::text,''),true);
    perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'email',actor_email,'role',role_name)::text,true);
    for r in execute query_text loop rows_value:=rows_value||jsonb_build_array(to_jsonb(r)); end loop;
    result_value:=jsonb_build_object('ok',true,'rows',rows_value);
  exception when others then get stacked diagnostics code_value=returned_sqlstate,msg=message_text;
    result_value:=jsonb_build_object('ok',false,'code',code_value,'message',msg);
  end;
  set local role postgres; perform set_config('request.jwt.claim.sub','',true); perform set_config('request.jwt.claims','{}',true); return result_value;
end; $$;
create function pg_temp.t19p_ok(r jsonb,label text) returns jsonb language plpgsql as $$ begin
  perform pg_temp.t19p_check(r->>'ok'='true',label||': '||r::text); return r->'rows'; end; $$;
create function pg_temp.t19p_error(r jsonb,message_value text,label text) returns void language plpgsql as $$ begin
  perform pg_temp.t19p_check(r->>'ok'='false' and r->>'message'=message_value,label||': '||r::text); end; $$;

do $$ declare rep uuid:=pg_temp.t19p_user(); u1 uuid:=pg_temp.t19p_user(); u2 uuid:=pg_temp.t19p_user(); outsider uuid:=pg_temp.t19p_user();
  g uuid:=gen_random_uuid(); a1 uuid:=gen_random_uuid(); a2 uuid:=gen_random_uuid(); v timestamptz; key1 uuid:=gen_random_uuid(); key2 uuid:=gen_random_uuid();
  f jsonb:='{"user_name":"架空一郎","user_address":"架空住所1","user_phone":"000-0000-0001","emergency_name":"架空連絡先1","emergency_address":"架空緊急住所1","emergency_phone":"000-0000-0011","special_notes":"本人だけのメモ","requires_guardian_consent":false}'; r jsonb;
begin
  insert into public.group_applications(id,representative_user_id,group_name,representative_name,representative_address,
    representative_phone,representative_email,start_date,end_date,usage_place,purpose,local_activity,special_notes,
    planned_participants,status,submitted_at,participant_due_at)
  values(g,rep,'架空団体','架空代表','代表住所','000-0000-0099','rep@example.invalid',current_date+20,current_date+22,
    'common_and_second_floor','架空目的','架空町内活動','代表だけのメモ',2,'collecting',clock_timestamp(),clock_timestamp()+interval '1 day');
  insert into public.group_invites(group_id,token_hash,code_hash,created_by) values(g,repeat('a',64),repeat('b',64),rep);
  insert into public.applications(id,user_id,usage_type,group_id,status,start_date,end_date,user_name,user_address,user_phone,
    emergency_name,emergency_address,emergency_phone,requires_guardian_consent)
  values(a1,u1,'community_group',g,'draft',current_date+20,current_date+22,'古い氏名','旧住所','000-0000-0000','旧連絡先','旧住所','000-0000-0000',false),
    (a2,u2,'community_group',g,'draft',current_date+20,current_date+22,'架空二郎','架空住所2','000-0000-0002','架空連絡先2','架空緊急住所2','000-0000-0022',false);
  insert into public.group_members(group_id,application_id) values(g,a1),(g,a2);
  select updated_at into v from public.applications where id=a1;
  perform pg_temp.t19p_error(pg_temp.t19p_call(outsider,format('select * from public.save_group_participant_application(%L,%L,%L::jsonb)',a1,v,f)),'not-found','other user cannot save');
  perform pg_temp.t19p_error(pg_temp.t19p_call(u1,format('select * from public.save_group_participant_application(%L,%L,%L::jsonb)',a1,v,f||'{"purpose":"forged"}')),'invalid-fields','shared field rejected');
  perform pg_temp.t19p_ok(pg_temp.t19p_call(u1,format('select * from public.save_group_participant_application(%L,%L,%L::jsonb)',a1,v,f)),'owner saves personal fields');
  perform pg_temp.t19p_check((select user_name='架空一郎' and special_notes='本人だけのメモ' and purpose is null and start_date=current_date+20 from public.applications where id=a1),'save changes only personal fields');
  r:=pg_temp.t19p_ok(pg_temp.t19p_call(u1,format('select public.get_group_participant_application(%L) data',a1)),'owner gets form');
  perform pg_temp.t19p_check((r#>>'{0,data,group_name}')='架空団体','read returns group name');
  select updated_at into v from public.applications where id=a1;
  r:=pg_temp.t19p_ok(pg_temp.t19p_call(u1,format('select * from public.submit_group_participant_application(%L,%L,%L,true)',a1,v,key1)),'first submits');
  perform pg_temp.t19p_check((r#>>'{0,result_group_status}')='collecting' and (select status='submitted' from public.applications where id=a1),'first keeps group collecting');
  perform pg_temp.t19p_check((select count(*)=1 from public.reception_numbers where application_id=a1)
    and (select total_amount=900 from public.application_charges where application_id=a1),'receipt and charge created');
  perform pg_temp.t19p_ok(pg_temp.t19p_call(u1,format('select * from public.submit_group_participant_application(%L,%L,%L,true)',a1,v,key1)),'same submit retry');
  perform pg_temp.t19p_check((select count(*)=1 from public.application_status_events where application_id=a1 and to_status='submitted'),'retry adds no event');
  select updated_at into v from public.applications where id=a2;
  r:=pg_temp.t19p_ok(pg_temp.t19p_call(u2,format('select * from public.submit_group_participant_application(%L,%L,%L,true)',a2,v,key2)),'last submits');
  perform pg_temp.t19p_check((r#>>'{0,result_group_status}')='under_review' and (select status='under_review' from public.group_applications where id=g),'last advances group');
  perform pg_temp.t19p_check((select count(*)=1 from public.group_status_events where group_id=g and from_status='collecting' and to_status='under_review')
    and (select count(*)=1 from public.audit_logs where entity_id=g and action='complete_group_participant_submissions'),'one group transition and audit');
  perform pg_temp.t19p_check((select revoked_at is not null from public.group_invites where group_id=g),'invite revoked when membership freezes');
  perform pg_temp.t19p_error(pg_temp.t19p_call(u2,format('select * from public.save_group_participant_application(%L,%L,%L::jsonb)',a2,(select updated_at from public.applications where id=a2),f)),'not-editable','reviewed group cannot edit');
end; $$;

select count(*)::integer as passed_checks,bool_and(passed) as all_passed from pg_temp.t19p_results;
rollback;
