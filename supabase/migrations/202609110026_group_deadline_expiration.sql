-- T21: atomic expiry for incomplete community groups and a one-minute Supabase Cron job.
begin;
select private.lock_calendar_facility();
create index if not exists group_applications_revision_due_idx on public.group_applications(status,revision_due_at);

create function private.process_due_community_group(target_id uuid,moment timestamptz)
returns text language plpgsql security definer set search_path='' as $$
declare g public.group_applications%rowtype; a public.applications%rowtype; before_g jsonb; before_a jsonb;
  effective text; deadline timestamptz; reason_value text; active_count integer; ready boolean; prior text;
begin
  if moment is null or not isfinite(moment) then raise exception 'invalid-observed-at'; end if;
  select * into g from public.group_applications where id=target_id for update;
  if not found then return 'missing'; end if;
  effective:=case when g.status='cancellation_requested' then g.status_before_cancellation else g.status end;
  deadline:=case when effective='collecting' then g.participant_due_at when effective='revision_requested' then g.revision_due_at end;
  if effective not in ('collecting','revision_requested') or deadline is null or moment<deadline then return 'not-due'; end if;
  perform m.id from public.group_members m where m.group_id=g.id order by m.id for update;
  perform x.id from public.applications x where x.group_id=g.id order by x.id for update;
  perform s.id from public.stays s join public.applications x on x.id=s.application_id where x.group_id=g.id order by s.id for update of s;
  perform r.id from public.room_allocations r where r.group_id=g.id order by r.id for update;
  perform i.id from public.group_invites i where i.group_id=g.id order by i.id for update;
  select count(*)::integer into active_count from public.group_members m join public.applications x on x.id=m.application_id
    where m.group_id=g.id and m.state='active' and x.status not in ('rejected','cancelled');
  ready:=active_count=g.planned_participants and active_count>0 and not exists(select 1 from public.group_members m
    join public.applications x on x.id=m.application_id where m.group_id=g.id and m.state='active' and x.status not in ('submitted','approved'));
  if ready then
    if g.status<>'cancellation_requested' then
      prior:=g.status; before_g:=private.group_snapshot(g.id);
      update public.group_applications set status='under_review',revision_due_at=null,decision_reason=null where id=g.id;
      update public.group_invites set revoked_at=moment where group_id=g.id and revoked_at is null;
      insert into public.group_status_events(group_id,from_status,to_status,public_reason,occurred_at)
        values(g.id,prior,'under_review','期限処理時に提出完了を確認',moment);
      insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind)
        values('group_application',g.id,'deadline_ready_for_review',before_g,private.group_snapshot(g.id),'system');
      return 'under-review';
    end if;
    return 'ready-cancellation-requested';
  end if;
  reason_value:=case when effective='collecting' then '参加者提出期限切れ' else '修正期限切れ' end;
  prior:=g.status; before_g:=private.group_snapshot(g.id);
  for a in select x.* from public.applications x where x.group_id=g.id and x.status not in ('rejected','cancelled') order by x.id loop
    before_a:=private.community_snapshot(a.id);
    update public.applications set status='cancelled',cancel_reason=coalesce(cancel_reason,reason_value) where id=a.id;
    insert into public.application_status_events(application_id,from_status,to_status,public_reason,occurred_at)
      values(a.id,a.status,'cancelled',reason_value,moment);
    insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,reason)
      values('application',a.id,'group_deadline_expired',before_a,private.community_snapshot(a.id),'system',reason_value);
  end loop;
  -- Keep the hash row so an expired link still produces the safe invite-expired
  -- response; the cancelled parent makes it permanently unusable.
  update public.room_allocations set released_from=start_date where group_id=g.id and released_from is null;
  update public.group_applications set status='cancelled',cancel_reason=coalesce(cancel_reason,reason_value),completed_at=moment where id=g.id;
  insert into public.group_status_events(group_id,from_status,to_status,public_reason,occurred_at)
    values(g.id,prior,'cancelled',reason_value,moment);
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,reason)
    values('group_application',g.id,'group_deadline_expired',before_g,private.group_snapshot(g.id),'system',reason_value);
  return 'cancelled';
end; $$;

create function private.expire_due_community_groups_locked(batch_size integer default 500,moment timestamptz default clock_timestamp())
returns table(group_id uuid,outcome text) language plpgsql security definer set search_path='' as $$
declare candidate uuid;
begin
  if batch_size is null or batch_size<1 or batch_size>500 then raise exception 'invalid-batch-size'; end if;
  for candidate in select g.id from public.group_applications g where
    ((case when g.status='cancellation_requested' then g.status_before_cancellation else g.status end)='collecting'
      and g.participant_due_at is not null and moment>=g.participant_due_at)
    or ((case when g.status='cancellation_requested' then g.status_before_cancellation else g.status end)='revision_requested'
      and g.revision_due_at is not null and moment>=g.revision_due_at)
    order by coalesce(g.revision_due_at,g.participant_due_at),g.id limit batch_size
  loop group_id:=candidate; outcome:=private.process_due_community_group(candidate,moment); return next; end loop;
end; $$;

create function private.expire_due_community_groups(batch_size integer default 500,moment timestamptz default clock_timestamp())
returns table(group_id uuid,outcome text) language plpgsql security definer set search_path='' as $$
begin
  update public.facility_guard g set id=g.id where g.id=1;
  if not found then raise exception 'facility-guard-missing'; end if;
  return query select * from private.expire_due_community_groups_locked(batch_size,moment);
end; $$;

create function private.community_group_deadline_expired(target_id uuid,moment timestamptz default clock_timestamp())
returns boolean language sql stable security definer set search_path='' as $$
  select coalesce((select
    ((case when g.status='cancellation_requested' then g.status_before_cancellation else g.status end)='collecting'
      and g.participant_due_at is not null and moment>=g.participant_due_at)
    or ((case when g.status='cancellation_requested' then g.status_before_cancellation else g.status end)='revision_requested'
      and g.revision_due_at is not null and moment>=g.revision_due_at)
    from public.group_applications g where g.id=target_id),false);
$$;

create or replace function private.lock_calendar_facility()
returns void language plpgsql security definer set search_path='' as $$
begin
  update public.facility_guard g set id=g.id where g.id=1;
  if not found then raise exception 'facility-guard-missing'; end if;
  perform * from private.expire_due_community_groups_locked(500,clock_timestamp());
end; $$;

-- Group-user operations keep their existing deadline-specific errors. They
-- still take the same facility lock as Cron, so submit and expiry serialize.
create or replace function private.lock_group_user()
returns uuid language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();
begin
  if actor is null or not private.has_active_profile() then
    raise exception using errcode='42501',message='active-user-required'; end if;
  update public.facility_guard g set id=g.id where g.id=1;
  if not found then raise exception 'facility-guard-missing'; end if;
  perform p.id from public.profiles p where p.id=actor and p.account_state='active' for share;
  if not found then raise exception using errcode='42501',message='active-user-required'; end if;
  return actor;
end; $$;

create or replace function public.get_public_calendar(target_month date)
returns table(date date,availability text) language plpgsql stable security definer set search_path='' as $$
declare last_day date:=private.calendar_month_end(target_month); today_jst date:=(clock_timestamp() at time zone 'Asia/Tokyo')::date;
begin
  return query select target_month+d.day_offset,case
    when target_month+d.day_offset>today_jst+60 then 'not_yet_open'
    when target_month+d.day_offset<today_jst+14 then 'unavailable'
    when exists(select 1 from public.calendar_claims q where q.claim_type in ('camp','blocked','group')
      and target_month+d.day_offset between q.start_date and q.end_date
      and (q.released_from is null or target_month+d.day_offset<q.released_from)
      and (q.claim_type<>'group' or not private.community_group_deadline_expired(q.group_id,clock_timestamp())))
      or private.community_occupancy(target_month+d.day_offset)>=15 then 'unavailable' else 'available' end
  from generate_series(0,last_day-target_month)d(day_offset) order by d.day_offset;
end; $$;

revoke all on function private.process_due_community_group(uuid,timestamptz),
  private.expire_due_community_groups_locked(integer,timestamptz),private.expire_due_community_groups(integer,timestamptz),
  private.community_group_deadline_expired(uuid,timestamptz)
  from public,anon,authenticated,service_role;

do $block$ begin
  if exists(select 1 from pg_available_extensions where name='pg_cron') then
    execute 'create extension if not exists pg_cron';
    execute $schedule$select cron.schedule('expire-community-groups-every-minute','* * * * *','select private.expire_due_community_groups(500)')$schedule$;
  end if;
end $block$;
commit;
