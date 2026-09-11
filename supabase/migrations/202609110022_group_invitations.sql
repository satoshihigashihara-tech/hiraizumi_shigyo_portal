-- T19 first half: private group invitations and authenticated participant joining.
-- Personal form submission, review and group completion remain later work.
begin;
select private.lock_calendar_facility();
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

alter table public.applications add column group_id uuid
  references public.group_applications(id) on delete restrict;
alter table public.applications drop constraint applications_usage_type_check;
alter table public.applications drop constraint applications_usage_camp_check;
alter table public.applications drop constraint community_dates_check;
alter table public.applications drop constraint community_revision_dates_check;
alter table public.applications add constraint applications_usage_type_check
  check (usage_type in ('camp','community_individual','community_group'));
alter table public.applications add constraint applications_usage_camp_check check (
  (usage_type='camp' and camp_id is not null and group_id is null)
  or (usage_type='community_individual' and camp_id is null and group_id is null and room_preference is null)
  or (usage_type='community_group' and camp_id is null and group_id is not null
    and room_preference is null and original_application_id is null));
alter table public.applications add constraint community_dates_check check (
  usage_type not in ('community_individual','community_group')
  or (start_date is null and end_date is null)
  or (start_date is not null and end_date is not null
    and start_date between date '0001-01-01' and date '9999-12-31'
    and end_date between date '0001-01-01' and date '9999-12-31'
    and end_date-start_date between 1 and 14));
alter table public.applications add constraint community_revision_dates_check check (
  (revision_start_date is null and revision_end_date is null)
  or (usage_type in ('community_individual','community_group')
    and revision_start_date is not null and revision_end_date is not null
    and revision_start_date between date '0001-01-01' and date '9999-12-31'
    and revision_end_date between date '0001-01-01' and date '9999-12-31'
    and revision_end_date-revision_start_date between 1 and 14));
create index applications_group_idx on public.applications(group_id,created_at,id)
  where group_id is not null;

create table public.group_members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.group_applications(id) on delete restrict,
  application_id uuid not null unique references public.applications(id) on delete restrict,
  state text not null default 'active' check (state in ('active','removed')),
  removed_at timestamptz,
  removal_reason text,
  joined_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check ((state='active' and removed_at is null and removal_reason is null)
    or (state='removed' and removed_at is not null and nullif(btrim(removal_reason),'') is not null)),
  check (removal_reason is null or char_length(btrim(removal_reason)) between 1 and 2000)
);
create index group_members_group_idx on public.group_members(group_id,state,joined_at,id);
create trigger group_members_set_updated_at before update on public.group_members
for each row execute function private.set_application_updated_at();

create table public.group_invites (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.group_applications(id) on delete restrict,
  token_hash text not null unique check (token_hash~'^[0-9a-f]{64}$'),
  code_hash text not null unique check (code_hash~'^[0-9a-f]{64}$'),
  revoked_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default clock_timestamp()
);
create unique index group_invites_one_active_idx on public.group_invites(group_id) where revoked_at is null;

alter table public.group_members enable row level security;
alter table public.group_invites enable row level security;
create policy group_members_select_owner on public.group_members for select to authenticated
using (private.has_active_profile() and exists(select 1 from public.applications a
  where a.id=group_members.application_id and a.user_id=auth.uid()));
create policy group_members_select_staff on public.group_members for select to authenticated using (private.is_staff());
revoke all on public.group_members,public.group_invites from public,anon,authenticated,service_role;
grant select on public.group_members to authenticated;

create function private.group_invite_hash(invite_value text,invite_kind text)
returns text language plpgsql immutable set search_path='' as $$
declare normalized text;
begin
  if invite_kind='token' then
    if invite_value is null or invite_value!~'^[0-9a-f]{64}$' then raise exception 'invalid-invite'; end if;
    normalized:=lower(invite_value);
  elsif invite_kind='code' then
    normalized:=upper(regexp_replace(coalesce(invite_value,''),'[-[:space:]]','','g'));
    if normalized!~'^[A-HJ-NP-Z2-9]{16}$' then raise exception 'invalid-invite'; end if;
  else raise exception 'invalid-invite'; end if;
  return encode(extensions.digest(convert_to(normalized,'UTF8'),'sha256'),'hex');
end; $$;

create function private.new_group_invite_code()
returns text language plpgsql volatile security definer set search_path='' as $$
declare alphabet constant text:='ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; result text:=''; n integer;
begin
  for n in 1..16 loop
    result:=result||substr(alphabet,(get_byte(extensions.gen_random_bytes(1),0)%32)+1,1);
  end loop;
  return result;
end; $$;

create function private.assert_group_member_consistency(target_application_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare a public.applications%rowtype; m public.group_members%rowtype; g public.group_applications%rowtype;
begin
  select * into a from public.applications where id=target_application_id;
  if not found or a.usage_type<>'community_group' then return; end if;
  select * into m from public.group_members where application_id=a.id;
  if not found or m.group_id is distinct from a.group_id then raise exception 'group-member-inconsistent'; end if;
  select * into g from public.group_applications where id=a.group_id;
  if not found or a.start_date is distinct from g.start_date or a.end_date is distinct from g.end_date then
    raise exception 'group-member-inconsistent'; end if;
  if m.state='active' and exists(select 1 from public.group_members other_m
    join public.applications other_a on other_a.id=other_m.application_id
    where other_m.group_id=m.group_id and other_m.state='active' and other_a.user_id=a.user_id
      and other_m.application_id<>a.id) then raise exception 'duplicate-group-member'; end if;
end; $$;

create function private.check_group_application_member()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  perform private.assert_group_member_consistency(new.id); return new;
end; $$;
create constraint trigger applications_check_group_member after insert or update of user_id,usage_type,group_id,start_date,end_date
on public.applications deferrable initially deferred for each row execute function private.check_group_application_member();

create function private.check_group_member_row()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  perform private.assert_group_member_consistency(new.application_id); return new;
end; $$;
create constraint trigger group_members_check_application after insert or update of group_id,application_id,state
on public.group_members deferrable initially deferred for each row execute function private.check_group_member_row();

create function public.issue_community_group_invite(target_group_id uuid,expected_updated_at timestamptz)
returns table(result_group_id uuid,result_updated_at timestamptz,invite_token text,invite_code text,expires_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare actor uuid:=private.lock_group_user(); g public.group_applications%rowtype; token_value text;
  code_value text; token_digest text; code_digest text; before_value jsonb; moment timestamptz:=clock_timestamp();
begin
  select * into g from public.group_applications where id=target_group_id for update;
  if not found or g.representative_user_id is distinct from actor then raise exception 'not-found'; end if;
  perform private.check_calendar_version(g.updated_at,expected_updated_at);
  if g.status<>'collecting' then raise exception 'invite-not-available'; end if;
  if g.participant_due_at is null or moment>=g.participant_due_at then raise exception 'invite-expired'; end if;
  before_value:=private.group_snapshot(g.id);
  token_value:=encode(extensions.gen_random_bytes(32),'hex');
  code_value:=private.new_group_invite_code();
  token_digest:=private.group_invite_hash(token_value,'token'); code_digest:=private.group_invite_hash(code_value,'code');
  update public.group_invites set revoked_at=moment where group_id=g.id and revoked_at is null;
  insert into public.group_invites(group_id,token_hash,code_hash,created_by)
    values(g.id,token_digest,code_digest,actor);
  update public.group_applications set updated_at=moment where id=g.id returning * into g;
  perform private.group_audit(g.id,'issue_group_invite',before_value,actor);
  return query select g.id,g.updated_at,token_value,code_value,g.participant_due_at;
end; $$;

create function public.get_community_group_invite(invite_value text,invite_kind text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid(); digest_value text; i public.group_invites%rowtype;
  g public.group_applications%rowtype; existing_id uuid; count_value integer; moment timestamptz:=statement_timestamp();
begin
  if actor is null or not private.has_active_profile() then
    raise exception using errcode='42501',message='active-user-required'; end if;
  digest_value:=private.group_invite_hash(invite_value,invite_kind);
  select * into i from public.group_invites where revoked_at is null
    and case when invite_kind='token' then token_hash=digest_value else code_hash=digest_value end;
  if not found then raise exception 'invalid-invite'; end if;
  select * into g from public.group_applications where id=i.group_id;
  if not found or g.status<>'collecting' or g.participant_due_at is null or moment>=g.participant_due_at then
    raise exception 'invite-expired'; end if;
  select a.id into existing_id from public.group_members m join public.applications a on a.id=m.application_id
    where m.group_id=g.id and m.state='active' and a.user_id=actor order by m.joined_at,m.id limit 1;
  select count(*) into count_value from public.group_members where group_id=g.id and state='active';
  return jsonb_build_object('group_id',g.id,'group_name',g.group_name,'start_date',g.start_date,'end_date',g.end_date,
    'purpose',g.purpose,'local_activity',g.local_activity,'planned_participants',g.planned_participants,
    'participant_due_at',g.participant_due_at,'joined_participants',count_value,
    'already_joined_application_id',existing_id,'can_join',existing_id is null and count_value<g.planned_participants
      and (actor<>g.representative_user_id or g.representative_stays));
end; $$;

create function public.join_community_group(invite_value text,invite_kind text,target_application_id uuid)
returns table(result_group_id uuid,result_application_id uuid,result_group_updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare actor uuid:=private.lock_group_user(); digest_value text; i public.group_invites%rowtype;
  g public.group_applications%rowtype; a public.applications%rowtype; existing_id uuid;
  count_value integer; before_value jsonb; moment timestamptz:=clock_timestamp();
begin
  if target_application_id is null then raise exception 'invalid-application'; end if;
  select * into a from public.applications where id=target_application_id for update;
  if found then
    if a.user_id is distinct from actor or a.usage_type<>'community_group' or a.group_id is null
      or not exists(select 1 from public.group_members m where m.application_id=a.id and m.group_id=a.group_id and m.state='active')
      then raise exception 'not-found'; end if;
    return query select a.group_id,a.id,current_group.updated_at
      from public.group_applications current_group where current_group.id=a.group_id; return;
  end if;
  digest_value:=private.group_invite_hash(invite_value,invite_kind);
  select * into i from public.group_invites where revoked_at is null
    and case when invite_kind='token' then token_hash=digest_value else code_hash=digest_value end for update;
  if not found then raise exception 'invalid-invite'; end if;
  select * into g from public.group_applications where id=i.group_id for update;
  if not found or g.status<>'collecting' then raise exception 'invite-not-available'; end if;
  if g.participant_due_at is null or moment>=g.participant_due_at then raise exception 'invite-expired'; end if;
  select existing_a.id into existing_id from public.group_members existing_m
    join public.applications existing_a on existing_a.id=existing_m.application_id
    where existing_m.group_id=g.id and existing_m.state='active' and existing_a.user_id=actor
    order by existing_m.joined_at,existing_m.id limit 1;
  if existing_id is not null then return query select g.id,existing_id,g.updated_at; return; end if;
  if actor=g.representative_user_id and not g.representative_stays then raise exception 'representative-not-staying'; end if;
  select count(*) into count_value from public.group_members where group_id=g.id and state='active';
  if count_value>=g.planned_participants then raise exception 'group-full'; end if;
  if exists(select 1 from public.group_members other_m join public.applications other_a on other_a.id=other_m.application_id
    join public.group_applications other_g on other_g.id=other_m.group_id
    where other_m.state='active' and other_a.user_id=actor and other_g.id<>g.id
      and other_g.status in ('collecting','under_review','revision_requested','approved','cancellation_requested')
      and other_g.start_date<=g.end_date and other_g.end_date>=g.start_date)
    or exists(select 1 from public.applications other_a where other_a.user_id=actor
      and other_a.usage_type in ('camp','community_individual')
      and other_a.status in ('submitted','under_review','revision_requested','approved','cancellation_requested')
      and other_a.start_date<=g.end_date and other_a.end_date>=g.start_date)
    then raise exception 'duplicate-stay'; end if;
  before_value:=private.group_snapshot(g.id);
  insert into public.applications(id,user_id,usage_type,group_id,status,start_date,end_date,user_name,user_address,user_phone,
    emergency_name,emergency_address,emergency_phone,requires_guardian_consent)
  select target_application_id,actor,'community_group',g.id,'draft',g.start_date,g.end_date,p.full_name,p.address,p.phone,
    p.emergency_name,p.emergency_address,p.emergency_phone,null from public.profiles p where p.id=actor;
  insert into public.group_members(group_id,application_id,joined_at) values(g.id,target_application_id,moment);
  insert into public.application_status_events(application_id,to_status,actor_user_id,occurred_at)
    values(target_application_id,'draft',actor,moment);
  update public.group_applications set updated_at=moment where id=g.id returning * into g;
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id)
    values('application',target_application_id,'join_community_group','{}',jsonb_build_object(
      'application',jsonb_build_object('id',target_application_id,'usage_type','community_group','group_id',g.id,
        'status','draft','start_date',g.start_date,'end_date',g.end_date)),'user',actor);
  perform private.group_audit(g.id,'join_group_member',before_value,actor);
  return query select g.id,target_application_id,g.updated_at;
end; $$;

create function public.get_community_group_participants(target_group_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g public.group_applications%rowtype;
begin
  if auth.uid() is null or not private.has_active_profile() then
    raise exception using errcode='42501',message='active-user-required'; end if;
  select * into g from public.group_applications where id=target_group_id and representative_user_id=auth.uid();
  if not found then raise exception 'not-found'; end if;
  return jsonb_build_object('group_id',g.id,'group_name',g.group_name,'status',g.status,'updated_at',g.updated_at,
    'planned_participants',g.planned_participants,'participant_due_at',g.participant_due_at,
    'participants',(select coalesce(jsonb_agg(jsonb_build_object('application_id',a.id,'name',a.user_name,
      'application_status',a.status,'is_representative',a.user_id=g.representative_user_id,'joined_at',m.joined_at)
      order by m.joined_at,m.id),'[]'::jsonb) from public.group_members m join public.applications a on a.id=m.application_id
      where m.group_id=g.id and m.state='active'));
end; $$;

revoke all on function private.group_invite_hash(text,text),private.new_group_invite_code(),
  private.assert_group_member_consistency(uuid),private.check_group_application_member(),private.check_group_member_row()
from public,anon,authenticated,service_role;
revoke all on function public.issue_community_group_invite(uuid,timestamptz),
  public.get_community_group_invite(text,text),public.join_community_group(text,text,uuid),
  public.get_community_group_participants(uuid) from public,anon,authenticated,service_role;
grant execute on function public.issue_community_group_invite(uuid,timestamptz),
  public.get_community_group_invite(text,text),public.join_community_group(text,text,uuid),
  public.get_community_group_participants(uuid) to authenticated;
commit;
