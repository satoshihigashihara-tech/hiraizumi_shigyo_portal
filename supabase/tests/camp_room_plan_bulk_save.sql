-- A3 single-connection regression. Run after SQL 032; all fictional data rolls back.
begin;
set local timezone='UTC';
set local statement_timeout='60s';

create temporary table a3_results(test_no integer generated always as identity,test_name text,passed boolean) on commit drop;
create function pg_temp.a3_check(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  insert into pg_temp.a3_results(test_name,passed) values(label,true);
end $$;
create function pg_temp.a3_user(email_value text,is_staff boolean default false) returns uuid language plpgsql as $$
declare x uuid:=gen_random_uuid(); begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',email_value,'',clock_timestamp(),'{"provider":"email","providers":["email"]}','{}',clock_timestamp(),clock_timestamp());
  if is_staff then insert into public.staff_roles(user_id) values(x); end if; return x;
end $$;
create function pg_temp.a3_call(actor uuid,sql_text text) returns jsonb language plpgsql as $$
declare row_value record; rows_value jsonb:='[]'; state_value text; message_value text; actor_email text:=(select email from auth.users where id=actor);
begin
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'email',actor_email,'role','authenticated')::text,true);
    for row_value in execute sql_text loop rows_value:=rows_value||jsonb_build_array(to_jsonb(row_value)); end loop;
    set local role postgres; return jsonb_build_object('ok',true,'rows',rows_value);
  exception when others then
    get stacked diagnostics state_value=returned_sqlstate,message_value=message_text;
    set local role postgres; return jsonb_build_object('ok',false,'state',state_value,'message',message_value);
  end;
end $$;
create function pg_temp.a3_save(actor uuid,camp uuid,payload jsonb,roster bigint default null,plan bigint default null) returns jsonb language plpgsql as $$
declare c public.camps%rowtype;
begin
  select * into c from public.camps where id=camp;
  return pg_temp.a3_call(actor,format('select public.save_camp_room_plan(%L,%L,%L,%L::jsonb)',camp,coalesce(roster,c.roster_version),coalesce(plan,c.room_plan_version),payload));
end $$;
create function pg_temp.a3_snapshot(camp uuid) returns jsonb language sql as $$
 select jsonb_build_object('camp',(select to_jsonb(c) from public.camps c where id=camp),
 'claims',(select jsonb_agg(to_jsonb(q)) from public.calendar_claims q where camp_id=camp),
 'assignments',(select jsonb_agg(to_jsonb(r) order by id) from public.camp_room_assignments r where camp_id=camp),
 'versions',(select jsonb_agg(to_jsonb(v) order by version) from public.camp_room_plan_versions v where camp_id=camp),
 'audit',(select jsonb_agg(to_jsonb(a) order by id) from public.audit_logs a where entity_id=camp))
$$;
create function pg_temp.a3_fail_audit() returns trigger language plpgsql as $$ begin
  if new.action='save_camp_room_plan' then raise exception 'test-audit-failure'; end if; return new;
end $$;

do $$
declare staff uuid:=pg_temp.a3_user('a3-staff@example.invalid',true); viewer uuid:=pg_temp.a3_user('a3-viewer@example.invalid');
 c uuid:=gen_random_uuid(); legacy uuid:=gen_random_uuid(); other uuid:=gen_random_uuid(); e1 uuid:=gen_random_uuid(); e2 uuid:=gen_random_uuid();
 e3 uuid:=gen_random_uuid(); room1 uuid; room2 uuid; payload jsonb; r jsonb; before_value jsonb; rv bigint; pv bigint;
 app uuid:=gen_random_uuid(); claim_id uuid; initial_commit timestamptz; v jsonb;
begin
 select id into room1 from public.rooms where name='梅'; select id into room2 from public.rooms where name='竹';
 perform pg_temp.a3_check((select count(*)=0 from public.camp_room_mapping),'no production rooms automatically enabled');
 insert into public.camps(id,name,start_date,end_date,application_deadline,created_by,room_assignment_mode) values
 (c,'A3 roster',current_date+100,current_date+102,clock_timestamp()+interval '90 days',staff,'eligible_roster'),
 (other,'A3 other',current_date+110,current_date+112,clock_timestamp()+interval '90 days',staff,'eligible_roster'),
 (legacy,'A3 legacy',current_date+120,current_date+122,clock_timestamp()+interval '90 days',staff,'legacy_application');
 perform pg_temp.a3_check(not exists(select 1 from public.calendar_claims where camp_id=c),'new roster camp does not reserve a claim');
 perform pg_temp.a3_check(exists(select 1 from public.calendar_claims where camp_id=legacy),'legacy camp still reserves immediately');
 insert into public.camp_eligible_users(id,camp_id,management_name,email_normalized) values
 (e1,c,'架空一','a3-one@example.invalid'),(e2,c,'架空二','a3-two@example.invalid'),(e3,other,'架空別','a3-other@example.invalid');
 payload:=jsonb_build_array(jsonb_build_object('eligible_user_id',e1,'room_id',room1),jsonb_build_object('eligible_user_id',e2,'room_id',room1));
 r:=pg_temp.a3_save(viewer,c,payload); perform pg_temp.a3_check(r->>'state'='42501','nonstaff cannot save');
 r:=pg_temp.a3_save(null,c,payload); perform pg_temp.a3_check(r->>'state'='42501','anonymous cannot save');
 r:=pg_temp.a3_save(staff,legacy,payload); perform pg_temp.a3_check(r->>'message'='eligible-roster-required','legacy mode refused');
 r:=pg_temp.a3_save(staff,c,payload); perform pg_temp.a3_check(r->>'message'='room-not-confirmed','unconfirmed rooms refused');
 insert into public.camp_room_mapping(room_id,source_name,floor,display_name,print_name,assignment_enabled,confirmed_at,confirmation_evidence)
 select id,'架空テスト資料',2,name,name,true,clock_timestamp(),'local fictional test only' from public.rooms;
 before_value:=pg_temp.a3_snapshot(c);
 r:=pg_temp.a3_save(staff,c,'[]'); perform pg_temp.a3_check(r->>'message'='invalid-assignments','empty plan refused');
 r:=pg_temp.a3_save(staff,c,'{}'); perform pg_temp.a3_check(r->>'message'='invalid-assignments','object refused');
 r:=pg_temp.a3_save(staff,c,jsonb_build_array(payload->0)); perform pg_temp.a3_check(r->>'message'='invalid-roster','partial plan refused');
 r:=pg_temp.a3_save(staff,c,jsonb_build_array(payload->0,payload->0)); perform pg_temp.a3_check(r->>'message'='duplicate-assignment','duplicate refused');
 r:=pg_temp.a3_save(staff,c,jsonb_set(payload,'{1,eligible_user_id}',to_jsonb(e3))); perform pg_temp.a3_check(r->>'message'='invalid-roster','other camp refused');
 r:=pg_temp.a3_save(staff,c,jsonb_set(payload,'{0,room_id}','"bad"')); perform pg_temp.a3_check(r->>'message'='invalid-assignments','invalid UUID refused');
 r:=pg_temp.a3_save(staff,c,jsonb_set(payload,'{0,people_count}','2')); perform pg_temp.a3_check(r->>'message'='invalid-assignments','extra field refused');
 r:=pg_temp.a3_save(staff,c,payload,0); perform pg_temp.a3_check(r->>'message'='stale-update','stale roster refused');
 perform pg_temp.a3_check(pg_temp.a3_snapshot(c)=before_value,'rejections do not write any plan claim version or audit');
 update public.rooms set capacity=1 where id=room1;
 r:=pg_temp.a3_save(staff,c,payload); perform pg_temp.a3_check(r->>'message'='room-capacity-full','room overflow refused');
 update public.rooms set capacity=2 where id=room1;
 update public.camp_eligible_users set disabled_at=clock_timestamp() where id=e2;
 r:=pg_temp.a3_save(staff,c,payload); perform pg_temp.a3_check(r->>'message'='invalid-roster','disabled member refused');
 update public.camp_eligible_users set disabled_at=null,participation_status='released',released_at=clock_timestamp(),release_reason='架空解放' where id=e2;
 r:=pg_temp.a3_save(staff,c,payload); perform pg_temp.a3_check(r->>'message'='invalid-roster','released member refused');
 update public.camp_eligible_users set participation_status='participating',released_at=null,release_reason=null where id=e2;
 r:=pg_temp.a3_save(staff,c,payload); perform pg_temp.a3_check(r->>'ok'='true','complete save succeeds');
 select id into claim_id from public.calendar_claims where camp_id=c;
 select room_plan_committed_at,roster_version,room_plan_version into initial_commit,rv,pv from public.camps where id=c;
 perform pg_temp.a3_check(claim_id is not null and initial_commit is not null and pv=1,'first save reserves and commits');
 perform pg_temp.a3_check((select count(*)=2 from public.camp_room_assignments where camp_id=c),'one row per person');
 perform pg_temp.a3_check((select count(*)=1 from public.camp_room_plan_versions where camp_id=c) and
   (select count(*)=1 from public.audit_logs where entity_id=c and action='save_camp_room_plan'),'immutable version and audit recorded');
 before_value:=pg_temp.a3_snapshot(c);
 r:=pg_temp.a3_save(staff,c,payload,rv,0); perform pg_temp.a3_check(r->>'message'='stale-update' and pg_temp.a3_snapshot(c)=before_value,'repeated old save cannot overwrite');
 update public.camp_eligible_users set management_name='変更氏名',email_normalized='a3-edited@example.invalid' where id=e1;
 perform pg_temp.a3_check((select roster_version=rv and saved_roster_version=rv from public.camps where id=c),'label edit preserves completeness');
 r:=pg_temp.a3_save(staff,c,payload); perform pg_temp.a3_check(r->>'ok'='true' and
   (select bool_and(assignment_version=1) from public.camp_room_assignments where camp_id=c),'same rooms retain individual versions');
 v:=(select to_jsonb(x) from public.camp_room_plan_versions x where camp_id=c and version=1);
 payload:=jsonb_set(payload,'{0,room_id}',to_jsonb(room2));
 r:=pg_temp.a3_save(staff,c,payload); perform pg_temp.a3_check(r->>'ok'='true' and
   (select assignment_version=2 from public.camp_room_assignments where eligible_user_id=e1) and
   (select assignment_version=1 from public.camp_room_assignments where eligible_user_id=e2),'only changed person version advances');
 perform pg_temp.a3_check((select to_jsonb(x)=v from public.camp_room_plan_versions x where camp_id=c and version=1),'prior snapshot unchanged');
 e3:=gen_random_uuid();
 insert into public.camp_eligible_users(id,camp_id,management_name,email_normalized) values(e3,c,'架空追加','a3-add@example.invalid');
 perform pg_temp.a3_check((select saved_roster_version<>roster_version and room_plan_committed_at=initial_commit from public.camps where id=c)
   and (select id=claim_id and released_from is null from public.calendar_claims where camp_id=c)
   and (select count(*)=2 from public.camp_room_assignments where camp_id=c),'adding member retains claim and existing assignments');
 before_value:=pg_temp.a3_snapshot(c);
 r:=pg_temp.a3_save(staff,c,payload); perform pg_temp.a3_check(r->>'message'='invalid-roster' and pg_temp.a3_snapshot(c)=before_value,'incomplete resave keeps old plan');
 payload:=payload||jsonb_build_array(jsonb_build_object('eligible_user_id',e3,'room_id',room2));
 create trigger a3_fail_audit before insert on public.audit_logs for each row execute function pg_temp.a3_fail_audit();
 r:=pg_temp.a3_save(staff,c,payload); perform pg_temp.a3_check(r->>'message'='test-audit-failure' and pg_temp.a3_snapshot(c)=before_value,'audit failure rolls back assignments claim and versions');
 drop trigger a3_fail_audit on public.audit_logs;
 r:=pg_temp.a3_save(staff,c,payload); perform pg_temp.a3_check(r->>'ok'='true','complete resave accepts added member');
 r:=pg_temp.a3_call(viewer,format('select public.get_staff_camp_room_plan(%L)',c)); perform pg_temp.a3_check(r->>'state'='42501','nonstaff cannot read roster');
 r:=pg_temp.a3_call(staff,'select * from public.camp_room_assignments'); perform pg_temp.a3_check(r->>'state'='42501','staff cannot directly read table');
 r:=pg_temp.a3_call(staff,'delete from public.camp_room_assignments returning id'); perform pg_temp.a3_check(r->>'state'='42501','staff cannot directly write table');
 r:=pg_temp.a3_call(staff,format('select public.get_staff_camp_room_plan(%L)',c)); perform pg_temp.a3_check(r->>'ok'='true','staff projection succeeds');
 begin update public.camp_room_plan_versions set assignments='[]' where camp_id=c; raise exception 'test-expected-error';
 exception when others then perform pg_temp.a3_check(sqlerrm='room-plan-history-immutable','snapshot update forbidden'); end;
 begin delete from public.camp_room_assignments where camp_id=c; raise exception 'test-expected-error';
 exception when others then perform pg_temp.a3_check(sqlerrm='room-assignment-delete-forbidden','physical allocation deletion forbidden'); end;
 begin update public.camps set end_date=end_date+1 where id=c; raise exception 'test-expected-error';
 exception when others then perform pg_temp.a3_check(sqlerrm='roster-lifecycle-required','period change cannot rewrite history'); end;
 -- A submitted applicant must not have their room changed without A10 review.
 update public.camp_eligible_users set linked_user_id=viewer,linked_at=clock_timestamp(),linked_email_normalized='a3-viewer@example.invalid' where id=e1;
 insert into public.applications(id,usage_type,camp_id,camp_eligible_user_id,user_id,start_date,end_date,status)
 values(app,'camp',c,e1,viewer,current_date+100,current_date+102,'submitted');
 r:=pg_temp.a3_save(staff,c,jsonb_set(payload,'{0,room_id}',to_jsonb(room1)));
 perform pg_temp.a3_check(r->>'message'='room-change-review-required','submitted room change requires A10');
 r:=pg_temp.a3_call(staff,format('select * from public.assign_camp_application_room(%L,%L,%L)',app,room1,(select updated_at from public.applications where id=app)));
 perform pg_temp.a3_check(r->>'message'='eligible-roster-required','legacy assignment RPC cannot bypass plan');
 r:=pg_temp.a3_call(staff,format('select * from public.review_camp_application(%L,%L,%L)',app,'start_review',(select updated_at from public.applications where id=app)));
 perform pg_temp.a3_check(r->>'message'='eligible-roster-required','legacy review RPC cannot bypass plan');
end $$;
-- Capacity includes retained released rows until released_from, even after roster exclusion.
do $$
declare staff uuid:=pg_temp.a3_user('a3-extra-staff@example.invalid',true); c uuid:=gen_random_uuid();
 e1 uuid:=gen_random_uuid(); e2 uuid:=gen_random_uuid(); room uuid; payload jsonb; r jsonb; snap jsonb; base_date date:=current_date+200;
begin
 select id into room from public.rooms where name='梅';
 insert into public.camps(id,name,start_date,end_date,application_deadline,created_by,room_assignment_mode)
 values(c,'A3 retained capacity',base_date,base_date+1,clock_timestamp()+interval '190 days',staff,'eligible_roster');
 insert into public.camp_eligible_users(id,camp_id,management_name,email_normalized)
 values(e1,c,'架空一','a3-extra-one@example.invalid'),(e2,c,'架空二','a3-extra-two@example.invalid');
 payload:=jsonb_build_array(jsonb_build_object('eligible_user_id',e1,'room_id',room),jsonb_build_object('eligible_user_id',e2,'room_id',room));
 r:=pg_temp.a3_call(staff,format('select public.save_camp_room_plan(%L,null,0,%L::jsonb)',c,payload));
 perform pg_temp.a3_check(r->>'message'='invalid-version','NULL version rejected');
 r:=pg_temp.a3_call(staff,format('select public.save_camp_room_plan(%L,2,-1,%L::jsonb)',c,payload));
 perform pg_temp.a3_check(r->>'message'='invalid-version','negative version rejected');
 r:=pg_temp.a3_save(staff,c,payload); perform pg_temp.a3_check(r->>'ok'='true','capacity fixture saved');
 update public.camp_eligible_users set disabled_at=clock_timestamp() where id=e2;
 payload:=jsonb_build_array(payload->0);
 r:=pg_temp.a3_save(staff,c,payload);
 perform pg_temp.a3_check(r->>'message'='roster-lifecycle-required','qualification change alone cannot erase existing occupancy');
 -- Owner creates the exact release history that a later A4 RPC will atomically produce.
 select jsonb_agg(jsonb_build_object('eligible_user_id',eligible_user_id,'room_id',room_id,
   'assignment_version',assignment_version+case when eligible_user_id=e2 then 1 else 0 end,
   'released_from',case when eligible_user_id=e2 then base_date+1 end)) into snap from public.camp_room_assignments where camp_id=c;
 insert into public.camp_room_plan_versions(camp_id,version,roster_version,start_date,end_date,assignments,actor_user_id)
 values(c,2,3,base_date,base_date+1,snap,staff);
 update public.camp_room_assignments set assignment_version=2,room_plan_version=2,released_from=base_date+1,release_reason='架空解放' where eligible_user_id=e2;
 update public.camps set room_plan_version=2 where id=c;
 update public.rooms set capacity=1 where id=room;
 r:=pg_temp.a3_save(staff,c,payload);
 perform pg_temp.a3_check(r->>'message'='room-capacity-full','released person still occupies day before release');
 snap:=jsonb_build_array(jsonb_build_object('eligible_user_id',e2,'room_id',room,'assignment_version',3,'released_from',base_date));
 insert into public.camp_room_plan_versions(camp_id,version,roster_version,start_date,end_date,assignments,actor_user_id)
 values(c,3,3,base_date,base_date+1,snap,staff);
 update public.camp_room_assignments set assignment_version=3,room_plan_version=3,released_from=base_date where eligible_user_id=e2;
 update public.camps set room_plan_version=3 where id=c;
 r:=pg_temp.a3_save(staff,c,payload);
 perform pg_temp.a3_check(r->>'ok'='true','release date is excluded from occupancy');
 perform pg_temp.a3_check((select count(*)=2 from public.camp_room_assignments where camp_id=c),'released allocation remains as history');
 update public.rooms set capacity=2 where id=room;
 update public.camp_eligible_users set disabled_at=null where id=e2;
 r:=pg_temp.a3_save(staff,c,payload||jsonb_build_array(jsonb_build_object('eligible_user_id',e2,'room_id',room)));
 perform pg_temp.a3_check(r->>'message'='roster-lifecycle-required','ordinary save cannot revive released allocation');
 -- A sixteen-person roster cannot be saved by omitting its sixteenth member.
 insert into public.camp_eligible_users(camp_id,management_name,email_normalized)
 select c,'架空追加','a3-capacity-'||n||'@example.invalid' from generate_series(1,14) n;
 select jsonb_agg(jsonb_build_object('eligible_user_id',id,'room_id',room)) into payload
 from (select id from public.camp_eligible_users where camp_id=c order by id limit 15) x;
 r:=pg_temp.a3_save(staff,c,payload);
 perform pg_temp.a3_check(r->>'message'='facility-capacity-full','sixteen-person roster refused at facility limit');
end $$;

select count(*)::integer passed_checks,bool_and(passed) all_passed from pg_temp.a3_results;
rollback;
