-- A7 only fictional data. The adapter is replaced inside this rollback transaction.
begin;
set local statement_timeout='60s';
create temporary table a7_results(name text,passed boolean) on commit drop;
create function pg_temp.a7_check(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  insert into pg_temp.a7_results values(label,true);
end $$;
create function pg_temp.a7_call(actor uuid,sql_text text,role_value text default 'authenticated') returns jsonb language plpgsql as $$
declare r record; result_value jsonb:='[]'; state_value text; message_value text;
begin
  begin
    execute format('set local role %I',role_value);
    perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role',role_value)::text,true);
    for r in execute sql_text loop result_value:=result_value||jsonb_build_array(to_jsonb(r)); end loop;
    reset role; return jsonb_build_object('ok',true,'rows',result_value);
  exception when others then
    get stacked diagnostics state_value=returned_sqlstate,message_value=message_text;
    reset role; return jsonb_build_object('ok',false,'state',state_value,'message',message_value);
  end;
end $$;
create temporary table a7_fixture(owner_id uuid,other_id uuid,staff_id uuid,camp_id uuid,eligible_id uuid,app_id uuid) on commit drop;
do $$ declare u uuid:=gen_random_uuid(); o uuid:=gen_random_uuid(); s uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); r jsonb; begin
  insert into auth.users(id,email,email_confirmed_at) values(u,'a7-owner@example.invalid',clock_timestamp()),(o,'a7-other@example.invalid',clock_timestamp()),(s,'a7-staff@example.invalid',clock_timestamp());
  insert into public.staff_roles(user_id) values(s);
  insert into public.camps(id,name,start_date,end_date,application_deadline,created_by) values(c,'A7架空',current_date+100,current_date+102,clock_timestamp()+interval '90 days',s);
  perform set_config('private.camp_mode_migration','allowed',true);
  update public.camps set room_assignment_mode='eligible_roster' where id=c;
  insert into public.camp_eligible_users(id,camp_id,email_normalized,linked_user_id,linked_at,linked_email_normalized)
    values(e,c,'a7-owner@example.invalid',u,clock_timestamp(),'a7-owner@example.invalid');
  insert into public.applications(id,user_id,usage_type,camp_id,camp_eligible_user_id,status,start_date,end_date,user_name)
    values(a,u,'camp',c,e,'draft',current_date+100,current_date+102,'架空利用者');
  insert into public.rooms(name,capacity) values('A7専用架空室',2);
  insert into public.camp_room_mapping(room_id,source_name,floor,display_name,print_name,assignment_enabled,printing_enabled,confirmed_at,confirmation_evidence)
    select id,'架空検証原図',2,'架空表示名','架空印字名',true,true,clock_timestamp(),'test-only' from public.rooms where name='A7専用架空室';
  perform set_config('request.jwt.claims',jsonb_build_object('sub',s,'role','authenticated')::text,true);
  perform public.save_camp_room_plan(c,(select roster_version from public.camps where id=c),0,
    jsonb_build_array(jsonb_build_object('eligible_user_id',e,'room_id',(select id from public.rooms where name='A7専用架空室'))));
  insert into pg_temp.a7_fixture values(u,o,s,c,e,a);
  r:=pg_temp.a7_call(u,format('select public.begin_camp_application_pdf(%L,%s,%L)',a,
    (select input_version from public.applications where id=a),gen_random_uuid()));
  perform pg_temp.a7_check(r->>'message'='pdf-prerequisites-unavailable','production adapter fails closed');
  perform pg_temp.a7_check((select count(*)=0 from public.camp_application_versions),'failed begin leaves no version');
  perform pg_temp.a7_check((select count(*)=0 from public.camp_pdf_jobs),'failed begin leaves no job');

  insert into private.camp_pdf_render_setting_versions(settings_version,template_hash,font_version,converter_image,mayor_name,
    user_name_limit,user_address_limit,emergency_name_limit,emergency_address_limit,purpose_limit,special_notes_limit,room_name_limit,verified_at)
  values(1,'39d3621b02fd4559fa227f263f541ccc92dbd0d1b19a663891d0783407c33bfe',
    'NotoSerifJP-2.003+sha256:2c9a12dbd4f2408c4610c7ee84a108b62d7236c3775baed618c64d9cb44b2f04',
    'ghcr.io/example.invalid/camp-pdf-renderer@sha256:'||repeat('a',64),'青木 幸保',20,30,20,30,60,80,15,clock_timestamp());
  insert into private.camp_pdf_active_render_setting(settings_version) values(1);
  update public.applications set user_address='架空住所',user_phone='0191-46-2111',emergency_name='架空連絡先',
    emergency_address='架空住所',emergency_phone='090-0000-0000',usage_place='common_and_second_floor',purpose='架空の滞在目的'
    where id=a;
  perform pg_temp.a7_check(private.camp_pdf_render_settings(a)->>'mayor_name'='青木 幸保','verified versioned settings open gate');
  update public.applications set purpose=repeat('目',61) where id=a;
  r:=pg_temp.a7_call(u,format('select public.begin_camp_application_pdf(%L,%s,%L)',a,
    (select input_version from public.applications where id=a),gen_random_uuid()));
  perform pg_temp.a7_check(r->>'message'='pdf-content-too-long','renderer field capacity enforced by DB gate');
  update public.applications set purpose='架空の滞在目的' where id=a;
  update public.applications set input_version=1 where id=a;
end $$;
create or replace function private.camp_pdf_render_settings(target_application_id uuid)
returns jsonb language sql set search_path='' as $$
  select jsonb_build_object('assignment_version',1,'room_id','11111111-1111-4111-8111-111111111111','room_name','架空検証室',
    'room_capacity',2,'template_hash',repeat('a',64),'settings_version',1,'font_version','test-only','converter_image','test-only','mayor_name','架空設定');
$$;
do $$
declare f record; r jsonb; v uuid; v2 uuid; key_value uuid:=gen_random_uuid(); j uuid; attempt uuid; source text; original jsonb;
  report jsonb:='{"page_count":1,"fonts_embedded":true,"text_verified":true,"layout_verified":true}'; role_name text; sql_text text;
begin
  select * into f from pg_temp.a7_fixture;
  perform pg_temp.a7_check(private.camp_pdf_assignment_context(f.app_id)->>'room_name'='架空印字名','A3 print name is the PDF room source');
  perform pg_temp.a7_check(private.camp_pdf_assignment_context(f.app_id)->>'room_id'=(select id::text from public.rooms where name='A7専用架空室'),'A8 settings cannot forge A3 room ID');
  update public.camp_room_mapping set printing_enabled=false where room_id=(select id from public.rooms where name='A7専用架空室');
  r:=pg_temp.a7_call(f.owner_id,format('select public.begin_camp_application_pdf(%L,1,%L)',f.app_id,gen_random_uuid()));
  perform pg_temp.a7_check(r->>'message'='pdf-room-not-printable','A3 allocation alone does not authorize printing');
  update public.camp_room_mapping set printing_enabled=true,floor=1 where room_id=(select id from public.rooms where name='A7専用架空室');
  r:=pg_temp.a7_call(f.owner_id,format('select public.begin_camp_application_pdf(%L,1,%L)',f.app_id,gen_random_uuid()));
  perform pg_temp.a7_check(r->>'message'='pdf-room-not-printable','non second floor room cannot enter PDF');
  update public.camp_room_mapping set floor=2 where room_id=(select id from public.rooms where name='A7専用架空室');
  update public.calendar_claims set released_from=start_date where camp_id=f.camp_id;
  r:=pg_temp.a7_call(f.owner_id,format('select public.begin_camp_application_pdf(%L,1,%L)',f.app_id,gen_random_uuid()));
  perform pg_temp.a7_check(r->>'message'='pdf-calendar-unavailable','released camp claim denies generation');
  update public.calendar_claims set released_from=null where camp_id=f.camp_id;

  -- Storage policy semantics against the explicitly labelled LOCAL mock only.
  if current_setting('test.a7_storage_mock',true)='true' then
    foreach role_name in array array['anon','authenticated'] loop
      r:=pg_temp.a7_call(f.owner_id,'insert into storage.objects(bucket_id,name) values(''camp-application-pdfs'',''forged.pdf'') returning id',role_name);
      perform pg_temp.a7_check(r->>'state'='42501',role_name||' cannot upload via permissive unrelated policy');
      r:=pg_temp.a7_call(f.owner_id,'insert into storage.objects(bucket_id,name) values(''other-bucket'',''fixture'') returning id',role_name);
      perform pg_temp.a7_check(r->>'ok'='true',role_name||' other bucket policy unchanged');
    end loop;
    insert into storage.objects(bucket_id,name) values('camp-application-pdfs','retained.pdf');
    r:=pg_temp.a7_call(f.owner_id,'select * from storage.objects where bucket_id=''camp-application-pdfs''');
    perform pg_temp.a7_check(r->>'ok'='true' and jsonb_array_length(r->'rows')=0,'Storage object metadata hidden');
    r:=pg_temp.a7_call(f.owner_id,'delete from storage.objects where bucket_id=''camp-application-pdfs'' returning id');
    perform pg_temp.a7_check(r->>'ok'='true' and jsonb_array_length(r->'rows')=0,'Storage deletion cannot see protected objects');
  end if;

  foreach role_name in array array['anon','authenticated','service_role'] loop
    foreach sql_text in array array['select * from public.camp_application_versions','select * from public.camp_pdf_jobs',
      'delete from public.camp_application_versions returning id','update public.camp_pdf_jobs set state=''succeeded'' returning id'] loop
      r:=pg_temp.a7_call(f.owner_id,sql_text,role_name);
      perform pg_temp.a7_check(r->>'state'='42501',role_name||' direct access denied: '||sql_text);
    end loop;
  end loop;
  foreach role_name in array array['anon','authenticated'] loop
    r:=pg_temp.a7_call(f.owner_id,'select public.claim_camp_pdf_job(null)',role_name);
    perform pg_temp.a7_check(r->>'state'='42501',role_name||' worker denied');
    r:=pg_temp.a7_call(f.owner_id,format('select public.authorize_camp_pdf_delivery(%L,%L,''GET'')',gen_random_uuid(),f.staff_id),role_name);
    perform pg_temp.a7_check(r->>'state'='42501',role_name||' cannot impersonate delivery actor');
  end loop;
  r:=pg_temp.a7_call(f.other_id,format('select public.begin_camp_application_pdf(%L,1,%L)',f.app_id,key_value));
  perform pg_temp.a7_check(r->>'state'='42501','other user cannot begin');
  r:=pg_temp.a7_call(f.owner_id,format('select public.begin_camp_application_pdf(%L,2,%L)',f.app_id,key_value));
  perform pg_temp.a7_check(r->>'message'='stale-update','stale input denied');
  r:=pg_temp.a7_call(f.owner_id,format('select public.begin_camp_application_pdf(%L,1,%L) as id',f.app_id,key_value));
  v:=(r->'rows'->0->>'id')::uuid;
  perform pg_temp.a7_check(v is not null,'owner begins');
  r:=pg_temp.a7_call(f.owner_id,format('select public.begin_camp_application_pdf(%L,1,%L) as id',f.app_id,key_value));
  perform pg_temp.a7_check((r->'rows'->0->>'id')::uuid=v,'idempotent begin');
  select id into j from public.camp_pdf_jobs where version_id=v;
  r:=pg_temp.a7_call(null,format('select public.claim_camp_pdf_job(%L) as job',j),'service_role');
  attempt:=(r->'rows'->0->'job'->>'attempt_id')::uuid; source:=r->'rows'->0->'job'->>'source_hash';
  perform pg_temp.a7_check(attempt is not null and length(source)=64,'worker claims immutable snapshot: '||r::text);
  r:=pg_temp.a7_call(null,format('select public.claim_camp_pdf_job(%L)',j),'service_role');
  perform pg_temp.a7_check(r->>'message'='job-unavailable','double claim denied');
  r:=pg_temp.a7_call(null,format('select public.complete_camp_pdf_job(%L,%L,%L,%L,100,%L)',j,gen_random_uuid(),source,repeat('b',64),report),'service_role');
  perform pg_temp.a7_check(r->>'message'='job-unavailable','wrong attempt denied');
  r:=pg_temp.a7_call(null,format('select public.complete_camp_pdf_job(%L,%L,%L,%L,100,%L)',j,attempt,repeat('0',64),repeat('b',64),report),'service_role');
  perform pg_temp.a7_check(r->>'message'='stale-update','source mismatch denied');
  r:=pg_temp.a7_call(null,format('select public.complete_camp_pdf_job(%L,%L,%L,%L,100,''{}'')',j,attempt,source,repeat('b',64)),'service_role');
  perform pg_temp.a7_check(r->>'message'='invalid-pdf-result','unverified render denied');
  r:=pg_temp.a7_call(null,format('select public.complete_camp_pdf_job(%L,%L,%L,%L,100,%L)',j,attempt,source,repeat('b',64),report),'service_role');
  perform pg_temp.a7_check(r->>'ok'='true','validated result registered');
  select to_jsonb(x) into original from public.camp_application_versions x where id=v;
  perform public.record_camp_pdf_job_response_failure(j,attempt);
  perform pg_temp.a7_check((select state='succeeded' from public.camp_pdf_jobs where id=j),'uncertain response observation preserves successful job');
  perform pg_temp.a7_check(original=(select to_jsonb(x) from public.camp_application_versions x where id=v),'uncertain response observation preserves PDF');
  perform pg_temp.a7_check((select count(*)=1 from public.audit_logs where entity_id=v and action='pdf_result_response_failed'),'response failure is auditable without claiming rollback');
  perform public.record_camp_pdf_job_response_failure(j,gen_random_uuid());
  perform pg_temp.a7_check((select count(*)=1 from public.audit_logs where entity_id=v and action='pdf_result_response_failed'),'wrong attempt cannot forge failure observation');

  r:=pg_temp.a7_call(null,format('select public.complete_camp_pdf_job(%L,%L,%L,%L,100,%L)',j,attempt,source,repeat('b',64),report),'service_role');
  perform pg_temp.a7_check(r->>'ok'='true' and original=(select to_jsonb(x) from public.camp_application_versions x where id=v),'identical completion is immutable replay');
  r:=pg_temp.a7_call(null,format('select public.complete_camp_pdf_job(%L,%L,%L,%L,100,%L)',j,attempt,source,repeat('c',64),report),'service_role');
  perform pg_temp.a7_check(r->>'ok'='false','different completion cannot replace bytes');
  perform pg_temp.a7_check((select render_context->>'room_name'='架空印字名' and render_context->>'room_id'<>'11111111-1111-4111-8111-111111111111' from public.camp_application_versions where id=v),'snapshot contains real A3 mapping rather than forged settings');
  insert into public.camp_eligible_users(camp_id,email_normalized) values(f.camp_id,'a7-new-unassigned@example.invalid');
  perform pg_temp.a7_check((select roster_version<>saved_roster_version from public.camps where id=f.camp_id),'new eligible user makes the full roster incomplete');
  perform pg_temp.a7_check(public.authorize_camp_pdf_delivery(v,f.owner_id,'GET')->>'allowed'='true','existing individual PDF remains valid after another unassigned user is added');
  delete from public.camp_eligible_users where camp_id=f.camp_id and email_normalized='a7-new-unassigned@example.invalid';
  update public.camp_room_mapping set print_name='変更後の架空印字名' where room_id=(select id from public.rooms where name='A7専用架空室');
  perform pg_temp.a7_check(public.authorize_camp_pdf_delivery(v,f.owner_id,'GET')->>'allowed'='false','changed print mapping invalidates old confirmation PDF');
  update public.camp_room_mapping set print_name='架空印字名' where room_id=(select id from public.rooms where name='A7専用架空室');
  foreach role_name in array array['GET','HEAD'] loop
    r:=public.authorize_camp_pdf_delivery(v,f.owner_id,role_name);
    perform pg_temp.a7_check(r->>'allowed'='true','owner ready delivery '||role_name);
    r:=public.authorize_camp_pdf_delivery(v,f.other_id,role_name);
    perform pg_temp.a7_check(r='{"allowed":false}'::jsonb,'other denied without path '||role_name);
    r:=public.authorize_camp_pdf_delivery(v,f.staff_id,role_name);
    perform pg_temp.a7_check(r->>'allowed'='false','staff cannot view unsubmitted '||role_name);
  end loop;
  update public.camp_eligible_users set disabled_at=clock_timestamp() where id=f.eligible_id;
  perform pg_temp.a7_check(public.authorize_camp_pdf_delivery(v,f.owner_id,'GET')->>'allowed'='false','revoked eligibility denies');
  update public.camp_eligible_users set disabled_at=null where id=f.eligible_id;
  update public.profiles set account_state='disabled' where id=f.owner_id;
  perform pg_temp.a7_check(public.authorize_camp_pdf_delivery(v,f.owner_id,'HEAD')->>'allowed'='false','disabled owner denies');
  update public.profiles set account_state='active' where id=f.owner_id;
  update public.camps set room_plan_version=room_plan_version+1 where id=f.camp_id;
  perform pg_temp.a7_check(public.authorize_camp_pdf_delivery(v,f.owner_id,'GET')->>'allowed'='false','changed room plan invalidates ready PDF');
  update public.camps set room_plan_version=room_plan_version-1 where id=f.camp_id;
  update public.applications set purpose='changed input' where id=f.app_id;
  perform pg_temp.a7_check(public.authorize_camp_pdf_delivery(v,f.owner_id,'GET')->>'allowed'='false','input edit invalidates ready PDF');
  -- Reset only the test fixture before exercising A9 retention; runtime cannot do this.
  update public.applications set input_version=1 where id=f.app_id;
  update public.camps set application_deadline=clock_timestamp()-interval '1 second' where id=f.camp_id;
  perform pg_temp.a7_check(public.authorize_camp_pdf_delivery(v,f.owner_id,'HEAD')->>'allowed'='false','deadline reached denies owner');
  update public.camps set application_deadline=clock_timestamp()+interval '90 days' where id=f.camp_id;

  -- A9 integration simulation, never available to authenticated/service roles.
  perform set_config('private.camp_pdf_submission','allowed',true);
  update public.camp_application_versions set state='submitted',confirmed_at=clock_timestamp(),submitted_at=clock_timestamp() where id=v;
  select to_jsonb(x) into original from public.camp_application_versions x where id=v;
  perform pg_temp.a7_check(public.authorize_camp_pdf_delivery(v,f.owner_id,'GET')->>'allowed'='false','owner submitted history not exposed');
  perform pg_temp.a7_check(public.authorize_camp_pdf_delivery(v,f.staff_id,'GET')->>'allowed'='true','staff submitted allowed');
  delete from public.staff_roles where user_id=f.staff_id;
  perform pg_temp.a7_check(public.authorize_camp_pdf_delivery(v,f.staff_id,'HEAD')->>'allowed'='false','staff role cancellation denies immediately');
  insert into public.staff_roles(user_id) values(f.staff_id);
  begin update public.camp_application_versions set pdf_hash=repeat('d',64) where id=v;
    raise exception 'mutation unexpectedly succeeded'; exception when others then perform pg_temp.a7_check(sqlerrm='pdf-version-immutable','submitted hash cannot change'); end;
  begin delete from public.camp_application_versions where id=v;
    raise exception 'deletion unexpectedly succeeded'; exception when others then perform pg_temp.a7_check(sqlerrm='pdf-version-immutable','submitted version cannot be deleted'); end;
  r:=pg_temp.a7_call(f.owner_id,format('select public.begin_camp_application_pdf(%L,1,%L) as id',f.app_id,gen_random_uuid()));
  v2:=(r->'rows'->0->>'id')::uuid;
  perform pg_temp.a7_check(v2 is not null and v2<>v and original=(select to_jsonb(x) from public.camp_application_versions x where id=v),'replacement preserves submitted original');
  select id into j from public.camp_pdf_jobs where version_id=v2;
  r:=public.claim_camp_pdf_job(j); attempt:=(r->>'attempt_id')::uuid; source:=r->>'source_hash';
  update public.camp_pdf_jobs set lease_until=clock_timestamp()-interval '2 hours' where id=j;
  r:=public.claim_camp_pdf_cleanup();
  perform pg_temp.a7_check(r->>'job_id'=j::text,'expired orphan reserved');
  perform pg_temp.a7_check((select state='cleaning' from public.camp_pdf_jobs where id=j),'cleanup blocks publication');
  r:=pg_temp.a7_call(null,format('select public.complete_camp_pdf_job(%L,%L,%L,%L,100,%L)',j,attempt,source,repeat('e',64),report),'service_role');
  perform pg_temp.a7_check(r->>'message'='job-unavailable','late callback denied after cleanup reservation');
  perform pg_temp.a7_check(public.complete_camp_pdf_cleanup(j,gen_random_uuid())=false,'wrong cleanup token denied');
  perform pg_temp.a7_check(public.complete_camp_pdf_cleanup(j,(select cleanup_token from public.camp_pdf_jobs where id=j)),'cleanup completion recorded');
  perform pg_temp.a7_check(public.claim_camp_pdf_cleanup() is null,'submitted and ready objects excluded from cleanup');
  perform pg_temp.a7_check(original=(select to_jsonb(x) from public.camp_application_versions x where id=v),'past version unchanged after cleanup');
  perform pg_temp.a7_check((select user_name='架空利用者' and status='draft' from public.applications where id=f.app_id),'generation does not submit or change name');
  perform pg_temp.a7_check((select management_name is null from public.camp_eligible_users where id=f.eligible_id),'generation does not sync management name');
  perform pg_temp.a7_check((select count(*)>0 from public.audit_logs where entity_type='camp_pdf' and action='pdf_delivery_denied'),'denial audited');
  perform pg_temp.a7_check((select count(*)>0 from public.audit_logs where entity_type='camp_pdf' and action='pdf_ready'),'ready audited');
  r:=pg_temp.a7_call(f.staff_id,format('select * from public.get_staff_camp_application_versions(%L)',f.app_id));
  perform pg_temp.a7_check(jsonb_array_length(r->'rows')=1 and not (r->'rows'->0 ? 'object_path'),'staff history projects submitted metadata only');
end $$;
create function pg_temp.a7_reject_ready_audit() returns trigger language plpgsql as $$
begin raise exception 'fictional-audit-failure'; end $$;
create trigger a7_reject_ready_audit before insert on public.audit_logs
for each row when(new.entity_type='camp_pdf' and new.action='pdf_ready') execute function pg_temp.a7_reject_ready_audit();
create temporary table a7_last_version(id uuid) on commit drop;
do $$ declare f record; r jsonb; id_value uuid; j jsonb; v public.camp_application_versions%rowtype; begin
  select * into f from pg_temp.a7_fixture;
  r:=pg_temp.a7_call(f.owner_id,format('select public.begin_camp_application_pdf(%L,1,%L) as id',f.app_id,gen_random_uuid()));
  id_value:=(r->'rows'->0->>'id')::uuid;
  insert into pg_temp.a7_last_version values(id_value);
  j:=public.claim_camp_pdf_job((select id from public.camp_pdf_jobs where version_id=id_value));
  r:=pg_temp.a7_call(null,format('select public.complete_camp_pdf_job(%L,%L,%L,%L,100,%L)',j->>'job_id',j->>'attempt_id',j->>'source_hash',repeat('e',64),
    '{"page_count":1,"fonts_embedded":true,"text_verified":true,"layout_verified":true}'),'service_role');
  perform pg_temp.a7_check(r->>'message'='fictional-audit-failure','audit insertion failure aborts completion');
  perform pg_temp.a7_check((select state='pending' and object_path is null from public.camp_application_versions where id=id_value),'audit failure leaves version unregistered');
  perform pg_temp.a7_check((select state='running' from public.camp_pdf_jobs where version_id=id_value),'audit failure rolls job state back');
  drop trigger a7_reject_ready_audit on public.audit_logs;
  perform public.complete_camp_pdf_job((j->>'job_id')::uuid,(j->>'attempt_id')::uuid,j->>'source_hash',repeat('e',64),100,
    '{"page_count":1,"fonts_embedded":true,"text_verified":true,"layout_verified":true}');
  select * into v from public.camp_application_versions where id=id_value;
  perform pg_temp.a7_check(private.camp_pdf_is_current(v),'current valid version accepted');
  v.application_date:=v.application_date-1;
  perform pg_temp.a7_check(private.camp_pdf_is_current(v)=false,'previous JST date is stale');
  -- Cross-scope insert cannot turn a PDF into another usage type or owner record.
  begin
    insert into public.camp_application_versions(application_id,camp_id,eligible_user_id,owner_id,version_no,request_key,input_version,room_plan_version,
      application_date,source_snapshot,source_hash,render_context)
    values(f.app_id,f.camp_id,f.eligible_id,f.other_id,99,gen_random_uuid(),1,0,current_date,'{}',repeat('a',64),'{}');
    raise exception 'wrong owner succeeded';
  exception when others then perform pg_temp.a7_check(sqlerrm='pdf-scope-mismatch','wrong owner rejected at table boundary'); end;
end $$;
create or replace function private.camp_pdf_render_settings(target_application_id uuid)
returns jsonb language sql set search_path='' as $$ select null::jsonb $$;
do $$ declare f record; begin
  select * into f from pg_temp.a7_fixture;
  perform pg_temp.a7_check(public.authorize_camp_pdf_delivery((select id from pg_temp.a7_last_version),f.owner_id,'GET')->>'allowed'='false',
    'unavailable render context fails closed, including SQL NULL');
end $$;
select count(*)::integer passed_checks,bool_and(passed) all_passed from pg_temp.a7_results;
rollback;
