-- Fictional T22 verification. ROLLBACK means this must not be saved in SQL Editor.
begin;
create temporary table t22_results(label text,passed boolean) on commit drop;
create function pg_temp.t22(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  insert into pg_temp.t22_results values(label,true);
end $$;
do $$
declare staff_id uuid:=gen_random_uuid(); eligible_id uuid:=gen_random_uuid(); blocked_id uuid:=gen_random_uuid();
  manual_id uuid:=gen_random_uuid(); rep_id uuid:=gen_random_uuid(); member_id uuid:=gen_random_uuid();
  app_id uuid:=gen_random_uuid(); blocked_app uuid:=gen_random_uuid(); open_app uuid:=gen_random_uuid();
  manual_app uuid:=gen_random_uuid(); member_app uuid:=gen_random_uuid(); group_id uuid:=gen_random_uuid();
  job uuid; claimed_user uuid; tries integer; result_value boolean; moment timestamptz:=clock_timestamp();
begin
  insert into auth.users(id,email) values
    (staff_id,'t22-staff@example.invalid'),(eligible_id,'t22-eligible@example.invalid'),
    (blocked_id,'t22-blocked@example.invalid'),(manual_id,'t22-manual@example.invalid'),
    (rep_id,'t22-rep@example.invalid'),(member_id,'t22-member@example.invalid');
  insert into public.staff_roles(user_id) values(staff_id);

  perform pg_temp.t22(private.account_cleanup_blocker(staff_id)='staff-protected','staff is protected');
  perform pg_temp.t22(private.account_cleanup_blocker(eligible_id)='completion-required','new account is not auto deleted');

  insert into public.applications(id,user_id,usage_type,status,start_date,end_date,user_name,requires_guardian_consent,submitted_at)
    values(app_id,eligible_id,'community_individual','approved',current_date-2,current_date-1,'架空対象',false,moment-interval '3 days');
  insert into public.stays(application_id,status,checked_in_at) values(app_id,'staying',moment-interval '2 days');
  update public.stays set status='moved_out',checked_out_at=moment where application_id=app_id;
  perform pg_temp.t22((select account_state='cleanup_pending' from public.profiles where id=eligible_id),'checkout makes cleanup pending');
  perform pg_temp.t22((select status='queued' and attempts=0 from public.account_cleanup_jobs where user_id=eligible_id),'checkout queues once');
  perform private.reconcile_account_cleanup(eligible_id,moment+interval '1 second');
  perform pg_temp.t22((select count(*)=1 from public.account_cleanup_jobs where user_id=eligible_id and status in ('queued','processing','failed')),'reconcile is idempotent');

  insert into public.applications(id,user_id,usage_type,status,start_date,end_date,user_name,requires_guardian_consent,submitted_at)
    values(blocked_app,blocked_id,'community_individual','approved',current_date-2,current_date-1,'架空保護',false,moment-interval '3 days');
  insert into public.stays(application_id,status,checked_in_at) values(blocked_app,'staying',moment-interval '2 days');
  update public.stays set status='moved_out',checked_out_at=moment where application_id=blocked_app;
  insert into public.applications(id,user_id,usage_type,status,user_name)
    values(open_app,blocked_id,'community_individual','draft','架空未終了');

  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  set local role service_role;
  select c.job_id,c.result_user_id,c.result_attempts into job,claimed_user,tries from public.claim_account_cleanup_job(10)c
    where c.result_user_id=eligible_id;
  reset role;
  perform pg_temp.t22(job is not null and claimed_user=eligible_id and tries=1,'service claims eligible job');
  perform pg_temp.t22((select status='cancelled' from public.account_cleanup_jobs where user_id=blocked_id)
    and (select account_state='active' from public.profiles where id=blocked_id),'new blocker cancels safely');

  set local role service_role;
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  select public.fail_account_cleanup_job(job,eligible_id,'fictional transient failure') into result_value;
  reset role;
  perform pg_temp.t22(result_value and (select status='failed' and attempts=1 and last_error='fictional transient failure'
    and next_attempt_at>moment from public.account_cleanup_jobs where id=job),'failure schedules retry');
  update public.account_cleanup_jobs set next_attempt_at=clock_timestamp()-interval '1 second' where id=job;
  set local role service_role;
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  select c.job_id,c.result_attempts into job,tries from public.claim_account_cleanup_job(1)c;
  reset role;
  perform pg_temp.t22(tries=2,'failed job retries');
  delete from auth.users where id=eligible_id;
  update public.account_cleanup_jobs set locked_until=clock_timestamp()-interval '1 second' where id=job;
  set local role service_role;
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  select c.job_id,c.result_attempts into job,tries from public.claim_account_cleanup_job(1)c;
  reset role;
  perform pg_temp.t22(tries=3,'deleted Auth before completion is reclaimed');
  set local role service_role;
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  select public.complete_account_cleanup_job(job,eligible_id) into result_value;
  reset role;
  perform pg_temp.t22(result_value and (select status='done' and completed_at is not null from public.account_cleanup_jobs where id=job),'missing Auth user completes retry');
  perform pg_temp.t22(not exists(select 1 from public.profiles where id=eligible_id) and
    (select user_id is null from public.applications where id=app_id),'profile removed and record retained');

  insert into public.applications(id,user_id,usage_type,status,user_name,submitted_at)
    values(manual_app,manual_id,'community_individual','cancelled','架空停止',moment);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',staff_id,'role','authenticated')::text,true);
  set local role authenticated;
  select public.disable_user_account(manual_id,'本人から停止依頼') into result_value;
  reset role;
  perform pg_temp.t22(result_value and (select account_state='disabled' from public.profiles where id=manual_id),'staff disables pre-stay terminal account');
  perform pg_temp.t22((select action='disable_user_account' and reason='本人から停止依頼' from public.audit_logs
    where entity_type='profile' and entity_id=manual_id),'manual disable is audited');

  insert into public.group_applications(id,representative_user_id,group_name,representative_stays,status,submitted_at,completed_at)
    values(group_id,rep_id,'架空終了団体',false,'cancelled',moment-interval '2 days',moment);
  perform private.reconcile_account_cleanup(rep_id,moment);
  perform pg_temp.t22((select account_state='cleanup_pending' from public.profiles where id=rep_id),'non-staying representative becomes eligible after group end');

  update public.account_cleanup_jobs set status='cancelled',last_error='test-reset' where user_id=rep_id and status='queued';
  update public.profiles set account_state='active' where id=rep_id;
  update public.group_applications set representative_user_id=null where id=group_id;
  insert into public.group_applications(id,group_name,representative_stays,status,submitted_at,start_date,end_date)
    values(gen_random_uuid(),'架空宿泊団体',false,'approved',moment-interval '3 days',current_date-2,current_date-1);
  select id into group_id from public.group_applications where group_name='架空宿泊団体';
  insert into public.applications(id,user_id,usage_type,group_id,status,start_date,end_date,user_name,requires_guardian_consent,submitted_at)
    values(member_app,member_id,'community_group',group_id,'approved',current_date-2,current_date-1,'架空団体員',false,moment-interval '3 days');
  insert into public.group_members(group_id,application_id) values(group_id,member_app);
  insert into public.stays(application_id,status,checked_in_at) values(member_app,'staying',moment-interval '2 days');
  update public.stays set status='moved_out',checked_out_at=moment where application_id=member_app;
  perform pg_temp.t22((select completed_at is not null from public.group_applications where id=group_id),'last checkout completes group');
  perform pg_temp.t22(exists(select 1 from public.audit_logs where entity_type='group_application' and entity_id=group_id
    and action='complete_group_stay' and actor_kind='system'),'group completion is audited');
  perform pg_temp.t22((select account_state='cleanup_pending' from public.profiles where id=member_id),'group member queued after final checkout');

  perform pg_temp.t22((select relrowsecurity from pg_class where oid='public.account_cleanup_jobs'::regclass),'job table has RLS');
  perform pg_temp.t22(not has_table_privilege('authenticated','public.account_cleanup_jobs','select'),'clients cannot read cleanup jobs');
end $$;
select count(*)::integer passed_checks,bool_and(passed) all_passed from pg_temp.t22_results;
rollback;
