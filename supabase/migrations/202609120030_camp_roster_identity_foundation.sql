-- A1: stable camp roster identity, versioning and migration diagnostics.
-- Existing camps stay on legacy_application and existing applications are not linked.
begin;
select private.lock_calendar_facility();

alter table public.camps
  add column room_assignment_mode text not null default 'legacy_application'
    check (room_assignment_mode in ('legacy_application','eligible_roster')),
  add column roster_version bigint not null default 0 check (roster_version >= 0),
  add column room_plan_version bigint not null default 0 check (room_plan_version >= 0),
  add column saved_roster_version bigint check (saved_roster_version is null or saved_roster_version >= 0),
  add column roster_label_version bigint not null default 0 check (roster_label_version >= 0),
  add column room_plan_committed_at timestamptz;

alter table public.camp_eligible_users
  add column management_name text
    check (management_name is null or char_length(btrim(management_name)) between 1 and 200),
  add column participation_status text not null default 'participating'
    check (participation_status in ('participating','released')),
  add column released_at timestamptz,
  add column release_reason text
    check (release_reason is null or char_length(btrim(release_reason)) between 1 and 2000),
  add column linked_user_id uuid,
  add column linked_at timestamptz,
  add column linked_email_normalized text,
  add constraint camp_eligible_users_camp_id_id_uq unique (camp_id,id),
  add constraint camp_eligible_users_release_check check (
    (participation_status='participating' and released_at is null and release_reason is null)
    or (participation_status='released' and released_at is not null and release_reason is not null)
  ),
  add constraint camp_eligible_users_link_check check (
    (linked_user_id is null and linked_at is null and linked_email_normalized is null)
    or (linked_user_id is not null and linked_at is not null
      and linked_email_normalized=lower(btrim(linked_email_normalized))
      and linked_email_normalized<>'')
  );

create unique index camp_eligible_users_one_linked_user_per_camp
on public.camp_eligible_users(camp_id,linked_user_id)
where linked_user_id is not null;

alter table public.applications
  add column camp_eligible_user_id uuid,
  add column input_version bigint not null default 1 check (input_version >= 1),
  add constraint applications_camp_eligible_user_scope_check
    check (usage_type='camp' or camp_eligible_user_id is null),
  add constraint applications_camp_eligible_user_fk
    foreign key(camp_id,camp_eligible_user_id)
    references public.camp_eligible_users(camp_id,id) on delete restrict;

create unique index applications_one_active_camp_per_eligible_user
on public.applications(camp_id,camp_eligible_user_id)
where camp_eligible_user_id is not null and status not in ('rejected','cancelled');

create index applications_camp_eligible_user_idx
on public.applications(camp_eligible_user_id)
where camp_eligible_user_id is not null;

-- The value is deliberately immovable in A1. A later migration RPC may set the
-- transaction-local guard before changing it, after its own diagnostics pass.
create function private.guard_camp_room_assignment_mode()
returns trigger language plpgsql set search_path='' as $$
begin
  if new.room_assignment_mode is distinct from old.room_assignment_mode
    and current_setting('private.camp_mode_migration',true) is distinct from 'allowed' then
    raise exception 'camp-mode-migration-required';
  end if;
  return new;
end; $$;
create trigger camps_guard_room_assignment_mode
before update of room_assignment_mode on public.camps
for each row execute function private.guard_camp_room_assignment_mode();

create function private.guard_camp_eligible_user_link()
returns trigger language plpgsql set search_path='' as $$
begin
  if old.linked_user_id is not null and
    (new.linked_user_id,new.linked_at,new.linked_email_normalized)
      is distinct from (old.linked_user_id,old.linked_at,old.linked_email_normalized) then
    raise exception 'eligible-user-link-immutable';
  end if;
  return new;
end; $$;
create trigger camp_eligible_users_guard_link
before update of linked_user_id,linked_at,linked_email_normalized on public.camp_eligible_users
for each row execute function private.guard_camp_eligible_user_link();

create function private.bump_camp_roster_versions()
returns trigger language plpgsql security definer set search_path='' as $$
declare target_camp uuid; roster_changed boolean:=false; label_changed boolean:=false;
begin
  if tg_op='DELETE' then target_camp:=old.camp_id; else target_camp:=new.camp_id; end if;
  if not exists(select 1 from public.camps c where c.id=target_camp and c.room_assignment_mode='eligible_roster') then
    if tg_op='DELETE' then return old; else return new; end if;
  end if;
  if tg_op in ('INSERT','DELETE') then
    roster_changed:=true; label_changed:=true;
  else
    roster_changed:=(old.email_normalized,old.disabled_at,old.participation_status,old.released_at)
      is distinct from (new.email_normalized,new.disabled_at,new.participation_status,new.released_at);
    label_changed:=old.management_name is distinct from new.management_name;
  end if;
  update public.camps set
    roster_version=roster_version+case when roster_changed then 1 else 0 end,
    roster_label_version=roster_label_version+case when label_changed then 1 else 0 end
  where id=target_camp and (roster_changed or label_changed);
  if tg_op='DELETE' then return old; else return new; end if;
end; $$;
create trigger camp_eligible_users_bump_roster_versions
after insert or delete or update of email_normalized,disabled_at,participation_status,released_at,management_name
on public.camp_eligible_users for each row execute function private.bump_camp_roster_versions();

create function private.bump_camp_application_input_version()
returns trigger language plpgsql set search_path='' as $$
begin
  if new.usage_type='camp' and exists(select 1 from public.camps c where c.id=new.camp_id
      and c.room_assignment_mode='eligible_roster')
    and (new.user_name,new.user_address,new.user_phone,new.email_snapshot,new.emergency_name,
      new.emergency_address,new.emergency_phone,new.usage_place,new.purpose,new.special_notes,
      new.requires_guardian_consent,new.room_preference)
      is distinct from
      (old.user_name,old.user_address,old.user_phone,old.email_snapshot,old.emergency_name,
      old.emergency_address,old.emergency_phone,old.usage_place,old.purpose,old.special_notes,
      old.requires_guardian_consent,old.room_preference) then
    new.input_version:=old.input_version+1;
  end if;
  return new;
end; $$;
create trigger applications_bump_camp_input_version
before update of user_name,user_address,user_phone,email_snapshot,emergency_name,emergency_address,
  emergency_phone,usage_place,purpose,special_notes,requires_guardian_consent,room_preference
on public.applications for each row execute function private.bump_camp_application_input_version();

create function private.check_camp_roster_application()
returns trigger language plpgsql security definer set search_path='' as $$
declare mode_value text; eligible public.camp_eligible_users%rowtype;
begin
  if new.usage_type<>'camp' then
    if new.camp_eligible_user_id is not null then raise exception 'camp-eligible-user-not-applicable'; end if;
    return new;
  end if;
  select c.room_assignment_mode into mode_value from public.camps c where c.id=new.camp_id;
  if new.camp_eligible_user_id is not null then
    select * into eligible from public.camp_eligible_users e
      where e.camp_id=new.camp_id and e.id=new.camp_eligible_user_id;
    if not found then raise exception 'camp-eligible-user-inconsistent'; end if;
    if eligible.linked_user_id is null
      or (new.user_id is not null and eligible.linked_user_id is distinct from new.user_id) then
      raise exception 'camp-eligible-user-owner-inconsistent';
    end if;
  end if;
  if mode_value='eligible_roster' and new.status not in ('rejected','cancelled') then
    if new.camp_eligible_user_id is null then raise exception 'camp-eligible-user-required'; end if;
    if eligible.disabled_at is not null or eligible.participation_status<>'participating' then
      raise exception 'camp-eligible-user-not-participating';
    end if;
  end if;
  return new;
end; $$;
create constraint trigger applications_check_camp_roster
after insert or update of user_id,usage_type,camp_id,camp_eligible_user_id,status
on public.applications deferrable initially deferred for each row
execute function private.check_camp_roster_application();

create function private.current_verified_email(target_user_id uuid)
returns text language sql stable security definer set search_path='' as $$
  select lower(btrim(u.email)) from auth.users u
  where u.id=target_user_id and u.email_confirmed_at is not null and nullif(btrim(u.email),'') is not null;
$$;

create or replace function private.can_read_camp(target_camp_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select private.is_staff() or (private.has_active_profile() and exists(
    select 1 from public.camps c join public.camp_eligible_users e on e.camp_id=c.id
    where c.id=target_camp_id and e.disabled_at is null
      and (c.room_assignment_mode='legacy_application' and e.email_normalized=lower(auth.jwt()->>'email')
        or c.room_assignment_mode='eligible_roster' and e.participation_status='participating'
          and (e.linked_user_id=auth.uid() or (e.linked_user_id is null
            and e.email_normalized=private.current_verified_email(auth.uid())))))
  );
$$;

create or replace function public.create_camp_application_draft(target_camp_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); current_email text:=lower(auth.jwt()->>'email'); verified_email text;
  camp_record public.camps%rowtype; eligible public.camp_eligible_users%rowtype;
  existing_id uuid; new_id uuid; created_new boolean:=false;
begin
  if actor is null then raise exception 'ログインが必要です。'; end if;
  if not private.has_active_profile() then raise exception 'このアカウントでは申請できません。'; end if;
  perform private.lock_calendar_facility();
  perform p.id from public.profiles p where p.id=actor and p.account_state='active' for share;
  if not found then raise exception 'このアカウントでは申請できません。'; end if;
  select * into camp_record from public.camps c where c.id=target_camp_id and c.deleted_at is null;
  if not found then raise exception '対象のキャンプが見つかりません。'; end if;
  if clock_timestamp()>=camp_record.application_deadline then raise exception 'このキャンプの申請期限を過ぎています。'; end if;

  if camp_record.room_assignment_mode='legacy_application' then
    if not exists(select 1 from public.camp_eligible_users e where e.camp_id=target_camp_id
      and e.disabled_at is null and e.email_normalized=current_email) then
      raise exception 'このキャンプの申請対象者ではありません。'; end if;
    select a.id into existing_id from public.applications a where a.user_id=actor and a.camp_id=target_camp_id
      and a.status not in ('rejected','cancelled') order by a.created_at desc limit 1;
  else
    verified_email:=private.current_verified_email(actor);
    select * into eligible from public.camp_eligible_users e where e.camp_id=target_camp_id
      and e.linked_user_id=actor for update;
    if not found and verified_email is not null then
      select * into eligible from public.camp_eligible_users e where e.camp_id=target_camp_id
        and e.linked_user_id is null and e.email_normalized=verified_email for update;
      if found then
        update public.camp_eligible_users set linked_user_id=actor,linked_at=clock_timestamp(),
          linked_email_normalized=verified_email where id=eligible.id returning * into eligible;
        insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id)
        values('camp_eligible_user',eligible.id,'link_camp_eligible_user','{}',
          jsonb_build_object('linked_user_id',actor,'linked_at',eligible.linked_at),'user',actor);
      end if;
    end if;
    if eligible.id is null or eligible.disabled_at is not null or eligible.participation_status<>'participating' then
      raise exception 'このキャンプの申請対象者ではありません。'; end if;
    select a.id into existing_id from public.applications a where a.camp_id=target_camp_id
      and a.camp_eligible_user_id=eligible.id and a.status not in ('rejected','cancelled')
      order by a.created_at desc limit 1;
    if existing_id is not null and not exists(select 1 from public.applications a where a.id=existing_id and a.user_id=actor) then
      raise exception 'このキャンプの申請対象者ではありません。'; end if;
  end if;
  if existing_id is not null then return existing_id; end if;
  begin
    insert into public.applications(user_id,usage_type,camp_id,camp_eligible_user_id,status,start_date,end_date)
    values(actor,'camp',target_camp_id,eligible.id,'draft',camp_record.start_date,camp_record.end_date)
    returning id into new_id;
    created_new:=true;
  exception when unique_violation then
    select a.id into new_id from public.applications a where a.camp_id=target_camp_id
      and a.status not in ('rejected','cancelled') and
      (camp_record.room_assignment_mode='legacy_application' and a.user_id=actor
        or camp_record.room_assignment_mode='eligible_roster' and a.camp_eligible_user_id=eligible.id)
      order by a.created_at desc limit 1;
  end;
  if new_id is null then raise exception '下書きを作成できませんでした。'; end if;
  if created_new then
    insert into public.application_status_events(application_id,from_status,to_status,actor_user_id)
      values(new_id,null,'draft',actor);
    perform private.record_camp_user_audit(new_id,'create_camp_draft',null,null,actor);
  end if;
  return new_id;
end; $$;

-- Preserve the existing submission algorithm and public wrapper. Only the
-- eligibility branch changes for eligible_roster camps.
create or replace function private.submit_camp_application(target_application_id uuid)
returns table(submitted_application_id uuid,reception_number text,submission_time timestamptz)
language plpgsql security definer set search_path='' as $$
declare current_user_id uuid:=auth.uid(); current_email text:=lower(auth.jwt()->>'email');
  application_record public.applications%rowtype; camp_record public.camps%rowtype; previous_status text;
  submitted_count integer; fiscal_year_value integer; serial_number_value integer;
  reception_number_value text; charge_id_value uuid; total_amount_value integer; submission_time_value timestamptz;
begin
  if current_user_id is null or not private.has_active_profile() then raise exception 'ログインが必要です。'; end if;
  perform guard.id from public.facility_guard guard where guard.id=1 for update;
  select * into application_record from public.applications a where a.id=target_application_id for update;
  if not found or application_record.user_id<>current_user_id then raise exception '申請が見つかりません。'; end if;
  if application_record.status='submitted' then
    select n.display_number into reception_number_value from public.reception_numbers n where n.application_id=target_application_id;
    return query select application_record.id,reception_number_value,application_record.last_submitted_at; return;
  end if;
  if application_record.status not in ('draft','revision_requested') then raise exception '現在の状態では申請を提出できません。'; end if;
  select * into camp_record from public.camps c where c.id=application_record.camp_id and c.deleted_at is null for update;
  if not found then raise exception '対象のキャンプが見つかりません。'; end if;
  submission_time_value:=clock_timestamp();
  if application_record.status='draft' then
    if submission_time_value>=camp_record.application_deadline then raise exception 'このキャンプの申請期限を過ぎています。'; end if;
  else
    if application_record.revision_due_at is null then raise exception '修正期限が設定されていません。町へお問い合わせください。'; end if;
    if submission_time_value>=application_record.revision_due_at then raise exception '修正期限を過ぎています。'; end if;
    if (application_record.start_date,application_record.end_date) is distinct from (camp_record.start_date,camp_record.end_date) then
      raise exception 'キャンプ期間が変更されているため再提出できません。町へお問い合わせください。'; end if;
  end if;
  if camp_record.room_assignment_mode='legacy_application' then
    if not exists(select 1 from public.camp_eligible_users e where e.camp_id=camp_record.id
      and e.disabled_at is null and e.email_normalized=current_email) then
      raise exception 'このキャンプの申請対象者ではありません。'; end if;
  elsif not exists(select 1 from public.camp_eligible_users e where e.camp_id=camp_record.id
    and e.id=application_record.camp_eligible_user_id and e.disabled_at is null
    and e.participation_status='participating' and e.linked_user_id=current_user_id) then
    raise exception 'このキャンプの申請対象者ではありません。';
  end if;
  if application_record.user_name is null or application_record.user_address is null
    or application_record.user_phone is null or application_record.email_snapshot is null
    or application_record.emergency_name is null or application_record.emergency_address is null
    or application_record.emergency_phone is null or application_record.purpose is null
    or application_record.usage_place<>'common_and_second_floor'
    or application_record.requires_guardian_consent is null or application_record.room_preference is null then
    raise exception '必須項目をすべて入力してください。'; end if;
  if application_record.user_phone!~'^[0-9+][0-9() -]{7,19}$'
    or application_record.emergency_phone!~'^[0-9+][0-9() -]{7,19}$' then raise exception '電話番号の形式を確認してください。'; end if;
  if application_record.requires_guardian_consent then raise exception '保護者同意書が必要な申請は、添付機能の完成後に提出できます。'; end if;
  select count(*) into submitted_count from public.applications a where a.camp_id=camp_record.id
    and a.id<>target_application_id and a.status in ('submitted','under_review','revision_requested','approved','cancellation_requested');
  if submitted_count>=15 then raise exception '施設の定員15人に達しています。'; end if;
  previous_status:=application_record.status;
  update public.applications set status='submitted',start_date=camp_record.start_date,end_date=camp_record.end_date,
    email_snapshot=current_email,submitted_at=coalesce(submitted_at,submission_time_value),
    last_submitted_at=submission_time_value,revision_due_at=null where id=target_application_id;
  select n.display_number into reception_number_value from public.reception_numbers n where n.application_id=target_application_id;
  if reception_number_value is null then
    fiscal_year_value:=extract(year from (submission_time_value at time zone 'Asia/Tokyo')-interval '3 months')::integer;
    insert into public.reception_counters(fiscal_year,last_number) values(fiscal_year_value,0) on conflict(fiscal_year) do nothing;
    update public.reception_counters set last_number=last_number+1,updated_at=submission_time_value
      where fiscal_year=fiscal_year_value returning last_number into serial_number_value;
    reception_number_value:=format('SG-%s-%s',fiscal_year_value,lpad(serial_number_value::text,4,'0'));
    insert into public.reception_numbers(fiscal_year,serial_number,display_number,application_id)
      values(fiscal_year_value,serial_number_value,reception_number_value,target_application_id);
  end if;
  insert into public.application_charges(application_id,total_amount,payment_status,calculated_at)
    values(target_application_id,0,'unpaid',submission_time_value)
    on conflict(application_id) do update set total_amount=0,calculated_at=excluded.calculated_at returning id into charge_id_value;
  delete from public.charge_months where charge_id=charge_id_value;
  insert into public.charge_months(charge_id,month,usage_days,daily_rate,monthly_cap,amount)
  select charge_id_value,month_start::date,
    (least(camp_record.end_date,(month_start+interval '1 month - 1 day')::date)-greatest(camp_record.start_date,month_start::date)+1)::integer,
    300,9000,least((least(camp_record.end_date,(month_start+interval '1 month - 1 day')::date)
      -greatest(camp_record.start_date,month_start::date)+1)::integer*300,9000)
  from generate_series(date_trunc('month',camp_record.start_date::timestamp),
    date_trunc('month',camp_record.end_date::timestamp),interval '1 month') month_start;
  select coalesce(sum(m.amount),0) into total_amount_value from public.charge_months m where m.charge_id=charge_id_value;
  update public.application_charges set total_amount=total_amount_value where id=charge_id_value;
  insert into public.application_status_events(application_id,from_status,to_status,actor_user_id)
    values(target_application_id,previous_status,'submitted',current_user_id);
  return query select target_application_id,reception_number_value,submission_time_value;
end; $$;

create function public.get_staff_camp_roster(target_camp_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.camps%rowtype;
begin
  if auth.uid() is null or not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
  select * into c from public.camps where id=target_camp_id and deleted_at is null;
  if not found then raise exception 'not-found'; end if;
  return jsonb_build_object('camp_id',c.id,'room_assignment_mode',c.room_assignment_mode,
    'roster_version',c.roster_version,'room_plan_version',c.room_plan_version,
    'saved_roster_version',c.saved_roster_version,'roster_label_version',c.roster_label_version,
    'room_plan_committed_at',c.room_plan_committed_at,
    'eligible_users',(select coalesce(jsonb_agg(jsonb_build_object(
      'id',e.id,'management_name',e.management_name,'email_normalized',e.email_normalized,
      'disabled_at',e.disabled_at,'participation_status',e.participation_status,
      'released_at',e.released_at,'release_reason',e.release_reason,'linked_user_id',e.linked_user_id,
      'linked_at',e.linked_at,'linked_email_normalized',e.linked_email_normalized,
      'application_id',a.id,'application_status',a.status,'input_version',a.input_version)
      order by e.management_name nulls last,e.email_normalized,e.id),'[]'::jsonb)
      from public.camp_eligible_users e left join lateral(select x.id,x.status,x.input_version
        from public.applications x where x.camp_id=e.camp_id and x.camp_eligible_user_id=e.id
        order by (x.status not in ('rejected','cancelled')) desc,x.created_at desc,x.id limit 1) a on true
      where e.camp_id=c.id));
end; $$;

create function public.diagnose_camp_roster_migration(target_camp_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.camps%rowtype; items jsonb; blocked text[]:='{}'; review_count integer:=0;
begin
  if auth.uid() is null or not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
  select * into c from public.camps where id=target_camp_id and deleted_at is null;
  if not found then raise exception 'not-found'; end if;
  if exists(select 1 from public.applications a join public.stays s on s.application_id=a.id
    where a.camp_id=c.id and s.status in ('staying','moved_out')) then blocked:=array_append(blocked,'stay-started-or-completed'); end if;
  if exists(select 1 from public.applications a where a.camp_id=c.id and
    (a.start_date is distinct from c.start_date or a.end_date is distinct from c.end_date)) then blocked:=array_append(blocked,'application-period-inconsistent'); end if;
  if (select count(*) from public.applications a where a.camp_id=c.id and a.status not in ('rejected','cancelled'))>15 then
    blocked:=array_append(blocked,'camp-capacity-exceeded'); end if;
  if exists(select 1 from public.applications a left join public.stays s on s.application_id=a.id
    where a.camp_id=c.id and a.status='approved' and s.id is null) then blocked:=array_append(blocked,'approved-stay-missing'); end if;
  if exists(select 1 from public.applications a join public.room_allocations r on r.application_id=a.id
    where a.camp_id=c.id and (r.start_date is distinct from a.start_date or r.end_date is distinct from a.end_date)) then
    blocked:=array_append(blocked,'room-period-inconsistent'); end if;

  with facts as (
    select a.*,nullif(lower(btrim(coalesce(a.email_snapshot,''))),'') snapshot_email,
      private.current_verified_email(a.user_id) current_email,
      se.id snapshot_id,se.disabled_at snapshot_disabled,se.linked_user_id snapshot_owner,
      ce.id current_id,ce.disabled_at current_disabled,ce.linked_user_id current_owner,
      count(*) filter(where a.status not in ('rejected','cancelled')) over(partition by a.user_id) owner_active_count,
      count(*) filter(where a.status not in ('rejected','cancelled'))
        over(partition by coalesce(se.id,ce.id)) candidate_active_count
    from public.applications a
    left join public.camp_eligible_users se on se.camp_id=a.camp_id and se.email_normalized=nullif(lower(btrim(coalesce(a.email_snapshot,''))),'')
    left join auth.users u on u.id=a.user_id
    left join public.camp_eligible_users ce on ce.camp_id=a.camp_id
      and ce.email_normalized=case when u.email_confirmed_at is not null then lower(btrim(u.email)) end
    where a.camp_id=c.id and a.usage_type='camp'
  ), classified as (
    select f.*,
      case
        when f.status in ('rejected','cancelled') then 'legacy_only'
        when f.snapshot_disabled is not null or f.current_disabled is not null then 'staff_review'
        when f.owner_active_count>1 or (coalesce(f.snapshot_id,f.current_id) is not null and f.candidate_active_count>1) then 'staff_review'
        when f.snapshot_id is not null and f.current_id is not null and f.snapshot_id<>f.current_id then 'staff_review'
        when f.snapshot_email is not null and f.snapshot_id is not null and f.user_id is not null
          and f.current_email=f.snapshot_email and (f.snapshot_owner is null or f.snapshot_owner=f.user_id) then 'auto_link_candidate'
        when f.snapshot_email is null and f.status='draft' and f.current_id is not null and f.user_id is not null
          and (f.current_owner is null or f.current_owner=f.user_id) then 'conditional_link_candidate'
        else 'staff_review' end classification,
      case
        when f.status in ('rejected','cancelled') then array['terminal-application']::text[]
        when f.snapshot_disabled is not null or f.current_disabled is not null then array['disabled-eligible-with-open-application']::text[]
        when f.owner_active_count>1 or (coalesce(f.snapshot_id,f.current_id) is not null and f.candidate_active_count>1)
          then array['multiple-active-applications']::text[]
        when f.snapshot_id is not null and f.current_id is not null and f.snapshot_id<>f.current_id then array['snapshot-current-target-conflict']::text[]
        when f.snapshot_email is not null and f.snapshot_id is not null and f.current_email=f.snapshot_email
          and (f.snapshot_owner is null or f.snapshot_owner=f.user_id) then array['snapshot-unique-owner-consistent']::text[]
        when f.snapshot_email is null and f.status='draft' and f.current_id is not null
          and (f.current_owner is null or f.current_owner=f.user_id) then array['empty-draft-current-confirmed-email']::text[]
        when f.snapshot_id is null and f.current_id is null then array['eligible-match-missing']::text[]
        else array['owner-or-candidate-inconsistent']::text[] end reasons
    from facts f
  )
  select coalesce(jsonb_agg(jsonb_build_object('application_id',id,'status',status,
    'classification',classification,'candidate_eligible_user_id',case
      when classification='auto_link_candidate' then snapshot_id
      when classification='conditional_link_candidate' then current_id end,
    'reason_codes',reasons,'evidence',jsonb_build_object('has_email_snapshot',snapshot_email is not null,
      'has_current_verified_email',current_email is not null,'snapshot_candidate_id',snapshot_id,
      'current_candidate_id',current_id,'owner_present',user_id is not null)) order by created_at,id),'[]'::jsonb),
    count(*) filter(where classification='staff_review') into items,review_count from classified;
  return jsonb_build_object('camp_id',c.id,'room_assignment_mode',c.room_assignment_mode,
    'mode_changed',false,'disposition',case when cardinality(blocked)>0 then 'switch_blocked'
      when review_count>0 then 'staff_review_required' else 'candidates_only' end,
    'blocking_reason_codes',to_jsonb(blocked),'applications',items);
end; $$;

revoke all on function private.guard_camp_room_assignment_mode(),private.guard_camp_eligible_user_link(),
  private.bump_camp_roster_versions(),private.bump_camp_application_input_version(),
  private.check_camp_roster_application(),private.current_verified_email(uuid)
from public,anon,authenticated,service_role;
revoke all on function public.get_staff_camp_roster(uuid),public.diagnose_camp_roster_migration(uuid)
from public,anon,authenticated,service_role;
grant execute on function public.get_staff_camp_roster(uuid),public.diagnose_camp_roster_migration(uuid) to authenticated;
revoke all on function private.submit_camp_application(uuid) from public,anon,authenticated,service_role;

commit;
