-- =============================================================================
-- WanBuddy v0.2 / M2  05: RLS・権限・ポリシー(PRD 7.2)
--   * public の全テーブルで RLS 有効化。anon には何も許可しない。
--   * ポリシーは操作(SELECT/INSERT/UPDATE/DELETE)ごと、`to authenticated`、auth.uid() は (select auth.uid())。
--   * テーブル権限(GRANT)も最小(列単位)。presences / presence_dogs / friendships / qr_tokens への
--     直接 INSERT 権限は与えない(RPC=security definer 経由のみ)。
-- =============================================================================

-- まず全部剥がす(Supabaseが自動付与していた権限を含む)
revoke all on all tables    in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

alter table public.profiles         enable row level security;
alter table public.profile_settings enable row level security;
alter table public.dogs             enable row level security;
alter table public.dog_instagram    enable row level security;
alter table public.friendships      enable row level security;
alter table public.blocks           enable row level security;
alter table public.facilities       enable row level security;
alter table public.facility_areas   enable row level security;
alter table public.presences        enable row level security;
alter table public.presence_dogs    enable row level security;
alter table public.qr_tokens        enable row level security;
alter table public.qr_scans         enable row level security;
alter table public.reports          enable row level security;
alter table public.feedback         enable row level security;
alter table public.terms_consents   enable row level security;

-- service_role(Edge Function。RLSはバイパス)にはテーブル権限を与える
grant all on all tables in schema public to service_role;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
grant select on public.profiles to authenticated;
-- user_code は自動生成のみ(トリガー)。INSERT/UPDATE とも列GRANTを与えない=クライアントは指定も変更もできない。
grant insert (id, nickname, avatar_path, visibility_owner) on public.profiles to authenticated;
grant update (nickname, avatar_path, visibility_owner) on public.profiles to authenticated;
-- DELETE は付与しない(退会は Edge Function(service_role)で auth.users ごと削除)

create policy profiles_select on public.profiles
  for select to authenticated
  using (private.can_view((select auth.uid()), id, visibility_owner));

create policy profiles_insert on public.profiles
  for insert to authenticated
  with check (
    id = (select auth.uid())
    and (avatar_path is null or starts_with(avatar_path, (select auth.uid())::text || '/'))
  );

create policy profiles_update on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (
    id = (select auth.uid())
    and (avatar_path is null or starts_with(avatar_path, (select auth.uid())::text || '/'))
  );

-- ---------------------------------------------------------------------------
-- profile_settings(本人のみ)。INSERT はトリガー、招待コード再生成は RPC。
-- ---------------------------------------------------------------------------
grant select on public.profile_settings to authenticated;
grant update (searchable, accept_qr) on public.profile_settings to authenticated;

create policy profile_settings_select on public.profile_settings
  for select to authenticated
  using (user_id = (select auth.uid()));

create policy profile_settings_update on public.profile_settings
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- dogs
-- ---------------------------------------------------------------------------
grant select on public.dogs to authenticated;
grant insert (id, owner_id, name, photo_path, breed, birthday, personality, visibility_dog, sort_order)
  on public.dogs to authenticated;
grant update (name, photo_path, breed, birthday, personality, visibility_dog, sort_order)
  on public.dogs to authenticated;
grant delete on public.dogs to authenticated;

create policy dogs_select on public.dogs
  for select to authenticated
  using (private.can_view((select auth.uid()), owner_id, visibility_dog));

create policy dogs_insert on public.dogs
  for insert to authenticated
  with check (
    owner_id = (select auth.uid())
    and (photo_path is null
         or starts_with(photo_path, (select auth.uid())::text || '/' || id::text || '/'))
  );

create policy dogs_update on public.dogs
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (
    owner_id = (select auth.uid())
    and (photo_path is null
         or starts_with(photo_path, (select auth.uid())::text || '/' || id::text || '/'))
  );

create policy dogs_delete on public.dogs
  for delete to authenticated
  using (owner_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- dog_instagram: 犬が見えて、かつ Instagram の公開範囲も満たす場合のみ
-- ---------------------------------------------------------------------------
grant select on public.dog_instagram to authenticated;
grant insert (dog_id, handle, visibility) on public.dog_instagram to authenticated;
grant update (handle, visibility) on public.dog_instagram to authenticated;
grant delete on public.dog_instagram to authenticated;

create policy dog_instagram_select on public.dog_instagram
  for select to authenticated
  using (
    exists (
      select 1
      from public.dogs d                      -- dogs のRLS(犬の公開範囲)も同時に効く
      where d.id = dog_instagram.dog_id
        and private.can_view((select auth.uid()), d.owner_id, dog_instagram.visibility)
    )
  );

create policy dog_instagram_insert on public.dog_instagram
  for insert to authenticated
  with check (
    exists (select 1 from public.dogs d
            where d.id = dog_instagram.dog_id and d.owner_id = (select auth.uid()))
  );

create policy dog_instagram_update on public.dog_instagram
  for update to authenticated
  using (
    exists (select 1 from public.dogs d
            where d.id = dog_instagram.dog_id and d.owner_id = (select auth.uid()))
  )
  with check (
    exists (select 1 from public.dogs d
            where d.id = dog_instagram.dog_id and d.owner_id = (select auth.uid()))
  );

create policy dog_instagram_delete on public.dog_instagram
  for delete to authenticated
  using (
    exists (select 1 from public.dogs d
            where d.id = dog_instagram.dog_id and d.owner_id = (select auth.uid()))
  );

-- ---------------------------------------------------------------------------
-- friendships: 閲覧は当事者のみ。INSERT/UPDATE 権限なし(RPCのみ)。
--   DELETE: accepted(友達解除。どちらからでも) / pending(申請の取り消し。申請者のみ)。
--   declined は削除不可(拒否された側が即再申請できないようにする)。
-- ---------------------------------------------------------------------------
grant select, delete on public.friendships to authenticated;

create policy friendships_select on public.friendships
  for select to authenticated
  using (requester_id = (select auth.uid()) or addressee_id = (select auth.uid()));

create policy friendships_delete on public.friendships
  for delete to authenticated
  using (
    (status = 'accepted'
       and (requester_id = (select auth.uid()) or addressee_id = (select auth.uid())))
    or (status = 'pending' and requester_id = (select auth.uid()))
  );

-- ---------------------------------------------------------------------------
-- blocks: 自分がしたブロックのみ閲覧/作成/解除(された側からは見えない)
-- ---------------------------------------------------------------------------
grant select, delete on public.blocks to authenticated;
grant insert (blocker_id, blocked_id) on public.blocks to authenticated;

create policy blocks_select on public.blocks
  for select to authenticated
  using (blocker_id = (select auth.uid()));

create policy blocks_insert on public.blocks
  for insert to authenticated
  with check (blocker_id = (select auth.uid()) and blocked_id <> (select auth.uid()));

create policy blocks_delete on public.blocks
  for delete to authenticated
  using (blocker_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- facilities / facility_areas: 有効な施設は登録ユーザー全員が閲覧可。書き込みは service_role のみ。
-- ---------------------------------------------------------------------------
grant select on public.facilities to authenticated;
grant select on public.facility_areas to authenticated;

create policy facilities_select on public.facilities
  for select to authenticated
  using (is_active);

create policy facility_areas_select on public.facility_areas
  for select to authenticated
  using (exists (select 1 from public.facilities f where f.id = facility_areas.facility_id and f.is_active));

-- ---------------------------------------------------------------------------
-- presences: 閲覧のみ(書き込みは RPC)
--   本人: 自分の行すべて / 他人: 表示対象(ended_at is null and expires_at > now)かつ can_view
-- ---------------------------------------------------------------------------
grant select on public.presences to authenticated;

create policy presences_select on public.presences
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or (
      ended_at is null
      and expires_at > (select private.app_now())
      and private.can_view((select auth.uid()), user_id, visibility)
    )
  );

-- presence_dogs: 在場が見え、かつその犬が犬自身の公開範囲(can_view)で見える場合のみ
grant select on public.presence_dogs to authenticated;

create policy presence_dogs_select on public.presence_dogs
  for select to authenticated
  using (
    exists (
      select 1
      from public.presences p
      join public.dogs d on d.id = presence_dogs.dog_id
      where p.id = presence_dogs.presence_id
        and (
          p.user_id = (select auth.uid())
          or (
            p.ended_at is null
            and p.expires_at > (select private.app_now())
            and private.can_view((select auth.uid()), p.user_id, p.visibility)
            and private.can_view((select auth.uid()), d.owner_id, d.visibility_dog)
          )
        )
    )
  );

-- ---------------------------------------------------------------------------
-- qr_tokens / qr_scans: クライアントには権限もポリシーも一切なし(RPC専用)。RLSは有効=全拒否。
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- reports: INSERT のみ(運営は Supabase ダッシュボード/service_role で確認)
-- ---------------------------------------------------------------------------
grant insert (reporter_id, target_user_id, reason, comment) on public.reports to authenticated;

create policy reports_insert on public.reports
  for insert to authenticated
  with check (
    reporter_id = (select auth.uid())
    and target_user_id is not null
    and target_user_id <> (select auth.uid())
  );

-- ---------------------------------------------------------------------------
-- feedback: INSERT のみ。匿名は user_id=NULL。
-- ---------------------------------------------------------------------------
grant insert (user_id, kind, body) on public.feedback to authenticated;

create policy feedback_insert on public.feedback
  for insert to authenticated
  with check (user_id is null or user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- terms_consents: 本人の閲覧/追加のみ(更新・削除不可=同意履歴の改ざん防止)
-- ---------------------------------------------------------------------------
grant select on public.terms_consents to authenticated;
grant insert (user_id, terms_version) on public.terms_consents to authenticated;

create policy terms_consents_select on public.terms_consents
  for select to authenticated
  using (user_id = (select auth.uid()));

create policy terms_consents_insert on public.terms_consents
  for insert to authenticated
  with check (user_id = (select auth.uid()));
