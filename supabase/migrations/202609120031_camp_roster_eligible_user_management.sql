-- A2: staff-managed, single-entry eligible roster records.
-- This migration deliberately separates eligible_roster from the legacy email flow.
begin;

-- A2 uses camp_eligible_users.updated_at as an optimistic-lock version. The
-- original trigger used transaction-stable now(), which can reuse a value for
-- two edits in one transaction; use the existing monotonic microsecond clock.
drop trigger camp_eligible_users_set_updated_at on public.camp_eligible_users;
create trigger camp_eligible_users_set_updated_at before update on public.camp_eligible_users
for each row execute function private.set_application_updated_at();

create function public.create_camp_roster_eligible_user(
  target_camp_id uuid,
  management_name_value text,
  email_value text
)
returns table (result_id uuid, result_management_name text, result_email text, result_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare c public.camps%rowtype; eligible public.camp_eligible_users%rowtype;
  normalized_email text:=lower(btrim(email_value)); normalized_name text:=btrim(management_name_value);
begin
  -- Lock order: facility/staff, camp, then its eligible rows.
  perform private.lock_calendar_for_staff();
  select * into c from public.camps where id=target_camp_id and deleted_at is null for update;
  if not found then raise exception 'not-found'; end if;
  if c.room_assignment_mode<>'eligible_roster' then raise exception 'eligible-roster-required'; end if;
  if normalized_name is null or char_length(normalized_name) not between 1 and 200 then raise exception 'invalid-management-name'; end if;
  if normalized_email='' or normalized_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'invalid-email';
  end if;
  if exists(select 1 from public.camp_eligible_users e
    where e.camp_id=c.id and e.email_normalized=normalized_email) then
    -- Do not disclose whether the existing row is disabled, released, or linked.
    raise exception 'eligible-email-exists';
  end if;
  begin
    insert into public.camp_eligible_users(camp_id,management_name,email_normalized)
    values(c.id,normalized_name,normalized_email) returning * into eligible;
  exception when unique_violation then
    raise exception 'eligible-email-exists';
  end;
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id)
  values('camp_eligible_user',eligible.id,'create_camp_roster_eligible_user','{}',
    jsonb_build_object('management_name',eligible.management_name,'email',eligible.email_normalized,
      'participation_status',eligible.participation_status,'disabled_at',eligible.disabled_at),
    'staff',auth.uid());
  return query select eligible.id,eligible.management_name,eligible.email_normalized,eligible.updated_at;
end;
$$;

create function public.update_camp_roster_eligible_user(
  target_camp_id uuid,
  target_eligible_user_id uuid,
  new_management_name text,
  new_email text,
  expected_updated_at timestamptz,
  change_reason text default null
)
returns table (result_id uuid, result_management_name text, result_email text, result_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare c public.camps%rowtype; eligible public.camp_eligible_users%rowtype;
  normalized_name text:=btrim(new_management_name); normalized_email text:=lower(btrim(new_email));
  before_value jsonb; email_changed boolean;
begin
  -- Lock order: facility/staff, camp, then the stable eligible-user ID.
  perform private.lock_calendar_for_staff();
  select * into c from public.camps where id=target_camp_id and deleted_at is null for update;
  if not found then raise exception 'not-found'; end if;
  if c.room_assignment_mode<>'eligible_roster' then raise exception 'eligible-roster-required'; end if;
  select * into eligible from public.camp_eligible_users
    where id=target_eligible_user_id and camp_id=c.id for update;
  if not found then raise exception 'not-found'; end if;
  perform private.check_calendar_version(eligible.updated_at,expected_updated_at);
  if eligible.disabled_at is not null or eligible.participation_status<>'participating' then
    raise exception 'invalid-status';
  end if;
  if normalized_name is null or char_length(normalized_name) not between 1 and 200 then raise exception 'invalid-management-name'; end if;
  if normalized_email='' or normalized_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'invalid-email';
  end if;
  email_changed:=eligible.email_normalized is distinct from normalized_email;
  if email_changed and eligible.linked_user_id is not null then
    perform private.check_calendar_reason(change_reason);
  elsif change_reason is not null and char_length(btrim(change_reason))>2000 then
    raise exception 'reason-too-long';
  end if;
  if not email_changed and eligible.management_name=normalized_name then
    return query select eligible.id,eligible.management_name,eligible.email_normalized,eligible.updated_at;
    return;
  end if;
  if email_changed and exists(select 1 from public.camp_eligible_users e
    where e.camp_id=c.id and e.email_normalized=normalized_email and e.id<>eligible.id) then
    raise exception 'eligible-email-exists';
  end if;
  before_value:=jsonb_build_object('management_name',eligible.management_name,'email',eligible.email_normalized,
    'disabled_at',eligible.disabled_at,'participation_status',eligible.participation_status);
  begin
    update public.camp_eligible_users set management_name=normalized_name,email_normalized=normalized_email
      where id=eligible.id returning * into eligible;
  exception when unique_violation then
    raise exception 'eligible-email-exists';
  end;
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id,reason)
  values('camp_eligible_user',eligible.id,'update_camp_roster_eligible_user',before_value,
    jsonb_build_object('management_name',eligible.management_name,'email',eligible.email_normalized,
      'disabled_at',eligible.disabled_at,'participation_status',eligible.participation_status),
    'staff',auth.uid(),case when email_changed then btrim(change_reason) else null end);
  return query select eligible.id,eligible.management_name,eligible.email_normalized,eligible.updated_at;
end;
$$;

-- The legacy RPCs retain their existing behaviour, but may not mutate a new roster.
create or replace function public.add_camp_eligible_users(target_camp_id uuid,eligible_emails text[])
returns integer language plpgsql security definer set search_path='' as $$
declare registered_count integer; c public.camps%rowtype;
begin
  perform private.lock_calendar_for_staff();
  select * into c from public.camps where id=target_camp_id and deleted_at is null for update;
  if not found then raise exception '対象のキャンプが見つかりません。'; end if;
  if c.room_assignment_mode<>'legacy_application' then raise exception 'eligible-roster-required'; end if;
  if eligible_emails is null or cardinality(eligible_emails)=0 then raise exception '対象者のメールアドレスを入力してください。'; end if;
  if cardinality(eligible_emails)>1000 then raise exception '一度に登録できるメールアドレスは1000件までです。'; end if;
  if exists(select 1 from unnest(eligible_emails) as submitted(email) where submitted.email is null
    or submitted.email<>lower(btrim(submitted.email))
    or submitted.email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then
    raise exception '形式が正しくないメールアドレスがあります。';
  end if;
  with normalized_emails as (select distinct submitted.email from unnest(eligible_emails) as submitted(email))
  insert into public.camp_eligible_users(camp_id,email_normalized)
  select c.id,normalized.email from normalized_emails normalized
  on conflict(camp_id,email_normalized) do update set disabled_at=null,updated_at=now();
  get diagnostics registered_count=row_count;
  return registered_count;
end;
$$;

create or replace function public.update_camp_eligible_user(
  target_camp_id uuid,target_eligible_user_id uuid,new_email text,expected_updated_at timestamptz,change_reason text
)
returns table(result_id uuid,result_email text,result_updated_at timestamptz,result_disabled_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare c public.camps%rowtype; eligible public.camp_eligible_users%rowtype; normalized_email text:=lower(btrim(new_email)); before_value jsonb;
begin
  perform private.lock_calendar_for_staff();
  select * into c from public.camps where id=target_camp_id and deleted_at is null for update;
  if not found then raise exception using message='not-found'; end if;
  if c.room_assignment_mode<>'legacy_application' then raise exception 'eligible-roster-required'; end if;
  select * into eligible from public.camp_eligible_users where id=target_eligible_user_id and camp_id=c.id for update;
  if not found then raise exception using message='not-found'; end if;
  perform private.check_calendar_version(eligible.updated_at,expected_updated_at);
  if eligible.disabled_at is not null then raise exception using message='invalid-status'; end if;
  if normalized_email='' or normalized_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception using message='invalid-email'; end if;
  if eligible.email_normalized=normalized_email then return query select eligible.id,eligible.email_normalized,eligible.updated_at,eligible.disabled_at; return; end if;
  perform private.check_calendar_reason(change_reason);
  if exists(select 1 from public.applications a where a.camp_id=c.id and lower(btrim(coalesce(a.email_snapshot,'')))=eligible.email_normalized) then raise exception using message='eligible-has-application'; end if;
  if exists(select 1 from public.camp_eligible_users other where other.camp_id=c.id and other.email_normalized=normalized_email and other.id<>eligible.id) then raise exception using message='eligible-email-exists'; end if;
  before_value:=jsonb_build_object('email',eligible.email_normalized,'disabled_at',eligible.disabled_at);
  update public.camp_eligible_users set email_normalized=normalized_email where id=eligible.id returning * into eligible;
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id,reason)
  values('camp_eligible_user',eligible.id,'update_camp_eligible_user',before_value,jsonb_build_object('email',eligible.email_normalized,'disabled_at',eligible.disabled_at),'staff',auth.uid(),btrim(change_reason));
  return query select eligible.id,eligible.email_normalized,eligible.updated_at,eligible.disabled_at;
end;
$$;

create or replace function public.disable_camp_eligible_user(
  target_camp_id uuid,target_eligible_user_id uuid,expected_updated_at timestamptz,change_reason text
)
returns table(result_id uuid,result_email text,result_updated_at timestamptz,result_disabled_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare c public.camps%rowtype; eligible public.camp_eligible_users%rowtype; before_value jsonb;
begin
  perform private.lock_calendar_for_staff();
  select * into c from public.camps where id=target_camp_id and deleted_at is null for update;
  if not found then raise exception using message='not-found'; end if;
  if c.room_assignment_mode<>'legacy_application' then raise exception 'eligible-roster-required'; end if;
  select * into eligible from public.camp_eligible_users where id=target_eligible_user_id and camp_id=c.id for update;
  if not found then raise exception using message='not-found'; end if;
  perform private.check_calendar_version(eligible.updated_at,expected_updated_at);
  if eligible.disabled_at is not null then raise exception using message='invalid-status'; end if;
  perform private.check_calendar_reason(change_reason);
  if exists(select 1 from public.applications a where a.camp_id=c.id and lower(btrim(coalesce(a.email_snapshot,'')))=eligible.email_normalized) then raise exception using message='eligible-has-application'; end if;
  before_value:=jsonb_build_object('email',eligible.email_normalized,'disabled_at',eligible.disabled_at);
  update public.camp_eligible_users set disabled_at=clock_timestamp() where id=eligible.id returning * into eligible;
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id,reason)
  values('camp_eligible_user',eligible.id,'disable_camp_eligible_user',before_value,jsonb_build_object('email',eligible.email_normalized,'disabled_at',eligible.disabled_at),'staff',auth.uid(),btrim(change_reason));
  return query select eligible.id,eligible.email_normalized,eligible.updated_at,eligible.disabled_at;
end;
$$;

create or replace function public.get_staff_camp_roster(target_camp_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.camps%rowtype;
begin
  if auth.uid() is null or not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
  select * into c from public.camps where id=target_camp_id and deleted_at is null;
  if not found then raise exception 'not-found'; end if;
  return jsonb_build_object('camp_id',c.id,'room_assignment_mode',c.room_assignment_mode,
    'roster_version',c.roster_version,'room_plan_version',c.room_plan_version,'saved_roster_version',c.saved_roster_version,
    'roster_label_version',c.roster_label_version,'room_plan_committed_at',c.room_plan_committed_at,
    'eligible_users',(select coalesce(jsonb_agg(jsonb_build_object(
      'id',e.id,'management_name',e.management_name,'email_normalized',e.email_normalized,'updated_at',e.updated_at,
      'disabled_at',e.disabled_at,'participation_status',e.participation_status,'released_at',e.released_at,
      'release_reason',e.release_reason,'linked_user_id',e.linked_user_id,'linked_at',e.linked_at,
      'linked_email_normalized',e.linked_email_normalized,'application_id',a.id,'application_status',a.status,'input_version',a.input_version)
      order by e.management_name nulls last,e.email_normalized,e.id),'[]'::jsonb)
      from public.camp_eligible_users e left join lateral(select x.id,x.status,x.input_version from public.applications x
        where x.camp_id=e.camp_id and x.camp_eligible_user_id=e.id
        order by (x.status not in ('rejected','cancelled')) desc,x.created_at desc,x.id limit 1) a on true where e.camp_id=c.id));
end;
$$;

revoke all on function public.create_camp_roster_eligible_user(uuid,text,text),
  public.update_camp_roster_eligible_user(uuid,uuid,text,text,timestamptz,text) from public,anon,authenticated,service_role;
grant execute on function public.create_camp_roster_eligible_user(uuid,text,text),
  public.update_camp_roster_eligible_user(uuid,uuid,text,text,timestamptz,text) to authenticated;
revoke all on function public.add_camp_eligible_users(uuid,text[]),public.update_camp_eligible_user(uuid,uuid,text,timestamptz,text),
  public.disable_camp_eligible_user(uuid,uuid,timestamptz,text),public.get_staff_camp_roster(uuid) from public,anon,authenticated,service_role;
grant execute on function public.add_camp_eligible_users(uuid,text[]),public.update_camp_eligible_user(uuid,uuid,text,timestamptz,text),
  public.disable_camp_eligible_user(uuid,uuid,timestamptz,text),public.get_staff_camp_roster(uuid) to authenticated;

commit;
