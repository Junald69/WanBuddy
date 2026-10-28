-- 02: 閲覧マトリクス(PRD 7.2): 4種の閲覧者 × 公開範囲(public/friends/private)
--   閲覧者: 本人 / 友達 / 登録済みの非友達 / ブロック関係(相手にブロックされた・自分がブロックした の両方向)
--   対象:   profiles, dogs, presences, presence_dogs, dog_instagram, profile_settings, ビュー
\set ON_ERROR_STOP on
begin;

-- ---- フィクスチャ -------------------------------------------------------------
select tests.mkuser('o_public',  'public',  'public');
select tests.mkuser('o_friends', 'friends', 'friends');
select tests.mkuser('o_private', 'private', 'private');
select tests.mkuser('friend');
select tests.mkuser('stranger');
select tests.mkuser('blocked');     -- 元友達 → 各オーナーにブロックされる
select tests.mkuser('blocker');     -- 元友達 → 各オーナーを自分がブロックする
select tests.mkuser('third');       -- 第三者(友達の友達の検証用)

do $$
declare o text;
begin
  foreach o in array array['o_public', 'o_friends', 'o_private'] loop
    perform tests.befriend('friend', o);
    perform tests.befriend('blocked', o);
    perform tests.befriend('blocker', o);
  end loop;
  -- friend と third は友達(o_* とは無関係)
  perform tests.befriend('friend', 'third');
  foreach o in array array['o_public', 'o_friends', 'o_private'] loop
    perform tests.block(o, 'blocked');
    perform tests.block('blocker', o);
  end loop;
end $$;

-- ブロックで友達関係が削除されている
select tests.ok('ブロック成立で友達関係が削除される(オーナー側ブロック)',
  not exists (select 1 from public.friendships f
               where f.requester_id = tests.uid('blocked') or f.addressee_id = tests.uid('blocked')));
select tests.ok('ブロック成立で友達関係が削除される(自分がブロック)',
  not exists (select 1 from public.friendships f
               where f.requester_id = tests.uid('blocker') or f.addressee_id = tests.uid('blocker')));

-- ---- profiles / dogs の全ケース -----------------------------------------------------
create temp table exp (viewer text, owner_vis text, visible int);
grant all on exp to public;
insert into exp
select v.viewer, o.vis,
  case
    when v.viewer = 'self' then 1
    when v.viewer = 'friend'   then (o.vis in ('public', 'friends'))::int
    when v.viewer = 'stranger' then (o.vis = 'public')::int
    else 0                                            -- blocked / blocker
  end
from (values ('self'), ('friend'), ('stranger'), ('blocked'), ('blocker')) v(viewer)
cross join (values ('public'), ('friends'), ('private')) o(vis);

do $$
declare r record; who text; n bigint;
begin
  for r in select * from exp order by 1, 2 loop
    who := case when r.viewer = 'self' then 'o_' || r.owner_vis else r.viewer end;
    perform tests.become(who);
    n := tests.cnt(format('select 1 from public.profiles where id = %L', tests.uid('o_' || r.owner_vis)));
    perform tests.eq(format('profiles: 閲覧者=%s 公開範囲=%s', r.viewer, r.owner_vis), n::int, r.visible);
    n := tests.cnt(format('select 1 from public.dogs where id = %L', tests.dog_uid('o_' || r.owner_vis, 1)));
    perform tests.eq(format('dogs: 閲覧者=%s 公開範囲=%s', r.viewer, r.owner_vis), n::int, r.visible);
  end loop;
  perform tests.become_super();
end $$;

-- 一覧(where無し)でも漏れない: 各閲覧者が見える profiles の件数
select tests.become('stranger');
select tests.eq('stranger: profiles全件取得で見えるのは 自分+public のみ', tests.cnt('select 1 from public.profiles'), 2::bigint);
select tests.eq('stranger: dogs全件取得で見えるのは 自分の犬+public犬のみ', tests.cnt('select 1 from public.dogs'), 2::bigint);
select tests.become('blocked');
select tests.eq('blocked: profiles全件=自分のみ(オーナー全員が不可視)', tests.cnt('select 1 from public.profiles'), 1::bigint);
select tests.become('blocker');
select tests.eq('blocker(自分がブロック): profiles全件=自分のみ', tests.cnt('select 1 from public.profiles'), 1::bigint);
select tests.become('friend');
-- friend: 自分 + third(友達, friends公開) + o_public + o_friends
select tests.eq('friend: profiles全件=自分+third+o_public+o_friends', tests.cnt('select 1 from public.profiles'), 4::bigint);
select tests.become_super();

-- ---- profile_settings / 招待コードは本人以外に絶対見せない --------------------------------------
select tests.become('friend');
select tests.eq('友達でも他人の profile_settings(招待コード)は見えない',
  tests.cnt(format('select 1 from public.profile_settings where user_id = %L', tests.uid('o_public'))), 0::bigint);
select tests.eq('自分の profile_settings は見える', tests.cnt('select 1 from public.profile_settings'), 1::bigint);
select tests.become('o_public');
select tests.eq('本人は自分の profile_settings が見える',
  tests.cnt(format('select 1 from public.profile_settings where user_id = %L', tests.uid('o_public'))), 1::bigint);
select tests.become_super();

-- ---- presences / presence_dogs: 犬ごとの公開範囲が在場表示に反映される ---------------------------------
-- owner multi: 3頭(public/friends/private)で在場中。presence.visibility = friends
select tests.mkuser('multi', 'friends', 'public');          -- dog1 = public
select tests.befriend('friend', 'multi');
select tests.befriend('blocked', 'multi');
select tests.block('multi', 'blocked');
select tests.mkdog('multi', 2, 'friends');
select tests.mkdog('multi', 3, 'private');
insert into public.presences (id, user_id, facility_id, status, started_at, expires_at)
values (tests.dog_uid('multi', 100), tests.uid('multi'), tests.facility(), 'now', now(), now() + interval '2 hours');
insert into public.presence_dogs (presence_id, dog_id)
select tests.dog_uid('multi', 100), tests.dog_uid('multi', n) from generate_series(1, 3) n;
-- 非公開在場(visibility=private)
select tests.mkuser('shy', 'friends', 'friends');
select tests.befriend('friend', 'shy');
insert into public.presences (id, user_id, facility_id, status, started_at, expires_at, visibility)
values (tests.dog_uid('shy', 100), tests.uid('shy'), tests.facility(), 'now', now(), now() + interval '2 hours', 'private');
insert into public.presence_dogs (presence_id, dog_id) values (tests.dog_uid('shy', 100), tests.dog_uid('shy', 1));

select tests.become('multi');
select tests.eq('在場: 本人は自分の在場が見える', tests.cnt(format('select 1 from public.presences where id = %L', tests.dog_uid('multi', 100))), 1::bigint);
select tests.eq('在場の犬: 本人は3頭すべて見える', tests.cnt(format('select 1 from public.presence_dogs where presence_id = %L', tests.dog_uid('multi', 100))), 3::bigint);
select tests.become('friend');
select tests.eq('在場: 友達には見える', tests.cnt(format('select 1 from public.presences where id = %L', tests.dog_uid('multi', 100))), 1::bigint);
select tests.eq('在場の犬: 友達にはprivateの犬が出ない(public+friends=2頭)', tests.cnt(format('select 1 from public.presence_dogs where presence_id = %L', tests.dog_uid('multi', 100))), 2::bigint);
select tests.eq('在場の犬: private犬の行は存在しない', tests.cnt(format('select 1 from public.presence_dogs where dog_id = %L', tests.dog_uid('multi', 3))), 0::bigint);
select tests.eq('private在場(visibility=private)は友達にも見えない', tests.cnt(format('select 1 from public.presences where id = %L', tests.dog_uid('shy', 100))), 0::bigint);
select tests.eq('private在場の犬も友達には見えない', tests.cnt(format('select 1 from public.presence_dogs where presence_id = %L', tests.dog_uid('shy', 100))), 0::bigint);
select tests.become('stranger');
select tests.eq('在場: 非友達には(犬がpublicでも)見えない', tests.cnt(format('select 1 from public.presences where id = %L', tests.dog_uid('multi', 100))), 0::bigint);
select tests.eq('在場の犬: 非友達には(犬がpublicでも)見えない', tests.cnt(format('select 1 from public.presence_dogs where presence_id = %L', tests.dog_uid('multi', 100))), 0::bigint);
select tests.become('blocked');
select tests.eq('在場: ブロック関係には見えない', tests.cnt(format('select 1 from public.presences where id = %L', tests.dog_uid('multi', 100))), 0::bigint);
select tests.become('shy');
select tests.eq('private在場でも本人は見える', tests.cnt(format('select 1 from public.presences where id = %L', tests.dog_uid('shy', 100))), 1::bigint);
select tests.become_super();

-- 在場ボード(view): 犬の配列に反映される
select tests.become('friend');
select tests.eq('presence_board: 友達には犬2頭のみ(private犬を含まない)',
  (select jsonb_array_length(dogs)::bigint from public.presence_board where presence_id = tests.dog_uid('multi', 100)), 2::bigint);
select tests.eq('presence_board: private在場は友達に出ない',
  tests.cnt(format('select 1 from public.presence_board where presence_id = %L', tests.dog_uid('shy', 100))), 0::bigint);
select tests.become('multi');
select tests.eq('presence_board: 本人は犬3頭',
  (select jsonb_array_length(dogs)::bigint from public.presence_board where presence_id = tests.dog_uid('multi', 100)), 3::bigint);
select tests.become('stranger');
select tests.eq('presence_board: 非友達は何も見えない', tests.cnt('select 1 from public.presence_board'), 0::bigint);
select tests.become_super();

-- 全部の犬が非公開 → 在場は友達に見えるが犬は空
select tests.mkuser('allpriv', 'friends', 'private');
select tests.befriend('friend', 'allpriv');
insert into public.presences (id, user_id, facility_id, status, started_at, expires_at)
values (tests.dog_uid('allpriv', 100), tests.uid('allpriv'), tests.facility(), 'now', now(), now() + interval '2 hours');
insert into public.presence_dogs values (tests.dog_uid('allpriv', 100), tests.dog_uid('allpriv', 1));
select tests.become('friend');
select tests.eq('全頭が非公開の在場: 在場は見え犬は0頭',
  (select jsonb_array_length(dogs)::bigint from public.presence_board where presence_id = tests.dog_uid('allpriv', 100)), 0::bigint);
select tests.become_super();

-- M-3: プロフィール非公開(private)でも、友達(accepted)にはニックネームだけは見える(PRD 4.4)。
--   在場ボード / my_friends の nickname は友達に返す。avatar_path や profiles 本体は私的なまま(NULL/見えない)。
select tests.mkuser('privprof', 'private', 'friends');
update public.profiles set avatar_path = tests.uid('privprof')::text || '/a.jpg' where id = tests.uid('privprof');
select tests.befriend('friend', 'privprof');
insert into public.presences (id, user_id, facility_id, status, started_at, expires_at)
values (tests.dog_uid('privprof', 100), tests.uid('privprof'), tests.facility(), 'now', now(), now() + interval '2 hours');
insert into public.presence_dogs values (tests.dog_uid('privprof', 100), tests.dog_uid('privprof', 1));
select tests.become('friend');
select tests.ok('M-3 プロフィール非公開の友達: 在場ボードに nickname が出る',
  (select nickname = 'privprof' and user_id = tests.uid('privprof') from public.presence_board
    where presence_id = tests.dog_uid('privprof', 100)));
select tests.ok('M-3 プロフィール非公開の友達: avatar_path は出ない(NULL)',
  (select avatar_path is null from public.presence_board where presence_id = tests.dog_uid('privprof', 100)));
select tests.ok('M-3 プロフィール非公開の友達: my_friends に nickname が出る・avatar_path は NULL',
  (select nickname = 'privprof' and avatar_path is null from public.my_friends
    where friend_id = tests.uid('privprof')));
select tests.eq('M-3 プロフィール本体(profiles)は友達にも見えないまま', tests.cnt('select 1 from public.profiles where id = tests.uid(''privprof'')'), 0::bigint);
select tests.eq('M-3 private.display_name: 友達(非公開プロフィール)は名前を返す', private.display_name(tests.uid('privprof')), 'privprof');
-- 非友達: 非公開プロフィールの名前は見えない / 公開プロフィールの名前は見える
select tests.become('stranger');
select tests.ok('M-3 非友達: 非公開プロフィールの display_name は NULL', private.display_name(tests.uid('privprof')) is null);
select tests.eq('M-3 非友達: 公開プロフィールの display_name は名前', private.display_name(tests.uid('o_public')), 'o_public');
select tests.ok('M-3 非友達: 在場ボードに非公開の友達の行は出ない', not exists (select 1 from public.presence_board where user_id = tests.uid('privprof')));
select tests.ok('M-3 非友達: my_friends は空', not exists (select 1 from public.my_friends));
-- ブロック関係(友達行が残っている不整合状態でも名前を出さない)
select tests.become_super();
select tests.mkuser('blk_a', 'private', 'friends');
select tests.mkuser('blk_b', 'private', 'friends');
select tests.block('blk_a', 'blk_b');
select tests.befriend('blk_a', 'blk_b');   -- ブロック後に友達行が(何らかの経緯で)存在してしまったと仮定
insert into public.presences (id, user_id, facility_id, status, started_at, expires_at)
values (tests.dog_uid('blk_b', 100), tests.uid('blk_b'), tests.facility(), 'now', now(), now() + interval '2 hours');
insert into public.presence_dogs values (tests.dog_uid('blk_b', 100), tests.dog_uid('blk_b', 1));
select tests.become('blk_a');
select tests.ok('M-3 ブロックした側: 友達行が残っていても nickname は NULL', (select nickname is null from public.my_friends where friend_id = tests.uid('blk_b')));
select tests.ok('M-3 ブロックした側: 在場ボードに相手は出ない', not exists (select 1 from public.presence_board where user_id = tests.uid('blk_b')));
select tests.ok('M-3 ブロックした側: display_name は NULL', private.display_name(tests.uid('blk_b')) is null);
select tests.become('blk_b');
select tests.ok('M-3 ブロックされた側: 友達行が残っていても nickname は NULL', (select nickname is null from public.my_friends where friend_id = tests.uid('blk_a')));
select tests.ok('M-3 ブロックされた側: display_name は NULL', private.display_name(tests.uid('blk_a')) is null);
select tests.become_super();
-- 未ログイン相当(sub無し)では NULL
select tests.become_authenticated_no_sub();
select tests.ok('M-3 sub無しの display_name は NULL', private.display_name(tests.uid('privprof')) is null);
select tests.become_super();

-- 期限切れ/終了した在場は他人には見えない(本人には履歴として見える)
select tests.mkuser('past');
select tests.befriend('friend', 'past');
insert into public.presences (id, user_id, facility_id, status, started_at, expires_at)
values (tests.dog_uid('past', 100), tests.uid('past'), tests.facility(), 'now', now() - interval '5 hours', now() - interval '1 hour');
insert into public.presence_dogs values (tests.dog_uid('past', 100), tests.dog_uid('past', 1));
select tests.become('friend');
select tests.eq('期限切れ(未完了処理)の在場は友達に見えない', tests.cnt(format('select 1 from public.presences where id = %L', tests.dog_uid('past', 100))), 0::bigint);
select tests.eq('presence_board にも出ない', tests.cnt(format('select 1 from public.presence_board where presence_id = %L', tests.dog_uid('past', 100))), 0::bigint);
select tests.become('past');
select tests.eq('期限切れの在場は本人には見える', tests.cnt(format('select 1 from public.presences where id = %L', tests.dog_uid('past', 100))), 1::bigint);
select tests.eq('期限切れの在場は presence_board には出ない(本人でも)', tests.cnt('select 1 from public.presence_board'), 0::bigint);
select tests.become_super();

-- ---- dog_instagram: 犬の公開範囲 AND Instagram個別の公開範囲 ------------------------------------------
select tests.mkuser('ig', 'public', 'public');
select tests.mkuser('ig2', 'public', 'friends');
select tests.befriend('friend', 'ig');
select tests.befriend('friend', 'ig2');
insert into public.dog_instagram (dog_id, handle, visibility) values
  (tests.dog_uid('ig', 1), 'ig_friends_only', 'friends'),
  (tests.dog_uid('ig2', 1), 'ig2_friends', 'friends');
select tests.mkdog('ig', 2, 'public');
insert into public.dog_instagram (dog_id, handle, visibility) values (tests.dog_uid('ig', 2), 'ig_private', 'private');

select tests.become('friend');
select tests.eq('Instagram: 友達限定の設定は友達に見える', tests.cnt(format('select 1 from public.dog_instagram where dog_id = %L', tests.dog_uid('ig', 1))), 1::bigint);
select tests.eq('Instagram: 非公開設定は友達にも見えない', tests.cnt(format('select 1 from public.dog_instagram where dog_id = %L', tests.dog_uid('ig', 2))), 0::bigint);
select tests.eq('Instagram: 犬がfriends公開+IG friends → 友達に見える', tests.cnt(format('select 1 from public.dog_instagram where dog_id = %L', tests.dog_uid('ig2', 1))), 1::bigint);
select tests.become('stranger');
select tests.eq('Instagram: 犬がpublicでも IG が友達限定なら非友達に見えない', tests.cnt(format('select 1 from public.dog_instagram where dog_id = %L', tests.dog_uid('ig', 1))), 0::bigint);
select tests.become('ig');
select tests.eq('Instagram: 本人は全て見える', tests.cnt('select 1 from public.dog_instagram'), 2::bigint);
select tests.become_super();
-- 犬が friends のとき、犬自体が見えない人にはIGも見えない
select tests.become('stranger');
select tests.eq('Instagram: 犬が見えない非友達にはIGも見えない', tests.cnt(format('select 1 from public.dog_instagram where dog_id = %L', tests.dog_uid('ig2', 1))), 0::bigint);
select tests.become_super();

-- ---- 判定関数そのものの安全性(第三者視点での探索の防止) -------------------------------------------------
select tests.become('stranger');
select tests.ok('can_view: 他人を viewer に指定しても false(探索不可)',
  not private.can_view(tests.uid('friend'), tests.uid('o_public'), 'public'));
select tests.ok('is_friend: 無関係な第三者2人の友達関係は探れない(false)',
  not private.is_friend(tests.uid('friend'), tests.uid('third')));
select tests.ok('can_view: 自分視点の public は true', private.can_view(tests.uid('stranger'), tests.uid('o_public'), 'public'));
select tests.ok('can_view: 不明な visibility 値は false', not private.can_view(tests.uid('stranger'), tests.uid('o_public'), 'unknown'));
select tests.ok('can_view: NULL visibility は false', not private.can_view(tests.uid('stranger'), tests.uid('o_public'), null));
select tests.ok('can_view: NULL viewer は false', not private.can_view(null, tests.uid('o_public'), 'public'));
select tests.ok('can_view: 自分自身は private でも true', private.can_view(tests.uid('stranger'), tests.uid('stranger'), 'private'));
select tests.become('friend');
select tests.ok('is_friend: 当事者視点なら true', private.is_friend(tests.uid('friend'), tests.uid('third')));
select tests.ok('is_friend: ブロック関係なら(友達だった過去があっても)false', not private.is_friend(tests.uid('friend'), tests.uid('blocked')));
select tests.become_super();
-- 友達行が不整合に残っていても(例: 手動投入)、ブロック作成時に友達行が消える
insert into public.friendships (requester_id, addressee_id, status, method) values (tests.uid('stranger'), tests.uid('blocked'), 'accepted', 'request');
insert into public.blocks values (tests.uid('stranger'), tests.uid('blocked'));   -- トリガーで友達行も消える
select tests.ok('ブロックトリガー: 不整合な友達行もブロック作成時に削除される',
  not exists (select 1 from public.friendships where requester_id = tests.uid('stranger') and addressee_id = tests.uid('blocked')));

-- is_blocked_either は authenticated から直接呼べない(ブロック探索の防止)
select tests.become('stranger');
select tests.throws('is_blocked_either は authenticated から呼べない', format('select private.is_blocked_either(%L, %L)', tests.uid('stranger'), tests.uid('blocked')), '42501');
select tests.throws('friend_count は authenticated から呼べない', format('select private.friend_count(%L)', tests.uid('stranger')), '42501');
select tests.become_super();

-- ---- ブロックの可視性: ブロックされた側は blocks 行を見られない -------------------------------------------
select tests.become('blocked');
select tests.eq('ブロックされた側は blocks を1行も見られない(ブロックを悟れない)', tests.cnt('select 1 from public.blocks'), 0::bigint);
select tests.become('o_public');
select tests.eq('ブロックした側は自分のブロックが見える', tests.cnt('select 1 from public.blocks'), 1::bigint);
select tests.become_super();

rollback;
