-- Phase 1 / T13 only. Apply after 001-014. No fee recalculation or stay changes.
begin;
select private.lock_calendar_facility();

create function public.update_application_payment(
  target_application_id uuid, expected_updated_at timestamptz,
  target_payment_status text, target_payment_due_date date,
  change_reason text default null
)
returns table(result_id uuid, result_usage_type text, result_camp_id uuid, result_updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare a public.applications%rowtype; c public.application_charges%rowtype;
  before_value jsonb; reason_value text := nullif(btrim(change_reason),'');
begin
  -- Same lock order as existing staff review and room operations.
  perform private.lock_calendar_for_staff();
  select * into a from public.applications where id=target_application_id
    and usage_type in ('camp','community_individual') and original_application_id is null for update;
  if not found then raise exception 'not-found'; end if;
  perform private.check_calendar_version(a.updated_at,expected_updated_at);
  if a.status='draft' or a.submitted_at is null then raise exception 'invalid-status'; end if;
  if target_payment_status is null or target_payment_status not in ('unpaid','paid') then raise exception 'invalid-payment-status'; end if;
  if target_payment_due_date is not null and (not isfinite(target_payment_due_date)
    or target_payment_due_date < date '0001-01-01' or target_payment_due_date > date '9999-12-31') then
    raise exception 'invalid-payment-deadline'; end if;
  if char_length(reason_value)>2000 then raise exception 'reason-too-long'; end if;
  select * into c from public.application_charges where application_id=a.id for update;
  if not found then raise exception 'charge-not-found'; end if;
  if c.payment_status='paid' and target_payment_status='unpaid' and reason_value is null then
    raise exception 'reason-required'; end if;
  if (c.payment_status,c.payment_due_date) is not distinct from (target_payment_status,target_payment_due_date) then
    return query select a.id,a.usage_type,a.camp_id,a.updated_at;
    return;
  end if;
  before_value:=jsonb_build_object('charge',to_jsonb(c),'application_updated_at',a.updated_at);
  update public.application_charges set payment_status=target_payment_status,
    payment_due_date=target_payment_due_date,
    paid_at=case when target_payment_status='unpaid' then null
      when c.payment_status='paid' then c.paid_at else clock_timestamp() end
    where id=c.id returning * into c;
  update public.applications set updated_at=clock_timestamp() where id=a.id returning * into a;
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id,reason)
  values('application',a.id,'update_payment',before_value,
    jsonb_build_object('charge',to_jsonb(c),'application_updated_at',a.updated_at),'staff',auth.uid(),reason_value);
  return query select a.id,a.usage_type,a.camp_id,a.updated_at;
end; $$;

-- One read-only snapshot pairs the payment with the parent version.
-- Return only public payment fields; reasons and staff identities remain in audit_logs.
create function public.get_application_payment(target_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.applications%rowtype; charge_value jsonb;
begin
  if auth.uid() is null or not private.has_active_profile() then
    raise exception using errcode='42501',message='active-user-required'; end if;
  select * into a from public.applications where id=target_application_id
    and usage_type in ('camp','community_individual') and original_application_id is null
    and (user_id=auth.uid() or private.is_staff());
  if not found then raise exception 'not-found'; end if;
  select jsonb_build_object('total_amount',c.total_amount,'payment_status',c.payment_status,
    'payment_due_date',c.payment_due_date,'paid_at',c.paid_at,
    'months',(select coalesce(jsonb_agg(jsonb_build_object('month',m.month,'usage_days',m.usage_days,
      'daily_rate',m.daily_rate,'monthly_cap',m.monthly_cap,'amount',m.amount) order by m.month),'[]'::jsonb)
      from public.charge_months m where m.charge_id=c.id)) into charge_value
    from public.application_charges c where c.application_id=a.id;
  return jsonb_build_object('id',a.id,'usage_type',a.usage_type,'camp_id',a.camp_id,
    'status',a.status,'updated_at',a.updated_at,'charge',charge_value);
end; $$;

revoke all on function public.update_application_payment(uuid,timestamptz,text,date,text),
  public.get_application_payment(uuid) from public,anon,authenticated,service_role;
grant execute on function public.update_application_payment(uuid,timestamptz,text,date,text),
  public.get_application_payment(uuid) to authenticated;
commit;
