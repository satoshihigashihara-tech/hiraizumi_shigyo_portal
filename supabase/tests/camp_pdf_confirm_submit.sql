-- A9 only fictional data. Everything rolls back.
begin;
set local statement_timeout='60s';
create temporary table a9_results(name text,passed boolean) on commit drop;
create function pg_temp.a9_check(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  insert into pg_temp.a9_results values(label,true);
end $$;
create function pg_temp.a9_call(actor uuid,sql_text text,role_value text default 'authenticated') returns jsonb language plpgsql as $$
declare r record; rows_value jsonb:='[]'; state_value text; message_value text;
begin
  begin
    execute format('set local role %I',role_value);
    perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role',role_value)::text,true);
    for r in execute sql_text loop rows_value:=rows_value||jsonb_build_array(to_jsonb(r)); end loop;
    reset role; return jsonb_build_object('ok',true,'rows',rows_value);
  exception when others then
    get stacked diagnostics state_value=returned_sqlstate,message_value=message_text;
    reset role; return jsonb_build_object('ok',false,'state',state_value,'message',message_value);
  end;
end $$;
create function pg_temp.a9_reject_name_audit() returns trigger language plpgsql as $$ begin
  if new.action='sync_camp_submission_names' then raise exception 'fictional-name-audit-failure'; end if;
  return new;
end $$;

do $$
declare owner_id uuid:=gen_random_uuid(); other_id uuid:=gen_random_uuid(); staff_id uuid:=gen_random_uuid();
  camp_id uuid:=gen_random_uuid(); eligible_id uuid:=gen_random_uuid(); app_id uuid:=gen_random_uuid(); room_id uuid:=gen_random_uuid();
  pdf_version_id_value uuid; revision_version_id uuid; job_id uuid; attempt_id uuid; request_key uuid:=gen_random_uuid(); submission_key_value uuid:=gen_random_uuid();
  source_hash text; r jsonb; context_value jsonb; input_value bigint; original_setting bigint; second_setting bigint;
  receipt_before text; charge_before jsonb;
  report jsonb:='{"page_count":1,"fonts_embedded":true,"text_verified":true,"layout_verified":true}';
begin
  insert into auth.users(id,email,email_confirmed_at) values
    (owner_id,'a9-owner@example.invalid',clock_timestamp()),
    (other_id,'a9-other@example.invalid',clock_timestamp()),
    (staff_id,'a9-staff@example.invalid',clock_timestamp());
  insert into public.staff_roles(user_id) values(staff_id);
  update public.profiles set full_name='旧プロフィール名' where id=owner_id;
  insert into public.camps(id,name,start_date,end_date,application_deadline,created_by)
    values(camp_id,'A9架空',current_date+100,current_date+102,clock_timestamp()+interval '90 days',staff_id);
  perform set_config('private.camp_mode_migration','allowed',true);
  update public.camps set room_assignment_mode='eligible_roster' where id=camp_id;
  perform set_config('private.camp_mode_migration','',true);
  insert into public.camp_eligible_users(id,camp_id,email_normalized,linked_user_id,linked_at,linked_email_normalized,management_name)
    values(eligible_id,camp_id,'a9-owner@example.invalid',owner_id,clock_timestamp(),'a9-owner@example.invalid','旧管理名');
  insert into public.applications(id,user_id,usage_type,camp_id,camp_eligible_user_id,status,start_date,end_date)
    values(app_id,owner_id,'camp',camp_id,eligible_id,'draft',current_date+100,current_date+102);
  insert into public.rooms(id,name,capacity) values(room_id,'A9専用架空室',2);
  insert into public.camp_room_mapping(room_id,source_name,floor,display_name,print_name,assignment_enabled,printing_enabled,confirmed_at,confirmation_evidence)
    values(room_id,'A9架空原図',2,'A9架空表示','A9架空印字',true,true,clock_timestamp(),'test-only');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',staff_id,'role','authenticated')::text,true);
  perform public.save_camp_room_plan(camp_id,(select roster_version from public.camps where id=camp_id),0,
    jsonb_build_array(jsonb_build_object('eligible_user_id',eligible_id,'room_id',room_id)));

  select settings_version into original_setting from private.camp_pdf_active_render_setting where singleton;
  if original_setting is null then
    select coalesce(max(settings_version),0)+1 into original_setting from private.camp_pdf_render_setting_versions;
    insert into private.camp_pdf_render_setting_versions(settings_version,template_hash,font_version,converter_image,mayor_name,
      user_name_limit,user_address_limit,emergency_name_limit,emergency_address_limit,purpose_limit,special_notes_limit,room_name_limit,verified_at)
    values(original_setting,repeat('a',64),
      'NotoSerifJP-2.003+sha256:2c9a12dbd4f2408c4610c7ee84a108b62d7236c3775baed618c64d9cb44b2f04',
      'ghcr.io/example.invalid/camp-pdf-renderer@sha256:'||repeat('a',64),
      '架空町長',20,30,20,30,60,48,15,clock_timestamp());
    insert into private.camp_pdf_active_render_setting(settings_version) values(original_setting);
  end if;

  r:=pg_temp.a9_call(owner_id,format('select public.save_camp_application_draft(%L,%L,%L,%L,%L,%L,%L,%L,%L,false,%L)',
    app_id,'不正旧経路','架空住所','0191-46-2111','架空連絡先','架空住所','090-0000-0000','架空目的',null,'shared_ok'));
  perform pg_temp.a9_check(r->>'message'='eligible-roster-form-required','legacy save path blocked: '||r::text);
  r:=pg_temp.a9_call(other_id,format('select public.save_camp_roster_application_draft(%L,1,%L,%L,%L,%L,%L,%L,%L,%L,false)',
    app_id,'A9正式氏名','架空住所','0191-46-2111','架空連絡先','架空住所','090-0000-0000','架空目的',null));
  perform pg_temp.a9_check(r->>'state'='42501','other owner cannot save');
  r:=pg_temp.a9_call(owner_id,format('select * from public.save_camp_roster_application_draft(%L,1,%L,%L,%L,%L,%L,%L,%L,%L,false)',
    app_id,'A9正式氏名','架空住所','0191-46-2111','架空連絡先','架空住所','090-0000-0000','架空目的',null));
  perform pg_temp.a9_check(r->>'ok'='true','owner saves roster form');
  select input_version into input_value from public.applications where id=app_id;
  perform pg_temp.a9_check(input_value>1 and (select room_preference is null from public.applications where id=app_id),'save versions input and ignores room preference');
  r:=pg_temp.a9_call(owner_id,format('select public.submit_camp_application(%L)',app_id));
  perform pg_temp.a9_check(r->>'ok'='false' and (select status='draft' from public.applications where id=app_id),'legacy submit path cannot submit roster application');
  r:=pg_temp.a9_call(owner_id,format('select * from public.save_camp_roster_application_draft(%L,1,%L,%L,%L,%L,%L,%L,%L,%L,false)',
    app_id,'A9正式氏名','架空住所','0191-46-2111','架空連絡先','架空住所','090-0000-0000','架空目的',null));
  perform pg_temp.a9_check(r->>'message'='stale-update','stale save denied');

  r:=pg_temp.a9_call(owner_id,format('select public.begin_camp_application_pdf(%L,%s,%L) id',app_id,input_value,request_key));
  pdf_version_id_value:=(r->'rows'->0->>'id')::uuid;
  select j.id into job_id from public.camp_pdf_jobs j where j.version_id=pdf_version_id_value;
  r:=pg_temp.a9_call(null,format('select public.claim_camp_pdf_job(%L) job',job_id),'service_role');
  attempt_id:=(r->'rows'->0->'job'->>'attempt_id')::uuid;
  source_hash:=r->'rows'->0->'job'->>'source_hash';
  r:=pg_temp.a9_call(null,format('select public.complete_camp_pdf_job(%L,%L,%L,%L,100,%L)',job_id,attempt_id,source_hash,repeat('b',64),report),'service_role');
  perform pg_temp.a9_check(r->>'ok'='true','one-page PDF becomes ready');
  perform pg_temp.a9_check((select source_snapshot->>'previously_approved'='false' from public.camp_application_versions where id=pdf_version_id_value),'initial PDF selects pre-approval change contract');

  r:=pg_temp.a9_call(other_id,format('select public.get_my_camp_pdf_submission_context(%L)',app_id));
  perform pg_temp.a9_check(r->>'state'='42501','other owner cannot read PDF context');
  r:=pg_temp.a9_call(owner_id,format('select public.get_my_camp_pdf_submission_context(%L) context',app_id));
  context_value:=r->'rows'->0->'context';
  perform pg_temp.a9_check(context_value->>'pdf_state'='ready' and context_value->>'pdf_version_id'=pdf_version_id_value::text,'owner sees canonical ready version');
  perform pg_temp.a9_check(not (context_value ?| array['email_snapshot','object_path','render_snapshot','render_context','job_id']),'context omits secrets and worker data');

  r:=pg_temp.a9_call(owner_id,format('select * from public.submit_camp_application_with_pdf(%L,%L,%s,%L,false)',app_id,pdf_version_id_value,input_value,submission_key_value));
  perform pg_temp.a9_check(r->>'message'='pdf-confirmation-required','explicit PDF confirmation required');
  r:=pg_temp.a9_call(owner_id,format('select * from public.submit_camp_application_with_pdf(%L,%L,%s,%L,true)',app_id,pdf_version_id_value,input_value+1,submission_key_value));
  perform pg_temp.a9_check(r->>'message'='stale-update','stale input version denied');
  update public.camps set room_plan_version=room_plan_version+1 where id=camp_id;
  r:=pg_temp.a9_call(owner_id,format('select * from public.submit_camp_application_with_pdf(%L,%L,%s,%L,true)',app_id,pdf_version_id_value,input_value,submission_key_value));
  perform pg_temp.a9_check(r->>'message'='stale-update','changed room plan denies old PDF');
  update public.camps set room_plan_version=room_plan_version-1 where id=camp_id;
  select max(settings_version)+1 into second_setting from private.camp_pdf_render_setting_versions;
  insert into private.camp_pdf_render_setting_versions(settings_version,template_hash,font_version,converter_image,mayor_name,
    user_name_limit,user_address_limit,emergency_name_limit,emergency_address_limit,purpose_limit,special_notes_limit,room_name_limit,verified_at)
  select second_setting,repeat('c',64),font_version,converter_image,mayor_name,user_name_limit,user_address_limit,
    emergency_name_limit,emergency_address_limit,purpose_limit,special_notes_limit,room_name_limit,clock_timestamp()
  from private.camp_pdf_render_setting_versions where settings_version=original_setting;
  update private.camp_pdf_active_render_setting set settings_version=second_setting where singleton;
  r:=pg_temp.a9_call(owner_id,format('select * from public.submit_camp_application_with_pdf(%L,%L,%s,%L,true)',app_id,pdf_version_id_value,input_value,submission_key_value));
  perform pg_temp.a9_check(r->>'message'='stale-update','changed template denies old PDF');
  update private.camp_pdf_active_render_setting set settings_version=original_setting where singleton;
  update public.camps set application_deadline=clock_timestamp()-interval '1 second' where id=camp_id;
  r:=pg_temp.a9_call(owner_id,format('select * from public.submit_camp_application_with_pdf(%L,%L,%s,%L,true)',app_id,pdf_version_id_value,input_value,submission_key_value));
  perform pg_temp.a9_check(r->>'message'='deadline-passed','JST deadline is rechecked');
  update public.camps set application_deadline=clock_timestamp()+interval '90 days' where id=camp_id;
  update public.camp_eligible_users set disabled_at=clock_timestamp() where id=eligible_id;
  r:=pg_temp.a9_call(owner_id,format('select * from public.submit_camp_application_with_pdf(%L,%L,%s,%L,true)',app_id,pdf_version_id_value,input_value,submission_key_value));
  perform pg_temp.a9_check(r->>'state'='42501','eligibility is rechecked');
  update public.camp_eligible_users set disabled_at=null where id=eligible_id;

  create trigger a9_reject_name_audit before insert on public.audit_logs
    for each row execute function pg_temp.a9_reject_name_audit();
  r:=pg_temp.a9_call(owner_id,format('select * from public.submit_camp_application_with_pdf(%L,%L,%s,%L,true)',app_id,pdf_version_id_value,input_value,submission_key_value));
  perform pg_temp.a9_check(r->>'message'='fictional-name-audit-failure','name audit failure aborts submission');
  perform pg_temp.a9_check((select status='draft' and latest_submitted_camp_pdf_version_id is null from public.applications where id=app_id)
    and (select state='ready' and submission_key is null from public.camp_application_versions where id=pdf_version_id_value)
    and (select full_name='旧プロフィール名' from public.profiles where id=owner_id)
    and (select management_name='旧管理名' from public.camp_eligible_users where id=eligible_id)
    and not exists(select 1 from public.reception_numbers where application_id=app_id),'audit failure rolls back every submission write');
  drop trigger a9_reject_name_audit on public.audit_logs;

  r:=pg_temp.a9_call(owner_id,format('select * from public.submit_camp_application_with_pdf(%L,%L,%s,%L,true)',app_id,pdf_version_id_value,input_value,submission_key_value));
  perform pg_temp.a9_check(r->>'ok'='true' and r->'rows'->0->>'submitted_version_id'=pdf_version_id_value::text,'confirmed canonical PDF submits atomically');
  perform pg_temp.a9_check((select status='submitted' and latest_submitted_camp_pdf_version_id=pdf_version_id_value from public.applications where id=app_id),'application references submitted PDF');
  perform pg_temp.a9_check((select a9.state='submitted' and a9.submission_key=submission_key_value from public.camp_application_versions a9 where a9.id=pdf_version_id_value),'PDF retains submission key');
  perform pg_temp.a9_check((select full_name='A9正式氏名' from public.profiles where id=owner_id)
    and (select management_name='A9正式氏名' from public.camp_eligible_users where id=eligible_id),'names synchronize in transaction');
  perform pg_temp.a9_check((select count(*)=1 from public.reception_numbers where application_id=app_id)
    and (select count(*)=1 from public.application_charges where application_id=app_id),'one receipt and charge created');
  perform pg_temp.a9_check((select count(*)=1 from public.application_status_events where application_id=app_id and to_status='submitted')
    and (select count(*)=1 from public.audit_logs where entity_id=eligible_id and action='sync_camp_submission_names')
    and (select count(*)=1 from public.audit_logs where entity_id=pdf_version_id_value and action='pdf_confirmed_and_submitted'),'status, name, and PDF audits exist');
  r:=pg_temp.a9_call(owner_id,format('select * from public.submit_camp_application_with_pdf(%L,%L,%s,%L,true)',app_id,pdf_version_id_value,input_value,submission_key_value));
  perform pg_temp.a9_check(r->>'ok'='true' and (select count(*)=1 from public.reception_numbers where application_id=app_id),'same key replays without duplication');
  r:=pg_temp.a9_call(owner_id,format('select * from public.submit_camp_application_with_pdf(%L,%L,%s,%L,true)',app_id,pdf_version_id_value,input_value,gen_random_uuid()));
  perform pg_temp.a9_check(r->>'message'='not-submittable','different second submission denied');

  select display_number into receipt_before from public.reception_numbers where application_id=app_id;
  select to_jsonb(q) into charge_before from public.application_charges q where q.application_id=app_id;
  insert into public.application_status_events(application_id,from_status,to_status,actor_user_id)
    values(app_id,'submitted','approved',staff_id);
  update public.applications set status='revision_requested',revision_due_at=clock_timestamp()+interval '7 days' where id=app_id;
  select input_version into input_value from public.applications where id=app_id;
  r:=pg_temp.a9_call(owner_id,format('select * from public.save_camp_roster_application_draft(%L,%s,%L,%L,%L,%L,%L,%L,%L,%L,false)',
    app_id,input_value,'A9再提出氏名','架空住所','0191-46-2111','架空連絡先','架空住所','090-0000-0000','架空の変更目的',null));
  perform pg_temp.a9_check(r->>'ok'='true','revision form saves without replacing receipt or charge');
  select input_version into input_value from public.applications where id=app_id;
  r:=pg_temp.a9_call(owner_id,format('select public.begin_camp_application_pdf(%L,%s,%L) id',app_id,input_value,gen_random_uuid()));
  revision_version_id:=(r->'rows'->0->>'id')::uuid;
  perform pg_temp.a9_check((select source_snapshot->>'previously_approved'='true' from public.camp_application_versions where id=revision_version_id),'approved history selects post-approval change contract');
  select j.id into job_id from public.camp_pdf_jobs j where j.version_id=revision_version_id;
  r:=pg_temp.a9_call(null,format('select public.claim_camp_pdf_job(%L) job',job_id),'service_role');
  attempt_id:=(r->'rows'->0->'job'->>'attempt_id')::uuid;
  source_hash:=r->'rows'->0->'job'->>'source_hash';
  r:=pg_temp.a9_call(null,format('select public.complete_camp_pdf_job(%L,%L,%L,%L,100,%L)',job_id,attempt_id,source_hash,repeat('d',64),report),'service_role');
  perform pg_temp.a9_check(r->>'ok'='true','revision PDF becomes ready');
  r:=pg_temp.a9_call(owner_id,format('select * from public.submit_camp_application_with_pdf(%L,%L,%s,%L,true)',app_id,revision_version_id,input_value,gen_random_uuid()));
  perform pg_temp.a9_check(r->>'ok'='true','revision PDF submits');
  perform pg_temp.a9_check((select display_number=receipt_before from public.reception_numbers where application_id=app_id)
    and (select to_jsonb(q)=charge_before from public.application_charges q where q.application_id=app_id)
    and (select count(*)=1 from public.application_charges where application_id=app_id),'revision preserves receipt, charge, and payment');
  perform pg_temp.a9_check((select latest_submitted_camp_pdf_version_id=revision_version_id from public.applications where id=app_id)
    and (select state='submitted' from public.camp_application_versions where id=pdf_version_id_value)
    and (select state='submitted' from public.camp_application_versions where id=revision_version_id),'revision advances latest pointer and retains both immutable PDFs');
end $$;

select count(*)::integer as passed_checks,bool_and(passed) as all_passed from pg_temp.a9_results;
rollback;
