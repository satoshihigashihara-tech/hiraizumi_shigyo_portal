-- T16 MVP: active-staff-only search for the two implemented application types.
-- Group applications are deliberately excluded until their schema exists.
begin;

create function public.search_staff_applications(
  search_text text,
  usage_type_filter text,
  application_status_filter text,
  payment_status_filter text,
  stay_status_filter text,
  starts_from date,
  ends_to date,
  page_number integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  query_value text := nullif(btrim(search_text), '');
  escaped_query text;
  today_jst date := (statement_timestamp() at time zone 'Asia/Tokyo')::date;
  result_value jsonb;
begin
  if auth.uid() is null or not private.is_staff() then
    raise exception using errcode = '42501', message = 'staff-required';
  end if;

  if query_value is not null and char_length(query_value) > 100 then
    raise exception 'invalid-query';
  end if;
  if usage_type_filter is not null
    and usage_type_filter not in ('camp', 'community_individual') then
    raise exception 'invalid-usage-type';
  end if;
  if application_status_filter is not null
    and application_status_filter not in (
      'draft', 'submitted', 'under_review', 'revision_requested',
      'approved', 'rejected', 'cancellation_requested', 'cancelled'
    ) then
    raise exception 'invalid-application-status';
  end if;
  if payment_status_filter is not null
    and payment_status_filter not in ('unpaid', 'overdue', 'paid') then
    raise exception 'invalid-payment-status';
  end if;
  if stay_status_filter is not null
    and stay_status_filter not in ('before_move_in', 'staying', 'moved_out') then
    raise exception 'invalid-stay-status';
  end if;
  if (starts_from is not null and not isfinite(starts_from))
    or (ends_to is not null and not isfinite(ends_to))
    or (starts_from is not null and ends_to is not null and starts_from > ends_to) then
    raise exception 'invalid-period';
  end if;
  if page_number is null or page_number < 1 or page_number > 10000 then
    raise exception 'invalid-page';
  end if;

  -- Treat %, _ and backslash literally. User text is never SQL source text.
  escaped_query := replace(replace(replace(lower(query_value), '\', '\\'), '%', '\%'), '_', '\_');

  with matched as materialized (
    select
      application.id,
      application.usage_type,
      application.camp_id,
      application.user_name as applicant_name,
      camp.name as camp_name,
      application.status,
      application.start_date,
      application.end_date,
      reception.display_number as reception_number,
      1 as people_count,
      charge.total_amount,
      case
        when charge.payment_status = 'paid' then 'paid'
        when charge.payment_status = 'unpaid'
          and charge.payment_due_date is not null
          and charge.payment_due_date < today_jst then 'overdue'
        else charge.payment_status
      end as payment_status,
      charge.payment_due_date,
      stay.status as stay_status,
      application.updated_at,
      application.created_at,
      case
        when application.usage_type = 'camp' then
          '/staff/camps/' || application.camp_id::text || '/applications/' || application.id::text
        else '/staff/community/applications/' || application.id::text
      end as detail_path
    from public.applications as application
    left join public.camps as camp on camp.id = application.camp_id
    left join public.reception_numbers as reception on reception.application_id = application.id
    left join public.application_charges as charge on charge.application_id = application.id
    left join public.stays as stay on stay.application_id = application.id
    where application.usage_type in ('camp', 'community_individual')
      and application.original_application_id is null
      and (usage_type_filter is null or application.usage_type = usage_type_filter)
      and (application_status_filter is null or application.status = application_status_filter)
      and (
        payment_status_filter is null
        or (payment_status_filter = 'paid' and charge.payment_status = 'paid')
        or (payment_status_filter = 'overdue' and charge.payment_status = 'unpaid'
          and charge.payment_due_date is not null and charge.payment_due_date < today_jst)
        or (payment_status_filter = 'unpaid' and charge.payment_status = 'unpaid'
          and (charge.payment_due_date is null or charge.payment_due_date >= today_jst))
      )
      and (stay_status_filter is null or stay.status = stay_status_filter)
      and (starts_from is null or application.end_date >= starts_from)
      and (ends_to is null or application.start_date <= ends_to)
      and (
        query_value is null
        or lower(coalesce(application.user_name, '')) like '%' || escaped_query || '%' escape '\'
        or lower(coalesce(reception.display_number, '')) like '%' || escaped_query || '%' escape '\'
        or lower(coalesce(camp.name, '')) like '%' || escaped_query || '%' escape '\'
      )
  ), paged as (
    select * from matched
    order by created_at desc, id desc
    limit 50 offset ((page_number - 1) * 50)
  )
  select jsonb_build_object(
    'page', page_number,
    'page_size', 50,
    'total_count', (select count(*) from matched),
    'has_next', ((page_number::bigint * 50) < (select count(*) from matched)),
    'items', coalesce((
      select jsonb_agg(
        to_jsonb(item) - 'created_at'
        order by item.created_at desc, item.id desc
      )
      from paged as item
    ), '[]'::jsonb)
  ) into result_value;

  return result_value;
end;
$$;

revoke all on function public.search_staff_applications(
  text, text, text, text, text, date, date, integer
) from public, anon, authenticated, service_role;
grant execute on function public.search_staff_applications(
  text, text, text, text, text, date, date, integer
) to authenticated;

commit;
