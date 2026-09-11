-- Fictional T21 verification; ROLLBACK means this must not be saved in SQL Editor.
begin;
create temporary table t21_results(label text,passed boolean) on commit drop;
create function pg_temp.t21(ok boolean,label text) returns void language plpgsql as $$ begin
 if ok is distinct from true then raise exception 'FAIL: %',label; end if; insert into pg_temp.t21_results values(label,true); end $$;
do $$ declare moment timestamptz:='2030-01-10 00:00+09'; g1 uuid:=gen_random_uuid(); g2 uuid:=gen_random_uuid();
 g3 uuid:=gen_random_uuid(); g4 uuid:=gen_random_uuid(); a1 uuid:=gen_random_uuid(); a2 uuid:=gen_random_uuid(); a3 uuid:=gen_random_uuid();
 a4 uuid:=gen_random_uuid(); room_value uuid; first_events integer; processed integer;
begin
 insert into public.group_applications(id,group_name,start_date,end_date,usage_place,purpose,local_activity,planned_participants,status,submitted_at,participant_due_at,revision_due_at,status_before_cancellation)
 values(g1,'架空期限切れ',date '2030-02-01',date '2030-02-02','common_and_second_floor','架空','架空',2,'collecting',moment-interval '8 days',moment,null,null),
 (g2,'架空提出完了',date '2030-02-03',date '2030-02-04','common_and_second_floor','架空','架空',2,'collecting',moment-interval '8 days',moment,null,null),
 (g3,'架空修正期限',date '2030-02-05',date '2030-02-06','common_and_second_floor','架空','架空',2,'cancellation_requested',moment-interval '8 days',moment-interval '4 days',moment,'revision_requested'),
 (g4,'架空期限前',date '2030-02-07',date '2030-02-08','common_and_second_floor','架空','架空',2,'collecting',moment-interval '1 day',moment+interval '1 minute',null,null);
 insert into public.applications(id,usage_type,group_id,status,start_date,end_date,user_name,requires_guardian_consent,submitted_at,last_submitted_at)
 values(a1,'community_group',g1,'draft',date '2030-02-01',date '2030-02-02','架空一郎',false,null,null),
 (a2,'community_group',g2,'submitted',date '2030-02-03',date '2030-02-04','架空二郎',false,moment,moment),
 (a3,'community_group',g2,'approved',date '2030-02-03',date '2030-02-04','架空三郎',false,moment,moment),
 (a4,'community_group',g3,'revision_requested',date '2030-02-05',date '2030-02-06','架空四郎',false,moment,moment);
 insert into public.group_members(group_id,application_id) values(g1,a1),(g2,a2),(g2,a3),(g3,a4);
 insert into public.group_invites(group_id,token_hash,code_hash) values(g1,repeat('a',64),repeat('b',64));
 select id into room_value from public.rooms order by id limit 1;
 insert into public.room_allocations(group_id,room_id,people_count,start_date,end_date) values(g1,room_value,1,date '2030-02-01',date '2030-02-02');
 select count(*) into processed from private.expire_due_community_groups(500,moment);
 perform pg_temp.t21(processed=3,'due groups processed');
 perform pg_temp.t21((select status='cancelled' from public.group_applications where id=g1) and (select status='cancelled' from public.applications where id=a1),'initial expiry');
 perform pg_temp.t21((select released_from=start_date from public.calendar_claims where group_id=g1)
   and (select exists(select 1 from public.group_invites i join public.group_applications g on g.id=i.group_id where i.group_id=g1 and g.status='cancelled')),'claim release and invite invalidation');
 perform pg_temp.t21((select released_from=start_date from public.room_allocations where group_id=g1),'room release');
 perform pg_temp.t21((select status='under_review' from public.group_applications where id=g2),'ready group review');
 perform pg_temp.t21((select status='cancelled' and cancel_reason='修正期限切れ' from public.group_applications where id=g3) and (select status='cancelled' from public.applications where id=a4),'revision expiry during cancellation request');
 perform pg_temp.t21((select status='collecting' from public.group_applications where id=g4),'future untouched');
 perform pg_temp.t21(private.community_group_deadline_expired(g4,moment+interval '1 minute'),'deadline predicate uses exclusive boundary');
 perform pg_temp.t21((select bool_and(actor_kind='system' and actor_user_id is null) from public.audit_logs where entity_id in(g1,g2,g3,a1,a4)),'system audit');
 select count(*) into first_events from public.group_status_events where group_id in(g1,g2,g3);
 perform private.expire_due_community_groups(500,moment+interval '1 second');
 perform pg_temp.t21((select count(*) from public.group_status_events where group_id in(g1,g2,g3))=first_events,'idempotent');
end $$;
select count(*)::integer passed_checks,bool_and(passed) all_passed from pg_temp.t21_results;
rollback;
