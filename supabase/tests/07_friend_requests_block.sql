-- 07: 招待コード/ユーザーID申請(承認制)・承認/拒否・上限・ブロック・情報の非開示
\set ON_ERROR_STOP on
begin;

select tests.set_now_jst('2026-10-28 12:00');
select tests.mkuser('a'); select tests.mkuser('b'); select tests.mkuser('c'); select tests.mkuser('d');
select tests.mkuser('hidden');   -- searchable=false
select tests.mkuser('x');

select user_code as ucode_b from public.profiles where id = tests.uid('b') \gset
select user_code as ucode_hidden from public.profiles where id = tests.uid('hidden') \gset
select invite_code as icode_b from public.profile_settings where user_id = tests.uid('b') \gset
select invite_code as icode_hidden from public.profile_settings where user_id = tests.uid('hidden') \gset
select tests.ok('searchable の既定は false(3.3: ID検索で見つかるは既定OFF)', (select not searchable from public.profile_settings where user_id = tests.uid('b')));
update public.profile_settings set searchable = true where user_id in (tests.uid('a'), tests.uid('b'), tests.uid('c'), tests.uid('d'), tests.uid('x'));
select tests.ok('user_code は小文字英数字、invite_code は10桁の大文字英数字', :'ucode_b' ~ '^[a-z0-9_]{3,}$' and :'icode_b' ~ '^[A-HJ-NP-Z2-9]{10}$');

-- ---- ID検索(完全一致のみ・ニックネームとアイコンだけ) ------------------------------------------------
select tests.become('a');
select tests.eq('ID検索: 完全一致で相手が見つかる(nicknameのみ)', (select nickname from public.search_user_by_user_code(:'ucode_b')), 'b');
select tests.eq('ID検索: 前方一致は不可', tests.cnt(format('select 1 from public.search_user_by_user_code(%L)', left(:'ucode_b', 3))), 0::bigint);
select tests.eq('ID検索: 大文字小文字・空白は正規化される', tests.cnt(format('select 1 from public.search_user_by_user_code(%L)', '  ' || upper(:'ucode_b') || ' ')), 1::bigint);
select tests.eq('ID検索: searchable=false は0行', tests.cnt(format('select 1 from public.search_user_by_user_code(%L)', :'ucode_hidden')), 0::bigint);
select tests.eq('ID検索: 存在しないIDも0行(区別不可)', tests.cnt('select 1 from public.search_user_by_user_code(''no_such_user_zz'')'), 0::bigint);
select tests.eq('ID検索: 自分自身は0行', tests.cnt(format('select 1 from public.search_user_by_user_code(%L)', tests.ucode('a'))), 0::bigint);
select tests.eq('ID検索: NULLは0行', tests.cnt('select 1 from public.search_user_by_user_code(null)'), 0::bigint);
select tests.eq('ID検索で申請: searchable=false は 見つからない WB011', tests.errstate(format('select public.request_friend_by_user_code(%L)', :'ucode_hidden')), 'WB011');
select tests.eq('ID検索で申請: 存在しないID WB011(同じ)', tests.errstate('select public.request_friend_by_user_code(''no_such_user_zz'')'), 'WB011');
select tests.become_super();
-- プロフィール未作成のログインユーザー
insert into auth.users (id, email) values (tests.uid('noprof'), 'noprof@example.test');
select tests.become('noprof');
select tests.eq('プロフィール未作成: 検索 WB402', tests.errstate(format('select * from public.search_user_by_user_code(%L)', :'ucode_b')), 'WB402');
select tests.eq('プロフィール未作成: 申請 WB402', tests.errstate(format('select public.request_friend_by_invite_code(%L)', :'icode_b')), 'WB402');
select tests.become_super();

-- ---- 招待コードで申請 → 承認 ----------------------------------------------------------------------
select tests.become('a');
select public.request_friend_by_invite_code(lower(:'icode_b')) as fs1 \gset
select tests.become_super();
select tests.ok('申請: pending / method=code / 申請者=a',
  (select status = 'pending' and method = 'code' and requester_id = tests.uid('a') and addressee_id = tests.uid('b') and responded_at is null
     from public.friendships where id = :'fs1'));
select tests.become('a');
select tests.eq('申請中は相手のプロフィールは見えない(pending)', tests.cnt(format('select 1 from public.profiles where id = %L', tests.uid('b'))), 0::bigint);
select tests.eq('同じ相手への再申請 WB006', tests.errstate(format('select public.request_friend_by_invite_code(%L)', :'icode_b')), 'WB006');
select tests.eq('申請者は自分で承認できない WB015', tests.errstate(format('select public.respond_friend_request(%L, true)', :'fs1')), 'WB015');
select tests.become('c');
select tests.eq('第三者は承認できない WB015', tests.errstate(format('select public.respond_friend_request(%L, true)', :'fs1')), 'WB015');
select tests.eq('第三者は申請を一覧で見られない', tests.cnt('select 1 from public.list_incoming_friend_requests()'), 0::bigint);
select tests.eq('第三者は friendships を見られない', tests.cnt(format('select 1 from public.friendships where id = %L', :'fs1')), 0::bigint);
select tests.become('b');
select tests.eq('受信一覧に1件(申請者のnickname付き)', (select from_nickname from public.list_incoming_friend_requests()), 'a');
select tests.eq('承認 → accepted', public.respond_friend_request(:'fs1', true), 'accepted');
select tests.eq('承認済みを再度承認/拒否 WB015', tests.errstate(format('select public.respond_friend_request(%L, false)', :'fs1')), 'WB015');
select tests.eq('承認後: 相手のプロフィールが見える(friends)', tests.cnt(format('select 1 from public.profiles where id = %L', tests.uid('a'))), 1::bigint);
select tests.eq('承認後の受信一覧は空', tests.cnt('select 1 from public.list_incoming_friend_requests()'), 0::bigint);
select tests.eq('承認済みの友達に申請 WB003', tests.errstate(format('select public.request_friend_by_user_code(%L)', tests.ucode('a'))), 'WB003');
select tests.become_super();

-- ---- 拒否 → 再申請不可(申請者側) ------------------------------------------------------------------
select tests.become('c');
select public.request_friend_by_user_code(:'ucode_b') as fs2 \gset
select tests.become('b');
select tests.eq('拒否 → declined', public.respond_friend_request(:'fs2', false), 'declined');
select tests.become('c');
select tests.eq('拒否された側は再申請できない WB013', tests.errstate(format('select public.request_friend_by_user_code(%L)', :'ucode_b')), 'WB013');
select tests.eq('拒否された側から相手が友達に見えない', tests.cnt(format('select 1 from public.profiles where id = %L', tests.uid('b'))), 0::bigint);
select tests.become('b');
select tests.eq('拒否した側は受信一覧に出ない', tests.cnt('select 1 from public.list_incoming_friend_requests()'), 0::bigint);
select public.request_friend_by_invite_code(tests.icode('c')) as fs3 \gset
select tests.become_super();
select tests.eq('拒否した側から申請 → 拒否履歴を消し新規pending', (select count(*) from public.friendships where id = :'fs2'), 0::bigint);
select tests.become('c');
select tests.eq('(続き)bの申請を c が承認できる', public.respond_friend_request(:'fs3', true), 'accepted');
select tests.become_super();

-- ---- 相互申請 → 自動承認 ------------------------------------------------------------------------------
select tests.become('x');
select public.request_friend_by_user_code(tests.ucode('d')) as fs4 \gset
select tests.become('d');
select tests.eq('相互申請(逆向き申請がpending) → 即承認され同じ行が使われる', public.request_friend_by_user_code(tests.ucode('x')), :'fs4'::uuid);
select tests.become_super();
select tests.eq('(続き)accepted、重複行なし', (select count(*) from public.friendships where status = 'accepted' and tests.uid('x') in (requester_id, addressee_id) and tests.uid('d') in (requester_id, addressee_id)), 1::bigint);

-- ---- 自分自身 ------------------------------------------------------------------------------------------
select tests.become('a');
select tests.eq('自分の招待コードで申請 WB002', tests.errstate(format('select public.request_friend_by_invite_code(%L)', tests.icode('a'))), 'WB002');
select tests.eq('不正な招待コード WB011', tests.errstate('select public.request_friend_by_invite_code(''ZZZZZZZZZZ'')'), 'WB011');
select tests.eq('NULL招待コード WB011', tests.errstate('select public.request_friend_by_invite_code(null)'), 'WB011');

-- ---- 招待コード再生成 ----------------------------------------------------------------------------------
select tests.become('b');
select public.regenerate_invite_code() as newcode \gset
select tests.ok('再生成: 新コードは旧コードと異なる形式OKの10桁', :'newcode' <> :'icode_b' and :'newcode' ~ '^[A-HJ-NP-Z2-9]{10}$');
select tests.become('x');
select tests.eq('旧コードは即無効 WB011', tests.errstate(format('select public.request_friend_by_invite_code(%L)', :'icode_b')), 'WB011');
select tests.lives('新コードは有効', format('select public.request_friend_by_invite_code(%L)', :'newcode'));
select tests.become('b');
select tests.ok('profile_settings は本人のみ参照できる(他人のinvite_codeは読めない)', tests.cnt(format('select 1 from public.profile_settings where user_id = %L', tests.uid('a'))) = 0);
select tests.become_super();

-- ---- 申請の上限(未承認の送信) ------------------------------------------------------------------------
update private.app_config set value = '2' where key = 'max_outgoing_pending_requests';
select tests.mkuser('t1'); select tests.mkuser('t2'); select tests.mkuser('t3');
select tests.mkuser('spammer');
select tests.become('spammer');
select public.request_friend_by_invite_code(tests.icode('t1'));
select public.request_friend_by_invite_code(tests.icode('t2'));
select tests.eq('未承認の送信申請が上限(2)で WB014', tests.errstate(format('select public.request_friend_by_invite_code(%L)', tests.icode('t3'))), 'WB014');
select tests.become_super();
update private.app_config set value = '30' where key = 'max_outgoing_pending_requests';

-- ---- 友達上限 ------------------------------------------------------------------------------------------
update private.app_config set value = '2' where key = 'max_friends';
select tests.mkuser('cap'); select tests.mkuser('f1'); select tests.mkuser('f2'); select tests.mkuser('f3'); select tests.mkuser('f4');
select tests.befriend('cap', 'f1'); select tests.befriend('cap', 'f2');
select tests.become('f3');
select tests.eq('相手が上限: 申請は可能(承認時に判定)', (select 1 from (select public.request_friend_by_invite_code(tests.icode('cap'))) s), 1);
select tests.become('cap');
select id as capfs from public.friendships where requester_id = tests.uid('f3') and addressee_id = tests.uid('cap') \gset
select tests.eq('承認側が上限: 承認不可 WB005', tests.errstate(format('select public.respond_friend_request(%L, true)', :'capfs')), 'WB005');
select tests.eq('上限でも拒否はできる', public.respond_friend_request(:'capfs', false), 'declined');
select tests.eq('上限ユーザーからの申請 WB005', tests.errstate(format('select public.request_friend_by_invite_code(%L)', tests.icode('f4'))), 'WB005');
select tests.become('f4');
select public.request_friend_by_invite_code(tests.icode('cap'));
select tests.become_super();
-- 申請者が上限に達していた場合、承認側からは曖昧なエラー(WB009)
select tests.mkuser('g1'); select tests.mkuser('g2'); select tests.mkuser('req'); select tests.mkuser('addr');
select tests.become('req');
select public.request_friend_by_invite_code(tests.icode('addr')) as fs9 \gset
select tests.become_super();
select tests.befriend('req', 'g1'); select tests.befriend('req', 'g2');
select tests.become('addr');
select tests.eq('申請者が上限: 承認不可 WB009(承認側に相手の友達数を悟らせない文言)', tests.errstate(format('select public.respond_friend_request(%L, true)', :'fs9')), 'WB009');
select tests.become_super();
update private.app_config set value = '100' where key = 'max_friends';

-- ---- ブロック -------------------------------------------------------------------------------------------
select tests.mkuser('blocker'); select tests.mkuser('victim'); select tests.mkuser('bystander');
select tests.befriend('blocker', 'victim');
select tests.become('victim');
select tests.eq('ブロック前: 友達として見える', tests.cnt(format('select 1 from public.profiles where id = %L', tests.uid('blocker'))), 1::bigint);
select tests.become('blocker');
insert into public.blocks (blocker_id, blocked_id) values ((select auth.uid()), tests.uid('victim'));
select tests.become_super();
select tests.eq('ブロックすると友達関係は即削除される', (select count(*) from public.friendships where tests.uid('blocker') in (requester_id, addressee_id) and tests.uid('victim') in (requester_id, addressee_id)), 0::bigint);
select tests.become('victim');
select tests.eq('ブロックされた側: 相手が見えない', tests.cnt(format('select 1 from public.profiles where id = %L', tests.uid('blocker'))), 0::bigint);
select tests.eq('ブロックされた側: 申請しても「見つからない」 WB011(ブロックを悟らせない)', tests.errstate(format('select public.request_friend_by_invite_code(%L)', tests.icode('blocker'))), 'WB011');
select tests.eq('ブロックされた側: ID検索で出ない', tests.cnt(format('select 1 from public.search_user_by_user_code(%L)', tests.ucode('blocker'))), 0::bigint);
select tests.eq('ブロックされた側は blocks を見られない(自分がブロックされている事実は不可視)', tests.cnt('select 1 from public.blocks'), 0::bigint);
select tests.become('blocker');
select tests.eq('ブロックした側: 自分のブロック一覧が見える', tests.cnt('select 1 from public.blocks'), 1::bigint);
select tests.eq('ブロックした側: 相手に申請しても WB011', tests.errstate(format('select public.request_friend_by_invite_code(%L)', tests.icode('victim'))), 'WB011');
select tests.eq('自分自身はブロックできない(RLS WITH CHECK)', tests.errstate(format('insert into public.blocks (blocker_id, blocked_id) values (%L, %L)', tests.uid('blocker'), tests.uid('blocker'))), '42501');
select tests.eq('他人名義のブロックは作れない(RLS)', tests.errstate(format('insert into public.blocks (blocker_id, blocked_id) values (%L, %L)', tests.uid('bystander'), tests.uid('victim'))), '42501');
select tests.eq('ブロック解除(DELETE)ができる', tests.affected('delete from public.blocks'), 1::bigint);
select tests.become('victim');
select tests.lives('解除後は申請できる', format('select public.request_friend_by_invite_code(%L)', tests.icode('blocker')));
select tests.become_super();

-- ブロック中の pending 申請は 承認側に見えない/承認できない
select tests.mkuser('p1'); select tests.mkuser('p2');
select tests.become('p1');
select public.request_friend_by_invite_code(tests.icode('p2')) as fs10 \gset
select tests.become('p2');
insert into public.blocks (blocker_id, blocked_id) values ((select auth.uid()), tests.uid('p1'));
select tests.eq('ブロック中: 受信一覧に出ない', tests.cnt('select 1 from public.list_incoming_friend_requests()'), 0::bigint);
select tests.eq('ブロック中: 承認できない WB015', tests.errstate(format('select public.respond_friend_request(%L, true)', :'fs10')), 'WB015');
select tests.become_super();

-- ---- 友達の削除(双方向) ---------------------------------------------------------------------------------
select tests.mkuser('del1'); select tests.mkuser('del2');
select tests.befriend('del1', 'del2');
select tests.become('del2');
select tests.eq('友達削除: 当事者(addressee側)が削除できる', tests.affected(format('delete from public.friendships where addressee_id = %L', tests.uid('del2'))), 1::bigint);
select tests.become('del1');
select tests.eq('友達削除後: 相手側からも見えなくなる', tests.cnt(format('select 1 from public.profiles where id = %L', tests.uid('del2'))), 0::bigint);
select tests.become('bystander');
select tests.eq('第三者は他人の友達関係を削除できない(0行)', tests.affected('delete from public.friendships'), 0::bigint);

rollback;
