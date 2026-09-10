-- MVP phase 6: explicit staff review transitions for camp applications.

create or replace function public.review_camp_application(
  target_application_id uuid,
  review_action text,
  public_reason text default null
)
returns table (
  result_camp_id uuid,
  result_status text,
  result_revision_due_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_staff_id uuid := auth.uid();
  application_record public.applications%rowtype;
  normalized_reason text := nullif(btrim(public_reason), '');
  next_status text;
  revision_due_value timestamptz;
  standard_revision_due timestamptz;
  start_boundary timestamptz;
begin
  if current_staff_id is null or not private.is_staff() then
    raise exception '職員としてログインしてください。';
  end if;

  if review_action not in ('start_review', 'request_revision', 'reject') then
    raise exception '審査操作が正しくありません。';
  end if;

  perform guard.id
  from public.facility_guard as guard
  where guard.id = 1
  for update;

  select application.*
  into application_record
  from public.applications as application
  where application.id = target_application_id
    and application.usage_type = 'camp'
  for update;

  if not found then
    raise exception '対象のキャンプ申請が見つかりません。';
  end if;

  if review_action = 'start_review' then
    if application_record.status <> 'submitted' then
      raise exception '申請済みの申請だけ審査を開始できます。';
    end if;

    next_status := 'under_review';
    normalized_reason := null;
    revision_due_value := null;
  elsif review_action = 'request_revision' then
    if application_record.status <> 'under_review' then
      raise exception '審査中の申請だけ修正依頼できます。';
    end if;

    if normalized_reason is null then
      raise exception '修正理由を入力してください。';
    end if;

    if char_length(normalized_reason) > 2000 then
      raise exception '修正理由は2000文字以内で入力してください。';
    end if;

    standard_revision_due := (
      ((now() at time zone 'Asia/Tokyo')::date + 4)::timestamp
      at time zone 'Asia/Tokyo'
    );
    start_boundary := (
      application_record.start_date::timestamp at time zone 'Asia/Tokyo'
    );
    revision_due_value := least(standard_revision_due, start_boundary);

    if revision_due_value <= now() then
      raise exception '利用開始日時を過ぎているため修正依頼できません。';
    end if;

    next_status := 'revision_requested';
  else
    if application_record.status <> 'under_review' then
      raise exception '審査中の申請だけ不許可にできます。';
    end if;

    if normalized_reason is null then
      raise exception '不許可理由を入力してください。';
    end if;

    if char_length(normalized_reason) > 2000 then
      raise exception '不許可理由は2000文字以内で入力してください。';
    end if;

    next_status := 'rejected';
    revision_due_value := null;
  end if;

  update public.applications
  set
    status = next_status,
    decision_reason = normalized_reason,
    revision_due_at = revision_due_value
  where id = target_application_id;

  insert into public.application_status_events (
    application_id,
    from_status,
    to_status,
    public_reason,
    actor_user_id
  )
  values (
    target_application_id,
    application_record.status,
    next_status,
    normalized_reason,
    current_staff_id
  );

  return query
  select
    application_record.camp_id,
    next_status,
    revision_due_value;
end;
$$;

revoke all on function public.review_camp_application(uuid, text, text)
from public;

grant execute on function public.review_camp_application(uuid, text, text)
to authenticated;
