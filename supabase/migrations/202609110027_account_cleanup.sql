-- T22: account cleanup queue, eligibility guards, staff disable, and Edge Function scheduling.
begin;
select private.lock_calendar_facility();

create table public.account_cleanup_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  status text not null default 'queued'
    check (status in ('queued','processing','done','failed','cancelled')),
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default clock_timestamp(),
  locked_until timestamptz,
  last_error text,
  completed_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check ((status='processing')=(locked_until is not null)),
  check ((status='done')=(completed_at is not null)),
  check (last_error is null or char_length(last_error) <= 500)
);
create unique index account_cleanup_jobs_user_open_uq on public.account_cleanup_jobs(user_id)
  where status in ('queued','processing','failed');
create index account_cleanup_jobs_due_idx on public.account_cleanup_jobs(status,next_attempt_at,locked_until);
alter table public.account_cleanup_jobs enable row level security;
revoke all on public.account_cleanup_jobs from public,anon,authenticated,service_role;

create function private.account_cleanup_blocker(target_user_id uuid)
returns text language plpgsql stable security definer set search_path='' as $$
begin
  if target_user_id is null or not exists(select 1 from public.profiles p where p.id=target_user_id) then return 'profile-missing'; end if;
  if exists(select 1 from public.staff_roles s where s.user_id=target_user_id) then return 'staff-protected'; end if;
  if exists(select 1 from public.applications a where a.user_id=target_user_id and (
      a.status in ('draft','submitted','under_review','revision_requested','cancellation_requested')
      or (a.status='approved' and not exists(select 1 from public.stays s where s.application_id=a.id and s.status='moved_out'))
    )) then return 'application-open'; end if;
  if exists(select 1 from public.group_members m join public.applications a on a.id=m.application_id
    join public.group_applications g on g.id=m.group_id
    where a.user_id=target_user_id and m.state='active' and g.completed_at is null) then return 'group-membership-open'; end if;
  if exists(select 1 from public.group_applications g
    where g.representative_user_id=target_user_id and g.completed_at is null) then return 'group-representative-open'; end if;
  if not (
    exists(select 1 from public.applications a join public.stays s on s.application_id=a.id
      where a.user_id=target_user_id and s.status='moved_out' and s.checked_out_at is not null)
    or exists(select 1 from public.group_applications g where g.representative_user_id=target_user_id
      and not g.representative_stays and g.completed_at is not null)
  ) then return 'completion-required'; end if;
  return null;
end; $$;

create function private.reconcile_account_cleanup(target_user_id uuid,moment timestamptz default clock_timestamp())
returns text language plpgsql security definer set search_path='' as $$
declare blocker text; current_state text;
begin
  if target_user_id is null or moment is null or not isfinite(moment) then return 'ignored'; end if;
  update public.facility_guard g set id=g.id where g.id=1;
  if not found then raise exception 'facility-guard-missing'; end if;
  select p.account_state into current_state from public.profiles p where p.id=target_user_id for update;
  if not found or current_state='disabled' then return 'ignored'; end if;
  blocker:=private.account_cleanup_blocker(target_user_id);
  if blocker is not null then
    if current_state='cleanup_pending' then update public.profiles set account_state='active' where id=target_user_id; end if;
    update public.account_cleanup_jobs set status='cancelled',locked_until=null,last_error=blocker,
      completed_at=null,updated_at=moment where user_id=target_user_id and status in ('queued','processing','failed');
    return blocker;
  end if;
  update public.profiles set account_state='cleanup_pending' where id=target_user_id and account_state='active';
  insert into public.account_cleanup_jobs(user_id,status,next_attempt_at,updated_at)
    values(target_user_id,'queued',moment,moment)
    on conflict(user_id) where status in ('queued','processing','failed') do update
      set status=case when public.account_cleanup_jobs.status='processing'
        and public.account_cleanup_jobs.locked_until>moment then 'processing' else 'queued' end,
        locked_until=case when public.account_cleanup_jobs.status='processing'
          and public.account_cleanup_jobs.locked_until>moment then public.account_cleanup_jobs.locked_until end,
        next_attempt_at=least(public.account_cleanup_jobs.next_attempt_at,moment),last_error=null,updated_at=moment;
  return 'queued';
end; $$;

create function private.reconcile_application_account_cleanup()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.user_id is not null and exists(select 1 from auth.users u where u.id=old.user_id) then
    perform private.reconcile_account_cleanup(old.user_id); end if;
  if new.user_id is not null and new.user_id is distinct from old.user_id then perform private.reconcile_account_cleanup(new.user_id); end if;
  return new;
end; $$;
create trigger applications_reconcile_account_cleanup after update of status,user_id on public.applications
for each row when (old.status is distinct from new.status or old.user_id is distinct from new.user_id)
execute function private.reconcile_application_account_cleanup();

create function private.reconcile_group_account_cleanup()
returns trigger language plpgsql security definer set search_path='' as $$
declare candidate uuid;
begin
  if old.representative_user_id is not null and exists(select 1 from auth.users u where u.id=old.representative_user_id) then
    perform private.reconcile_account_cleanup(old.representative_user_id); end if;
  if new.representative_user_id is not null and new.representative_user_id is distinct from old.representative_user_id then
    perform private.reconcile_account_cleanup(new.representative_user_id); end if;
  for candidate in select distinct a.user_id from public.group_members m join public.applications a on a.id=m.application_id
    where m.group_id=new.id and a.user_id is not null loop perform private.reconcile_account_cleanup(candidate); end loop;
  return new;
end; $$;
create trigger group_applications_reconcile_account_cleanup after update of status,completed_at,representative_user_id on public.group_applications
for each row when (old.status is distinct from new.status or old.completed_at is distinct from new.completed_at
  or old.representative_user_id is distinct from new.representative_user_id)
execute function private.reconcile_group_account_cleanup();

create function private.finish_group_after_checkout()
returns trigger language plpgsql security definer set search_path='' as $$
declare group_value uuid; moment timestamptz:=coalesce(new.checked_out_at,clock_timestamp()); before_group jsonb;
begin
  if new.status<>'moved_out' or old.status='moved_out' then return new; end if;
  select a.group_id into group_value from public.applications a where a.id=new.application_id and a.usage_type='community_group';
  if group_value is null then
    perform private.reconcile_account_cleanup((select a.user_id from public.applications a where a.id=new.application_id));
    return new;
  end if;
  if not exists(select 1 from public.group_members m join public.applications a on a.id=m.application_id
    left join public.stays s on s.application_id=a.id where m.group_id=group_value and m.state='active'
      and a.status='approved' and (s.id is null or s.status<>'moved_out')) then
    before_group:=private.group_snapshot(group_value);
    update public.group_applications set completed_at=coalesce(completed_at,moment) where id=group_value and completed_at is null;
    if found then insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,occurred_at)
      values('group_application',group_value,'complete_group_stay',before_group,private.group_snapshot(group_value),'system',moment); end if;
  end if;
  perform private.reconcile_account_cleanup((select a.user_id from public.applications a where a.id=new.application_id));
  return new;
end; $$;
create trigger stays_finish_group_and_reconcile after update of status on public.stays
for each row execute function private.finish_group_after_checkout();

create function public.claim_account_cleanup_job(batch_size integer default 10)
returns table(job_id uuid,result_user_id uuid,result_attempts integer)
language plpgsql security definer set search_path='' as $$
declare j public.account_cleanup_jobs%rowtype; blocker text; moment timestamptz:=clock_timestamp(); claimed integer:=0;
begin
  if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception using errcode='42501',message='service-role-required'; end if;
  if batch_size is null or batch_size<1 or batch_size>20 then raise exception 'invalid-batch-size'; end if;
  for j in select * from public.account_cleanup_jobs q where
      (q.status in ('queued','failed') and q.next_attempt_at<=moment)
      or (q.status='processing' and q.locked_until<=moment)
    order by q.next_attempt_at,q.created_at,q.id for update skip locked
  loop
    exit when claimed>=batch_size;
    blocker:=private.account_cleanup_blocker(j.user_id);
    -- A previous attempt may have deleted Auth before recording completion.
    -- Only a previously attempted job may continue without a profile.
    if blocker is not null and not (blocker='profile-missing' and j.attempts>0) then
      update public.account_cleanup_jobs set status='cancelled',locked_until=null,last_error=blocker,updated_at=moment where id=j.id;
      update public.profiles set account_state='active' where id=j.user_id and account_state='cleanup_pending';
      continue;
    end if;
    update public.account_cleanup_jobs set status='processing',attempts=attempts+1,locked_until=moment+interval '5 minutes',
      last_error=null,updated_at=moment where id=j.id returning attempts into result_attempts;
    job_id:=j.id; result_user_id:=j.user_id; claimed:=claimed+1; return next;
  end loop;
end; $$;

create function public.complete_account_cleanup_job(target_job_id uuid,target_user_id uuid)
returns boolean language plpgsql security definer set search_path='' as $$
begin
  if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception using errcode='42501',message='service-role-required'; end if;
  update public.account_cleanup_jobs set status='done',locked_until=null,last_error=null,
    completed_at=clock_timestamp(),updated_at=clock_timestamp()
    where id=target_job_id and user_id=target_user_id and status='processing';
  return found;
end; $$;

create function public.fail_account_cleanup_job(target_job_id uuid,target_user_id uuid,error_message text)
returns boolean language plpgsql security definer set search_path='' as $$
declare moment timestamptz:=clock_timestamp();
begin
  if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception using errcode='42501',message='service-role-required'; end if;
  update public.account_cleanup_jobs set status='failed',locked_until=null,
    last_error=left(coalesce(nullif(btrim(error_message),''),'delete-failed'),500),
    next_attempt_at=moment+least(interval '24 hours',interval '1 minute'*power(2,least(attempts,10))),updated_at=moment
    where id=target_job_id and user_id=target_user_id and status='processing';
  return found;
end; $$;

create function public.disable_user_account(target_user_id uuid,disable_reason text)
returns boolean language plpgsql security definer set search_path='' as $$
declare reason_value text:=nullif(btrim(disable_reason),''); before_value jsonb;
begin
  if auth.uid() is null or not private.is_staff() then raise exception using errcode='42501',message='staff-required'; end if;
  if reason_value is null then raise exception 'reason-required'; end if;
  if char_length(reason_value)>2000 then raise exception 'reason-too-long'; end if;
  perform private.lock_calendar_facility();
  perform p.id from public.profiles p where p.id=target_user_id and p.account_state='active' for update;
  if not found then raise exception 'not-found'; end if;
  if exists(select 1 from public.staff_roles s where s.user_id=target_user_id) then raise exception 'staff-protected'; end if;
  if private.account_cleanup_blocker(target_user_id) is distinct from 'completion-required' then raise exception 'account-protected'; end if;
  if not exists(select 1 from public.applications a where a.user_id=target_user_id and a.status in ('rejected','cancelled')) then
    raise exception 'manual-disable-not-eligible'; end if;
  before_value:=jsonb_build_object('account_state','active');
  update public.profiles set account_state='disabled' where id=target_user_id;
  update public.account_cleanup_jobs set status='cancelled',locked_until=null,last_error='staff-disabled',updated_at=clock_timestamp()
    where user_id=target_user_id and status in ('queued','processing','failed');
  insert into public.audit_logs(entity_type,entity_id,action,before_data,after_data,actor_kind,actor_user_id,reason)
    values('profile',target_user_id,'disable_user_account',before_value,jsonb_build_object('account_state','disabled'),
      'staff',auth.uid(),reason_value);
  return true;
end; $$;

create function private.enqueue_due_account_cleanups(batch_size integer default 100)
returns integer language plpgsql security definer set search_path='' as $$
declare candidate uuid; queued integer:=0;
begin
  if batch_size is null or batch_size<1 or batch_size>500 then raise exception 'invalid-batch-size'; end if;
  for candidate in select p.id from public.profiles p where p.account_state='active' and not exists(
      select 1 from public.staff_roles s where s.user_id=p.id)
      and (exists(select 1 from public.applications a join public.stays x on x.application_id=a.id
          where a.user_id=p.id and x.status='moved_out' and x.checked_out_at is not null)
        or exists(select 1 from public.group_applications g where g.representative_user_id=p.id
          and not g.representative_stays and g.completed_at is not null))
    order by p.id limit batch_size
  loop
    if private.reconcile_account_cleanup(candidate)='queued' then queued:=queued+1; end if;
  end loop;
  return queued;
end; $$;

create function private.invoke_account_cleanup_edge()
returns bigint language plpgsql security definer set search_path='' as $$
declare endpoint text; secret_value text; request_id bigint;
begin
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null
    or to_regclass('vault.decrypted_secrets') is null then return null; end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
    into endpoint using 'account_cleanup_url';
  execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
    into secret_value using 'account_cleanup_cron_secret';
  if nullif(endpoint,'') is null or nullif(secret_value,'') is null then return null; end if;
  perform private.enqueue_due_account_cleanups(100);
  execute 'select net.http_post(url := $1, headers := $2, body := $3, timeout_milliseconds := 5000)'
    into request_id using endpoint,jsonb_build_object('content-type','application/json','x-cron-secret',secret_value),'{}'::jsonb;
  return request_id;
end; $$;

revoke all on function private.account_cleanup_blocker(uuid),private.reconcile_account_cleanup(uuid,timestamptz),
  private.reconcile_application_account_cleanup(),private.reconcile_group_account_cleanup(),private.finish_group_after_checkout(),
  private.enqueue_due_account_cleanups(integer),private.invoke_account_cleanup_edge() from public,anon,authenticated,service_role;
revoke all on function public.claim_account_cleanup_job(integer),public.complete_account_cleanup_job(uuid,uuid),
  public.fail_account_cleanup_job(uuid,uuid,text),public.disable_user_account(uuid,text)
  from public,anon,authenticated,service_role;
grant execute on function public.claim_account_cleanup_job(integer),public.complete_account_cleanup_job(uuid,uuid),
  public.fail_account_cleanup_job(uuid,uuid,text) to service_role;
grant execute on function public.disable_user_account(uuid,text) to authenticated;

do $block$ begin
  if exists(select 1 from pg_available_extensions where name='pg_net') then execute 'create extension if not exists pg_net'; end if;
  if exists(select 1 from pg_available_extensions where name='pg_cron') then
    execute 'create extension if not exists pg_cron';
    if not exists(select 1 from cron.job where jobname='process-account-cleanup-every-minute') then
      perform cron.schedule('process-account-cleanup-every-minute','* * * * *','select private.invoke_account_cleanup_edge()');
    end if;
  end if;
end $block$;
commit;
