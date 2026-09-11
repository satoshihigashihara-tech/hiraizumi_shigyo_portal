-- T17 first half: cancellation for community individual applications only.
-- Apply once after 018. Cancellation requests retain reservations; staff
-- confirmation releases them while preserving fees, stays and history.
begin;
select private.lock_calendar_facility();

create function private.community_cancellation_snapshot(target_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'application',(select jsonb_build_object('id',a.id,'usage_type',a.usage_type,
      'status',a.status,'start_date',a.start_date,'end_date',a.end_date,
      'cancel_reason',a.cancel_reason,'updated_at',a.updated_at)
      from public.applications a where a.id=target_id),
    'claim',(select jsonb_build_object('id',q.id,'start_date',q.start_date,
      'end_date',q.end_date,'released_from',q.released_from)
      from public.calendar_claims q where q.application_id=target_id),
    'room',(select jsonb_build_object('id',r.id,'room_id',r.room_id,
      'start_date',r.start_date,'end_date',r.end_date,'released_from',r.released_from)
      from public.room_allocations r where r.application_id=target_id),
    'stay',(select jsonb_build_object('id',s.id,'status',s.status,
      'checked_in_at',s.checked_in_at,'checked_out_at',s.checked_out_at)
      from public.stays s where s.application_id=target_id),
    'charge',(select jsonb_build_object('id',c.id,'total_amount',c.total_amount,
      'payment_status',c.payment_status,'payment_due_date',c.payment_due_date,'paid_at',c.paid_at)
      from public.application_charges c where c.application_id=target_id));
$$;

create function public.request_community_application_cancellation(
  target_application_id uuid, expected_updated_at timestamptz, cancellation_reason text
)
returns table(result_id uuid, result_status text, result_updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare actor uuid; a public.applications%rowtype; s public.stays%rowtype; prior_status text;
  reason_value text:=nullif(btrim(cancellation_reason),''); before_value jsonb; moment timestamptz;
begin
  actor:=private.lock_community_user();
  select * into a from public.applications where id=target_application_id
    and usage_type='community_individual' and original_application_id is null for update;
  if not found or a.user_id is distinct from actor then raise exception 'not-found'; end if;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if a.status not in ('submitted','under_review','revision_requested','approved') then
    raise exception 'invalid-status'; end if;
  perform private.check_calendar_reason(reason_value);
  select * into s from public.stays where application_id=a.id for update;
  if a.status='approved' then
    if s.id is null then raise exception 'invalid-stay'; end if;
    if s.status<>'before_move_in' then raise exception 'stay-started'; end if;
  elsif s.id is not null then raise exception 'invalid-stay';
  end if;
  before_value:=private.community_cancellation_snapshot(a.id);
  prior_status:=a.status;
  moment:=clock_timestamp();
  update public.applications set status='cancellation_requested',cancel_reason=reason_value
  where id=a.id returning * into a;
  insert into public.application_status_events(application_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
  values(a.id,prior_status,'cancellation_requested',reason_value,actor,moment);
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id,reason)
  values('application',a.id,'request_cancellation',before_value,
    private.community_cancellation_snapshot(a.id),'user',actor,reason_value);
  return query select a.id,a.status,a.updated_at;
end; $$;

create function public.confirm_community_application_cancellation(
  target_application_id uuid, expected_updated_at timestamptz, confirmation_reason text
)
returns table(result_id uuid, result_status text, result_updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare a public.applications%rowtype; q public.calendar_claims%rowtype;
  r public.room_allocations%rowtype; s public.stays%rowtype;
  reason_value text:=nullif(btrim(confirmation_reason),''); before_value jsonb; moment timestamptz;
begin
  a:=private.lock_community_application_for_staff(target_application_id,expected_updated_at);
  if a.status<>'cancellation_requested' then raise exception 'invalid-status'; end if;
  perform private.check_calendar_reason(reason_value);
  select * into s from public.stays where application_id=a.id for update;
  select * into r from public.room_allocations where application_id=a.id for update;
  select * into q from public.calendar_claims where application_id=a.id for update;
  if q.id is null or q.claim_type<>'individual' or q.start_date is distinct from a.start_date
    or q.end_date is distinct from a.end_date or q.released_from is not null then
    raise exception 'calendar-inconsistent'; end if;
  if s.id is not null and s.status<>'before_move_in' then raise exception 'stay-started'; end if;
  if s.id is not null and r.id is null then raise exception 'invalid-allocation'; end if;
  if r.id is not null and (r.people_count<>1 or r.start_date is distinct from a.start_date
    or r.end_date is distinct from a.end_date or r.released_from is not null) then
    raise exception 'invalid-allocation'; end if;
  before_value:=private.community_cancellation_snapshot(a.id);
  moment:=clock_timestamp();
  update public.calendar_claims set released_from=start_date where id=q.id;
  if r.id is not null then update public.room_allocations set released_from=start_date where id=r.id; end if;
  update public.applications set status='cancelled' where id=a.id returning * into a;
  insert into public.application_status_events(application_id,from_status,to_status,public_reason,actor_user_id,occurred_at)
  values(a.id,'cancellation_requested','cancelled',reason_value,auth.uid(),moment);
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id,reason)
  values('application',a.id,'confirm_cancellation',before_value,
    private.community_cancellation_snapshot(a.id),'staff',auth.uid(),reason_value);
  return query select a.id,a.status,a.updated_at;
end; $$;

create function public.get_community_application_cancellation(target_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.applications%rowtype; s public.stays%rowtype; staff_actor boolean;
begin
  if auth.uid() is null or not private.has_active_profile() then
    raise exception using errcode='42501',message='active-user-required'; end if;
  staff_actor:=private.is_staff();
  select * into a from public.applications where id=target_application_id
    and usage_type='community_individual' and original_application_id is null
    and (user_id=auth.uid() or staff_actor);
  if not found then raise exception 'not-found'; end if;
  select * into s from public.stays where application_id=a.id;
  return jsonb_build_object('id',a.id,'status',a.status,'updated_at',a.updated_at,
    'start_date',a.start_date,'end_date',a.end_date,'cancel_reason',a.cancel_reason,
    'stay_status',s.status,
    'can_request',not staff_actor and a.user_id=auth.uid()
      and a.status in ('submitted','under_review','revision_requested','approved')
      and (a.status<>'approved' or s.status='before_move_in'),
    'can_confirm',staff_actor and a.status='cancellation_requested');
end; $$;

revoke all on function private.community_cancellation_snapshot(uuid) from public,anon,authenticated,service_role;
revoke all on function public.request_community_application_cancellation(uuid,timestamptz,text),
  public.confirm_community_application_cancellation(uuid,timestamptz,text),
  public.get_community_application_cancellation(uuid)
from public,anon,authenticated,service_role;
grant execute on function public.request_community_application_cancellation(uuid,timestamptz,text),
  public.confirm_community_application_cancellation(uuid,timestamptz,text),
  public.get_community_application_cancellation(uuid)
to authenticated;
revoke insert,update,delete,truncate,references,trigger on public.applications,
  public.calendar_claims,public.room_allocations,public.stays,
  public.application_status_events,public.audit_logs from public,anon,authenticated;
commit;
