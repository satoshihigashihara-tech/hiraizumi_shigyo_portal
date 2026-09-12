-- A3 separate-connection fixtures. Run with scripts/test-community-applications-db.mjs.
-- The runner uses two worker connections and an observer proving actual Lock waits.
-- Fictional data only; cleanup runs after each case and the schema is removed.
begin;
create schema a3_room_plan_concurrency_test;
create table a3_room_plan_concurrency_test.context(staff uuid,viewer uuid,camp uuid,eligible uuid,room uuid,application uuid,group_id uuid,starts date,ends date);
create table a3_room_plan_concurrency_test.results(case_name text,passed boolean,backend_a integer,backend_b integer,waited boolean,error_code text,error_message text);
create function a3_room_plan_concurrency_test.call_as(actor uuid,sql_text text) returns jsonb language plpgsql as $$
declare row_value record; rows_value jsonb:='[]'; state_value text; message_value text;
begin
 begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'email',(select email from auth.users where id=actor),'role','authenticated')::text,true);
  set local role authenticated;
  for row_value in execute sql_text loop rows_value:=rows_value||jsonb_build_array(to_jsonb(row_value)); end loop;
  set local role postgres; return jsonb_build_object('ok',true,'rows',rows_value);
 exception when others then
  get stacked diagnostics state_value=returned_sqlstate,message_value=message_text;
  set local role postgres; return jsonb_build_object('ok',false,'state',state_value,'message',message_value);
 end;
end $$;
create function a3_room_plan_concurrency_test.setup() returns void language plpgsql as $$
declare staff uuid:=gen_random_uuid(); viewer uuid:=gen_random_uuid(); camp uuid:=gen_random_uuid(); eligible uuid:=gen_random_uuid(); room uuid;
 starts date:=(clock_timestamp() at time zone 'Asia/Tokyo')::date+20; ends date:=starts+1; r jsonb; app uuid:=gen_random_uuid(); grp uuid:=gen_random_uuid();
begin
 insert into auth.users(id,email,email_confirmed_at) values(staff,'a3-race-staff@example.invalid',clock_timestamp()),(viewer,'a3-race-user@example.invalid',clock_timestamp());
 insert into public.staff_roles(user_id) values(staff);
 select id into room from public.rooms where name='梅';
 insert into public.camp_room_mapping(room_id,source_name,floor,display_name,print_name,assignment_enabled,confirmed_at,confirmation_evidence)
 values(room,'架空資料',2,'架空部屋','架空部屋',true,clock_timestamp(),'fictional local test');
 insert into public.camps(id,name,start_date,end_date,application_deadline,created_by,room_assignment_mode)
 values(camp,'A3 concurrency',starts,ends,clock_timestamp()+interval '10 days',staff,'eligible_roster');
 insert into public.camp_eligible_users(id,camp_id,email_normalized,management_name) values(eligible,camp,'a3-race-eligible@example.invalid','架空対象者');
 insert into a3_room_plan_concurrency_test.context values(staff,viewer,camp,eligible,room,app,grp,starts,ends);
 r:=a3_room_plan_concurrency_test.call_as(viewer,format('select * from public.create_community_application_draft(%L,%L::jsonb)',app,
 jsonb_build_object('user_name','架空利用者','user_address','架空住所','user_phone','0000000000','emergency_name','架空連絡先','emergency_address','架空住所','emergency_phone','0000000000',
 'purpose','架空調査','local_activity','町内調査','usage_place','common_and_second_floor','requires_guardian_consent',false,'start_date',starts,'end_date',ends)));
 if r->>'ok'<>'true' then raise exception 'individual fixture: %',r; end if;
 r:=a3_room_plan_concurrency_test.call_as(viewer,format('select * from public.create_community_group_draft(%L,%L::jsonb)',grp,
 jsonb_build_object('group_name','架空団体','representative_name','架空代表者','representative_address','架空住所','representative_phone','0000000000',
 'purpose','架空調査','local_activity','町内調査','usage_place','common_and_second_floor','planned_participants',2,'representative_stays',false,'start_date',starts,'end_date',ends)));
 if r->>'ok'<>'true' then raise exception 'group fixture: %',r; end if;
end $$;
create function a3_room_plan_concurrency_test.act(kind text) returns jsonb language plpgsql as $$
declare c a3_room_plan_concurrency_test.context%rowtype; command text; actor uuid;
begin
 select * into c from a3_room_plan_concurrency_test.context; actor:=c.staff;
 case kind
 when 'save' then command:=format('select public.save_camp_room_plan(%L,1,0,%L::jsonb)',c.camp,
   jsonb_build_array(jsonb_build_object('eligible_user_id',c.eligible,'room_id',c.room)));
 when 'camp' then command:=format('select public.create_staff_camp(%L,%L,%L,%L)','架空競合camp',c.starts,c.ends,clock_timestamp()+interval '10 days');
 when 'blocked' then command:=format('select * from public.save_staff_blocked_period(null,%L,%L,%L)',c.starts,c.ends,'架空競合停止');
 when 'individual' then actor:=c.viewer; command:=format('select * from public.submit_community_application(%L,%L,%L,true)',c.application,(select updated_at from public.applications where id=c.application),gen_random_uuid());
 when 'group' then actor:=c.viewer; command:=format('select * from public.start_community_group_application(%L,%L,%L,true)',c.group_id,(select updated_at from public.group_applications where id=c.group_id),gen_random_uuid());
 else raise exception 'unknown action';
 end case;
 return a3_room_plan_concurrency_test.call_as(actor,command);
end $$;
create function a3_room_plan_concurrency_test.cleanup_case() returns void language plpgsql as $$
declare c a3_room_plan_concurrency_test.context%rowtype;
begin
 select * into c from a3_room_plan_concurrency_test.context;
 -- Owner-only maintenance of fictional test data after both workers have finished.
 alter table public.camp_room_assignments disable trigger camp_room_assignments_guard;
 delete from public.camp_room_assignments where camp_id=c.camp;
 alter table public.camp_room_assignments enable trigger camp_room_assignments_guard;
 alter table public.camp_room_plan_versions disable trigger camp_room_plan_versions_immutable;
 delete from public.camp_room_plan_versions where camp_id=c.camp;
 alter table public.camp_room_plan_versions enable trigger camp_room_plan_versions_immutable;
 delete from public.audit_logs where actor_user_id in(c.staff,c.viewer);
 delete from public.camp_eligible_users where camp_id=c.camp;
 delete from public.calendar_claims where camp_id in(select id from public.camps where created_by=c.staff)
   or blocked_period_id in(select id from public.blocked_periods where created_by=c.staff) or application_id=c.application or group_id=c.group_id;
 delete from public.applications where id=c.application;
 delete from public.group_applications where id=c.group_id;
 delete from public.camps where created_by=c.staff;
 delete from public.blocked_periods where created_by=c.staff;
 delete from auth.users where id in(c.staff,c.viewer);
 delete from a3_room_plan_concurrency_test.context;
end $$;
create function a3_room_plan_concurrency_test.verify() returns setof a3_room_plan_concurrency_test.results language sql as $$
 select * from a3_room_plan_concurrency_test.results order by case_name
$$;
commit;
