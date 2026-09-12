-- T20 phase 2 regression. Fictional rows only; everything is rolled back.
begin;
create temporary table t20b_results(label text,passed boolean) on commit drop;
create function pg_temp.t20b_check(ok boolean,label text) returns void language plpgsql security definer as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  insert into pg_temp.t20b_results values(label,true);
end; $$;

do $$ declare staff uuid:=gen_random_uuid(); rep uuid:=gen_random_uuid(); u1 uuid:=gen_random_uuid(); u2 uuid:=gen_random_uuid(); u3 uuid:=gen_random_uuid();
  g uuid:=gen_random_uuid(); a1 uuid:=gen_random_uuid(); a2 uuid:=gen_random_uuid(); a3 uuid:=gen_random_uuid();
  room_value uuid; v timestamptz; r record; invite record; fields jsonb; participant_view jsonb; fiscal integer:=extract(year from current_date)::integer;
begin
  insert into auth.users(id,email) values(staff,'t20b-staff@example.invalid'),(rep,'t20b-rep@example.invalid'),
    (u1,'t20b-one@example.invalid'),(u2,'t20b-two@example.invalid'),(u3,'t20b-three@example.invalid');
  insert into public.staff_roles(user_id) values(staff);
  insert into public.group_applications(id,representative_user_id,group_name,representative_name,representative_address,
    representative_phone,representative_email,start_date,end_date,usage_place,purpose,local_activity,planned_participants,
    status,submitted_at,participant_due_at,revision_due_at,decision_reason)
  values(g,rep,'架空変更団体','架空代表','架空住所','000-0000-0000','t20b-rep@example.invalid',current_date+30,current_date+32,
    'common_and_second_floor','架空目的','架空活動',2,'revision_requested',clock_timestamp(),clock_timestamp()+interval '7 day',
    clock_timestamp()+interval '3 day','修正してください');
  insert into public.applications(id,user_id,usage_type,group_id,status,start_date,end_date,user_name,user_address,user_phone,email_snapshot,
    emergency_name,emergency_address,emergency_phone,requires_guardian_consent,submitted_at,last_submitted_at,revision_due_at,decision_reason)
  values(a1,u1,'community_group',g,'revision_requested',current_date+30,current_date+32,'架空一郎','架空住所','000-0000-0001','t20b-one@example.invalid',
      '架空連絡先','架空住所','000-0000-0011',false,clock_timestamp(),clock_timestamp(),clock_timestamp()+interval '3 day','修正してください'),
    (a2,u2,'community_group',g,'approved',current_date+30,current_date+32,'架空二郎','架空住所','000-0000-0002','t20b-two@example.invalid',
      '架空連絡先','架空住所','000-0000-0022',false,clock_timestamp(),clock_timestamp(),null,null);
  insert into public.group_members(group_id,application_id) values(g,a1),(g,a2);
  insert into public.reception_counters(fiscal_year,last_number) values(fiscal,910002)
    on conflict(fiscal_year) do update set last_number=greatest(public.reception_counters.last_number,910002);
  insert into public.reception_numbers(fiscal_year,serial_number,display_number,application_id)
    values(fiscal,910001,'SG-'||fiscal||'-910001',a1),(fiscal,910002,'SG-'||fiscal||'-910002',a2);

  fields:=jsonb_build_object('user_name','架空一郎修正','user_address','架空住所','user_phone','000-0000-0001',
    'emergency_name','架空連絡先','emergency_address','架空住所','emergency_phone','000-0000-0011',
    'special_notes','修正済み','requires_guardian_consent',false);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',u1,'email','t20b-one@example.invalid','role','authenticated')::text,true);
  set local role authenticated;
  participant_view:=public.get_group_participant_application(a1);
  perform pg_temp.t20b_check(participant_view->>'status'='revision_requested'
    and (participant_view->>'can_edit')::boolean
    and participant_view->>'active_deadline' is not null
    and participant_view->>'decision_reason'='修正してください','participant correction read is editable and public');
  select updated_at into v from public.applications where id=a1;
  perform public.save_group_participant_application(a1,v,fields);
  select updated_at into v from public.applications where id=a1;
  select * into r from public.submit_group_participant_application(a1,v,gen_random_uuid(),true);
  perform pg_temp.t20b_check(r.result_status='submitted' and r.result_group_status='under_review','revision resubmission returns group to review');
  perform pg_temp.t20b_check((select decision_reason is null and revision_due_at is null from public.applications where id=a1),'revision fields cleared');
  reset role;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',staff,'role','authenticated')::text,true);
  set local role authenticated;
  select updated_at into v from public.group_applications where id=g;
  perform public.review_group_application(g,'confirm_purpose',v);
  select updated_at into v from public.applications where id=a1;
  perform public.review_group_participant(a1,'start_review',v);
  select updated_at into v from public.applications where id=a1;
  perform public.reject_group_participant(a1,v,'別の参加者へ交代してください',clock_timestamp()+interval '2 day');
  perform pg_temp.t20b_check((select status='revision_requested' from public.group_applications where id=g)
    and (select status='rejected' from public.applications where id=a1),'participant rejection requests group revision');
  reset role;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',rep,'email','t20b-rep@example.invalid','role','authenticated')::text,true);
  set local role authenticated;
  select updated_at into v from public.group_applications where id=g;
  perform public.remove_community_group_participant(g,a1,v,'交代のため削除');
  reset role;
  perform pg_temp.t20b_check((select status='collecting' and participant_due_at=revision_due_at from public.group_applications where id=g)
    and (select state='removed' from public.group_members where application_id=a1),'representative removes rejected participant');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',rep,'email','t20b-rep@example.invalid','role','authenticated')::text,true);
  set local role authenticated;
  select updated_at into v from public.group_applications where id=g;
  select * into invite from public.issue_community_group_invite(g,v);
  reset role;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',u3,'email','t20b-three@example.invalid','role','authenticated')::text,true);
  set local role authenticated;
  perform public.join_community_group(invite.invite_token,'token',a3);
  select updated_at into v from public.applications where id=a3;
  perform public.save_group_participant_application(a3,v,jsonb_build_object('user_name','架空三郎','user_address','架空住所',
    'user_phone','000-0000-0003','emergency_name','架空連絡先','emergency_address','架空住所',
    'emergency_phone','000-0000-0033','special_notes',null,'requires_guardian_consent',false));
  select updated_at into v from public.applications where id=a3;
  select * into r from public.submit_group_participant_application(a3,v,gen_random_uuid(),true);
  perform pg_temp.t20b_check(r.result_group_status='under_review','replacement submission returns group to review');
  reset role;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',staff,'role','authenticated')::text,true);
  set local role authenticated;
  select updated_at into v from public.applications where id=a3;
  perform public.review_group_participant(a3,'start_review',v);
  select updated_at into v from public.applications where id=a3;
  perform public.review_group_participant(a3,'approve',v);
  select id into room_value from public.rooms where capacity=2 order by name limit 1;
  select updated_at into v from public.group_applications where id=g;
  perform public.set_group_room_allocations(g,v,jsonb_build_array(jsonb_build_object('room_id',room_value,'people_count',2)));
  select updated_at into v from public.group_applications where id=g;
  perform public.review_group_application(g,'approve',v);
  reset role;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',rep,'email','t20b-rep@example.invalid','role','authenticated')::text,true);
  set local role authenticated;
  select updated_at into v from public.group_applications where id=g;
  perform public.request_community_group_cancellation(g,v,'団体利用を取りやめます');
  reset role;
  perform pg_temp.t20b_check((select status='cancellation_requested' from public.group_applications where id=g)
    and (select released_from is null from public.calendar_claims where group_id=g),'cancellation request retains reservation');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',staff,'role','authenticated')::text,true);
  set local role authenticated;
  select updated_at into v from public.group_applications where id=g;
  perform public.confirm_community_group_cancellation(g,v,'取消を確認');
  perform pg_temp.t20b_check((select status='cancelled' from public.group_applications where id=g)
    and (select released_from=start_date from public.calendar_claims where group_id=g),'confirmed cancellation releases group claim');
  perform pg_temp.t20b_check((select bool_and(status in ('cancelled','rejected')) from public.applications where group_id=g),'confirmed cancellation closes participant applications');
  perform pg_temp.t20b_check((select bool_and(released_from=start_date) from public.room_allocations where group_id=g),'confirmed cancellation releases rooms');
  reset role;
end; $$;

do $$ declare staff uuid:=gen_random_uuid(); rep uuid:=gen_random_uuid(); u1 uuid:=gen_random_uuid(); u2 uuid:=gen_random_uuid();
  g uuid:=gen_random_uuid(); a1 uuid:=gen_random_uuid(); a2 uuid:=gen_random_uuid(); room_value uuid; v timestamptz;
begin
  insert into auth.users(id,email) values(staff,'t20c-staff@example.invalid'),(rep,'t20c-rep@example.invalid'),
    (u1,'t20c-one@example.invalid'),(u2,'t20c-two@example.invalid');
  insert into public.staff_roles(user_id) values(staff);
  insert into public.group_applications(id,representative_user_id,group_name,start_date,end_date,usage_place,purpose,local_activity,
    planned_participants,status,submitted_at,purpose_reviewed_at)
  values(g,rep,'架空減員団体',current_date+40,current_date+42,'common_and_second_floor','架空目的','架空活動',2,'approved',clock_timestamp(),clock_timestamp());
  insert into public.applications(id,user_id,usage_type,group_id,status,start_date,end_date,user_name,requires_guardian_consent,submitted_at,last_submitted_at)
  values(a1,u1,'community_group',g,'approved',current_date+40,current_date+42,'架空一郎',false,clock_timestamp(),clock_timestamp()),
    (a2,u2,'community_group',g,'approved',current_date+40,current_date+42,'架空二郎',false,clock_timestamp(),clock_timestamp());
  insert into public.group_members(group_id,application_id) values(g,a1),(g,a2);
  insert into public.stays(application_id,status) values(a1,'before_move_in'),(a2,'before_move_in');
  select id into room_value from public.rooms where capacity=2 order by name limit 1;
  insert into public.room_allocations(group_id,room_id,people_count,start_date,end_date) values(g,room_value,2,current_date+40,current_date+42);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',staff,'role','authenticated')::text,true);
  set local role authenticated;
  select updated_at into v from public.group_applications where id=g;
  perform public.cancel_approved_group_participant(g,a1,v,'1名減員',jsonb_build_array(jsonb_build_object('room_id',room_value,'people_count',1)));
  perform pg_temp.t20b_check((select status='approved' and planned_participants=1 from public.group_applications where id=g)
    and (select people_count=1 and released_from is null from public.room_allocations where group_id=g order by updated_at desc limit 1),'approved group may continue with one participant');
  perform pg_temp.t20b_check((select released_from is null from public.calendar_claims where group_id=g),'partial reduction retains exclusive claim');
  select updated_at into v from public.group_applications where id=g;
  perform public.cancel_approved_group_participant(g,a2,v,'全員利用中止','[]'::jsonb);
  perform pg_temp.t20b_check((select status='cancelled' and planned_participants=0 from public.group_applications where id=g)
    and (select released_from=start_date from public.calendar_claims where group_id=g),'last participant cancellation closes group');
  reset role;
end; $$;

select count(*)::integer as passed_checks,bool_and(passed) as all_passed from pg_temp.t20b_results;
rollback;
