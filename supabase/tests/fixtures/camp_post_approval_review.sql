-- Fictional A10 fixtures, only loaded by the isolated DB test runner.
create schema a10_review_test;
create table a10_review_test.context(staff uuid,owner uuid[],camp uuid,eligible uuid[],app uuid[],room uuid[],original_setting bigint);
create function a10_review_test.call_as(actor uuid,command text,role_value text default 'authenticated') returns jsonb language plpgsql as $$
declare r record; result jsonb:='[]'; code text; message text;
begin
 begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role',role_value)::text,true);
  execute format('set local role %I',role_value);
  for r in execute command loop result:=result||jsonb_build_array(to_jsonb(r)); end loop;
  reset role; return jsonb_build_object('ok',true,'rows',result);
 exception when others then
  get stacked diagnostics code=returned_sqlstate,message=message_text;
  reset role; return jsonb_build_object('ok',false,'code',code,'message',message);
 end;
end $$;
create function a10_review_test.prepare_pdf(app_id uuid) returns uuid language plpgsql as $$
declare a public.applications%rowtype; v uuid; j uuid; job jsonb; r jsonb;
begin
 select * into a from public.applications where id=app_id;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a.user_id,'role','authenticated')::text,true);
 v:=public.begin_camp_application_pdf(a.id,a.input_version,gen_random_uuid());
 select id into j from public.camp_pdf_jobs where version_id=v;
 r:=a10_review_test.call_as(null,format('select public.claim_camp_pdf_job(%L) value',j),'service_role');
 if r->>'ok'<>'true' then raise exception 'claim fixture failed %',r; end if;
 job:=r->'rows'->0->'value';
 r:=a10_review_test.call_as(null,format('select public.complete_camp_pdf_job(%L,%L,%L,%L,100,%L)',j,job->>'attempt_id',job->>'source_hash',repeat('b',64),
   '{"page_count":1,"fonts_embedded":true,"text_verified":true,"layout_verified":true}'),'service_role');
 if r->>'ok'<>'true' then raise exception 'complete fixture failed %',r; end if;
 return v;
end $$;
create function a10_review_test.submit(app_id uuid) returns uuid language plpgsql as $$
declare a public.applications%rowtype; v uuid; j uuid; job jsonb; r jsonb;
begin
 select * into a from public.applications where id=app_id;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a.user_id,'role','authenticated')::text,true);
 v:=public.begin_camp_application_pdf(a.id,a.input_version,gen_random_uuid());
 select id into j from public.camp_pdf_jobs where version_id=v;
 r:=a10_review_test.call_as(null,format('select public.claim_camp_pdf_job(%L) value',j),'service_role');
 if r->>'ok'<>'true' then raise exception 'claim fixture failed %',r; end if;
 job:=r->'rows'->0->'value';
 r:=a10_review_test.call_as(null,format('select public.complete_camp_pdf_job(%L,%L,%L,%L,100,%L)',j,job->>'attempt_id',job->>'source_hash',repeat('b',64),
   '{"page_count":1,"fonts_embedded":true,"text_verified":true,"layout_verified":true}'),'service_role');
 if r->>'ok'<>'true' then raise exception 'complete fixture failed %',r; end if;
 r:=a10_review_test.call_as(a.user_id,format('select * from public.submit_camp_application_with_pdf(%L,%L,%s,%L,true)',a.id,v,a.input_version,gen_random_uuid()));
 if r->>'ok'<>'true' then raise exception 'submit fixture failed %',r; end if;
 return v;
end $$;
create function a10_review_test.review_command(app_id uuid,operation text) returns text language sql as $$
 select format('select public.review_camp_roster_application(%L,%L,%L,%s,%s,%L,%L,%L) value',
 a.camp_id,a.id,a.updated_at,c.room_plan_version,r.assignment_version,a.latest_submitted_camp_pdf_version_id,operation,'架空審査理由')
 from public.applications a join public.camps c on c.id=a.camp_id join public.camp_room_assignments r on r.eligible_user_id=a.camp_eligible_user_id and r.camp_id=c.id where a.id=app_id;
$$;
create function a10_review_test.review(app_id uuid,operation text) returns jsonb language sql as $$
 select a10_review_test.call_as(staff,a10_review_test.review_command(app_id,operation)) from a10_review_test.context;
$$;
create function a10_review_test.setup() returns void language plpgsql as $$
declare x a10_review_test.context%rowtype; n int; starts date:=(clock_timestamp() at time zone 'Asia/Tokyo')::date+100;
 payload jsonb:='[]'; setting bigint; r jsonb;
begin
 x.staff:=gen_random_uuid();x.camp:=gen_random_uuid();x.owner:='{}';x.eligible:='{}';x.app:='{}';x.room:=array[gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid()];
 insert into auth.users(id,email,email_confirmed_at) values(x.staff,'a10-staff@example.invalid',clock_timestamp());
 insert into public.staff_roles(user_id) values(x.staff);
 insert into public.camps(id,name,start_date,end_date,application_deadline,created_by,room_assignment_mode)
 values(x.camp,'A10架空',starts,starts+3,(starts-1)::timestamp at time zone 'Asia/Tokyo',x.staff,'eligible_roster');
 for n in 1..6 loop
  insert into public.rooms(id,name,capacity) values(x.room[n],'A10架空室'||n,case when n=3 then 1 else 3 end);
  insert into public.camp_room_mapping(room_id,source_name,floor,display_name,print_name,assignment_enabled,printing_enabled,confirmed_at,confirmation_evidence)
  values(x.room[n],'架空原図',2,'架空室'||n,'架空室'||n,true,true,clock_timestamp(),'fictional only');
 end loop;
 for n in 1..7 loop
  x.owner:=array_append(x.owner,gen_random_uuid());x.eligible:=array_append(x.eligible,gen_random_uuid());x.app:=array_append(x.app,case when n=1 then null else gen_random_uuid() end);
  insert into auth.users(id,email,email_confirmed_at) values(x.owner[n],'a10-'||n||'@example.invalid',clock_timestamp());
  insert into public.camp_eligible_users(id,camp_id,email_normalized,management_name,linked_user_id,linked_at,linked_email_normalized)
  values(x.eligible[n],x.camp,'a10-'||n||'@example.invalid','架空氏名'||n,x.owner[n],clock_timestamp(),'a10-'||n||'@example.invalid');
  payload:=payload||jsonb_build_array(jsonb_build_object('eligible_user_id',x.eligible[n],'room_id',x.room[1+(n-1)/3]));
 end loop;
 r:=a10_review_test.call_as(x.staff,format('select public.save_camp_room_plan(%L,7,0,%L)',x.camp,payload));
 if r->>'ok'<>'true' then raise exception 'plan fixture failed %',r; end if;
 select settings_version into x.original_setting from private.camp_pdf_active_render_setting where singleton;
 if x.original_setting is null then
  select coalesce(max(settings_version),0)+1 into setting from private.camp_pdf_render_setting_versions;
  insert into private.camp_pdf_render_setting_versions(settings_version,template_hash,font_version,converter_image,mayor_name,user_name_limit,user_address_limit,emergency_name_limit,emergency_address_limit,purpose_limit,special_notes_limit,room_name_limit,verified_at)
  values(setting,repeat('a',64),'NotoSerifJP-2.003+sha256:2c9a12dbd4f2408c4610c7ee84a108b62d7236c3775baed618c64d9cb44b2f04',
   'ghcr.io/example.invalid/camp-pdf-renderer@sha256:'||repeat('a',64),'架空町長',20,30,20,30,60,48,15,clock_timestamp());
  insert into private.camp_pdf_active_render_setting(settings_version) values(setting);
 end if;
 insert into a10_review_test.context values(x.*);
 for n in 2..7 loop
  insert into public.applications(id,usage_type,camp_id,camp_eligible_user_id,user_id,start_date,end_date,status,user_name,user_address,user_phone,
    emergency_name,emergency_address,emergency_phone,usage_place,purpose,requires_guardian_consent)
  values(x.app[n],'camp',x.camp,x.eligible[n],x.owner[n],starts,starts+3,'draft','架空氏名'||n,'架空住所','090-0000-0000','架空連絡先','架空住所','090-0000-0000','common_and_second_floor','架空目的',false);
  if n>=3 then perform a10_review_test.submit(x.app[n]); end if;
  if n in (4,5,6) then
   r:=a10_review_test.review(x.app[n],'start_review'); if r->>'ok'<>'true' then raise exception 'start fixture failed %',r; end if;
  end if;
  if n=5 then r:=a10_review_test.review(x.app[n],'request_revision'); elsif n=6 then r:=a10_review_test.review(x.app[n],'approve'); end if;
  if n in (5,6) and r->>'ok'<>'true' then raise exception 'review fixture failed %',r; end if;
 end loop;
end $$;
create function a10_review_test.change_command(members int[] default array[1,2,3,4,5,6],room_index int default 4) returns text language plpgsql as $$
declare x a10_review_test.context%rowtype; dto jsonb; payload jsonb; expectations jsonb;
begin
 select * into x from a10_review_test.context;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',x.staff,'role','authenticated')::text,true);
 dto:=public.get_staff_camp_room_change_context(x.camp);
 select jsonb_agg(jsonb_build_object('eligible_user_id',e.id,'room_id',case when array_position(x.eligible,e.id)=any(members) then x.room[room_index+case when room_index in (1,4) then (array_position(x.eligible,e.id)-1)/3 else 0 end] else r.room_id end) order by e.id)
 into payload from public.camp_eligible_users e join public.camp_room_assignments r on r.eligible_user_id=e.id and r.camp_id=e.camp_id
 where e.camp_id=x.camp and e.disabled_at is null and e.participation_status='participating';
 select jsonb_agg(v-array['application_status','stay_status','revision_due_at']) into expectations from jsonb_array_elements(dto->'participants') v;
 return format('select public.change_camp_rooms_and_request_revisions(%L,%s,%s,%L,%L,%L,true) value',x.camp,dto->>'roster_version',dto->>'room_plan_version',payload,expectations,'架空部屋変更');
end $$;
create function a10_review_test.snapshot() returns jsonb language sql as $$
 select jsonb_build_object('camps',(select to_jsonb(c) from public.camps c where c.id=x.camp),
 'members',(select jsonb_agg(to_jsonb(e) order by e.id) from public.camp_eligible_users e where e.camp_id=x.camp),
 'apps',(select jsonb_agg(to_jsonb(a) order by a.id) from public.applications a where a.camp_id=x.camp),
 'assignments',(select jsonb_agg(to_jsonb(a) order by a.id) from public.camp_room_assignments a where a.camp_id=x.camp),
 'plans',(select jsonb_agg(to_jsonb(v) order by v.id) from public.camp_room_plan_versions v where v.camp_id=x.camp),
 'pdfs',(select jsonb_agg(to_jsonb(v) order by v.id) from public.camp_application_versions v where v.camp_id=x.camp),
 'charges',(select jsonb_agg(to_jsonb(v) order by v.id) from public.application_charges v where application_id=any(x.app)),
 'months',(select jsonb_agg(to_jsonb(v) order by v.id) from public.charge_months v where charge_id in(select id from public.application_charges where application_id=any(x.app))),
 'stays',(select jsonb_agg(to_jsonb(v) order by v.id) from public.stays v where application_id=any(x.app)),
 'receipts',(select jsonb_agg(to_jsonb(v) order by v.id) from public.reception_numbers v where application_id=any(x.app)),
 'claims',(select jsonb_agg(to_jsonb(v) order by v.id) from public.calendar_claims v where camp_id=x.camp),
 'events',(select jsonb_agg(to_jsonb(v) order by v.id) from public.application_status_events v where application_id=any(x.app)),
 'audit',(select jsonb_agg(to_jsonb(v) order by v.id) from public.audit_logs v where actor_user_id=x.staff)) from a10_review_test.context x;
$$;
create function a10_review_test.cleanup() returns void language plpgsql as $$
declare x a10_review_test.context%rowtype; setting bigint;
begin
 select * into x from a10_review_test.context;
 if not found then return; end if;
 update public.applications set latest_submitted_camp_pdf_version_id=null where camp_id=x.camp;
 set constraints all immediate;
 delete from public.camp_pdf_jobs where version_id in(select id from public.camp_application_versions where camp_id=x.camp);
 alter table public.camp_application_versions disable trigger camp_pdf_version_guard;
 delete from public.camp_application_versions where camp_id=x.camp;
 alter table public.camp_application_versions enable trigger camp_pdf_version_guard;
 delete from public.camp_room_plan_pdf_jobs where version_id in(select id from public.camp_room_plan_pdf_versions where camp_id=x.camp);
 alter table public.camp_room_plan_pdf_versions disable trigger camp_room_plan_pdf_version_guard;
 delete from public.camp_room_plan_pdf_versions where camp_id=x.camp;
 alter table public.camp_room_plan_pdf_versions enable trigger camp_room_plan_pdf_version_guard;
 alter table public.camp_room_assignments disable trigger camp_room_assignments_guard;
 delete from public.camp_room_assignments where camp_id=x.camp;
 alter table public.camp_room_assignments enable trigger camp_room_assignments_guard;
 alter table public.camp_room_plan_versions disable trigger camp_room_plan_versions_immutable;
 delete from public.camp_room_plan_versions where camp_id=x.camp;
 alter table public.camp_room_plan_versions enable trigger camp_room_plan_versions_immutable;
 delete from public.applications where camp_id=x.camp;
 delete from public.camp_eligible_users where camp_id=x.camp;
 delete from public.calendar_claims where camp_id=x.camp;
 delete from public.camps where id=x.camp;
 delete from public.audit_logs where actor_user_id=x.staff or actor_user_id=any(x.owner);
 delete from public.account_cleanup_jobs where user_id=x.staff or user_id=any(x.owner);
 delete from auth.users where id=x.staff or id=any(x.owner);
 delete from public.camp_room_mapping where room_id=any(x.room);
 delete from public.rooms where id=any(x.room);
 if x.original_setting is null then
  delete from private.camp_pdf_active_render_setting where singleton returning settings_version into setting;
  alter table private.camp_pdf_render_setting_versions disable trigger camp_pdf_render_setting_versions_immutable;
  delete from private.camp_pdf_render_setting_versions where settings_version=setting;
  alter table private.camp_pdf_render_setting_versions enable trigger camp_pdf_render_setting_versions_immutable;
 end if;
 delete from a10_review_test.context;
end $$;
