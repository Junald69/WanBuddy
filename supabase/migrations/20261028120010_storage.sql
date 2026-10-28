-- =============================================================================
-- WanBuddy v0.2 / M2  10: Storage(バケットとポリシー)
--   avatars   : <user_id>/<file>
--   dog-photos: <user_id>/<dog_id>/<file>
--   どちらも private(public=false)。閲覧はアプリ側の署名URL経由。
--   * 書き込み(INSERT/UPDATE/DELETE): 自分のフォルダのみ(dog-photos は自分の犬のフォルダのみ)
--   * 閲覧(SELECT): 本人、または 該当プロフィール/犬を can_view で閲覧できる人
--   * anon: ポリシーなし = 何も不可
--   ファイルサイズ/MIME制限は【提案値】(2MB / jpeg・png・webp)。
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars',    'avatars',    false, 2097152, array['image/jpeg', 'image/png', 'image/webp']),
  ('dog-photos', 'dog-photos', false, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- パス検証・閲覧判定(security definer。例外を出さず false を返す)
create function private.storage_path_uuid(p text)
returns uuid
language sql
immutable
set search_path = ''
as $$
  select case when p ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then p::uuid end
$$;
revoke all on function private.storage_path_uuid(text) from public, anon;
grant execute on function private.storage_path_uuid(text) to authenticated;

-- 自分の犬のフォルダか(dog-photos の書き込み用)
create function private.storage_is_own_dog_folder(p_owner text, p_dog text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.dogs d
     where d.id = private.storage_path_uuid(p_dog)
       and d.owner_id = private.storage_path_uuid(p_owner)
       and d.owner_id = auth.uid()
  )
$$;
revoke all on function private.storage_is_own_dog_folder(text, text) from public, anon;
grant execute on function private.storage_is_own_dog_folder(text, text) to authenticated;

-- 閲覧できるか(avatars)
create function private.storage_can_read_avatar(p_owner text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
     where p.id = private.storage_path_uuid(p_owner)
       and private.can_view(auth.uid(), p.id, p.visibility_owner)
  )
$$;
revoke all on function private.storage_can_read_avatar(text) from public, anon;
grant execute on function private.storage_can_read_avatar(text) to authenticated;

-- 閲覧できるか(dog-photos)
create function private.storage_can_read_dog_photo(p_owner text, p_dog text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.dogs d
     where d.id = private.storage_path_uuid(p_dog)
       and d.owner_id = private.storage_path_uuid(p_owner)
       and private.can_view(auth.uid(), d.owner_id, d.visibility_dog)
  )
$$;
revoke all on function private.storage_can_read_dog_photo(text, text) from public, anon;
grant execute on function private.storage_can_read_dog_photo(text, text) to authenticated;

-- ---- avatars ---------------------------------------------------------------------
create policy avatars_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'avatars'
    and cardinality(storage.foldername(name)) = 1
    and private.storage_can_read_avatar((storage.foldername(name))[1])
  );

create policy avatars_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and cardinality(storage.foldername(name)) = 1
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy avatars_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'avatars'
    and cardinality(storage.foldername(name)) = 1
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'avatars'
    and cardinality(storage.foldername(name)) = 1
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy avatars_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'avatars'
    and cardinality(storage.foldername(name)) = 1
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- ---- dog-photos ------------------------------------------------------------------
create policy dog_photos_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'dog-photos'
    and cardinality(storage.foldername(name)) = 2
    and private.storage_can_read_dog_photo((storage.foldername(name))[1], (storage.foldername(name))[2])
  );

create policy dog_photos_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'dog-photos'
    and cardinality(storage.foldername(name)) = 2
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and private.storage_is_own_dog_folder((storage.foldername(name))[1], (storage.foldername(name))[2])
  );

create policy dog_photos_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'dog-photos'
    and cardinality(storage.foldername(name)) = 2
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and private.storage_is_own_dog_folder((storage.foldername(name))[1], (storage.foldername(name))[2])
  )
  with check (
    bucket_id = 'dog-photos'
    and cardinality(storage.foldername(name)) = 2
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and private.storage_is_own_dog_folder((storage.foldername(name))[1], (storage.foldername(name))[2])
  );

create policy dog_photos_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'dog-photos'
    and cardinality(storage.foldername(name)) = 2
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
