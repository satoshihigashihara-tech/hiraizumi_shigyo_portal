-- Fictional, local-only fixture shared by A4 single and multi-session tests.
create schema a4_lifecycle_test;
create table a4_lifecycle_test.context(staff uuid,owner uuid,camp uuid,eligible uuid,other_eligible uuid,app uuid,room uuid,
 eligible_version timestamptz,app_version timestamptz,roster bigint,plan bigint);
create function a4_lifecycle_test.call_as(actor uuid,command text) returns jsonb language plpgsql as $$
declare row_value record; rows_value jsonb:='[]'; state_value text; message_value text;
begin
 begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'email',(select email from auth.users where id=actor),'role','authenticated')::text,true);
  set local role authenticated;
  for row_value in execute command loop rows_value:=rows_value||jsonb_build_array(to_jsonb(row_value)); end loop;
  set local role postgres; return jsonb_build_object('ok',true,'rows',rows_value);
 exception when others then
  get stacked diagnostics state_value=returned_sqlstate,message_value=message_text;
  set local role postgres; return jsonb_build_object('ok',false,'state',state_value,'message',message_value);
 end;
end $$;
create function a4_lifecycle_test.setup(app_status text default 'draft',stay_status text default null,days_ahead integer default 20,assigned boolean default true)
returns void language plpgsql as $$
declare staff uuid:=gen_random_uuid(); owner uuid:=gen_random_uuid(); camp uuid:=gen_random_uuid(); eligible uuid:=gen_random_uuid(); other_e uuid:=gen_random_uuid();
 app uuid; room uuid; starts date:=(clock_timestamp() at time zone 'Asia/Tokyo')::date+days_ahead; snap jsonb;
begin
 insert into auth.users(id,email,email_confirmed_at) values(staff,'a4-staff@example.invalid',clock_timestamp()),(owner,'a4-owner@example.invalid',clock_timestamp());
 insert into public.staff_roles(user_id) values(staff);
 select id into room from public.rooms where name='梅';
 insert into public.camp_room_mapping(room_id,source_name,floor,display_name,print_name,assignment_enabled,confirmed_at,confirmation_evidence)
 values(room,'架空資料',2,'架空部屋','架空部屋',true,clock_timestamp(),'fictional local test');
 insert into public.camps(id,name,start_date,end_date,application_deadline,created_by,room_assignment_mode)
 values(camp,'A4 fictional',starts,starts+3,(starts-1)::timestamp at time zone 'Asia/Tokyo',staff,'eligible_roster');
 insert into public.camp_eligible_users(id,camp_id,email_normalized,management_name) values
   (eligible,camp,'a4-owner@example.invalid','架空対象者'),(other_e,camp,'a4-other@example.invalid','架空別人');
 if app_status is not null then
  app:=gen_random_uuid();
  update public.camp_eligible_users set linked_user_id=owner,linked_at=clock_timestamp(),linked_email_normalized='a4-owner@example.invalid' where id=eligible;
  insert into public.applications(id,usage_type,camp_id,camp_eligible_user_id,user_id,start_date,end_date,status,submitted_at)
    values(app,'camp',camp,eligible,owner,starts,starts+3,app_status,case when app_status<>'draft' then clock_timestamp() end);
  if stay_status is not null then
   insert into public.stays(application_id,status,checked_in_at,checked_out_at) values(app,stay_status,
    case when stay_status in ('staying','moved_out') then starts::timestamp at time zone 'Asia/Tokyo' end,
    case when stay_status='moved_out' then (starts+1)::timestamp at time zone 'Asia/Tokyo' end);
  end if;
 end if;
 if assigned then
  snap:=jsonb_build_array(jsonb_build_object('eligible_user_id',eligible,'room_id',room,'capacity',2,'assignment_version',1,'released_from',null),
    jsonb_build_object('eligible_user_id',other_e,'room_id',room,'capacity',2,'assignment_version',1,'released_from',null));
  insert into public.camp_room_plan_versions(camp_id,version,roster_version,start_date,end_date,assignments,actor_user_id)
    values(camp,1,2,starts,starts+3,snap,staff);
  insert into public.camp_room_assignments(camp_id,eligible_user_id,room_id,assignment_version,room_plan_version,start_date,end_date)
    values(camp,eligible,room,1,1,starts,starts+3),(camp,other_e,room,1,1,starts,starts+3);
  update public.camps set room_plan_version=1,saved_roster_version=roster_version,room_plan_committed_at=clock_timestamp() where id=camp;
 end if;
 insert into a4_lifecycle_test.context select staff,owner,camp,eligible,other_e,app,room,
   (select updated_at from public.camp_eligible_users where id=eligible),(select updated_at from public.applications where id=app),2,case when assigned then 1 else 0 end;
end $$;
create function a4_lifecycle_test.command(action_value text default 'withdraw',confirm_checkout boolean default false) returns text language sql as $$
 select format('select public.end_camp_roster_participation(%L,%L,%L,%L,%L,%L,%L,%L,%L,true,%L)',
   camp,eligible,eligible_version,roster,plan,app,app_version,action_value,'架空終了理由',confirm_checkout) from a4_lifecycle_test.context;
$$;
create function a4_lifecycle_test.act(action_value text default 'withdraw',confirm_checkout boolean default false) returns jsonb language sql as $$
 select a4_lifecycle_test.call_as(staff,a4_lifecycle_test.command(action_value,confirm_checkout)) from a4_lifecycle_test.context;
$$;
create function a4_lifecycle_test.snapshot() returns jsonb language sql as $$
 select jsonb_build_object('camp',(select to_jsonb(c) from public.camps c where c.id=x.camp),
 'eligible',(select jsonb_agg(to_jsonb(e) order by e.id) from public.camp_eligible_users e where e.camp_id=x.camp),
 'applications',(select jsonb_agg(to_jsonb(a) order by a.id) from public.applications a where a.camp_id=x.camp),
 'stays',(select jsonb_agg(to_jsonb(s) order by s.id) from public.stays s where application_id=x.app),
 'claims',(select jsonb_agg(to_jsonb(q) order by q.id) from public.calendar_claims q where q.camp_id=x.camp),
 'assignments',(select jsonb_agg(to_jsonb(r) order by r.id) from public.camp_room_assignments r where r.camp_id=x.camp),
 'versions',(select jsonb_agg(to_jsonb(v) order by v.id) from public.camp_room_plan_versions v where v.camp_id=x.camp),
 'events',(select jsonb_agg(to_jsonb(v) order by v.id) from public.application_status_events v where application_id=x.app),
 'audit',(select jsonb_agg(to_jsonb(v) order by v.id) from public.audit_logs v where actor_user_id=x.staff)) from a4_lifecycle_test.context x;
$$;
create function a4_lifecycle_test.cleanup() returns void language plpgsql as $$
declare x a4_lifecycle_test.context%rowtype;
begin
 select * into x from a4_lifecycle_test.context;
 alter table public.camp_room_assignments disable trigger camp_room_assignments_guard;
 delete from public.camp_room_assignments where camp_id=x.camp;
 alter table public.camp_room_assignments enable trigger camp_room_assignments_guard;
 alter table public.camp_room_plan_versions disable trigger camp_room_plan_versions_immutable;
 delete from public.camp_room_plan_versions where camp_id=x.camp;
 alter table public.camp_room_plan_versions enable trigger camp_room_plan_versions_immutable;
 alter table public.camp_application_versions disable trigger camp_pdf_version_guard;
 delete from public.camp_application_versions where camp_id=x.camp;
 alter table public.camp_application_versions enable trigger camp_pdf_version_guard;
 delete from public.applications where camp_id=x.camp;
 delete from public.audit_logs where actor_user_id=x.staff;
 delete from public.camp_eligible_users where camp_id=x.camp;
 delete from public.calendar_claims where camp_id=x.camp;
 delete from public.camps where id=x.camp;
 delete from public.account_cleanup_jobs where user_id in(x.staff,x.owner);
 delete from auth.users where id in(x.staff,x.owner);
 delete from public.camp_room_mapping;
 delete from a4_lifecycle_test.context;
end $$;
create function a4_lifecycle_test.seed_retained_records() returns void language plpgsql as $$
declare x a4_lifecycle_test.context%rowtype; charge uuid; v uuid; n integer;
begin
 select * into x from a4_lifecycle_test.context;
 insert into public.application_charges(application_id,total_amount,payment_status,paid_at)
   values(x.app,1200,'paid',clock_timestamp()) returning id into charge;
 insert into public.charge_months(charge_id,month,usage_days,amount) values(charge,date_trunc('month',current_date)::date,4,1200);
 insert into public.application_status_events(application_id,from_status,to_status,actor_user_id)
   values(x.app,'under_review','approved',x.staff);
 for n in 1..2 loop
  insert into public.camp_application_versions(application_id,camp_id,eligible_user_id,owner_id,version_no,request_key,
   input_version,room_plan_version,application_date,source_snapshot,source_hash,render_context)
  values(x.app,x.camp,x.eligible,x.owner,n,gen_random_uuid(),1,1,(clock_timestamp() at time zone 'Asia/Tokyo')::date,
   '{"user_name":"架空の過去氏名"}',repeat('a',64),'{}') returning id into v;
  update public.camp_application_versions set state='ready',object_path='fictional/'||v||'.pdf',pdf_hash=repeat('b',64),
   size_bytes=100,validation='{"pages":1}',generated_at=clock_timestamp() where id=v;
  if n=1 then
   perform set_config('private.camp_pdf_submission','allowed',true);
   update public.camp_application_versions set state='submitted',confirmed_at=now(),submitted_at=now() where id=v;
  end if;
 end loop;
end $$;
create function a4_lifecycle_test.retained_snapshot() returns jsonb language sql as $$
 select jsonb_build_object('charge',(select jsonb_agg(to_jsonb(v)) from public.application_charges v where application_id=x.app),
 'months',(select jsonb_agg(to_jsonb(v)) from public.charge_months v join public.application_charges q on q.id=v.charge_id where q.application_id=x.app),
 'pdf',(select jsonb_agg(to_jsonb(v) order by version_no) from public.camp_application_versions v where application_id=x.app),
 'approval',(select jsonb_agg(to_jsonb(v) order by id) from public.application_status_events v where application_id=x.app and to_status='approved'))
 from a4_lifecycle_test.context x;
$$;
