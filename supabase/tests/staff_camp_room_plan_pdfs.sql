-- A11 staff-only immutable room-plan PDF contract. Fictional changes roll back.
begin;
set local statement_timeout='60s';
create temporary table a11_results(name text,passed boolean) on commit drop;
create function pg_temp.a11_check(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  insert into pg_temp.a11_results values(label,true);
end $$;
create function pg_temp.a11_call(actor uuid,sql_text text,role_value text default 'authenticated') returns jsonb language plpgsql as $$
declare r record; rows_value jsonb:='[]'; state_value text; message_value text;
begin
  begin
    execute format('set local role %I',role_value);
    perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role',role_value)::text,true);
    for r in execute sql_text loop rows_value:=rows_value||jsonb_build_array(to_jsonb(r)); end loop;
    reset role; return jsonb_build_object('ok',true,'rows',rows_value);
  exception when others then get stacked diagnostics state_value=returned_sqlstate,message_value=message_text;
    reset role; return jsonb_build_object('ok',false,'state',state_value,'message',message_value);
  end;
end $$;

do $$ declare staff uuid:=gen_random_uuid(); user_id uuid:=gen_random_uuid(); camp uuid:=gen_random_uuid(); eligible uuid:=gen_random_uuid();
 room uuid; r jsonb; version_id uuid; job_id uuid; attempt_id uuid; source_hash_value text; report jsonb:='{"page_count":1,"fonts_embedded":true,"text_verified":true,"layout_verified":true}';
begin
  insert into auth.users(id,email,email_confirmed_at) values(staff,'a11-staff@example.invalid',clock_timestamp()),(user_id,'a11-user@example.invalid',clock_timestamp());
  insert into public.staff_roles(user_id) values(staff);
  insert into public.camps(id,name,start_date,end_date,application_deadline,created_by) values(camp,'A11架空',current_date+100,current_date+102,clock_timestamp()+interval '90 days',staff);
  perform set_config('private.camp_mode_migration','allowed',true);
  update public.camps set room_assignment_mode='eligible_roster' where id=camp;
  insert into public.camp_eligible_users(id,camp_id,email_normalized,management_name) values(eligible,camp,'a11-user@example.invalid','架空対象者');
  insert into public.rooms(name,capacity) values('A11架空室',2) returning id into room;
  insert into public.camp_room_mapping(room_id,source_name,floor,display_name,print_name,assignment_enabled,printing_enabled,confirmed_at,confirmation_evidence)
    values(room,'架空原図',2,'架空表示室','架空印字室',true,true,clock_timestamp(),'test-only');
  r:=pg_temp.a11_call(staff,format('select public.save_camp_room_plan(%L,1,0,%L::jsonb)',camp,
    jsonb_build_array(jsonb_build_object('eligible_user_id',eligible,'room_id',room))::text));
  perform pg_temp.a11_check(r->>'ok'='true','A3 complete plan prepared');
  r:=pg_temp.a11_call(staff,format('select public.begin_staff_camp_room_plan_pdf(%L,1,1,1,%L)',camp,gen_random_uuid()));
  perform pg_temp.a11_check(r->>'message'='pdf-prerequisites-unavailable','A8 inactive setting keeps A11 closed');
  insert into private.camp_pdf_render_setting_versions(settings_version,template_hash,font_version,converter_image,mayor_name,
    user_name_limit,user_address_limit,emergency_name_limit,emergency_address_limit,purpose_limit,special_notes_limit,room_name_limit,verified_at)
  values(1,repeat('a',64),'NotoSerifJP-2.003+sha256:'||repeat('b',64),'ghcr.io/example.invalid/renderer@sha256:'||repeat('c',64),
    '架空町長',20,30,20,30,60,48,15,clock_timestamp());
  insert into private.camp_pdf_active_render_setting(settings_version) values(1);
  r:=pg_temp.a11_call(user_id,format('select public.begin_staff_camp_room_plan_pdf(%L,1,1,1,%L)',camp,gen_random_uuid()));
  perform pg_temp.a11_check(r->>'state'='42501','ordinary user cannot request staff roster PDF');
  r:=pg_temp.a11_call(staff,format('select public.begin_staff_camp_room_plan_pdf(%L,0,1,1,%L)',camp,gen_random_uuid()));
  perform pg_temp.a11_check(r->>'message'='stale-update','stale roster version rejected');
  r:=pg_temp.a11_call(staff,format('select public.begin_staff_camp_room_plan_pdf(%L,1,1,1,%L) id',camp,gen_random_uuid()));
  version_id:=(r->'rows'->0->>'id')::uuid;
  perform pg_temp.a11_check(version_id is not null,'staff requests immutable room plan PDF');
  perform pg_temp.a11_check((select source_snapshot#>>'{entries,0,management_name}'='架空対象者'
    and source_snapshot#>>'{entries,0,eligible_user_id}'=eligible::text and source_snapshot#>>'{entries,0,room_name}'='架空印字室'
    and source_snapshot->>'start_date'=(current_date+100)::text and source_snapshot->>'end_date'=(current_date+102)::text
    from public.camp_room_plan_pdf_versions where id=version_id),'snapshot has only required staff roster fields');
  perform pg_temp.a11_check(public.authorize_camp_room_plan_pdf_delivery(version_id,user_id,'GET')->>'allowed'='false','ordinary user cannot download');
  perform pg_temp.a11_check(public.authorize_camp_room_plan_pdf_delivery(version_id,staff,'GET')->>'allowed'='false','pending PDF is not downloadable');
  r:=pg_temp.a11_call(staff,format('select public.claim_camp_room_plan_pdf_job(null) value'),'service_role');
  job_id=(r#>>'{rows,0,value,job_id}')::uuid; attempt_id=(r#>>'{rows,0,value,attempt_id}')::uuid; source_hash_value=r#>>'{rows,0,value,source_hash}';
  perform pg_temp.a11_check(r#>>'{rows,0,value,document_type}'='staff_room_plan','worker receives explicit document type');
  perform public.complete_camp_room_plan_pdf_job(job_id,attempt_id,source_hash_value,repeat('d',64),12345,report);
  perform pg_temp.a11_check(public.authorize_camp_room_plan_pdf_delivery(version_id,staff,'HEAD')->>'allowed'='true','active staff downloads latest ready PDF');
  perform pg_temp.a11_check((select object_path like 'room-plans/'||version_id::text||'/%' from public.camp_room_plan_pdf_versions where id=version_id),'separate private object namespace');
  update public.camp_eligible_users set management_name='架空対象者改定' where id=eligible;
  perform pg_temp.a11_check(public.authorize_camp_room_plan_pdf_delivery(version_id,staff,'GET')->>'allowed'='false','label change invalidates old named roster PDF');
  foreach r in array array[jsonb_build_object('role','anon'),jsonb_build_object('role','authenticated'),jsonb_build_object('role','service_role')] loop
    perform pg_temp.a11_check(not has_table_privilege(r->>'role','public.camp_room_plan_pdf_versions','select'),(r->>'role')||' cannot directly read names');
  end loop;
end $$;
select count(*)::integer as passed_checks,bool_and(passed) as all_passed from pg_temp.a11_results;
rollback;
