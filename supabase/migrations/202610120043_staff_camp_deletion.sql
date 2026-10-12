-- Delete through the staff RPC without disabling lifecycle guards or erasing history.
begin;
select private.lock_calendar_facility();

create or replace function private.guard_roster_camp_period()
returns trigger language plpgsql set search_path='' as $$
begin
  if old.room_assignment_mode='eligible_roster' and
    (new.start_date,new.end_date,new.deleted_at) is distinct from (old.start_date,old.end_date,old.deleted_at) then
    if old.deleted_at is null and new.deleted_at is not null
      and (new.start_date,new.end_date) is not distinct from (old.start_date,old.end_date)
      and private.is_staff()
      and not exists(select 1 from public.applications where camp_id=old.id and status not in ('cancelled','rejected'))
      and not exists(select 1 from public.camp_eligible_users where camp_id=old.id and disabled_at is null and participation_status='participating')
      and not exists(select 1 from public.camp_room_assignments where camp_id=old.id and released_from is null) then
      return new;
    end if;
    raise exception 'roster-lifecycle-required';
  end if;
  return new;
end $$;

create or replace function public.delete_staff_camp(target_camp_id uuid, expected_updated_at timestamptz, change_reason text)
returns table(result_id uuid,result_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare c public.camps%rowtype; e public.camp_eligible_users%rowtype;
  a public.applications%rowtype; before_value jsonb; moment timestamptz;
begin
  perform private.lock_calendar_for_staff();
  -- Same profile-before-camp lock order as participation and cleanup operations.
  perform p.id from public.profiles p where p.id in (
    select user_id from public.applications where camp_id=target_camp_id
    union select linked_user_id from public.camp_eligible_users where camp_id=target_camp_id
  ) or exists(select 1 from public.camp_eligible_users member where member.camp_id=target_camp_id
    and member.linked_user_id is null and member.email_normalized=private.current_verified_email(p.id))
    order by p.id for update;
  select * into c from public.camps where id=target_camp_id for update;
  if not found then raise exception 'not-found'; end if;
  perform private.check_calendar_version(c.updated_at,expected_updated_at);
  if c.deleted_at is not null then raise exception 'invalid-status'; end if;
  perform private.check_calendar_reason(change_reason);
  perform private.assert_camp_editable(c.id);
  before_value:=private.calendar_snapshot('camp',c.id);
  if c.room_assignment_mode='eligible_roster' then
    for e in select * from public.camp_eligible_users where camp_id=c.id
      and disabled_at is null and participation_status='participating' order by id for update loop
      select * into c from public.camps where id=target_camp_id;
      select * into a from public.applications where camp_id=c.id and camp_eligible_user_id=e.id
        order by (status not in ('rejected','cancelled')) desc,created_at desc,id limit 1 for update;
      perform private.end_camp_roster_participation(c.id,e.id,e.updated_at,c.roster_version,c.room_plan_version,
        a.id,a.updated_at,'withdraw',change_reason,false);
    end loop;
  end if;
  moment:=clock_timestamp();
  for a in select * from public.applications where camp_id=target_camp_id and status='draft' order by id for update loop
    update public.applications set status='cancelled',cancel_reason=btrim(change_reason) where id=a.id;
    insert into public.application_status_events(application_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
      values(a.id,'draft','cancelled','キャンプの削除',auth.uid(),moment);
  end loop;
  update public.camps set deleted_at=moment where id=target_camp_id returning * into c;
  -- Keep elapsed occupancy; release only the remaining dates after today.
  update public.calendar_claims set released_from=greatest(c.start_date,
    least((moment at time zone 'Asia/Tokyo')::date+1,c.end_date+1)) where camp_id=c.id;
  perform private.record_calendar_audit('camp',c.id,'delete_camp',before_value,change_reason);
  return query select c.id,c.updated_at;
end $$;
commit;
