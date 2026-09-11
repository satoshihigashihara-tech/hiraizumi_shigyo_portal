-- T20 phase 1 regression. Fictional rows only; everything is rolled back.
begin;
create temporary table t20_results(label text,passed boolean) on commit drop;
create function pg_temp.t20_check(ok boolean,label text) returns void language plpgsql security definer as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  insert into pg_temp.t20_results values(label,true);
end; $$;

do $$ declare staff uuid:=gen_random_uuid(); rep uuid:=gen_random_uuid(); u1 uuid:=gen_random_uuid(); u2 uuid:=gen_random_uuid();
  g uuid:=gen_random_uuid(); a1 uuid:=gen_random_uuid(); a2 uuid:=gen_random_uuid(); room_value uuid;
  v timestamptz; r record; fiscal integer:=extract(year from current_date)::integer;
begin
  insert into auth.users(id,email) values(staff,'t20-staff@example.invalid'),(rep,'t20-rep@example.invalid'),
    (u1,'t20-one@example.invalid'),(u2,'t20-two@example.invalid');
  insert into public.staff_roles(user_id) values(staff);
  insert into public.group_applications(id,representative_user_id,group_name,representative_name,representative_address,
    representative_phone,representative_email,start_date,end_date,usage_place,purpose,local_activity,planned_participants,
    status,submitted_at,participant_due_at)
  values(g,rep,'架空審査団体','架空代表','架空住所','000-0000-0000','t20-rep@example.invalid',current_date+30,current_date+32,
    'common_and_second_floor','架空の利用目的','架空の町内活動',2,'under_review',clock_timestamp(),clock_timestamp()+interval '7 day');
  insert into public.applications(id,user_id,usage_type,group_id,status,start_date,end_date,user_name,user_address,user_phone,email_snapshot,
    emergency_name,emergency_address,emergency_phone,requires_guardian_consent,submitted_at,last_submitted_at)
  values(a1,u1,'community_group',g,'submitted',current_date+30,current_date+32,'架空一郎','架空住所','000-0000-0001','t20-one@example.invalid',
      '架空連絡先','架空住所','000-0000-0011',false,clock_timestamp(),clock_timestamp()),
    (a2,u2,'community_group',g,'submitted',current_date+30,current_date+32,'架空二郎','架空住所','000-0000-0002','t20-two@example.invalid',
      '架空連絡先','架空住所','000-0000-0022',false,clock_timestamp(),clock_timestamp());
  insert into public.group_members(group_id,application_id) values(g,a1),(g,a2);
  insert into public.application_charges(application_id,total_amount) values(a1,0),(a2,0);
  insert into public.reception_counters(fiscal_year,last_number) values(fiscal,3)
    on conflict(fiscal_year) do update set last_number=greatest(public.reception_counters.last_number,3);
  insert into public.reception_numbers(fiscal_year,serial_number,display_number,application_id)
    values(fiscal,900001,'SG-'||fiscal||'-900001',a1),(fiscal,900002,'SG-'||fiscal||'-900002',a2);

  perform set_config('request.jwt.claims',jsonb_build_object('sub',staff,'role','authenticated')::text,true);
  set local role authenticated;
  select updated_at into v from public.applications where id=a1;
  begin perform public.review_group_participant(a1,'start_review',v); raise exception 'missing failure';
  exception when others then perform pg_temp.t20_check(sqlerrm='invalid-status','purpose must be reviewed first'); end;
  select updated_at into v from public.group_applications where id=g;
  select * into r from public.review_group_application(g,'confirm_purpose',v);
  perform pg_temp.t20_check(r.result_status='under_review','purpose review keeps group under review');
  select updated_at into v from public.applications where id=a1;
  perform public.review_group_participant(a1,'start_review',v);
  select updated_at into v from public.applications where id=a1;
  perform public.review_group_participant(a1,'approve',v,'架空確認済み');
  select updated_at into v from public.applications where id=a2;
  perform public.review_group_participant(a2,'start_review',v);
  select updated_at into v from public.applications where id=a2;
  perform public.review_group_participant(a2,'approve',v);
  perform pg_temp.t20_check((select bool_and(status='approved') from public.applications where group_id=g),'all participants approved');
  select id into room_value from public.rooms where capacity=2 order by name limit 1;
  select updated_at into v from public.group_applications where id=g;
  perform public.set_group_room_allocations(g,v,jsonb_build_array(jsonb_build_object('room_id',room_value,'people_count',2)));
  select updated_at into v from public.group_applications where id=g;
  select * into r from public.review_group_application(g,'approve',v,'団体許可');
  perform pg_temp.t20_check(r.result_status='approved','group approved');
  perform pg_temp.t20_check((select count(*)=2 from public.stays s join public.applications a on a.id=s.application_id where a.group_id=g and s.status='before_move_in'),'stays initialized');
  perform pg_temp.t20_check((select count(*)=1 and sum(people_count)=2 from public.room_allocations where group_id=g and released_from is null),'aggregate room plan retained');
  perform pg_temp.t20_check((select count(*)>=1 from public.audit_logs where entity_id=g and actor_kind='staff' and action='approve_group_application'),'staff audit written');
  reset role;
end; $$;

select count(*)::integer as passed_checks,bool_and(passed) as all_passed from pg_temp.t20_results;
rollback;
