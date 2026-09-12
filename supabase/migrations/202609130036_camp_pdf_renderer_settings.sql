-- A8 versioned renderer settings (SQL 036). No container deployment or activation here.
begin;
select private.lock_calendar_facility();

create table private.camp_pdf_render_setting_versions (
  settings_version bigint primary key check (settings_version > 0),
  template_hash text not null check (template_hash ~ '^[0-9a-f]{64}$'),
  font_version text not null check (font_version ~ '^NotoSerifJP-[0-9.]+\+sha256:[0-9a-f]{64}$'),
  converter_image text not null check (converter_image ~ '^ghcr\.io/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$'),
  mayor_name text not null check (char_length(btrim(mayor_name)) between 1 and 40),
  user_name_limit integer not null check (user_name_limit between 1 and 40),
  user_address_limit integer not null check (user_address_limit between 1 and 80),
  emergency_name_limit integer not null check (emergency_name_limit between 1 and 40),
  emergency_address_limit integer not null check (emergency_address_limit between 1 and 80),
  purpose_limit integer not null check (purpose_limit between 1 and 120),
  special_notes_limit integer not null check (special_notes_limit between 1 and 180),
  room_name_limit integer not null check (room_name_limit between 1 and 40),
  verified_at timestamptz not null,
  created_at timestamptz not null default clock_timestamp()
);

create table private.camp_pdf_active_render_setting (
  singleton boolean primary key default true check (singleton),
  settings_version bigint not null references private.camp_pdf_render_setting_versions(settings_version) on delete restrict,
  activated_at timestamptz not null default clock_timestamp()
);

revoke all on private.camp_pdf_render_setting_versions, private.camp_pdf_active_render_setting
  from public, anon, authenticated, service_role;

create function private.guard_camp_pdf_render_setting_version()
returns trigger language plpgsql set search_path='' as $$
begin
  raise exception 'pdf-render-settings-immutable';
end $$;
create trigger camp_pdf_render_setting_versions_immutable
before update or delete on private.camp_pdf_render_setting_versions
for each row execute function private.guard_camp_pdf_render_setting_version();

-- The active pointer is intentionally empty after migration. Only the
-- deployment transaction may insert an immutable, verified OCI digest and
-- point this singleton at it. Until then all generation remains denied.
create or replace function private.camp_pdf_render_settings(target_application_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.applications%rowtype;
  s private.camp_pdf_render_setting_versions%rowtype;
  room_name_value text;
begin
  select v.* into s
  from private.camp_pdf_active_render_setting active
  join private.camp_pdf_render_setting_versions v on v.settings_version=active.settings_version
  where active.singleton;
  if not found then raise exception 'pdf-prerequisites-unavailable'; end if;

  select * into a from public.applications where id=target_application_id and usage_type='camp';
  if not found or a.user_name is null or a.user_address is null or a.user_phone is null
    or a.emergency_name is null or a.emergency_address is null or a.emergency_phone is null
    or a.purpose is null or a.usage_place is distinct from 'common_and_second_floor'
    or char_length(btrim(a.user_name)) not between 1 and s.user_name_limit
    or char_length(btrim(a.user_address)) not between 1 and s.user_address_limit
    or char_length(btrim(a.user_phone)) not between 1 and 20
    or char_length(btrim(a.emergency_name)) not between 1 and s.emergency_name_limit
    or char_length(btrim(a.emergency_address)) not between 1 and s.emergency_address_limit
    or char_length(btrim(a.emergency_phone)) not between 1 and 20
    or char_length(btrim(a.purpose)) not between 1 and s.purpose_limit
    or char_length(coalesce(btrim(a.special_notes),'')) > s.special_notes_limit then
    raise exception 'pdf-content-too-long';
  end if;

  select m.print_name into room_name_value
  from public.camp_room_assignments assignment
  join public.camp_room_mapping m on m.room_id=assignment.room_id
  where assignment.camp_id=a.camp_id and assignment.eligible_user_id=a.camp_eligible_user_id
    and assignment.released_from is null;
  if room_name_value is null or char_length(btrim(room_name_value)) not between 1 and s.room_name_limit then
    raise exception 'pdf-content-too-long';
  end if;

  return jsonb_build_object(
    'template_hash',s.template_hash,
    'settings_version',s.settings_version,
    'font_version',s.font_version,
    'converter_image',s.converter_image,
    'mayor_name',s.mayor_name
  );
end $$;

revoke all on function private.guard_camp_pdf_render_setting_version(),
  private.camp_pdf_render_settings(uuid) from public,anon,authenticated,service_role;
commit;
