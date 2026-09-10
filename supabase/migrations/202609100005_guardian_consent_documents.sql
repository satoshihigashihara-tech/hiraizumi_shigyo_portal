-- MVP phase 5: private guardian-consent document metadata.
-- The Storage bucket is created through the Supabase Storage API/dashboard.

create table public.consent_documents (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null unique
    references public.applications(id) on delete cascade,
  object_path text not null unique
    check (btrim(object_path) <> ''),
  mime_type text not null
    check (mime_type in ('application/pdf', 'image/jpeg', 'image/png')),
  size_bytes integer not null
    check (size_bytes between 1 and 5242880),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger consent_documents_set_updated_at
before update on public.consent_documents
for each row execute function public.set_updated_at();

alter table public.consent_documents enable row level security;

create policy "consent_documents_select_owner_or_staff"
on public.consent_documents
for select
to authenticated
using (private.can_read_application(application_id));

revoke all on public.consent_documents from anon, authenticated;
grant select on public.consent_documents to authenticated;

create or replace function public.register_guardian_consent_document(
  target_application_id uuid,
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
  current_user_id uuid := auth.uid();
  application_record public.applications%rowtype;
  previous_object_path text;
  expected_path_pattern text;
begin
  if current_user_id is null or not private.has_active_profile() then
    raise exception 'ログインが必要です。';
  end if;

  select application.*
  into application_record
  from public.applications as application
  where application.id = target_application_id
  for update;

  if not found or application_record.user_id <> current_user_id then
    raise exception '申請が見つかりません。';
  end if;

  if application_record.status not in ('draft', 'revision_requested') then
    raise exception '現在の状態では同意書を変更できません。';
  end if;

  if application_record.status = 'revision_requested'
    and application_record.revision_due_at is not null
    and now() >= application_record.revision_due_at then
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

  if target_mime_type not in ('application/pdf', 'image/jpeg', 'image/png') then
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

  return previous_object_path;
end;
$$;

revoke all on function public.register_guardian_consent_document(
  uuid,
  text,
  text,
  integer
) from public;

grant execute on function public.register_guardian_consent_document(
  uuid,
  text,
  text,
  integer
) to authenticated;
