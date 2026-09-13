-- Enable the eight rooms already defined by the approved project requirements
-- for staff camp room assignment and document output.
begin;
select private.lock_calendar_facility();

do $$
begin
  if (select count(*) from public.rooms
      where (name, capacity) in (
        ('桐', 1), ('藤', 1), ('梅', 2), ('竹', 2),
        ('松', 2), ('あやめ', 2), ('もみぢ', 2), ('さくら', 3)
      )) <> 8
    or (select count(*) from public.rooms) <> 8
    or (select sum(capacity) from public.rooms) <> 15 then
    raise exception 'room-master-mismatch';
  end if;
end $$;

insert into public.camp_room_mapping (
  room_id,
  source_name,
  floor,
  display_name,
  print_name,
  assignment_enabled,
  printing_enabled,
  confirmed_at,
  confirmation_evidence
)
select
  room.id,
  room.name,
  2,
  room.name,
  room.name,
  true,
  true,
  clock_timestamp(),
  'docs/requirements.md 111-120, 216-217 (confirmed 2026-09-13)'
from public.rooms as room
where room.name in ('桐', '藤', '梅', '竹', '松', 'あやめ', 'もみぢ', 'さくら')
on conflict (room_id) do update
set source_name = excluded.source_name,
    floor = excluded.floor,
    display_name = excluded.display_name,
    print_name = excluded.print_name,
    assignment_enabled = true,
    printing_enabled = true,
    confirmed_at = excluded.confirmed_at,
    confirmation_evidence = excluded.confirmation_evidence;

do $$
begin
  if (select count(*) from public.camp_room_mapping
      where assignment_enabled and printing_enabled and floor = 2) <> 8 then
    raise exception 'room-mapping-activation-failed';
  end if;
end $$;

commit;
