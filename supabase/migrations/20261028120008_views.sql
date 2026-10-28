-- =============================================================================
-- WanBuddy v0.2 / M2  08: 閲覧用ビュー(すべて security_invoker = true)
--   ビューは呼び出し元の権限・RLSで評価される(ビュー所有者のRLSバイパスを防ぐ)。
--   anon には付与しない。
-- =============================================================================

-- 友達一覧(accepted)。nickname は 相手のプロフィールが非公開でも返す(友達なので。private.display_name)。
--   avatar_path は profiles のRLSのまま(相手のプロフィールが見えない場合は NULL)。
create view public.my_friends
with (security_invoker = true) as
select f.id as friendship_id,
       case when f.requester_id = (select auth.uid()) then f.addressee_id else f.requester_id end as friend_id,
       private.display_name(case when f.requester_id = (select auth.uid()) then f.addressee_id else f.requester_id end) as nickname,
       p.avatar_path,
       f.method,
       f.responded_at as friends_since
  from public.friendships f
  left join public.profiles p
    on p.id = case when f.requester_id = (select auth.uid()) then f.addressee_id else f.requester_id end
 where f.status = 'accepted'
   and (f.requester_id = (select auth.uid()) or f.addressee_id = (select auth.uid()));

-- 在場ボード: 施設ごとの「いま見える在場」。犬は presence_dogs/dogs のRLS(犬ごとの公開範囲)で絞られる。
create view public.presence_board
with (security_invoker = true) as
select pr.id as presence_id,
       pr.facility_id,
       pr.area_code,
       pr.status,
       pr.planned_at,
       pr.started_at,
       pr.expires_at,
       pr.user_id,
       private.display_name(pr.user_id) as nickname,   -- 友達なら相手のプロフィールが非公開でも名前は出す(M-3)
       p.avatar_path,
       coalesce(dg.dogs, '[]'::jsonb) as dogs
  from public.presences pr
  left join public.profiles p on p.id = pr.user_id
  left join lateral (
    select jsonb_agg(
             jsonb_build_object('id', d.id, 'name', d.name, 'photo_path', d.photo_path, 'breed', d.breed)
             order by d.sort_order, d.created_at
           ) as dogs
      from public.presence_dogs pd
      join public.dogs d on d.id = pd.dog_id
     where pd.presence_id = pr.id
  ) dg on true
 where pr.ended_at is null
   and pr.expires_at > (select private.app_now());

grant select on public.my_friends, public.presence_board to authenticated;
grant select on public.my_friends, public.presence_board to service_role;
