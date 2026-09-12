-- A12: close the gap between cleanup job claim and the later Auth API DELETE.
-- No data changes, mode switches, render activation or new client privileges.
begin;
select private.lock_calendar_facility();

create function private.guard_camp_participant_auth_delete()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  -- Registration/edit/end RPCs take this same lock. The real UPDATE rejects
  -- stale REPEATABLE READ snapshots before a cascading Auth deletion can occur.
  perform private.lock_calendar_facility();
  if exists (
    select 1 from public.camp_eligible_users e
    join public.camps c on c.id=e.camp_id
    where c.room_assignment_mode='eligible_roster' and c.deleted_at is null
      and e.disabled_at is null and e.participation_status='participating'
      and (e.linked_user_id=old.id or (e.linked_user_id is null
        and old.email_confirmed_at is not null and e.email_normalized=lower(btrim(old.email))))
  ) then
    raise exception 'camp-participation-open';
  end if;
  return old;
end; $$;

revoke all on function private.guard_camp_participant_auth_delete() from public,anon,authenticated,service_role;
create trigger camp_participant_auth_delete_guard before delete on auth.users
for each row execute function private.guard_camp_participant_auth_delete();
commit;
