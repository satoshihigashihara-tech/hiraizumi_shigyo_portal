-- Runner loads fixtures/camp_roster_lifecycle.sql first. No hosted connections.
begin;
set local timezone='UTC';
create temporary table a4_results(test_no integer generated always as identity,test_name text,passed boolean) on commit drop;
create function pg_temp.a4_check(ok boolean,label text) returns void language plpgsql as $$ begin
 if ok is distinct from true then raise exception 'FAIL: %',label; end if;
 insert into pg_temp.a4_results(test_name,passed) values(label,true);
end $$;
create function pg_temp.a4_fail_audit() returns trigger language plpgsql as $$ begin
 if new.action='end_camp_roster_participation' then raise exception 'test-audit-failure'; end if; return new;
end $$;
do $$
declare x a4_lifecycle_test.context%rowtype; r jsonb; before_value jsonb; st text; action_value text; claim jsonb; other_row jsonb; history jsonb; future_camp uuid;
begin
 foreach st in array array[null,'draft','submitted','under_review','revision_requested','approved','rejected','cancelled'] loop
  foreach action_value in array array['withdraw','reject'] loop
   perform a4_lifecycle_test.setup(st,case when st='approved' then 'before_move_in' end);
   select * into x from a4_lifecycle_test.context;
   before_value:=a4_lifecycle_test.snapshot();
   r:=a4_lifecycle_test.act(action_value);
   if action_value='reject' and (st is null or st in ('draft','rejected','cancelled')) then
    perform pg_temp.a4_check(r->>'message'='invalid-status' and a4_lifecycle_test.snapshot()=before_value,'invalid rejection leaves all state unchanged');
   else
    perform pg_temp.a4_check(r->>'ok'='true',format('%s %s succeeds: %s',action_value,st,r));
    perform pg_temp.a4_check((select participation_status='released' and ((disabled_at is not null)=(action_value='withdraw')) from public.camp_eligible_users where id=x.eligible),'qualification independent from participation');
    perform pg_temp.a4_check((select released_from=start_date and assignment_version=2 from public.camp_room_assignments where eligible_user_id=x.eligible),'before camp releases full period and advances individual version');
    perform pg_temp.a4_check((select room_plan_version=2 and roster_version=3 and saved_roster_version=3 from public.camps where id=x.camp),'plan and complete roster versions advance');
    perform pg_temp.a4_check((a4_lifecycle_test.snapshot()->'claims')=(before_value->'claims'),'camp claim immutable');
    perform pg_temp.a4_check((select to_jsonb(v) from public.camp_room_plan_versions v where camp_id=x.camp and version=1)=(before_value->'versions'->0),'previous plan immutable');
    perform pg_temp.a4_check((select assignment_version=1 and released_from is null from public.camp_room_assignments where eligible_user_id=x.other_eligible),'other assignment unchanged');
    if st is not null then
     perform pg_temp.a4_check((select status=case when action_value='reject' then 'rejected' when st in ('rejected','cancelled') then st else 'cancelled' end from public.applications where id=x.app),'application terminal state');
    end if;
    if st='approved' then perform pg_temp.a4_check((select status='before_move_in' and checked_in_at is null and checked_out_at is null from public.stays where application_id=x.app),'no invented stay for prearrival cancellation'); end if;
    r:=a4_lifecycle_test.act(action_value);
    perform pg_temp.a4_check(r->>'message'='stale-update','duplicate old request rejected');
   end if;
   set constraints all immediate;
   perform a4_lifecycle_test.cleanup();
  end loop;
 end loop;
 -- Unassigned/never committed camps remain unclaimed after release.
 perform a4_lifecycle_test.setup(null,null,20,false);
 r:=a4_lifecycle_test.act(); perform pg_temp.a4_check(r->>'ok'='true','unassigned withdrawal');
 perform pg_temp.a4_check((select room_plan_committed_at is null and saved_roster_version is null from public.camps where id=(select camp from a4_lifecycle_test.context))
   and not exists(select 1 from public.calendar_claims where camp_id=(select camp from a4_lifecycle_test.context)),'uncommitted remains unclaimed');
 perform a4_lifecycle_test.cleanup();
 -- Existing incomplete plan stays incomplete.
 perform a4_lifecycle_test.setup(); select * into x from a4_lifecycle_test.context;
 update public.camps set saved_roster_version=1 where id=x.camp;
 r:=a4_lifecycle_test.act(); perform pg_temp.a4_check(r->>'ok'='true' and (select saved_roster_version=1 and roster_version=3 from public.camps where id=x.camp),'incomplete roster not falsely completed');
 perform a4_lifecycle_test.cleanup();
 -- Auth, confirmation, old versions, audit atomicity.
 perform a4_lifecycle_test.setup(); select * into x from a4_lifecycle_test.context;
 before_value:=a4_lifecycle_test.snapshot();
 r:=a4_lifecycle_test.call_as(x.owner,a4_lifecycle_test.command()); perform pg_temp.a4_check(r->>'state'='42501','nonstaff denied');
 r:=a4_lifecycle_test.call_as(null,a4_lifecycle_test.command()); perform pg_temp.a4_check(r->>'state'='42501','anonymous denied');
 r:=a4_lifecycle_test.call_as(x.staff,replace(a4_lifecycle_test.command(),',true,',',false,')); perform pg_temp.a4_check(r->>'message'='confirmation-required','explicit confirmation required');
 r:=a4_lifecycle_test.call_as(x.staff,replace(a4_lifecycle_test.command(),'架空終了理由','')); perform pg_temp.a4_check(r->>'message'='reason-required','reason required');
 r:=a4_lifecycle_test.call_as(x.staff,replace(a4_lifecycle_test.command(),x.app::text,gen_random_uuid()::text)); perform pg_temp.a4_check(r->>'message'='stale-update','application identity expected');
 create trigger a4_audit_failure before insert on public.audit_logs for each row execute function pg_temp.a4_fail_audit();
 r:=a4_lifecycle_test.act(); perform pg_temp.a4_check(r->>'message'='test-audit-failure','audit failure injected');
 drop trigger a4_audit_failure on public.audit_logs;
 perform pg_temp.a4_check(a4_lifecycle_test.snapshot()=before_value,'all writes rolled back on audit failure and invalid requests');
 perform a4_lifecycle_test.cleanup();
 -- Mode, deleted camp, foreign member and stale version boundaries.
 perform a4_lifecycle_test.setup(); select * into x from a4_lifecycle_test.context;
 r:=a4_lifecycle_test.call_as(x.owner,format('select public.get_staff_camp_roster_lifecycle(%L,%L)',x.camp,x.eligible));
 perform pg_temp.a4_check(r->>'state'='42501','owner cannot fetch staff lifecycle projection');
 r:=a4_lifecycle_test.call_as(x.staff,replace(a4_lifecycle_test.command(),x.eligible::text,x.other_eligible::text));
 perform pg_temp.a4_check(r->>'message'='stale-update','foreign expected participant version refused');
 r:=a4_lifecycle_test.call_as(x.staff,replace(a4_lifecycle_test.command(),x.camp::text,gen_random_uuid()::text));
 perform pg_temp.a4_check(r->>'message'='not-found','unknown camp refused');
 perform set_config('private.camp_mode_migration','allowed',true);
 update public.camps set room_assignment_mode='legacy_application' where id=x.camp;
 before_value:=a4_lifecycle_test.snapshot();
 r:=a4_lifecycle_test.act(); perform pg_temp.a4_check(r->>'message'='eligible-roster-required' and a4_lifecycle_test.snapshot()=before_value,'legacy camp not mutated');
 perform a4_lifecycle_test.cleanup();
 -- Late checkout clamps release to original period end plus one.
 perform a4_lifecycle_test.setup('approved','staying',-5); select * into x from a4_lifecycle_test.context;
 r:=a4_lifecycle_test.act('withdraw',true);
 perform pg_temp.a4_check(r->>'ok'='true' and (select released_from=end_date+1 from public.camp_room_assignments where eligible_user_id=x.eligible),'late checkout cannot extend reservation');
 perform a4_lifecycle_test.cleanup();
 -- Staying withdrawal requires checkout; preserve confirmation day and cancel atomically.
 perform a4_lifecycle_test.setup('approved','staying',-1); select * into x from a4_lifecycle_test.context;
 perform a4_lifecycle_test.seed_retained_records(); history:=a4_lifecycle_test.retained_snapshot();
 before_value:=a4_lifecycle_test.snapshot();
 r:=a4_lifecycle_test.act('withdraw'); perform pg_temp.a4_check(r->>'message'='checkout-confirmation-required' and a4_lifecycle_test.snapshot()=before_value,'staying requires separate confirmation');
 r:=a4_lifecycle_test.act('reject',true); perform pg_temp.a4_check(r->>'message'='invalid-status','staying rejection forbidden');
 r:=a4_lifecycle_test.act('withdraw',true); perform pg_temp.a4_check(r->>'ok'='true','staying withdrawal');
 perform pg_temp.a4_check((select status='cancelled' from public.applications where id=x.app) and (select status='moved_out' and checked_out_at is not null from public.stays where application_id=x.app),'checkout and cancellation atomic');
 perform pg_temp.a4_check((select released_from=(clock_timestamp() at time zone 'Asia/Tokyo')::date+1 from public.camp_room_assignments where eligible_user_id=x.eligible),'checkout day retained');
 perform pg_temp.a4_check(a4_lifecycle_test.snapshot()->'claims'=before_value->'claims','staying withdrawal retains exclusive claim');
 perform pg_temp.a4_check(a4_lifecycle_test.retained_snapshot()=history,'paid charges, monthly amounts, approval and all PDF bytes metadata unchanged');
 perform pg_temp.a4_check((public.authorize_camp_pdf_delivery((select id from public.camp_application_versions where application_id=x.app and state='ready'),x.owner,'HEAD')->>'allowed')='false','ended owner cannot read pending confirmation PDF');
 perform pg_temp.a4_check((public.authorize_camp_pdf_delivery((select id from public.camp_application_versions where application_id=x.app and state='submitted'),x.staff,'GET')->>'allowed')='true','staff can read unchanged submitted PDF after withdrawal');
 set constraints all immediate;
 perform a4_lifecycle_test.cleanup();
 -- Released participants cannot rejoin through ordinary draft creation or full save.
 perform a4_lifecycle_test.setup(); select * into x from a4_lifecycle_test.context;
 r:=a4_lifecycle_test.act();
 r:=a4_lifecycle_test.call_as(x.owner,format('select public.create_camp_application_draft(%L)',x.camp));
 perform pg_temp.a4_check(r->>'ok'='false','ended participant cannot create another application');
 r:=a4_lifecycle_test.call_as(x.staff,format('select public.save_camp_room_plan(%L,3,2,%L::jsonb)',x.camp,
   jsonb_build_array(jsonb_build_object('eligible_user_id',x.eligible,'room_id',x.room),jsonb_build_object('eligible_user_id',x.other_eligible,'room_id',x.room))));
 perform pg_temp.a4_check(r->>'message'='invalid-roster','ordinary save cannot revive released participant');
 perform a4_lifecycle_test.cleanup();
 -- Common stay API uses new assignment and retains approved history on normal checkout.
 perform a4_lifecycle_test.setup('approved','before_move_in',0); select * into x from a4_lifecycle_test.context;
 future_camp:=gen_random_uuid();
 insert into public.camps(id,name,start_date,end_date,application_deadline,created_by,room_assignment_mode)
 values(future_camp,'架空の次回camp',current_date+50,current_date+53,clock_timestamp()+interval '30 days',x.staff,'eligible_roster');
 insert into public.camp_eligible_users(camp_id,email_normalized,management_name)
 values(future_camp,'a4-owner@example.invalid','架空次回');
 perform pg_temp.a4_check(private.account_cleanup_blocker(x.owner)='camp-participation-open','unlinked verified future roster protects account');
 r:=a4_lifecycle_test.call_as(x.staff,format('select * from public.update_application_stay(%L,%L,%L)',x.app,x.app_version,'check_in'));
 perform pg_temp.a4_check(r->>'ok'='true','common checkin uses roster allocation');
 r:=a4_lifecycle_test.call_as(x.staff,format('select * from public.update_application_stay(%L,%L,%L)',x.app,(select updated_at from public.applications where id=x.app),'check_out'));
 perform pg_temp.a4_check(r->>'ok'='true','common checkout uses lifecycle');
 set constraints all immediate;
 perform pg_temp.a4_check((select status='approved' from public.applications where id=x.app) and (select participation_status='released' and disabled_at is null from public.camp_eligible_users where id=x.eligible),'normal checkout preserves approved and qualification');
 r:=a4_lifecycle_test.call_as(x.staff,format('select public.get_application_stay(%L)',x.app));
 perform pg_temp.a4_check(r->'rows'->0->'get_application_stay'->'room_allocation'->>'is_current'='false','historical allocation returned without current occupancy');
 perform pg_temp.a4_check((select account_state='active' from public.profiles where id=x.owner),'checkout cannot queue cleanup of future participant');
 delete from public.camp_eligible_users where camp_id=future_camp;
 delete from public.camps where id=future_camp;
 perform a4_lifecycle_test.cleanup();
 -- Already moved out: retain actual checkout, approval and original release boundary.
 perform a4_lifecycle_test.setup('approved','moved_out',-2); select * into x from a4_lifecycle_test.context;
 before_value:=a4_lifecycle_test.snapshot();
 r:=a4_lifecycle_test.act(); perform pg_temp.a4_check(r->>'ok'='true','historical moved out participation can end');
 perform pg_temp.a4_check((select status='approved' from public.applications where id=x.app) and a4_lifecycle_test.snapshot()->'stays'=before_value->'stays','past stay and approval retained');
 perform pg_temp.a4_check((select released_from=(clock_timestamp() at time zone 'Asia/Tokyo')::date from public.camp_room_assignments where eligible_user_id=x.eligible),'historical checkout boundary retained');
 set constraints all immediate;
 perform a4_lifecycle_test.cleanup();
end $$;
select count(*) checked_cases,bool_and(passed) all_passed from a4_results;
rollback;
