-- A6: expose only the signed-in participant's camp room assignment.
begin;

create function public.get_my_camp_room_assignments()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  result jsonb;
begin
  if actor is null or not private.has_active_profile() then
    raise exception using errcode = '42501', message = 'user-required';
  end if;

  with owned_roster_camps as (
    select
      c.id as camp_id,
      c.name as camp_name,
      c.start_date,
      c.end_date,
      c.room_assignment_mode,
      a.id as application_id,
      case
        when e.disabled_at is not null or e.participation_status <> 'participating' then 'ended'
        else 'participating'
      end as participation_state,
      case
        when e.disabled_at is not null or e.participation_status <> 'participating'
          or assignment.released_from is not null then 'ended'
        when assignment.id is null then 'unassigned'
        else 'assigned'
      end as placement_state,
      case
        when e.disabled_at is null and e.participation_status = 'participating'
          and assignment.released_from is null then mapping.display_name
      end as room_name,
      case
        when e.disabled_at is null and e.participation_status = 'participating'
          and assignment.released_from is null then mapping.floor
      end as floor,
      case
        when e.disabled_at is null and e.participation_status = 'participating'
          and assignment.released_from is null then assignment.start_date
      end as assignment_start_date,
      case
        when e.disabled_at is null and e.participation_status = 'participating'
          and assignment.released_from is null then assignment.end_date
      end as assignment_end_date
    from public.camp_eligible_users e
    join public.camps c on c.id = e.camp_id
      and c.room_assignment_mode = 'eligible_roster'
    left join lateral (
      select owned.id
      from public.applications owned
      where owned.camp_id = e.camp_id
        and owned.camp_eligible_user_id = e.id
        and owned.user_id = actor
        and owned.usage_type = 'camp'
      order by owned.created_at desc, owned.id desc
      limit 1
    ) a on true
    left join public.camp_room_assignments assignment
      on assignment.camp_id = e.camp_id and assignment.eligible_user_id = e.id
    left join public.camp_room_mapping mapping
      on mapping.room_id = assignment.room_id
      and mapping.assignment_enabled
      and mapping.confirmed_at is not null
      and nullif(btrim(mapping.confirmation_evidence), '') is not null
    where e.linked_user_id = actor
      and c.deleted_at is null
      and (a.id is null or exists (
        select 1 from public.applications verified
        where verified.id = a.id
          and verified.user_id = actor
          and verified.camp_id = e.camp_id
          and verified.camp_eligible_user_id = e.id
      ))
  ), owned_legacy_camps as (
    select distinct on (c.id)
      c.id as camp_id,
      c.name as camp_name,
      c.start_date,
      c.end_date,
      c.room_assignment_mode,
      a.id as application_id,
      'legacy'::text as participation_state,
      'legacy'::text as placement_state,
      null::text as room_name,
      null::integer as floor,
      null::date as assignment_start_date,
      null::date as assignment_end_date
    from public.applications a
    join public.camps c on c.id = a.camp_id
      and c.room_assignment_mode = 'legacy_application'
    where a.user_id = actor
      and a.usage_type = 'camp'
      and c.deleted_at is null
    order by c.id, a.created_at desc, a.id desc
  ), owned as (
    select * from owned_roster_camps
    union all
    select * from owned_legacy_camps
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'camp_id', camp_id,
    'camp_name', camp_name,
    'start_date', start_date,
    'end_date', end_date,
    'room_assignment_mode', room_assignment_mode,
    'application_id', application_id,
    'participation_state', participation_state,
    'placement_state', placement_state,
    'room_name', room_name,
    'floor', floor,
    'assignment_start_date', assignment_start_date,
    'assignment_end_date', assignment_end_date
  ) order by start_date desc, camp_id), '[]'::jsonb)
  into result
  from owned;

  return result;
end;
$$;

revoke all on function public.get_my_camp_room_assignments()
from public, anon, authenticated, service_role;
grant execute on function public.get_my_camp_room_assignments() to authenticated;

commit;
