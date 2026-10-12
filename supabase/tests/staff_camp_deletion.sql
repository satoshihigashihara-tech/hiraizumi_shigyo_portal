-- Fictional fixtures only; all changes roll back.
begin;
create temporary table deletion_checks(passed boolean) on commit drop;
create function pg_temp.deletion_check(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  insert into pg_temp.deletion_checks values(true);
end $$;
do $$
declare staff uuid:=gen_random_uuid(); owner uuid:=gen_random_uuid(); camp uuid; eligible uuid; app uuid;
  version timestamptz; r record;
begin
  insert into auth.users(id,email,email_confirmed_at) values
    (staff,'delete-staff@example.invalid',clock_timestamp()),(owner,'delete-owner@example.invalid',clock_timestamp());
  insert into public.staff_roles(user_id) values(staff);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',staff,'email','delete-staff@example.invalid','role','authenticated')::text,true);
  set local role authenticated;
  camp:=public.create_staff_camp_with_roster('架空削除テスト',current_date+200,current_date+202,
    clock_timestamp()+interval '100 days','[{"management_name":"架空対象者","email":"delete-owner@example.invalid"}]');
  set local role postgres;
  select id into eligible from public.camp_eligible_users where camp_id=camp;
  set local role authenticated;
  perform public.save_camp_room_plan(camp,(select roster_version from public.camps where id=camp),0,
    jsonb_build_array(jsonb_build_object('eligible_user_id',eligible,'room_id',(select id from public.rooms where name='桐'))));
  set local role postgres;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner,'email','delete-owner@example.invalid','role','authenticated')::text,true);
  set local role authenticated;
  app:=public.create_camp_application_draft(camp);
  set local role postgres;
  select updated_at into version from public.camps where id=camp;
  begin
    set local role authenticated;
    perform public.delete_staff_camp(camp,version,'架空削除');
    raise exception 'FAIL ordinary user allowed';
  exception when insufficient_privilege then null;
  end;
  set local role postgres;
  perform pg_temp.deletion_check((select deleted_at is null from public.camps where id=camp),'ordinary user rejected');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',staff,'email','delete-staff@example.invalid','role','authenticated')::text,true);
  begin
    set local role authenticated;
    perform public.delete_staff_camp(camp,version-interval '1 second','架空削除');
    raise exception 'FAIL stale version allowed';
  exception when others then
    if sqlerrm<>'stale-update' then raise; end if;
  end;
  set local role postgres;
  perform pg_temp.deletion_check((select disabled_at is null from public.camp_eligible_users where id=eligible),'stale request leaves roster unchanged');
  -- Build only a submitted-status fixture; PDF submission itself has separate tests.
  perform set_config('private.camp_pdf_submission','allowed',true);
  update public.applications set status='submitted' where id=app;
  perform set_config('private.camp_pdf_submission','',true);
  begin
    set local role authenticated;
    perform public.delete_staff_camp(camp,version,'架空削除');
    raise exception 'FAIL submitted application allowed';
  exception when others then
    if sqlerrm<>'camp-has-applications' then raise; end if;
  end;
  set local role postgres;
  perform pg_temp.deletion_check((select deleted_at is null from public.camps where id=camp),'submitted application blocks deletion atomically');
  update public.applications set status='draft' where id=app;
  set local role authenticated;
  select * into r from public.delete_staff_camp(camp,version,'架空テスト整理');
  set local role postgres;
  perform pg_temp.deletion_check(r.result_id=camp,'staff RPC returns target');
  perform pg_temp.deletion_check((select deleted_at is not null from public.camps where id=camp),'camp archived');
  perform pg_temp.deletion_check((select status='cancelled' from public.applications where id=app),'draft retained as cancelled');
  perform pg_temp.deletion_check((select disabled_at is not null and participation_status='released' from public.camp_eligible_users where id=eligible),'roster released');
  perform pg_temp.deletion_check((select released_from is not null from public.camp_room_assignments where camp_id=camp and eligible_user_id=eligible),'room allocation released');
  perform pg_temp.deletion_check((select released_from=start_date from public.calendar_claims where camp_id=camp),'future calendar claim released');
  perform pg_temp.deletion_check(exists(select 1 from public.application_status_events where application_id=app and from_status='draft' and to_status='cancelled'),'status history retained');
  perform pg_temp.deletion_check(exists(select 1 from public.audit_logs where entity_id=camp and action='delete_camp'),'deletion audited');
  perform pg_temp.deletion_check((select tgenabled='O' from pg_trigger where tgname='camps_guard_roster_period'),'guard remains enabled');
  begin
    update public.camps set start_date=start_date+1 where id=camp;
    raise exception 'FAIL direct period mutation allowed';
  exception when others then
    if sqlerrm<>'roster-lifecycle-required' then raise; end if;
  end;
  perform pg_temp.deletion_check((select start_date=current_date+200 from public.camps where id=camp),'period guard is not bypassed');
  insert into public.camps(name,start_date,end_date,application_deadline,created_by)
    values('架空終了キャンプ',current_date-20,current_date-18,clock_timestamp()-interval '21 days',staff)
    returning id,updated_at into camp,version;
  set local role authenticated;
  perform public.delete_staff_camp(camp,version,'架空テスト整理');
  set local role postgres;
  perform pg_temp.deletion_check((select deleted_at is not null from public.camps where id=camp),'legacy deletion also works');
  perform pg_temp.deletion_check((select released_from=end_date+1 from public.calendar_claims where camp_id=camp),'elapsed occupancy retained');
end $$;
select count(*)::integer passed_checks,bool_and(passed) all_passed from pg_temp.deletion_checks;
rollback;
