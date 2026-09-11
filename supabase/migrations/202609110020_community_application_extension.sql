-- T17 second half: consecutive extension applications for community individuals.
-- Apply once after 019. Each extension is a separate application, charge,
-- receipt, room allocation, review and stay record linked to one original.
begin;
select private.lock_calendar_facility();

create unique index applications_one_active_extension_per_original
on public.applications(original_application_id)
where original_application_id is not null and status not in ('rejected','cancelled');

create function private.check_community_extension_row()
returns trigger language plpgsql security definer set search_path = '' as $$
declare parent public.applications%rowtype;
begin
  if new.original_application_id is null then return new; end if;
  select * into parent from public.applications where id=new.original_application_id for share;
  if not found or parent.usage_type<>'community_individual' or parent.original_application_id is not null
    or new.usage_type<>'community_individual' or new.user_id is distinct from parent.user_id
    or new.camp_id is not null then raise exception 'invalid-extension'; end if;
  if new.start_date is distinct from parent.end_date+1 then raise exception 'invalid-extension-period'; end if;
  if char_length(nullif(btrim(new.extension_reason),''))>2000 then raise exception 'reason-too-long'; end if;
  if new.status<>'draft' and nullif(btrim(new.extension_reason),'') is null then raise exception 'reason-required'; end if;
  if new.status='submitted' and parent.status<>'approved' then raise exception 'extension-not-available'; end if;
  return new;
end; $$;
create trigger applications_check_community_extension
before insert or update of original_application_id,user_id,usage_type,camp_id,start_date,end_date,status,extension_reason
on public.applications for each row execute function private.check_community_extension_row();

create function public.get_community_application_extension_source(target_original_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.applications%rowtype; s public.stays%rowtype; existing_id uuid;
  today_jst date:=(statement_timestamp() at time zone 'Asia/Tokyo')::date; starts_on date;
begin
  if auth.uid() is null or not private.has_active_profile() then
    raise exception using errcode='42501',message='active-user-required'; end if;
  select * into a from public.applications where id=target_original_application_id
    and user_id=auth.uid() and usage_type='community_individual' and original_application_id is null;
  if not found then raise exception 'not-found'; end if;
  select * into s from public.stays where application_id=a.id;
  select id into existing_id from public.applications where original_application_id=a.id
    and status not in ('rejected','cancelled') order by created_at,id limit 1;
  starts_on:=a.end_date+1;
  return jsonb_build_object('id',a.id,'status',a.status,'end_date',a.end_date,
    'stay_status',s.status,'extension_start_date',starts_on,'existing_extension_id',existing_id,
    'can_extend',a.status='approved' and s.status in ('before_move_in','staying')
      and existing_id is null and starts_on between today_jst+14 and today_jst+59);
end; $$;

create function public.create_community_application_extension(
  target_extension_id uuid,target_original_application_id uuid,target_end_date date,extension_reason_value text
)
returns table(result_id uuid,result_updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare actor uuid:=private.lock_community_user(); parent public.applications%rowtype;
  child public.applications%rowtype; s public.stays%rowtype; starts_on date;
  reason_value text:=nullif(btrim(extension_reason_value),''); moment timestamptz:=clock_timestamp();
begin
  if target_extension_id is null or target_original_application_id is null then raise exception 'invalid-application'; end if;
  select * into child from public.applications where id=target_extension_id for update;
  if found then
    if child.user_id is distinct from actor or child.original_application_id is distinct from target_original_application_id
      or child.usage_type<>'community_individual' then raise exception 'not-found'; end if;
    return query select child.id,child.updated_at; return;
  end if;
  select * into parent from public.applications where id=target_original_application_id
    and user_id=actor and usage_type='community_individual' and original_application_id is null for update;
  if not found then raise exception 'not-found'; end if;
  select * into s from public.stays where application_id=parent.id for update;
  if parent.status<>'approved' or s.id is null or s.status not in ('before_move_in','staying') then
    raise exception 'extension-not-available'; end if;
  perform private.check_calendar_reason(reason_value);
  starts_on:=parent.end_date+1;
  perform private.check_community_period(starts_on,target_end_date,moment,true);
  if exists(select 1 from public.applications where original_application_id=parent.id
    and status not in ('rejected','cancelled')) then raise exception 'extension-exists'; end if;
  insert into public.applications(id,user_id,usage_type,original_application_id,status,start_date,end_date,
    user_name,user_address,user_phone,emergency_name,emergency_address,emergency_phone,usage_place,
    purpose,local_activity,special_notes,requires_guardian_consent,extension_reason)
  select target_extension_id,actor,'community_individual',parent.id,'draft',starts_on,target_end_date,
    p.full_name,p.address,p.phone,p.emergency_name,p.emergency_address,p.emergency_phone,'common_and_second_floor',
    parent.purpose,parent.local_activity,parent.special_notes,parent.requires_guardian_consent,reason_value
  from public.profiles p where p.id=actor;
  insert into public.application_status_events(application_id,to_status,actor_user_id,occurred_at)
  values(target_extension_id,'draft',actor,moment);
  perform private.community_audit(target_extension_id,'create_community_extension','{}',actor,'user',reason_value);
  return query select a.id,a.updated_at from public.applications a where a.id=target_extension_id;
exception when unique_violation then raise exception 'extension-exists';
end; $$;

-- Extensions use the same staff review and room allocation pipeline.
create or replace function private.lock_community_application_for_staff(target_id uuid,expected_version timestamptz)
returns public.applications language plpgsql security definer set search_path = '' as $$
declare a public.applications%rowtype;
begin
  perform private.lock_calendar_for_staff();
  select * into a from public.applications where id=target_id and usage_type='community_individual' for update;
  if not found then raise exception 'not-found'; end if;
  perform private.check_calendar_version(a.updated_at,expected_version);
  return a;
end; $$;

create or replace function public.get_staff_community_application_room_context(target_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.applications%rowtype;
begin
  if auth.uid() is null or not private.is_staff() then
    raise exception using errcode='42501',message='staff-required'; end if;
  select * into a from public.applications where id=target_application_id and usage_type='community_individual';
  if not found then raise exception 'not-found'; end if;
  return jsonb_build_object('id',a.id,'status',a.status,'updated_at',a.updated_at,
    'start_date',a.start_date,'end_date',a.end_date,'approval_comment',a.approval_comment,
    'original_application_id',a.original_application_id,
    'rooms',(select jsonb_agg(jsonb_build_object('id',id,'name',name,'capacity',capacity) order by name) from public.rooms))
    || private.community_room_result(a.id);
end; $$;

-- Extend the existing payment contract without changing its signature.
create or replace function public.update_application_payment(target_application_id uuid,expected_updated_at timestamptz,
  target_payment_status text,target_payment_due_date date,change_reason text default null)
returns table(result_id uuid,result_usage_type text,result_camp_id uuid,result_updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare a public.applications%rowtype; c public.application_charges%rowtype;
  before_value jsonb; reason_value text:=nullif(btrim(change_reason),'');
begin
  perform private.lock_calendar_for_staff();
  select * into a from public.applications where id=target_application_id
    and usage_type in ('camp','community_individual') for update;
  if not found then raise exception 'not-found'; end if;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if a.status='draft' or a.submitted_at is null then raise exception 'invalid-status'; end if;
  if target_payment_status is null or target_payment_status not in ('unpaid','paid') then raise exception 'invalid-payment-status'; end if;
  if target_payment_due_date is not null and (not isfinite(target_payment_due_date)
    or target_payment_due_date not between date '0001-01-01' and date '9999-12-31') then raise exception 'invalid-payment-deadline'; end if;
  if char_length(reason_value)>2000 then raise exception 'reason-too-long'; end if;
  select * into c from public.application_charges where application_id=a.id for update;
  if not found then raise exception 'charge-not-found'; end if;
  if c.payment_status='paid' and target_payment_status='unpaid' and reason_value is null then raise exception 'reason-required'; end if;
  if (c.payment_status,c.payment_due_date) is not distinct from (target_payment_status,target_payment_due_date) then
    return query select a.id,a.usage_type,a.camp_id,a.updated_at; return; end if;
  before_value:=jsonb_build_object('charge',to_jsonb(c),'application_updated_at',a.updated_at);
  update public.application_charges set payment_status=target_payment_status,payment_due_date=target_payment_due_date,
    paid_at=case when target_payment_status='unpaid' then null when c.payment_status='paid' then c.paid_at else clock_timestamp() end
    where id=c.id returning * into c;
  update public.applications set updated_at=clock_timestamp() where id=a.id returning * into a;
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id,reason)
  values('application',a.id,'update_payment',before_value,
    jsonb_build_object('charge',to_jsonb(c),'application_updated_at',a.updated_at),'staff',auth.uid(),reason_value);
  return query select a.id,a.usage_type,a.camp_id,a.updated_at;
end; $$;

create or replace function public.get_application_payment(target_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.applications%rowtype; charge_value jsonb;
begin
  if auth.uid() is null or not private.has_active_profile() then
    raise exception using errcode='42501',message='active-user-required'; end if;
  select * into a from public.applications where id=target_application_id
    and usage_type in ('camp','community_individual') and (user_id=auth.uid() or private.is_staff());
  if not found then raise exception 'not-found'; end if;
  select jsonb_build_object('total_amount',c.total_amount,'payment_status',c.payment_status,
    'payment_due_date',c.payment_due_date,'paid_at',c.paid_at,
    'months',(select coalesce(jsonb_agg(jsonb_build_object('month',m.month,'usage_days',m.usage_days,
      'daily_rate',m.daily_rate,'monthly_cap',m.monthly_cap,'amount',m.amount) order by m.month),'[]'::jsonb)
      from public.charge_months m where m.charge_id=c.id)) into charge_value
  from public.application_charges c where c.application_id=a.id;
  return jsonb_build_object('id',a.id,'usage_type',a.usage_type,'camp_id',a.camp_id,
    'original_application_id',a.original_application_id,'status',a.status,'updated_at',a.updated_at,'charge',charge_value);
end; $$;

-- Cancellation also applies to an extension before its stay starts.
create or replace function public.request_community_application_cancellation(target_application_id uuid,
  expected_updated_at timestamptz,cancellation_reason text)
returns table(result_id uuid,result_status text,result_updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare actor uuid; a public.applications%rowtype; s public.stays%rowtype; prior_status text;
  reason_value text:=nullif(btrim(cancellation_reason),''); before_value jsonb; moment timestamptz;
begin
  actor:=private.lock_community_user();
  select * into a from public.applications where id=target_application_id
    and usage_type='community_individual' for update;
  if not found or a.user_id is distinct from actor then raise exception 'not-found'; end if;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if a.status not in ('submitted','under_review','revision_requested','approved') then raise exception 'invalid-status'; end if;
  perform private.check_calendar_reason(reason_value);
  select * into s from public.stays where application_id=a.id for update;
  if a.status='approved' then
    if s.id is null then raise exception 'invalid-stay'; end if;
    if s.status<>'before_move_in' then raise exception 'stay-started'; end if;
  elsif s.id is not null then raise exception 'invalid-stay'; end if;
  before_value:=private.community_cancellation_snapshot(a.id); prior_status:=a.status; moment:=clock_timestamp();
  update public.applications set status='cancellation_requested',cancel_reason=reason_value where id=a.id returning * into a;
  insert into public.application_status_events(application_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
  values(a.id,prior_status,'cancellation_requested',reason_value,actor,moment);
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id,reason)
  values('application',a.id,'request_cancellation',before_value,private.community_cancellation_snapshot(a.id),'user',actor,reason_value);
  return query select a.id,a.status,a.updated_at;
end; $$;

create or replace function public.get_community_application_cancellation(target_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.applications%rowtype; s public.stays%rowtype; staff_actor boolean;
begin
  if auth.uid() is null or not private.has_active_profile() then
    raise exception using errcode='42501',message='active-user-required'; end if;
  staff_actor:=private.is_staff();
  select * into a from public.applications where id=target_application_id and usage_type='community_individual'
    and (user_id=auth.uid() or staff_actor);
  if not found then raise exception 'not-found'; end if;
  select * into s from public.stays where application_id=a.id;
  return jsonb_build_object('id',a.id,'status',a.status,'updated_at',a.updated_at,
    'start_date',a.start_date,'end_date',a.end_date,'cancel_reason',a.cancel_reason,'stay_status',s.status,
    'can_request',not staff_actor and a.user_id=auth.uid()
      and a.status in ('submitted','under_review','revision_requested','approved')
      and (a.status<>'approved' or s.status='before_move_in'),
    'can_confirm',staff_actor and a.status='cancellation_requested');
end; $$;

-- Staff search and private notes treat an extension as its own application.
create or replace function public.save_application_staff_note(target_application_id uuid, expected_updated_at timestamptz,
  target_note_id uuid, note_body text)
returns table(result_id uuid,result_usage_type text,result_camp_id uuid,result_updated_at timestamptz,result_note_id uuid)
language plpgsql security definer set search_path = '' as $$
declare a public.applications%rowtype; n public.staff_notes%rowtype; before_value jsonb;
  body_value text:=nullif(btrim(note_body),'');
begin
  perform private.lock_calendar_for_staff();
  select * into a from public.applications where id=target_application_id
    and usage_type in ('camp','community_individual') for update;
  if not found then raise exception 'not-found'; end if;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if body_value is null then raise exception 'note-required'; end if;
  if char_length(body_value)>2000 then raise exception 'note-too-long'; end if;
  if target_note_id is not null then
    select * into n from public.staff_notes where id=target_note_id and application_id=a.id for update;
    if not found then raise exception 'note-not-found'; end if;
    if n.body=body_value then return query select a.id,a.usage_type,a.camp_id,a.updated_at,n.id; return; end if;
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

create or replace function public.get_staff_application_notes(target_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.applications%rowtype;
begin
  if auth.uid() is null or not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
  select * into a from public.applications where id=target_application_id and usage_type in ('camp','community_individual');
  if not found then raise exception 'not-found'; end if;
  return jsonb_build_object('id',a.id,'usage_type',a.usage_type,'camp_id',a.camp_id,
    'original_application_id',a.original_application_id,'updated_at',a.updated_at,
    'notes',(select coalesce(jsonb_agg(jsonb_build_object('id',n.id,'body',n.body,'author_user_id',n.author_user_id,
      'created_at',n.created_at,'updated_at',n.updated_at) order by n.created_at,n.id),'[]'::jsonb)
      from public.staff_notes n where n.application_id=a.id));
end; $$;

create or replace function public.search_staff_applications(search_text text,usage_type_filter text,
  application_status_filter text,payment_status_filter text,stay_status_filter text,
  starts_from date,ends_to date,page_number integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare query_value text:=nullif(btrim(search_text),''); escaped_query text;
  today_jst date:=(statement_timestamp() at time zone 'Asia/Tokyo')::date; result_value jsonb;
begin
  if auth.uid() is null or not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
  if query_value is not null and char_length(query_value)>100 then raise exception 'invalid-query'; end if;
  if usage_type_filter is not null and usage_type_filter not in ('camp','community_individual') then raise exception 'invalid-usage-type'; end if;
  if application_status_filter is not null and application_status_filter not in
    ('draft','submitted','under_review','revision_requested','approved','rejected','cancellation_requested','cancelled')
    then raise exception 'invalid-application-status'; end if;
  if payment_status_filter is not null and payment_status_filter not in ('unpaid','overdue','paid') then raise exception 'invalid-payment-status'; end if;
  if stay_status_filter is not null and stay_status_filter not in ('before_move_in','staying','moved_out') then raise exception 'invalid-stay-status'; end if;
  if (starts_from is not null and not isfinite(starts_from)) or (ends_to is not null and not isfinite(ends_to))
    or (starts_from is not null and ends_to is not null and starts_from>ends_to) then raise exception 'invalid-period'; end if;
  if page_number is null or page_number<1 or page_number>10000 then raise exception 'invalid-page'; end if;
  escaped_query:=replace(replace(replace(lower(query_value),'\','\\'),'%','\%'),'_','\_');
  with matched as materialized (
    select application.id,application.usage_type,application.camp_id,application.original_application_id,
      application.user_name as applicant_name,camp.name as camp_name,application.status,
      application.start_date,application.end_date,reception.display_number as reception_number,1 as people_count,
      charge.total_amount,case when charge.payment_status='paid' then 'paid'
        when charge.payment_status='unpaid' and charge.payment_due_date is not null and charge.payment_due_date<today_jst then 'overdue'
        else charge.payment_status end as payment_status,charge.payment_due_date,stay.status as stay_status,
      application.updated_at,application.created_at,
      case when application.usage_type='camp' then '/staff/camps/'||application.camp_id::text||'/applications/'||application.id::text
        else '/staff/community/applications/'||application.id::text end as detail_path
    from public.applications application
    left join public.camps camp on camp.id=application.camp_id
    left join public.reception_numbers reception on reception.application_id=application.id
    left join public.application_charges charge on charge.application_id=application.id
    left join public.stays stay on stay.application_id=application.id
    where application.usage_type in ('camp','community_individual')
      and (usage_type_filter is null or application.usage_type=usage_type_filter)
      and (application_status_filter is null or application.status=application_status_filter)
      and (payment_status_filter is null or (payment_status_filter='paid' and charge.payment_status='paid')
        or (payment_status_filter='overdue' and charge.payment_status='unpaid' and charge.payment_due_date is not null and charge.payment_due_date<today_jst)
        or (payment_status_filter='unpaid' and charge.payment_status='unpaid' and (charge.payment_due_date is null or charge.payment_due_date>=today_jst)))
      and (stay_status_filter is null or stay.status=stay_status_filter)
      and (starts_from is null or application.end_date>=starts_from) and (ends_to is null or application.start_date<=ends_to)
      and (query_value is null or lower(coalesce(application.user_name,'')) like '%'||escaped_query||'%' escape '\'
        or lower(coalesce(reception.display_number,'')) like '%'||escaped_query||'%' escape '\'
        or lower(coalesce(camp.name,'')) like '%'||escaped_query||'%' escape '\')
  ), paged as (select * from matched order by created_at desc,id desc limit 50 offset ((page_number-1)*50))
  select jsonb_build_object('page',page_number,'page_size',50,'total_count',(select count(*) from matched),
    'has_next',(page_number::bigint*50)<(select count(*) from matched),
    'items',coalesce((select jsonb_agg(to_jsonb(item)-'created_at' order by item.created_at desc,item.id desc) from paged item),'[]'::jsonb))
  into result_value;
  return result_value;
end; $$;

-- Extend the existing stay contract without changing its signature.
create or replace function public.update_application_stay(target_application_id uuid,expected_updated_at timestamptz,stay_action text)
returns table(result_id uuid,result_usage_type text,result_camp_id uuid,
  result_updated_at timestamptz,result_status text,result_released_from date)
language plpgsql security definer set search_path = '' as $$
declare a public.applications%rowtype; s public.stays%rowtype; r public.room_allocations%rowtype;
  q public.calendar_claims%rowtype; moment timestamptz; today_jst date; release_date date; before_value jsonb;
begin
  perform private.lock_calendar_for_staff();
  select * into a from public.applications where id=target_application_id
    and usage_type in ('camp','community_individual') for update;
  if not found then raise exception 'not-found'; end if;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if a.status<>'approved' or a.submitted_at is null then raise exception 'invalid-status'; end if;
  if stay_action is null or stay_action not in ('check_in','check_out') then raise exception 'invalid-action'; end if;
  select * into s from public.stays where application_id=a.id for update;
  if not found then raise exception 'invalid-stay'; end if;
  if s.status='moved_out' then raise exception 'stay-completed'; end if;
  if (stay_action='check_in' and s.status<>'before_move_in')
    or (stay_action='check_out' and s.status<>'staying') then raise exception 'invalid-stay'; end if;
  select * into r from public.room_allocations where application_id=a.id for update;
  if not found or r.people_count<>1 or r.start_date is distinct from a.start_date
    or r.end_date is distinct from a.end_date or r.released_from is not null then raise exception 'invalid-allocation'; end if;
  if a.usage_type='community_individual' then
    select * into q from public.calendar_claims where application_id=a.id for update;
    if not found or q.claim_type<>'individual' or q.start_date is distinct from a.start_date
      or q.end_date is distinct from a.end_date or q.released_from is not null then raise exception 'calendar-inconsistent'; end if;
  end if;
  moment:=clock_timestamp(); today_jst:=(moment at time zone 'Asia/Tokyo')::date;
  if stay_action='check_in' then
    if a.usage_type='camp' then
      perform private.check_camp_calendar(a.camp_id); perform private.check_camp_room_capacity(a.id,r.room_id);
    else perform private.check_community_room_capacity(a.id,r.room_id); end if;
    moment:=clock_timestamp(); today_jst:=(moment at time zone 'Asia/Tokyo')::date;
    if today_jst<a.start_date or today_jst>a.end_date then raise exception 'outside-stay-period'; end if;
  elsif s.checked_in_at is null or s.checked_in_at>moment
    or (s.checked_in_at at time zone 'Asia/Tokyo')::date<a.start_date
    or (s.checked_in_at at time zone 'Asia/Tokyo')::date>a.end_date then raise exception 'invalid-stay'; end if;
  before_value:=private.application_stay_snapshot(a.id);
  if stay_action='check_in' then
    update public.stays set status='staying',checked_in_at=moment where id=s.id returning * into s;
  else
    release_date:=least(today_jst+1,a.end_date+1);
    update public.stays set status='moved_out',checked_out_at=moment where id=s.id returning * into s;
    update public.room_allocations set released_from=release_date where id=r.id;
    if a.usage_type='community_individual' then update public.calendar_claims set released_from=release_date where id=q.id; end if;
  end if;
  update public.applications set updated_at=clock_timestamp() where id=a.id returning * into a;
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id)
  values('application',a.id,stay_action,before_value,private.application_stay_snapshot(a.id),'staff',auth.uid());
  return query select a.id,a.usage_type,a.camp_id,a.updated_at,s.status,release_date;
end; $$;

create or replace function public.get_application_stay(target_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.applications%rowtype;
begin
  if auth.uid() is null or not private.has_active_profile() then
    raise exception using errcode='42501',message='active-user-required'; end if;
  select * into a from public.applications where id=target_application_id
    and usage_type in ('camp','community_individual') and (user_id=auth.uid() or private.is_staff());
  if not found then raise exception 'not-found'; end if;
  return jsonb_build_object('id',a.id,'usage_type',a.usage_type,'camp_id',a.camp_id,
    'original_application_id',a.original_application_id,'status',a.status,'updated_at',a.updated_at,
    'start_date',a.start_date,'end_date',a.end_date) || private.community_room_result(a.id);
end; $$;

revoke all on function private.check_community_extension_row(),private.lock_community_application_for_staff(uuid,timestamptz)
from public,anon,authenticated,service_role;
revoke all on function public.get_community_application_extension_source(uuid),
  public.create_community_application_extension(uuid,uuid,date,text),
  public.get_staff_community_application_room_context(uuid),
  public.update_application_payment(uuid,timestamptz,text,date,text),public.get_application_payment(uuid),
  public.update_application_stay(uuid,timestamptz,text),public.get_application_stay(uuid),
  public.save_application_staff_note(uuid,timestamptz,uuid,text),public.get_staff_application_notes(uuid),
  public.search_staff_applications(text,text,text,text,text,date,date,integer),
  public.request_community_application_cancellation(uuid,timestamptz,text),
  public.get_community_application_cancellation(uuid)
from public,anon,authenticated,service_role;
grant execute on function public.get_community_application_extension_source(uuid),
  public.create_community_application_extension(uuid,uuid,date,text),
  public.get_staff_community_application_room_context(uuid),
  public.update_application_payment(uuid,timestamptz,text,date,text),public.get_application_payment(uuid),
  public.update_application_stay(uuid,timestamptz,text),public.get_application_stay(uuid),
  public.save_application_staff_note(uuid,timestamptz,uuid,text),public.get_staff_application_notes(uuid),
  public.search_staff_applications(text,text,text,text,text,date,date,integer),
  public.request_community_application_cancellation(uuid,timestamptz,text),
  public.get_community_application_cancellation(uuid)
to authenticated;
commit;
