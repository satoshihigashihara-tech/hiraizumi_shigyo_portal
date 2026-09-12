begin;
set local statement_timeout='90s';
create temporary table a10_results(name text,passed boolean) on commit drop;
create function pg_temp.a10_check(ok boolean,label text) returns void language plpgsql as $$ begin
 if ok is distinct from true then raise exception 'FAIL: %',label; end if;
 insert into pg_temp.a10_results values(label,true);
end $$;
create function pg_temp.a10_fail_audit() returns trigger language plpgsql as $$ begin
 if new.action in ('camp_room_change_revision','camp_roster_approve') then raise exception 'a10-audit-failure'; end if; return new;
end $$;
create function pg_temp.a10_reject_after(mutation text,expected text,refresh_expectations boolean default true) returns void language plpgsql as $$
declare x a10_review_test.context%rowtype; command text; r jsonb; snapshot jsonb;
begin
 select * into x from a10_review_test.context;
 command:=a10_review_test.change_command();
 begin
  execute mutation;
  if refresh_expectations then command:=a10_review_test.change_command(); end if;
  snapshot:=a10_review_test.snapshot();
  r:=a10_review_test.call_as(x.staff,command);
  if r->>'message' is distinct from expected then raise exception 'expected %, got %',expected,r; end if;
  if snapshot is distinct from a10_review_test.snapshot() then raise exception 'rejected request mutated rows'; end if;
  raise exception using errcode='A1000',message='rollback-fixture';
 exception when sqlstate 'A1000' then null;
 end;
 perform pg_temp.a10_check(true,'rejected atomically: '||expected);
end $$;
do $$
declare x a10_review_test.context%rowtype; r jsonb; before_value jsonb; command text; previous_pdf uuid; new_pdf uuid;
 due timestamptz; n int; field text; original_paid jsonb; previous_history jsonb; versions jsonb; unchanged jsonb; snapshot jsonb;
begin
 perform a10_review_test.setup(); select * into x from a10_review_test.context;
 update public.application_charges set payment_status='paid',paid_at=clock_timestamp(),payment_due_date=current_date+90 where application_id=x.app[6];
 perform pg_temp.a10_reject_after(format('update public.camp_room_mapping set printing_enabled=false where room_id=%L',x.room[4]),'room-not-confirmed');
 perform pg_temp.a10_reject_after(format('update public.camp_room_mapping set assignment_enabled=false where room_id=%L',x.room[4]),'room-not-confirmed');
 perform pg_temp.a10_reject_after(format('update public.applications set revision_due_at=clock_timestamp()-interval ''1 second'' where id=%L',x.app[5]),'deadline-passed');
 perform pg_temp.a10_reject_after(format('delete from public.stays where application_id=%L',x.app[6]),'invalid-stay');
 perform pg_temp.a10_reject_after(format('insert into public.stays(application_id) values(%L)',x.app[2]),'invalid-stay');
 perform pg_temp.a10_reject_after(format('update public.stays set status=''staying'',checked_in_at=clock_timestamp() where application_id=%L',x.app[6]),'camp-started');
 perform pg_temp.a10_reject_after(format('update public.stays set status=''moved_out'',checked_in_at=clock_timestamp(),checked_out_at=clock_timestamp() where application_id=%L',x.app[6]),'camp-started');
 perform pg_temp.a10_reject_after(format('delete from public.calendar_claims where camp_id=%L',x.camp),'calendar-inconsistent');
 perform pg_temp.a10_reject_after(format('update public.applications set latest_submitted_camp_pdf_version_id=null where id=%L',x.app[3]),'submitted-pdf-inconsistent');
 perform pg_temp.a10_reject_after(format('update public.camp_eligible_users set management_name=''別の架空氏名'' where id=%L',x.eligible[3]),'stale-update',false);
 perform pg_temp.a10_reject_after(format('update public.profiles set account_state=''disabled'' where id=%L',x.staff),'staff-required',false);
 perform pg_temp.a10_reject_after(format('update public.profiles set account_state=''disabled'' where id=%L',x.owner[3]),'invalid-status');
 perform pg_temp.a10_reject_after(format('insert into public.applications(usage_type,camp_id,camp_eligible_user_id,user_id,start_date,end_date) select ''camp'',c.id,%L,%L,c.start_date,c.end_date from public.camps c where c.id=%L',x.eligible[1],x.owner[1],x.camp),'stale-update',false);
 perform pg_temp.a10_check(private.camp_roster_revision_deadline('2026-09-20','2026-09-12T14:59:59Z')='2026-09-15T15:00:00Z','JST +4 midnight before day boundary');
 perform pg_temp.a10_check(private.camp_roster_revision_deadline('2026-09-20','2026-09-12T15:00:00Z')='2026-09-16T15:00:00Z','JST +4 midnight after day boundary');
 perform pg_temp.a10_check(private.camp_roster_revision_deadline('2026-09-14','2026-09-12T15:00:00Z')='2026-09-13T15:00:00Z','deadline capped at start day');
 begin
  delete from public.application_charges where application_id=x.app[4];
  r:=a10_review_test.review(x.app[4],'approve');
  if r->>'message'<>'application-inconsistent' then raise exception 'missing charge unexpectedly allowed %',r; end if;
  raise exception using errcode='A1000',message='rollback-fixture';
 exception when sqlstate 'A1000' then null;
 end;
 perform pg_temp.a10_check(true,'missing charges cannot be silently recreated at approval');
 command:=a10_review_test.change_command(); before_value:=a10_review_test.snapshot();
 for n in 1..7 loop
  r:=a10_review_test.call_as(x.owner[n],command);
  perform pg_temp.a10_check(r->>'code'='42501','owner/other/representative cannot change '||n);
 end loop;
 r:=a10_review_test.call_as(null,command,'anon'); perform pg_temp.a10_check(r->>'code'='42501','anon cannot change');
 r:=a10_review_test.call_as(null,command,'service_role'); perform pg_temp.a10_check(r->>'code'='42501','service role cannot change');
 r:=a10_review_test.call_as(x.staff,replace(command,'架空部屋変更','')); perform pg_temp.a10_check(r->>'message'='reason-required','reason required');
 r:=a10_review_test.call_as(x.staff,replace(command,'true)','false)')); perform pg_temp.a10_check(r->>'message'='confirmation-required','confirmation required');
 r:=a10_review_test.call_as(x.staff,a10_review_test.change_command(array[1,2],3)); perform pg_temp.a10_check(r->>'message'='room-capacity-full','capacity checked');
 r:=a10_review_test.call_as(x.staff,replace(command,x.camp::text,gen_random_uuid()::text)); perform pg_temp.a10_check(r->>'message'='not-found','unknown camp rejected');
 perform pg_temp.a10_check(before_value=a10_review_test.snapshot(),'denied requests change nothing');
 create trigger a10_fail before insert on public.audit_logs for each row execute function pg_temp.a10_fail_audit();
 r:=a10_review_test.call_as(x.staff,command); perform pg_temp.a10_check(r->>'message'='a10-audit-failure','room audit injected failure: '||r::text);
 perform pg_temp.a10_check(before_value=a10_review_test.snapshot(),'room audit rolls back all records');
 drop trigger a10_fail on public.audit_logs;
 select revision_due_at into due from public.applications where id=x.app[5];
 select to_jsonb(a) into unchanged from public.applications a where id=x.app[7];
 select latest_submitted_camp_pdf_version_id into previous_pdf from public.applications where id=x.app[6];
 r:=a10_review_test.call_as(x.staff,command); perform pg_temp.a10_check(r->>'ok'='true','mixed status change succeeds: '||r::text);
 perform pg_temp.a10_check(jsonb_array_length(r->'rows'->0->'value'->'revised_ids')=4,'only four submitted changed applicants revised');
 perform pg_temp.a10_check(not exists(select 1 from public.applications where camp_eligible_user_id=x.eligible[1]),'unapplied stays unapplied');
 perform pg_temp.a10_check((select status='draft' from public.applications where id=x.app[2]),'draft input retained');
 for n in 3..6 loop perform pg_temp.a10_check((select status='revision_requested' from public.applications where id=x.app[n]),'changed submitted state revised '||n); end loop;
 perform pg_temp.a10_check((select to_jsonb(a)=unchanged from public.applications a where id=x.app[7]),'unchanged application byte-identical');
 perform pg_temp.a10_check((select revision_due_at=due from public.applications where id=x.app[5]),'existing valid revision deadline retained');
 perform pg_temp.a10_check((select count(*)=1 from public.application_status_events where application_id=x.app[5] and to_status='revision_requested'),'no duplicate revision state event');
 snapshot:=a10_review_test.snapshot();
 foreach field in array array['stays','charges','months','receipts','claims','pdfs'] loop
  perform pg_temp.a10_check(snapshot->field=before_value->field,'room change preserves '||field);
 end loop;
 perform pg_temp.a10_check((select count(*)=1 from public.application_status_events where application_id=x.app[6] and to_status='approved'),'initial approval event retained');
 perform pg_temp.a10_check((select assignment_version=1 from public.camp_room_assignments where eligible_user_id=x.eligible[7]),'unchanged own assignment version retained');
 r:=a10_review_test.call_as(x.staff,command); perform pg_temp.a10_check(r->>'message'='stale-update','duplicate original change rejected');
 command:=a10_review_test.change_command(array[]::int[]);snapshot:=a10_review_test.snapshot();
 r:=a10_review_test.call_as(x.staff,command); perform pg_temp.a10_check(r->'rows'->0->'value'->>'changed'='false' and snapshot=a10_review_test.snapshot(),'no-op creates no versions or audits');
 r:=a10_review_test.review(x.app[7],'start_review'); perform pg_temp.a10_check(r->>'ok'='true','unaffected submitted PDF can be reviewed after global plan change');
 r:=a10_review_test.review(x.app[7],'approve'); perform pg_temp.a10_check(r->>'ok'='true','unaffected submitted PDF can be approved');
 r:=a10_review_test.call_as(x.staff,format('select public.update_application_stay(%L,%L,%L)',x.app[6],(select updated_at from public.applications where id=x.app[6]),'check_in'));
 perform pg_temp.a10_check(r->>'ok'='false','revision cannot check in');
 r:=a10_review_test.call_as(x.owner[6],format('select * from public.submit_camp_application_with_pdf(%L,%L,1,%L,true)',x.app[6],previous_pdf,gen_random_uuid()));
 perform pg_temp.a10_check(r->>'ok'='false','old submitted PDF cannot be resubmitted');
 for n in 1..2 loop
  before_value:=a10_review_test.snapshot();
  new_pdf:=a10_review_test.submit(x.app[6]);
  perform pg_temp.a10_check(new_pdf<>previous_pdf and (select source_snapshot->>'previously_approved'='true' from public.camp_application_versions where id=new_pdf),'reapproval PDF change flag from actual history '||n);
  snapshot:=a10_review_test.snapshot();
  foreach field in array array['stays','charges','months','receipts','claims'] loop
   perform pg_temp.a10_check(snapshot->field=before_value->field,'resubmission preserves '||field||n);
  end loop;
  r:=a10_review_test.review(x.app[6],'start_review'); perform pg_temp.a10_check(r->>'ok'='true','start rereview '||n);
  command:=a10_review_test.review_command(x.app[6],'approve');snapshot:=a10_review_test.snapshot();
  create trigger a10_fail before insert on public.audit_logs for each row execute function pg_temp.a10_fail_audit();
  r:=a10_review_test.call_as(x.staff,command);perform pg_temp.a10_check(r->>'message'='a10-audit-failure' and snapshot=a10_review_test.snapshot(),'approve audit atomically rolls back '||n);
  drop trigger a10_fail on public.audit_logs;
  r:=a10_review_test.call_as(x.staff,command);perform pg_temp.a10_check(r->>'ok'='true','reapprove existing stay '||n);
  perform pg_temp.a10_check((a10_review_test.snapshot()->'stays')=before_value->'stays','same stay and times after reapproval '||n);
  perform pg_temp.a10_check((select to_jsonb(v) from public.camp_application_versions v where id=previous_pdf)=
   (select value from jsonb_array_elements(before_value->'pdfs') where value->>'id'=previous_pdf::text),'past PDF all columns unchanged '||n);
  r:=a10_review_test.call_as(x.staff,command);perform pg_temp.a10_check(r->>'message'='stale-update','double approval rejected '||n);
  if n=1 then r:=a10_review_test.call_as(x.staff,a10_review_test.change_command(array[6],1));perform pg_temp.a10_check(r->>'ok'='true','change back requires new submission');end if;
 end loop;
 perform pg_temp.a10_check((select count(*)=3 from public.application_status_events where application_id=x.app[6] and to_status='approved'),'all three approvals retained');
 -- Role and read boundaries; no direct table / private helper permission.
 r:=a10_review_test.call_as(x.owner[6],format('select public.get_staff_camp_roster_application_review(%L,%L)',x.camp,x.app[6]));perform pg_temp.a10_check(r->>'code'='42501','owner cannot read staff snapshot');
 perform pg_temp.a10_check(not has_function_privilege('authenticated','private.assert_camp_roster_submitted_pdf(uuid)','EXECUTE'),'private helper execution denied');
 perform pg_temp.a10_check(not has_table_privilege('authenticated','public.camp_application_versions','SELECT'),'PDF table direct read denied');
 r:=a10_review_test.call_as(x.staff,format('select public.get_staff_camp_roster_application_review(%L,%L) value',x.camp,x.app[6]));
 perform pg_temp.a10_check(r->>'ok'='true' and not (r->'rows'->0->'value' ?| array['object_path','source_hash','owner_id']),'staff DTO omits storage/owner details');
 -- A4 rejection after previous approval keeps history while releasing assignment.
 r:=a10_review_test.call_as(x.staff,format('select public.end_camp_roster_participation(%L,%L,%L,%s,%s,%L,%L,%L,%L,true,false)',x.camp,x.eligible[6],
  (select updated_at from public.camp_eligible_users where id=x.eligible[6]),(select roster_version from public.camps where id=x.camp),
  (select room_plan_version from public.camps where id=x.camp),x.app[6],(select updated_at from public.applications where id=x.app[6]),'reject','架空不許可'));
 perform pg_temp.a10_check(r->>'ok'='true','A4 rejection after rereview');
 perform pg_temp.a10_check((select status='before_move_in' from public.stays where application_id=x.app[6]) and (select payment_status='paid' from public.application_charges where application_id=x.app[6]),'A4 retains stay and paid charge');
 r:=a10_review_test.call_as(x.staff,a10_review_test.change_command(array[2],2));perform pg_temp.a10_check(r->>'ok'='true','change after release succeeds: '||r::text);
 perform pg_temp.a10_check((select assignments @> jsonb_build_array(jsonb_build_object('eligible_user_id',x.eligible[6],'released_from',start_date))
  from public.camp_room_plan_versions where camp_id=x.camp order by version desc limit 1),'new plan retains released history');
end $$;
select jsonb_build_object('checked_tests',count(*),'all_passed',bool_and(passed)) as result from a10_results;
rollback;
