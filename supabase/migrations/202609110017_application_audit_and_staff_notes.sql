-- Phase 3 / T15. No backfill; preserve all existing camp RPC signatures.
begin;
select private.lock_calendar_facility();

-- Audit summaries deliberately omit names, addresses, phone numbers and free text.
create function private.camp_audit_summary(a jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select coalesce(jsonb_object_agg(key,value),'{}'::jsonb) from jsonb_each(coalesce(a,'{}'::jsonb))
  where key in ('status','start_date','end_date','updated_at','submitted_at','last_submitted_at',
    'revision_due_at','requires_guardian_consent','room_preference');
$$;
create function private.camp_audit_consent(target_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((select jsonb_build_object('id',id,'object_path',object_path,'mime_type',mime_type,'size_bytes',size_bytes)
    from public.consent_documents where application_id=target_id),'{}'::jsonb);
$$;
create function private.record_camp_user_audit(target_id uuid, operation text, before_application jsonb,
  before_consent jsonb, actor uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare after_application jsonb; changed jsonb;
begin
  select to_jsonb(a) into after_application from public.applications a where id=target_id;
  select coalesce(jsonb_agg(key order by key),'[]'::jsonb) into changed from jsonb_each(after_application)
    where key in ('status','start_date','end_date','user_name','user_address','user_phone','email_snapshot',
      'emergency_name','emergency_address','emergency_phone','usage_place','purpose','special_notes',
      'requires_guardian_consent','room_preference','submitted_at','last_submitted_at','revision_due_at')
      and coalesce(before_application,'{}'::jsonb)->key is distinct from value;
  if operation='save_camp_draft' and changed='[]'::jsonb then return; end if;
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id)
  values('application',target_id,operation,
    case when before_application is null then '{}'::jsonb else jsonb_build_object(
      'application',private.camp_audit_summary(before_application),'consent',coalesce(before_consent,'{}'::jsonb)) end,
    jsonb_build_object('application',private.camp_audit_summary(after_application),
      'consent',private.camp_audit_consent(target_id),'changed_fields',changed),'user',actor);
end; $$;

create or replace function public.create_camp_application_draft(
  target_camp_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  current_email text := lower(auth.jwt() ->> 'email');
  camp_record public.camps%rowtype;
  existing_application_id uuid;
  new_application_id uuid;
  created_new_application boolean := false;
begin
  if current_user_id is null then
    raise exception 'ログインが必要です。';
  end if;

  if not private.has_active_profile() then
    raise exception 'このアカウントでは申請できません。';
  end if;

  perform private.lock_calendar_facility();
  perform p.id from public.profiles p where p.id = current_user_id
    and p.account_state = 'active' for share;
  if not found then raise exception 'このアカウントでは申請できません。'; end if;

  select camp.*
  into camp_record
  from public.camps as camp
  where camp.id = target_camp_id
    and camp.deleted_at is null;

  if not found then
    raise exception '対象のキャンプが見つかりません。';
  end if;

  -- now() is fixed at transaction start, which may be before the deadline.
  -- Check the actual time before either returning or creating a draft.
  if clock_timestamp() >= camp_record.application_deadline then
    raise exception 'このキャンプの申請期限を過ぎています。';
  end if;

  if not exists (
    select 1
    from public.camp_eligible_users as eligible
    where eligible.camp_id = target_camp_id
      and eligible.disabled_at is null
      and eligible.email_normalized = current_email
  ) then
    raise exception 'このキャンプの申請対象者ではありません。';
  end if;

  select application.id
  into existing_application_id
  from public.applications as application
  where application.user_id = current_user_id
    and application.camp_id = target_camp_id
    and application.status not in ('rejected', 'cancelled')
  order by application.created_at desc
  limit 1;

  if existing_application_id is not null then
    return existing_application_id;
  end if;

  begin
    insert into public.applications (
      user_id,
      usage_type,
      camp_id,
      status,
      start_date,
      end_date
    )
    values (
      current_user_id,
      'camp',
      target_camp_id,
      'draft',
      camp_record.start_date,
      camp_record.end_date
    )
    returning id into new_application_id;

    created_new_application := true;
  exception
    when unique_violation then
      select application.id
      into new_application_id
      from public.applications as application
      where application.user_id = current_user_id
        and application.camp_id = target_camp_id
        and application.status not in ('rejected', 'cancelled')
      order by application.created_at desc
      limit 1;
  end;

  if new_application_id is null then
    raise exception '下書きを作成できませんでした。';
  end if;

  if created_new_application then
    insert into public.application_status_events (
      application_id,
      from_status,
      to_status,
      actor_user_id
    )
    values (
      new_application_id,
      null,
      'draft',
      current_user_id
    );
  end if;

  if created_new_application then
    perform private.record_camp_user_audit(new_application_id,'create_camp_draft',null,null,current_user_id);
  end if;
  return new_application_id;
end;
$$;

create or replace function public.save_camp_application_draft(
  target_application_id uuid,
  applicant_name text,
  applicant_address text,
  applicant_phone text,
  emergency_contact_name text,
  emergency_contact_address text,
  emergency_contact_phone text,
  usage_purpose text,
  notes text,
  guardian_consent_required boolean,
  requested_room_preference text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  current_email text := lower(auth.jwt() ->> 'email');
  application_record public.applications%rowtype;
  before_consent jsonb;
begin
  if current_user_id is null or not private.has_active_profile() then
    raise exception 'ログインが必要です。';
  end if;

  perform private.lock_calendar_facility();
  perform id from public.profiles where id=current_user_id and account_state='active' for share;
  if not found then raise exception 'ログインが必要です。'; end if;
  select application.*
  into application_record
  from public.applications as application
  where application.id = target_application_id and application.usage_type = 'camp'
  for update;

  if not found or application_record.user_id is distinct from current_user_id then
    raise exception '申請が見つかりません。';
  end if;

  if application_record.status not in ('draft', 'revision_requested') then
    raise exception '現在の状態では申請を編集できません。';
  end if;

  if application_record.status = 'revision_requested'
    and application_record.revision_due_at is not null
    and clock_timestamp() >= application_record.revision_due_at then
    raise exception '修正期限を過ぎています。';
  end if;

  if requested_room_preference is not null
    and requested_room_preference not in ('shared_ok', 'private_requested') then
    raise exception '相部屋希望の値が正しくありません。';
  end if;

  before_consent:=private.camp_audit_consent(target_application_id);
  update public.applications
  set
    user_name = nullif(btrim(applicant_name), ''),
    user_address = nullif(btrim(applicant_address), ''),
    user_phone = nullif(btrim(applicant_phone), ''),
    email_snapshot = current_email,
    emergency_name = nullif(btrim(emergency_contact_name), ''),
    emergency_address = nullif(btrim(emergency_contact_address), ''),
    emergency_phone = nullif(btrim(emergency_contact_phone), ''),
    usage_place = 'common_and_second_floor',
    purpose = nullif(btrim(usage_purpose), ''),
    special_notes = nullif(btrim(notes), ''),
    requires_guardian_consent = guardian_consent_required,
    room_preference = requested_room_preference
  where id = target_application_id;

  perform private.record_camp_user_audit(target_application_id,'save_camp_draft',to_jsonb(application_record),before_consent,current_user_id);
  return target_application_id;
end;
$$;


create or replace function public.submit_camp_application(
  target_application_id uuid
)
returns table (
  submitted_application_id uuid,
  reception_number text,
  submission_time timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  application_record public.applications%rowtype;
  consent_was_required boolean;
  before_consent jsonb;
begin
  if current_user_id is null or not private.has_active_profile() then
    raise exception 'ログインが必要です。';
  end if;

  -- Preserve the global-before-application lock order used by the core function.
  perform private.lock_calendar_facility();
  perform p.id from public.profiles p where p.id = current_user_id
    and p.account_state = 'active' for share;
  if not found then raise exception 'ログインが必要です。'; end if;

  select application.*
  into application_record
  from public.applications as application
  where application.id = target_application_id
  for update;

  if not found or application_record.user_id <> current_user_id then
    raise exception '申請が見つかりません。';
  end if;

  perform private.check_camp_calendar(application_record.camp_id);

  before_consent:=private.camp_audit_consent(target_application_id);
  consent_was_required := application_record.requires_guardian_consent;

  if consent_was_required and not exists (
    select 1
    from public.consent_documents as document
    where document.application_id = target_application_id
  ) then
    raise exception '保護者同意書を添付してください。';
  end if;

  -- The phase-3 core predates attachments and rejects every consent-required
  -- application. Temporarily clear the flag inside this transaction after the
  -- verified metadata check, then restore it before committing.
  if consent_was_required then
    update public.applications
    set requires_guardian_consent = false
    where id = target_application_id;
  end if;

  return query
  select
    submitted.submitted_application_id,
    submitted.reception_number,
    submitted.submission_time
  from private.submit_camp_application(target_application_id) as submitted;

  if consent_was_required then
    update public.applications
    set requires_guardian_consent = true
    where id = target_application_id;
  end if;
  -- Only the final state is audited, never the transient consent flag toggle.
  if application_record.status in ('draft','revision_requested') then
    perform private.record_camp_user_audit(target_application_id,
      case when application_record.status='draft' then 'submit_camp_application' else 'resubmit_camp_application' end,
      to_jsonb(application_record),before_consent,current_user_id);
  end if;
end;
$$;

create or replace function public.register_guardian_consent_document(
  target_application_id uuid,
  expected_user_id uuid,
  target_object_path text,
  target_mime_type text,
  target_size_bytes integer
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_record public.applications%rowtype;
  previous_object_path text;
  expected_path_pattern text;
  before_consent jsonb;
begin
  if expected_user_id is null or not exists (
    select 1
    from public.profiles as profile
    where profile.id = expected_user_id
      and profile.account_state = 'active'
  ) then
    raise exception '有効な利用者が見つかりません。';
  end if;

  perform private.lock_calendar_facility();
  perform id from public.profiles where id=expected_user_id and account_state='active' for share;
  if not found then raise exception '有効な利用者が見つかりません。'; end if;
  select application.*
  into application_record
  from public.applications as application
  where application.id = target_application_id and application.usage_type = 'camp'
  for update;

  if not found or application_record.user_id is distinct from expected_user_id then
    raise exception '申請が見つかりません。';
  end if;

  if application_record.status not in ('draft', 'revision_requested') then
    raise exception '現在の状態では同意書を変更できません。';
  end if;

  if application_record.status = 'revision_requested'
    and application_record.revision_due_at is not null
    and clock_timestamp() >= application_record.revision_due_at then
    raise exception '修正期限を過ぎています。';
  end if;

  expected_path_pattern := format(
    '^applications/%s/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    target_application_id
  );

  if target_object_path is null
    or target_object_path !~ expected_path_pattern then
    raise exception '同意書の保存先が正しくありません。';
  end if;

  if target_mime_type is null or target_mime_type not in ('application/pdf', 'image/jpeg', 'image/png') then
    raise exception 'PDF、JPEG、PNG形式のファイルを選択してください。';
  end if;

  if target_size_bytes is null
    or target_size_bytes not between 1 and 5242880 then
    raise exception 'ファイルサイズは5MiB以下にしてください。';
  end if;

  select document.object_path
  into previous_object_path
  from public.consent_documents as document
  where document.application_id = target_application_id
  for update;

  if previous_object_path=target_object_path then
    if exists(select 1 from public.consent_documents where application_id=target_application_id
      and mime_type=target_mime_type and size_bytes=target_size_bytes) then return previous_object_path; end if;
    raise exception '同意書の保存先が正しくありません。';
  end if;
  before_consent:=private.camp_audit_consent(target_application_id);
  insert into public.consent_documents (
    application_id,
    object_path,
    mime_type,
    size_bytes
  )
  values (
    target_application_id,
    target_object_path,
    target_mime_type,
    target_size_bytes
  )
  on conflict (application_id) do update
  set
    object_path = excluded.object_path,
    mime_type = excluded.mime_type,
    size_bytes = excluded.size_bytes;

  update public.applications set updated_at=clock_timestamp() where id=target_application_id;
  perform private.record_camp_user_audit(target_application_id,
    case when previous_object_path is null then 'register_camp_consent' else 'replace_camp_consent' end,
    to_jsonb(application_record),before_consent,expected_user_id);
  return previous_object_path;
end;
$$;

-- Staff notes are separate from all owner-visible application records.
create table public.staff_notes (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.applications(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 2000),
  author_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);
create index staff_notes_application_idx on public.staff_notes(application_id,created_at,id);
alter table public.staff_notes enable row level security;
create policy staff_notes_select_staff on public.staff_notes for select to authenticated using (private.is_staff());
revoke all on public.staff_notes from public,anon,authenticated,service_role;
grant select on public.staff_notes to authenticated;

create function public.save_application_staff_note(target_application_id uuid, expected_updated_at timestamptz,
  target_note_id uuid, note_body text)
returns table(result_id uuid,result_usage_type text,result_camp_id uuid,result_updated_at timestamptz,result_note_id uuid)
language plpgsql security definer set search_path = '' as $$
declare a public.applications%rowtype; n public.staff_notes%rowtype; before_value jsonb;
  body_value text:=nullif(btrim(note_body),'');
begin
  perform private.lock_calendar_for_staff();
  select * into a from public.applications where id=target_application_id
    and usage_type in ('camp','community_individual') and original_application_id is null for update;
  if not found then raise exception 'not-found'; end if;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if body_value is null then raise exception 'note-required'; end if;
  if char_length(body_value)>2000 then raise exception 'note-too-long'; end if;
  if target_note_id is not null then
    select * into n from public.staff_notes where id=target_note_id and application_id=a.id for update;
    if not found then raise exception 'note-not-found'; end if;
    if n.body=body_value then
      return query select a.id,a.usage_type,a.camp_id,a.updated_at,n.id; return;
    end if;
    before_value:=jsonb_build_object('note',to_jsonb(n),'application_updated_at',a.updated_at);
    update public.staff_notes set body=body_value,updated_at=greatest(clock_timestamp(),n.updated_at+interval '1 microsecond')
      where id=n.id returning * into n;
  else
    before_value:='{}'::jsonb;
    insert into public.staff_notes(application_id,body,author_user_id) values(a.id,body_value,auth.uid()) returning * into n;
  end if;
  update public.applications set updated_at=clock_timestamp() where id=a.id returning * into a;
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id)
  values('application',a.id,case when target_note_id is null then 'add_staff_note' else 'edit_staff_note' end,
    before_value,jsonb_build_object('note',to_jsonb(n),'application_updated_at',a.updated_at),'staff',auth.uid());
  return query select a.id,a.usage_type,a.camp_id,a.updated_at,n.id;
end; $$;

create function public.get_staff_application_notes(target_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.applications%rowtype;
begin
  if auth.uid() is null or not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
  select * into a from public.applications where id=target_application_id
    and usage_type in ('camp','community_individual') and original_application_id is null;
  if not found then raise exception 'not-found'; end if;
  return jsonb_build_object('id',a.id,'usage_type',a.usage_type,'camp_id',a.camp_id,'updated_at',a.updated_at,
    'notes',(select coalesce(jsonb_agg(jsonb_build_object('id',n.id,'body',n.body,'author_user_id',n.author_user_id,
      'created_at',n.created_at,'updated_at',n.updated_at) order by n.created_at,n.id),'[]'::jsonb)
      from public.staff_notes n where n.application_id=a.id));
end; $$;

revoke all on function private.camp_audit_summary(jsonb),private.camp_audit_consent(uuid),
  private.record_camp_user_audit(uuid,text,jsonb,jsonb,uuid) from public,anon,authenticated,service_role;
revoke all on function public.save_application_staff_note(uuid,timestamptz,uuid,text),
  public.get_staff_application_notes(uuid) from public,anon,authenticated,service_role;
grant execute on function public.save_application_staff_note(uuid,timestamptz,uuid,text),
  public.get_staff_application_notes(uuid) to authenticated;
-- CREATE OR REPLACE preserves the existing camp execution grants, including service-only consent registration.
commit;
