-- Actual connections are orchestrated in scripts/test-community-applications-db.mjs.
-- Operations here use production RPCs with only fictional data.
create function a10_review_test.race_command(kind text) returns text language plpgsql as $$
declare x a10_review_test.context%rowtype; a public.applications%rowtype; c public.camps%rowtype; e public.camp_eligible_users%rowtype;
begin
 select * into x from a10_review_test.context;
 select * into c from public.camps where id=x.camp;
 select * into a from public.applications where id=x.app[6];
 select * into e from public.camp_eligible_users where id=x.eligible[6];
 case kind
 when 'submit' then return format('select * from public.submit_camp_application_with_pdf(%L,%L,%s,%L,true)',
   x.app[5],(select id from public.camp_application_versions where application_id=x.app[5] order by version_no desc limit 1),
   (select input_version from public.applications where id=x.app[5]),gen_random_uuid());
 when 'save' then return format('select public.save_camp_room_plan(%L,%s,%s,%L)',c.id,c.roster_version,c.room_plan_version,
   (select jsonb_agg(jsonb_build_object('eligible_user_id',r.eligible_user_id,'room_id',r.room_id)) from public.camp_room_assignments r where r.camp_id=c.id and r.released_from is null));
 when 'change' then return a10_review_test.change_command();
 when 'start-review' then return a10_review_test.review_command(x.app[3],'start_review');
 when 'approve' then return a10_review_test.review_command(x.app[4],'approve');
 when 'reject' then return format('select public.end_camp_roster_participation(%L,%L,%L,%s,%s,%L,%L,%L,%L,true,false)',
   c.id,e.id,e.updated_at,c.roster_version,c.room_plan_version,a.id,a.updated_at,'reject','架空不許可');
 when 'withdraw' then return format('select public.end_camp_roster_participation(%L,%L,%L,%s,%s,%L,%L,%L,%L,true,false)',
   c.id,e.id,e.updated_at,c.roster_version,c.room_plan_version,a.id,a.updated_at,'withdraw','架空終了');
 when 'payment' then return format('select public.update_application_payment(%L,%L,%L,null,null)',a.id,a.updated_at,'paid');
 when 'check-in' then return format('select public.update_application_stay(%L,%L,%L)',a.id,a.updated_at,'check_in');
 when 'draft' then
   select * into a from public.applications where id=x.app[5];
   return format('select public.save_camp_roster_application_draft(%L,%s,%L,%L,%L,%L,%L,%L,%L,null,false)',
     a.id,a.input_version,'架空更新氏名','架空住所','090-0000-0000','架空連絡先','架空住所','090-0000-0000','架空目的');
 when 'plan-pdf' then return format('select public.begin_staff_camp_room_plan_pdf(%L,%s,%s,%s,%L)',c.id,c.roster_version,c.roster_label_version,c.room_plan_version,gen_random_uuid());
 else raise exception 'unknown race %',kind;
 end case;
end $$;
