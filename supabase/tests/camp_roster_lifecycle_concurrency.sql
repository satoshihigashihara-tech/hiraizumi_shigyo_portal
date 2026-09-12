-- Shared fixture loaded by the runner before this file.
create table a4_lifecycle_test.results(case_name text primary key,passed boolean,waited boolean);
create function a4_lifecycle_test.race_command(kind text) returns text language plpgsql as $$
declare x a4_lifecycle_test.context%rowtype;
begin
 select * into x from a4_lifecycle_test.context;
 case kind
 when 'withdraw' then return a4_lifecycle_test.command('withdraw',true);
 when 'reject' then return a4_lifecycle_test.command('reject',false);
 when 'save' then return format('select public.save_camp_room_plan(%L,%L,%L,%L::jsonb)',x.camp,x.roster,x.plan,
   jsonb_build_array(jsonb_build_object('eligible_user_id',x.eligible,'room_id',x.room),jsonb_build_object('eligible_user_id',x.other_eligible,'room_id',x.room)));
 when 'edit' then return format('select * from public.update_camp_roster_eligible_user(%L,%L,%L,%L,%L)',x.camp,x.eligible,'架空変更','a4-owner@example.invalid',x.eligible_version);
 when 'add' then return format('select * from public.create_camp_roster_eligible_user(%L,%L,%L)',x.camp,'架空追加','a4-add@example.invalid');
 when 'check_in' then return format('select * from public.update_application_stay(%L,%L,%L)',x.app,x.app_version,'check_in');
 when 'check_out' then return format('select * from public.update_application_stay(%L,%L,%L)',x.app,x.app_version,'check_out');
 when 'create' then return format('select public.create_camp_application_draft(%L)',x.camp);
 when 'draft' then return format('select public.save_camp_application_draft(%L,%L,%L,%L,%L,%L,%L,%L,null,false,%L)',
   x.app,'架空本人','架空住所','0000000000','架空連絡先','架空住所','0000000000','架空目的','shared_ok');
 when 'camp' then return format('select public.create_staff_camp(%L,%L,%L,%L)','架空競合',
   (select start_date from public.camps where id=x.camp),(select end_date from public.camps where id=x.camp),clock_timestamp()+interval '1 day');
 when 'blocked' then return format('select * from public.save_staff_blocked_period(null,%L,%L,%L)',
   (select start_date from public.camps where id=x.camp),(select end_date from public.camps where id=x.camp),'架空競合');
 else raise exception 'unknown-race-command';
 end case;
end $$;
