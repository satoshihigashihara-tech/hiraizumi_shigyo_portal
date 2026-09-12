-- A8 catalog and activation boundary. All fictional changes roll back.
begin;
create temporary table a8_results(name text,passed boolean) on commit drop;
create function pg_temp.a8_check(ok boolean,label text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  insert into pg_temp.a8_results values(label,true);
end $$;

do $$ declare message_value text; begin
  perform pg_temp.a8_check((select count(*)=0 from private.camp_pdf_render_setting_versions),'migration activates no unbuilt image');
  begin perform private.camp_pdf_render_settings(gen_random_uuid());
  exception when others then get stacked diagnostics message_value=message_text; end;
  perform pg_temp.a8_check(message_value='pdf-prerequisites-unavailable','empty active pointer fails closed');

  foreach message_value in array array['anon','authenticated','service_role'] loop
    perform pg_temp.a8_check(not has_table_privilege(message_value,'private.camp_pdf_render_setting_versions','select'),message_value||' cannot read settings');
    perform pg_temp.a8_check(not has_table_privilege(message_value,'private.camp_pdf_active_render_setting','insert'),message_value||' cannot activate settings');
  end loop;

  begin
    insert into private.camp_pdf_render_setting_versions(settings_version,template_hash,font_version,converter_image,mayor_name,
      user_name_limit,user_address_limit,emergency_name_limit,emergency_address_limit,purpose_limit,special_notes_limit,room_name_limit,verified_at)
    values(1,repeat('a',64),'NotoSerifJP-2.003+sha256:'||repeat('b',64),'mutable-tag:latest','架空町長',40,80,40,80,120,180,40,clock_timestamp());
  exception when check_violation then message_value='rejected'; end;
  perform pg_temp.a8_check(message_value='rejected','mutable image tag rejected');

  insert into private.camp_pdf_render_setting_versions(settings_version,template_hash,font_version,converter_image,mayor_name,
    user_name_limit,user_address_limit,emergency_name_limit,emergency_address_limit,purpose_limit,special_notes_limit,room_name_limit,verified_at)
  values(1,repeat('a',64),'NotoSerifJP-2.003+sha256:'||repeat('b',64),
    'ghcr.io/example.invalid/camp-pdf-renderer@sha256:'||repeat('c',64),'架空町長',40,80,40,80,120,180,40,clock_timestamp());
  insert into private.camp_pdf_active_render_setting(settings_version) values(1);
  message_value=null;
  begin update private.camp_pdf_render_setting_versions set mayor_name='改変' where settings_version=1;
  exception when others then get stacked diagnostics message_value=message_text; end;
  perform pg_temp.a8_check(message_value='pdf-render-settings-immutable','settings version is immutable');
end $$;

select count(*)::integer as passed_checks,bool_and(passed) as all_passed from pg_temp.a8_results;
rollback;
