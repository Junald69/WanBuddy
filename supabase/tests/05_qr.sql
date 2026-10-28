-- 05: QR友達登録(自動承認)と全ての拒否ケース
\set ON_ERROR_STOP on
begin;

select tests.mkuser('owner');
select tests.mkuser('s1'); select tests.mkuser('s2'); select tests.mkuser('s3');
select tests.mkuser('s4'); select tests.mkuser('s5'); select tests.mkuser('s6');
select tests.mkuser('blk_by_owner'); select tests.mkuser('blk_by_me');
select tests.mkuser('friendly');
select tests.befriend('owner', 'friendly');

select tests.set_now_jst('2026-10-28 12:00');

-- ---- 発行 -------------------------------------------------------------------------
select tests.become('owner');
select qr_token as tok1, qr_expires_at as exp1 from public.issue_qr_token() \gset
select tests.ok('発行: トークンは64桁の16進', :'tok1' ~ '^[0-9a-f]{64}$');
select tests.eq('発行: 有効期限は10分後', :'exp1'::timestamptz, tests.jst('2026-10-28 12:10'));
select tests.become_super();
select tests.ok('平文トークンはDBに保存されない(sha256のみ)',
  not exists (select 1 from public.qr_tokens where encode(token_hash, 'hex') = :'tok1')
  and exists (select 1 from public.qr_tokens where token_hash = sha256(convert_to(:'tok1', 'UTF8'))));
select tests.eq('発行: max_uses=5', (select max_uses from public.qr_tokens where token_hash = sha256(convert_to(:'tok1', 'UTF8'))), 5);

select tests.become('owner');
select tests.throws('QR: authenticated は qr_tokens を直接参照できない', 'select * from public.qr_tokens', '42501');
select tests.throws('QR: authenticated は qr_tokens へ直接INSERTできない', format('insert into public.qr_tokens (user_id, token_hash, expires_at, max_uses) values (%L, ''\x00'', now(), 1)', tests.uid('owner')), '42501');
select tests.become_super();

-- ---- 正常系(自動承認) ------------------------------------------------------------------
select tests.become('s1');
select tests.eq('QR読み取り: 成功し相手のニックネームを返す', (select friend_nickname from public.redeem_qr_token(:'tok1')), 'owner');
select tests.become_super();
select tests.ok('QR読み取り: 即 accepted / method=qr / 読み取り側がrequester',
  exists (select 1 from public.friendships where requester_id = tests.uid('s1') and addressee_id = tests.uid('owner')
            and status = 'accepted' and method = 'qr' and responded_at is not null));
select tests.eq('QR読み取り: use_count が1になる', (select use_count from public.qr_tokens where token_hash = sha256(convert_to(:'tok1', 'UTF8'))), 1);
select tests.eq('QR読み取り: 読み取りログが残る', (select count(*) from public.qr_scans where scanner_id = tests.uid('s1')), 1::bigint);
select tests.become('s1');
select tests.eq('QR読み取り後: 友達としてお互いの公開範囲(friends)が見える', tests.cnt(format('select 1 from public.profiles where id = %L', tests.uid('owner'))), 1::bigint);
select tests.eq('my_friends ビューに出る', tests.cnt('select 1 from public.my_friends'), 1::bigint);
select tests.become('owner');
select tests.eq('相手側(QR表示側)からも友達として見える', tests.cnt(format('select 1 from public.profiles where id = %L', tests.uid('s1'))), 1::bigint);
select tests.become_super();

-- ---- 拒否: 既に友達 / 自分自身 / 不正トークン -------------------------------------------------------
select tests.become('s1');
select tests.eq('QR: 既に友達 → WB003', tests.errstate(format('select * from public.redeem_qr_token(%L)', :'tok1')), 'WB003');
select tests.become('owner');
select tests.eq('QR: 自分自身 → WB002', tests.errstate(format('select * from public.redeem_qr_token(%L)', :'tok1')), 'WB002');
select tests.become('s2');
select tests.eq('QR: 存在しないトークン → WB001', tests.errstate('select * from public.redeem_qr_token(''0000000000000000000000000000000000000000000000000000000000000000'')'), 'WB001');
select tests.eq('QR: 短すぎるトークン → WB001', tests.errstate('select * from public.redeem_qr_token(''abc'')'), 'WB001');
select tests.eq('QR: NULL → WB001', tests.errstate('select * from public.redeem_qr_token(null)'), 'WB001');
select tests.eq('QR: 他人の友達関係の探索はできない(失敗してもフレンド行は増えない)',
  (select count(*) from public.friendships where requester_id = tests.uid('s2') or addressee_id = tests.uid('s2')), 0::bigint);
select tests.become_super();

-- ---- 回数上限(5回) ---------------------------------------------------------------------------
select tests.become('s2'); select 1 from public.redeem_qr_token(:'tok1');
select tests.become('s3'); select 1 from public.redeem_qr_token(:'tok1');
select tests.become('s4'); select 1 from public.redeem_qr_token(:'tok1');
select tests.become('s5'); select 1 from public.redeem_qr_token(:'tok1');
select tests.become_super();
select tests.eq('QR: 5回目まで成功(s1〜s5)', (select use_count from public.qr_tokens where token_hash = sha256(convert_to(:'tok1', 'UTF8'))), 5);
select tests.become('s6');
select tests.eq('QR: 6回目は回数超過で拒否 WB001', tests.errstate(format('select * from public.redeem_qr_token(%L)', :'tok1')), 'WB001');
select tests.become_super();
select tests.ok('QR: 回数超過では友達にならない', not exists (select 1 from public.friendships where requester_id = tests.uid('s6')));

-- ---- 再生成で旧QRは無効 ------------------------------------------------------------------------------
select tests.become('owner');
select qr_token as tok2 from public.issue_qr_token() \gset
select tests.become('s6');
select tests.eq('QR: 再生成した新QR(tok2)は有効', tests.errstate(format('select * from public.redeem_qr_token(%L)', :'tok2')), null) \gset
select tests.become_super();
select tests.ok('(上の続き)新QRで s6 が友達になる', exists (select 1 from public.friendships where requester_id = tests.uid('s6') and status = 'accepted'));

select tests.become('owner');
select qr_token as tok3 from public.issue_qr_token() \gset
select qr_token as tok4 from public.issue_qr_token() \gset
select tests.become('blk_by_owner');
select tests.eq('QR: 再生成された古いQR(tok3)は無効 WB001', tests.errstate(format('select * from public.redeem_qr_token(%L)', :'tok3')), 'WB001');
select tests.become_super();
select tests.eq('QR: 発行済みで有効なトークンは常に1つだけ', (select count(*) from public.qr_tokens where user_id = tests.uid('owner') and revoked_at is null), 1::bigint);

-- ---- 失効(F2を閉じる) ---------------------------------------------------------------------------------
select tests.become('owner');
select tests.eq('QR失効: 1件失効', public.revoke_qr_tokens(), 1);
select tests.become('blk_by_owner');
select tests.eq('QR: 失効したQR(tok4)は無効 WB001', tests.errstate(format('select * from public.redeem_qr_token(%L)', :'tok4')), 'WB001');
select tests.become_super();

-- ---- 有効期限(10分) -------------------------------------------------------------------------------------
select tests.set_now_jst('2026-10-28 13:00');
select tests.become('owner');
select qr_token as tok5 from public.issue_qr_token() \gset
select tests.set_now_jst('2026-10-28 13:09');
select tests.become('blk_by_owner');
select tests.eq('QR: 9分後はまだ有効(期限直前)', tests.errstate(format('select * from public.redeem_qr_token(%L)', :'tok5')), null) \gset
select tests.become_super();
select tests.ok('(上の続き)期限直前の読み取りで友達になる', exists (select 1 from public.friendships where requester_id = tests.uid('blk_by_owner')));
delete from public.friendships where requester_id = tests.uid('blk_by_owner');

select tests.set_now_jst('2026-10-28 13:10');
select tests.become('blk_by_owner');
select tests.eq('QR: ちょうど10分後は期限切れ WB001', tests.errstate(format('select * from public.redeem_qr_token(%L)', :'tok5')), 'WB001');
select tests.set_now_jst('2026-10-28 14:00');
select tests.eq('QR: 1時間後も期限切れ WB001', tests.errstate(format('select * from public.redeem_qr_token(%L)', :'tok5')), 'WB001');
select tests.become_super();

-- ---- ブロック: 理由を悟らせない(文言とコードが期限切れと同一) --------------------------------------------------
select tests.set_now_jst('2026-10-28 15:00');
select tests.become('owner');
select qr_token as tok6 from public.issue_qr_token() \gset
select tests.become_super();
select tests.block('owner', 'blk_by_owner');                       -- オーナーがブロック
select tests.become('blk_by_owner');
select tests.eq('QR: オーナーにブロックされている場合 WB001', tests.errstate(format('select * from public.redeem_qr_token(%L)', :'tok6')), 'WB001');
select tests.eq('QR: ブロック拒否のメッセージは「期限切れ」と同一(ブロックを悟らせない)',
  tests.errmsg(format('select * from public.redeem_qr_token(%L)', :'tok6')),
  tests.errmsg('select * from public.redeem_qr_token(''0000000000000000000000000000000000000000000000000000000000000000'')'));
select tests.become_super();
select tests.block('blk_by_me', 'owner');            -- 読み取り側がオーナーをブロック(逆方向)
select tests.become('blk_by_me');
select tests.eq('QR: 自分がブロックしている相手のQR → WB001', tests.errstate(format('select * from public.redeem_qr_token(%L)', :'tok6')), 'WB001');
select tests.become_super();
select tests.ok('ブロック関係では友達にならない', not exists (select 1 from public.friendships where requester_id in (tests.uid('blk_by_owner'), tests.uid('blk_by_me'))));
select tests.eq('ブロック拒否ではトークンの使用回数が増えない', (select use_count from public.qr_tokens where token_hash = sha256(convert_to(:'tok6', 'UTF8'))), 0);

-- ---- QR受付OFF ---------------------------------------------------------------------------------------------------
select tests.become('owner');
update public.profile_settings set accept_qr = false;
select tests.eq('QR発行: 受付OFFのときは発行できない WB007', tests.errstate('select * from public.issue_qr_token()'), 'WB007');
select tests.become_super();
select tests.mkuser('late');
select tests.become('late');
select tests.eq('QR: 受付OFFにしたオーナーの発行済みQR → 汎用拒否 WB001', tests.errstate(format('select * from public.redeem_qr_token(%L)', :'tok6')), 'WB001');
select tests.become_super();
update public.profile_settings set accept_qr = true where user_id = tests.uid('owner');

-- ---- 1日の登録上限(JST暦日)。上限は設定値 --------------------------------------------------------------------------------
update private.app_config set value = '2' where key = 'qr_daily_scan_limit';
select tests.mkuser('o1'); select tests.mkuser('o2'); select tests.mkuser('o3'); select tests.mkuser('o4');
select tests.mkuser('scanner');
select tests.set_now_jst('2026-10-29 23:30');
select tests.become('o1'); select qr_token as ta from public.issue_qr_token() \gset
select tests.become('o2'); select qr_token as tb from public.issue_qr_token() \gset
select tests.become('o3'); select qr_token as tc from public.issue_qr_token() \gset
select tests.become('o4'); select qr_token as td from public.issue_qr_token() \gset
select tests.become('scanner');
select 1 from public.redeem_qr_token(:'ta');
select 1 from public.redeem_qr_token(:'tb');
select tests.eq('QR: 1日の上限(設定値2)を超えると拒否 WB004', tests.errstate(format('select * from public.redeem_qr_token(%L)', :'tc')), 'WB004');
select tests.set_now_jst('2026-10-30 00:05');   -- JSTで日付が変わる
select tests.become('o3'); select qr_token as tc from public.issue_qr_token() \gset
select tests.become('scanner');
select tests.eq('QR: JSTの日付が変わると再び読み取れる', tests.errstate(format('select * from public.redeem_qr_token(%L)', :'tc')), null);
select tests.become_super();
update private.app_config set value = '20' where key = 'qr_daily_scan_limit';

-- ---- 友達100人上限(設定値で小さくして検証) -------------------------------------------------------------------------------------
update private.app_config set value = '2' where key = 'max_friends';
select tests.mkuser('cap'); select tests.mkuser('x1'); select tests.mkuser('x2'); select tests.mkuser('x3');
select tests.befriend('cap', 'x1'); select tests.befriend('cap', 'x2');
select tests.set_now_jst('2026-10-31 10:00');
select tests.become('x3'); select qr_token as tx3 from public.issue_qr_token() \gset
select tests.become('cap');
select tests.eq('QR: 自分が友達上限 → WB005', tests.errstate(format('select * from public.redeem_qr_token(%L)', :'tx3')), 'WB005');
select tests.become('cap'); select qr_token as tcap from public.issue_qr_token() \gset
select tests.become('x3');
select tests.eq('QR: QR表示側が友達上限 → 汎用拒否 WB001(相手の友達数を悟らせない)', tests.errstate(format('select * from public.redeem_qr_token(%L)', :'tcap')), 'WB001');
select tests.become_super();
update private.app_config set value = '100' where key = 'max_friends';

-- ---- 申請中/拒否済みでもQRで承認に更新 ------------------------------------------------------------------------------------------------
select tests.mkuser('p1'); select tests.mkuser('p2'); select tests.mkuser('p3');
insert into public.friendships (requester_id, addressee_id, status, method) values (tests.uid('p1'), tests.uid('p2'), 'pending', 'code');
insert into public.friendships (requester_id, addressee_id, status, method, responded_at) values (tests.uid('p3'), tests.uid('p2'), 'declined', 'code', now());
select tests.become('p2'); select qr_token as tp2 from public.issue_qr_token() \gset
select tests.become('p1'); select 1 from public.redeem_qr_token(:'tp2');
select tests.become('p3'); select 1 from public.redeem_qr_token(:'tp2');
select tests.become_super();
select tests.eq('QR: 申請中の相手とQRで承認済みに更新(重複行なし)',
  (select count(*) from public.friendships where status = 'accepted' and method = 'qr' and tests.uid('p2') in (requester_id, addressee_id)), 2::bigint);

-- ---- 期限切れQR等の定期削除 ----------------------------------------------------------------------------------------------------------------
select tests.set_now_jst('2026-11-05 10:00');
select tests.become_service();
select tests.ok('purge: 24時間以上前に失効/期限切れのQRと古い読み取りログが削除される',
  (select qr_tokens_deleted > 0 and qr_scans_deleted > 0 from public.purge_old_presence_data()));
select tests.become_super();
select tests.eq('purge後: 期限切れのQRは残らない', (select count(*) from public.qr_tokens), 0::bigint);

rollback;
