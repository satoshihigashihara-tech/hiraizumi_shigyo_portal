-- A7 two-connection fixtures. Only run in the disposable local harness.
-- The original gated adapter is restored by cleanup; no production application.
begin;
create schema a7_pdf_concurrency_test;
create table a7_pdf_concurrency_test.context(owner_id uuid,staff_id uuid,camp_id uuid,eligible_id uuid,app_id uuid,adapter_definition text);
do $$ declare u uuid:=gen_random_uuid(); s uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); begin
  insert into a7_pdf_concurrency_test.context values(u,s,c,e,a,pg_get_functiondef('private.camp_pdf_render_settings(uuid)'::regprocedure));
  insert into auth.users(id,email,email_confirmed_at) values(u,'a7-race-owner@example.invalid',clock_timestamp()),(s,'a7-race-staff@example.invalid',clock_timestamp());
  insert into public.staff_roles(user_id) values(s);
  insert into public.camps(id,name,start_date,end_date,application_deadline,created_by) values(c,'A7架空競合',current_date+100,current_date+102,clock_timestamp()+interval '90 days',s);
  perform set_config('private.camp_mode_migration','allowed',true);
  update public.camps set room_assignment_mode='eligible_roster' where id=c;
  insert into public.camp_eligible_users(id,camp_id,email_normalized,linked_user_id,linked_at,linked_email_normalized)
    values(e,c,'a7-race-owner@example.invalid',u,clock_timestamp(),'a7-race-owner@example.invalid');
  insert into public.applications(id,user_id,usage_type,camp_id,camp_eligible_user_id,status,start_date,end_date,user_name)
    values(a,u,'camp',c,e,'draft',current_date+100,current_date+102,'架空競合');
  insert into public.rooms(name,capacity) values('A7専用架空室',2);
  insert into public.camp_room_mapping(room_id,source_name,floor,display_name,print_name,assignment_enabled,printing_enabled,confirmed_at,confirmation_evidence)
    select id,'架空検証原図',2,'架空表示名','架空印字名',true,true,clock_timestamp(),'test-only' from public.rooms where name='A7専用架空室';
  perform set_config('request.jwt.claims',jsonb_build_object('sub',s,'role','authenticated')::text,true);
  perform public.save_camp_room_plan(c,(select roster_version from public.camps where id=c),0,
    jsonb_build_array(jsonb_build_object('eligible_user_id',e,'room_id',(select id from public.rooms where name='A7専用架空室'))));

end $$;
create or replace function private.camp_pdf_render_settings(target_application_id uuid)
returns jsonb language sql set search_path='' as $$
  select jsonb_build_object('assignment_version',1,'room_id','11111111-1111-4111-8111-111111111111','room_name','架空検証室',
    'room_capacity',2,'template_hash',repeat('a',64),'settings_version',1,'font_version','test-only','converter_image','test-only','mayor_name','架空設定');
$$;
create function a7_pdf_concurrency_test.cleanup() returns void language plpgsql as $$
declare f a7_pdf_concurrency_test.context%rowtype;
begin
  select * into f from a7_pdf_concurrency_test.context;
  execute f.adapter_definition;
  delete from public.audit_logs where entity_id in(select id from public.camp_application_versions where application_id=f.app_id);
  delete from public.camp_pdf_jobs where version_id in(select id from public.camp_application_versions where application_id=f.app_id);
  -- Test teardown only. Runtime roles cannot disable the retention trigger.
  alter table public.camp_application_versions disable trigger camp_pdf_version_guard;
  delete from public.camp_application_versions where application_id=f.app_id;
  alter table public.camp_application_versions enable trigger camp_pdf_version_guard;
  delete from public.audit_logs where actor_user_id in(f.owner_id,f.staff_id);
  alter table public.camp_room_assignments disable trigger camp_room_assignments_guard;
  delete from public.camp_room_assignments where camp_id=f.camp_id;
  alter table public.camp_room_assignments enable trigger camp_room_assignments_guard;
  alter table public.camp_room_plan_versions disable trigger camp_room_plan_versions_immutable;
  delete from public.camp_room_plan_versions where camp_id=f.camp_id;
  alter table public.camp_room_plan_versions enable trigger camp_room_plan_versions_immutable;
  delete from public.camp_room_mapping where room_id=(select id from public.rooms where name='A7専用架空室');
  delete from public.rooms where name='A7専用架空室';
  delete from public.applications where id=f.app_id;
  delete from public.camp_eligible_users where id=f.eligible_id;
  delete from public.calendar_claims where camp_id=f.camp_id;
  delete from public.camps where id=f.camp_id;
  delete from auth.users where id in(f.owner_id,f.staff_id);
end $$;
commit;
