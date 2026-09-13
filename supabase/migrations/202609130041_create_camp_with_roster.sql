-- Create a roster-mode camp and its initial eligible roster atomically.
begin;

create function public.create_staff_camp_with_roster(
  camp_name text,
  camp_start_date date,
  camp_end_date date,
  camp_application_deadline timestamptz,
  eligible_users jsonb
)
returns uuid language plpgsql security definer set search_path='' as $$
declare
  new_id uuid;
  eligible_user jsonb;
  normalized_name text;
  normalized_email text;
begin
  perform private.lock_calendar_for_staff();
  perform private.check_camp_calendar_input(camp_name,camp_start_date,camp_end_date,camp_application_deadline);
  perform private.assert_calendar_available(camp_start_date,camp_end_date);

  if eligible_users is null or jsonb_typeof(eligible_users)<>'array' or jsonb_array_length(eligible_users)<1 then
    raise exception 'eligible-users-required';
  end if;
  if jsonb_array_length(eligible_users)>15 then raise exception 'too-many-eligible-users'; end if;
  if exists(
    select 1 from jsonb_array_elements(eligible_users) item
    where jsonb_typeof(item)<>'object'
      or nullif(btrim(item->>'management_name'),'') is null
      or char_length(btrim(item->>'management_name'))>200
  ) then raise exception 'invalid-management-name'; end if;
  if exists(
    select 1 from jsonb_array_elements(eligible_users) item
    where nullif(btrim(item->>'email'),'') is null
      or lower(btrim(item->>'email')) !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  ) then raise exception 'invalid-email'; end if;
  if exists(
    select 1 from (
      select lower(btrim(item->>'email')) email from jsonb_array_elements(eligible_users) item
      group by lower(btrim(item->>'email')) having count(*)>1
    ) duplicates
  ) then raise exception 'duplicate-eligible-email'; end if;

  insert into public.camps(name,start_date,end_date,application_deadline,created_by,room_assignment_mode)
  values(btrim(camp_name),camp_start_date,camp_end_date,camp_application_deadline,auth.uid(),'eligible_roster')
  returning id into new_id;

  for eligible_user in select value from jsonb_array_elements(eligible_users) loop
    normalized_name:=btrim(eligible_user->>'management_name');
    normalized_email:=lower(btrim(eligible_user->>'email'));
    insert into public.camp_eligible_users(camp_id,management_name,email_normalized)
    values(new_id,normalized_name,normalized_email);
  end loop;

  perform private.record_calendar_audit('camp',new_id,'create_camp_with_roster','{}'::jsonb,null);
  return new_id;
end;
$$;

revoke all on function public.create_staff_camp_with_roster(text,date,date,timestamptz,jsonb)
  from public,anon,authenticated,service_role;
grant execute on function public.create_staff_camp_with_roster(text,date,date,timestamptz,jsonb)
  to authenticated;

commit;
