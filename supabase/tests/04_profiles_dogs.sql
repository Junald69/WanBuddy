-- 04: プロフィール/犬(1対多・上限5頭)/Instagram/通報/意見/同意 の書き込み系RLS
\set ON_ERROR_STOP on
begin;

select tests.facility() as fid \gset
select tests.mkuser('u1');
select tests.mkuser('u2');
-- u3: auth.users のみ(プロフィール未作成)
insert into auth.users (id, email) values (tests.uid('u3'), 'u3@example.test');

-- ---- profiles ---------------------------------------------------------------------
select tests.become('u3');
select tests.lives('プロフィール作成: 自分のIDなら作成できる',
  format('insert into public.profiles (id, nickname) values (%L, ''さん太'')', tests.uid('u3')));
select tests.ok('user_code が自動生成される(8文字・小文字英数)',
  (select user_code ~ '^[a-z0-9]{8}$' from public.profiles where id = tests.uid('u3')));
select tests.ok('profile_settings が自動作成され招待コードは10文字', (select invite_code ~ '^[A-HJ-NP-Z2-9]{10}$' from public.profile_settings));
select tests.ok('既定: visibility_owner=friends / searchable=false / accept_qr=true',
  (select visibility_owner = 'friends' from public.profiles where id = tests.uid('u3'))
  and (select not searchable and accept_qr from public.profile_settings));
select tests.throws('L-2 プロフィール作成: user_code を指定した INSERT は列権限で拒否',
  format('insert into public.profiles (id, nickname, user_code) values (%L, ''x'', ''chosen_code'')', tests.uid('u3')), '42501');
select tests.throws('プロフィール作成: 他人のIDでは作成不可(RLS)',
  format('insert into public.profiles (id, nickname) values (%L, ''x'')', tests.uid('u1')), '42501');
select tests.become_super();

select user_code as u2code from public.profiles where id = tests.uid('u2') \gset
-- user_code 自体の制約(DB側。service_role/運営SQL経由でも守られる)
select tests.throws('profiles: user_code 形式違反はDB制約で拒否(23514)', format('update public.profiles set user_code = ''A!'' where id = %L', tests.uid('u1')), '23514');
select tests.throws('profiles: user_code 重複はDB制約で拒否(23505)',
  format('update public.profiles set user_code = %L where id = %L', :'u2code', tests.uid('u1')), '23505');
select tests.become('u1');
select tests.eq('他人のプロフィールの UPDATE は 0行(RLSで見えない/更新不可)',
  tests.affected('update public.profiles set nickname = ''hack'' where id = tests.uid(''u2'')'), 0::bigint);
select tests.throws('profiles: id の更新は列権限で拒否', format('update public.profiles set id = %L where id = %L', gen_random_uuid(), tests.uid('u1')), '42501');
select tests.throws('profiles: created_at の更新は列権限で拒否', format('update public.profiles set created_at = now() where id = %L', tests.uid('u1')), '42501');
select tests.throws('profiles: DELETE は権限なし', 'delete from public.profiles', '42501');
select tests.throws('profiles: ニックネーム空は拒否', format('update public.profiles set nickname = '''' where id = %L', tests.uid('u1')), '23514');
-- L-2: user_code は自動生成のみ(クライアントは指定も変更もできない)
select tests.throws('L-2 profiles: user_code の UPDATE は列権限で拒否(自分の行でも)',
  format('update public.profiles set user_code = ''mycode123'' where id = %L', tests.uid('u1')), '42501');
select tests.throws('L-2 profiles: user_code の UPDATE は拒否(他人のIDと重複させる試みも権限エラー)',
  format('update public.profiles set user_code = %L where id = %L', :'u2code', tests.uid('u1')), '42501');
select tests.ok('L-2 列権限: authenticated は profiles.user_code に INSERT/UPDATE 権限なし(SELECTのみ)',
  not has_column_privilege('authenticated', 'public.profiles', 'user_code', 'insert')
  and not has_column_privilege('authenticated', 'public.profiles', 'user_code', 'update')
  and has_column_privilege('authenticated', 'public.profiles', 'user_code', 'select'));
select tests.throws('profiles: avatar_path が他人のフォルダは拒否(RLS)',
  format('update public.profiles set avatar_path = %L where id = %L', tests.uid('u2')::text || '/a.jpg', tests.uid('u1')), '42501');
select tests.lives('profiles: avatar_path が自分のフォルダならOK',
  format('update public.profiles set avatar_path = %L where id = %L', tests.uid('u1')::text || '/a.jpg', tests.uid('u1')));
select tests.throws('profiles: visibility_owner 不正値は拒否', format('update public.profiles set visibility_owner = ''all'' where id = %L', tests.uid('u1')), '23514');
select tests.eq('profile_settings: 自分のsearchable/accept_qrは更新できる',
  tests.affected('update public.profile_settings set searchable = true, accept_qr = false'), 1::bigint);
select tests.throws('profile_settings: invite_code は直接更新不可(RPCのみ)', 'update public.profile_settings set invite_code = ''AAAAAAAAAA''', '42501');
select tests.throws('profile_settings: INSERT 不可', format('insert into public.profile_settings (user_id, invite_code) values (%L, ''AAAAAAAAAA'')', tests.uid('u1')), '42501');
select tests.become_super();

-- ---- dogs: 上限5頭 ----------------------------------------------------------------
select tests.become('u1');
select tests.lives('犬: 2頭目', format('insert into public.dogs (owner_id, name) values (%L, ''d2'')', tests.uid('u1')));
select tests.lives('犬: 3頭目', format('insert into public.dogs (owner_id, name) values (%L, ''d3'')', tests.uid('u1')));
select tests.lives('犬: 4頭目', format('insert into public.dogs (owner_id, name) values (%L, ''d4'')', tests.uid('u1')));
select tests.lives('犬: 5頭目', format('insert into public.dogs (owner_id, name) values (%L, ''d5'')', tests.uid('u1')));
select tests.eq('犬: 6頭目は拒否 WB107', tests.errstate(format('insert into public.dogs (owner_id, name) values (%L, ''d6'')', tests.uid('u1'))), 'WB107');
select tests.eq('犬: 現在5頭', tests.cnt('select 1 from public.dogs'), 5::bigint);
select tests.throws('犬: 他人を owner_id にして作成は拒否(RLS)', format('insert into public.dogs (owner_id, name) values (%L, ''x'')', tests.uid('u2')), '42501');
select tests.throws('犬: owner_id の更新は列権限で拒否', format('update public.dogs set owner_id = %L where id = %L', tests.uid('u2'), tests.dog_uid('u1', 1)), '42501');
select tests.eq('犬: 他人の犬の UPDATE は0行', tests.affected('update public.dogs set name = ''hack'' where owner_id = tests.uid(''u2'')'), 0::bigint);
select tests.eq('犬: 他人の犬の DELETE は0行', tests.affected('delete from public.dogs where owner_id = tests.uid(''u2'')'), 0::bigint);
select tests.throws('犬: 名前が空は拒否', format('update public.dogs set name = '''' where id = %L', tests.dog_uid('u1', 1)), '23514');
select tests.throws('犬: visibility 不正値は拒否', format('update public.dogs set visibility_dog = ''x'' where id = %L', tests.dog_uid('u1', 1)), '23514');
select tests.throws('犬: photo_path が他人のフォルダは拒否(RLS)',
  format('update public.dogs set photo_path = %L where id = %L', tests.uid('u2')::text || '/' || tests.dog_uid('u1', 1)::text || '/p.jpg', tests.dog_uid('u1', 1)), '42501');
select tests.throws('犬: photo_path が別の犬のフォルダは拒否(RLS)',
  format('update public.dogs set photo_path = %L where id = %L', tests.uid('u1')::text || '/' || tests.dog_uid('u1', 2)::text || '/p.jpg', tests.dog_uid('u1', 1)), '42501');
select tests.lives('犬: photo_path が <自分>/<その犬>/ ならOK',
  format('update public.dogs set photo_path = %L where id = %L', tests.uid('u1')::text || '/' || tests.dog_uid('u1', 1)::text || '/p.jpg', tests.dog_uid('u1', 1)));

-- 1頭を削除すると上限に空きができる(同じ犬数のまま入れ替えられる)
select tests.become('u1');
select tests.eq('犬: 1頭削除できる', tests.affected('delete from public.dogs where id = (select id from public.dogs order by created_at desc limit 1)'), 1::bigint);
select tests.lives('犬: 削除後に再度追加できる', format('insert into public.dogs (owner_id, name) values (%L, ''again'')', tests.uid('u1')));
select tests.become_super();

-- ---- dogs: 最後の1頭は削除不可 / 退会(カスケード)は可 -----------------------------------------
select tests.become('u2');
select tests.eq('犬: 最後の1頭の削除は拒否 WB108', tests.errstate(format('delete from public.dogs where id = %L', tests.dog_uid('u2', 1))), 'WB108');
select tests.become_super();

-- 犬を削除すると その犬だけの在場は終了し、複数頭の在場からは外れる
select tests.mkuser('m');
select tests.mkdog('m', 2);
insert into public.presences (id, user_id, facility_id, status, started_at, expires_at)
values (tests.dog_uid('m', 100), tests.uid('m'), :'fid', 'now', now(), now() + interval '2 hours');
insert into public.presence_dogs select tests.dog_uid('m', 100), tests.dog_uid('m', n) from generate_series(1, 2) n;
select tests.become('m');
delete from public.dogs where id = tests.dog_uid('m', 2);
select tests.become_super();
select tests.eq('犬を削除: 複数頭の在場から外れる(残り1頭・在場は継続)',
  (select count(*) from public.presence_dogs where presence_id = tests.dog_uid('m', 100)), 1::bigint);
select tests.ok('犬を削除: 在場は継続', (select ended_at is null from public.presences where id = tests.dog_uid('m', 100)));

-- 退会(auth.users 削除)→ profiles/dogs/在場/友達 が全て消える(最後の犬のトリガーに阻まれない)
select tests.mkuser('leaver');
select tests.mkdog('leaver', 2);
select tests.befriend('leaver', 'u1');
insert into public.presences (id, user_id, facility_id, status, started_at, expires_at)
values (tests.dog_uid('leaver', 100), tests.uid('leaver'), :'fid', 'now', now(), now() + interval '2 hours');
insert into public.presence_dogs select tests.dog_uid('leaver', 100), tests.dog_uid('leaver', n) from generate_series(1, 2) n;
insert into public.reports (reporter_id, target_user_id, reason) values (tests.uid('u1'), tests.uid('leaver'), 'other');
insert into public.reports (reporter_id, target_user_id, reason) values (tests.uid('leaver'), tests.uid('u1'), 'other');
select tests.lives('退会: auth.users の削除が成功する(最後の1頭トリガーに阻まれない)', format('delete from auth.users where id = %L', tests.uid('leaver')));
select tests.ok('退会: profiles/dogs/presences/friendships/profile_settings が消える',
  not exists (select 1 from public.profiles where id = tests.uid('leaver'))
  and not exists (select 1 from public.dogs where owner_id = tests.uid('leaver'))
  and not exists (select 1 from public.presences where user_id = tests.uid('leaver'))
  and not exists (select 1 from public.friendships where requester_id = tests.uid('leaver') or addressee_id = tests.uid('leaver'))
  and not exists (select 1 from public.profile_settings where user_id = tests.uid('leaver')));
select tests.ok('退会: 他人が出した通報は対象NULLで残り、退会者が出した通報は消える',
  (select count(*) from public.reports where reporter_id = tests.uid('u1') and target_user_id is null) = 1
  and not exists (select 1 from public.reports where reporter_id = tests.uid('leaver')));

-- ---- dog_instagram -------------------------------------------------------------------
select tests.become('u1');
select tests.lives('IG: 自分の犬に登録', format('insert into public.dog_instagram (dog_id, handle, visibility) values (%L, ''my.dog_1'', ''friends'')', tests.dog_uid('u1', 1)));
select tests.throws('IG: 他人の犬には登録不可(RLS)', format('insert into public.dog_instagram (dog_id, handle) values (%L, ''x'')', tests.dog_uid('u2', 1)), '42501');
select tests.throws('IG: 形式違反(@や空白)は拒否', format('update public.dog_instagram set handle = ''@bad name'' where dog_id = %L', tests.dog_uid('u1', 1)), '23514');
select tests.throws('IG: visibility=public は不可(友達限定/非公開のみ)', format('update public.dog_instagram set visibility = ''public'' where dog_id = %L', tests.dog_uid('u1', 1)), '23514');
select tests.become_super();

-- ---- reports / feedback / terms_consents -------------------------------------------------
select tests.become('u1');
select tests.lives('通報: 他人を通報できる', format('insert into public.reports (reporter_id, target_user_id, reason, comment) values (%L, %L, ''harassment'', ''c'')', tests.uid('u1'), tests.uid('u2')));
select tests.throws('通報: reporter を他人に偽装は拒否', format('insert into public.reports (reporter_id, target_user_id, reason) values (%L, %L, ''other'')', tests.uid('u2'), tests.uid('u1')), '42501');
select tests.throws('通報: 自分自身は通報不可', format('insert into public.reports (reporter_id, target_user_id, reason) values (%L, %L, ''other'')', tests.uid('u1'), tests.uid('u1')), '42501');
select tests.throws('通報: status を指定して挿入は拒否(列権限)', format('insert into public.reports (reporter_id, target_user_id, reason, status) values (%L, %L, ''other'', ''resolved'')', tests.uid('u1'), tests.uid('u2')), '42501');
select tests.throws('通報: SELECT 不可(通報内容は運営のみ)', 'select * from public.reports', '42501');
select tests.throws('通報: 不正な理由は拒否', format('insert into public.reports (reporter_id, target_user_id, reason) values (%L, %L, ''lol'')', tests.uid('u1'), tests.uid('u2')), '23514');
select tests.lives('意見: 匿名(user_id NULL)で送れる', 'insert into public.feedback (kind, body) values (''bug'', ''バグ'')');
select tests.lives('意見: 自分のuser_idで送れる', format('insert into public.feedback (user_id, kind, body) values (%L, ''request'', ''要望'')', tests.uid('u1')));
select tests.throws('意見: 他人のuser_idは拒否', format('insert into public.feedback (user_id, kind, body) values (%L, ''bug'', ''x'')', tests.uid('u2')), '42501');
select tests.throws('意見: SELECT 不可', 'select * from public.feedback', '42501');
select tests.lives('同意: 自分の同意を記録できる', format('insert into public.terms_consents (user_id, terms_version) values (%L, ''2026-10-28'')', tests.uid('u1')));
select tests.throws('同意: 他人名義は拒否', format('insert into public.terms_consents (user_id, terms_version) values (%L, ''2026-10-28'')', tests.uid('u2')), '42501');
select tests.eq('同意: 自分の分だけ見える', tests.cnt('select 1 from public.terms_consents'), 1::bigint);
select tests.throws('同意: UPDATE 不可(履歴の改ざん防止)', 'update public.terms_consents set terms_version = ''x''', '42501');
select tests.throws('同意: DELETE 不可', 'delete from public.terms_consents', '42501');
select tests.become('u2');
select tests.eq('同意: 他人の同意は見えない', tests.cnt('select 1 from public.terms_consents'), 0::bigint);

-- ---- 施設マスタ ----------------------------------------------------------------------------
select tests.eq('施設: シードされている(1件)', tests.cnt('select 1 from public.facilities'), 1::bigint);
select tests.eq('施設: 広場2件(フリー/小型犬用)', tests.cnt('select 1 from public.facility_areas'), 2::bigint);
select tests.ok('施設: 開園6:00/閉園21:00/Asia/Tokyo/無料',
  (select open_time = time '06:00' and close_time = time '21:00' and timezone = 'Asia/Tokyo'
          and fee_note = '無料' and code = 'tatsumi-no-mori-dogrun' and name = 'たつみの森ドッグラン' from public.facilities));
select tests.throws('施設: authenticated は変更できない', 'update public.facilities set name = ''x''', '42501');
select tests.throws('施設: authenticated は追加できない', 'insert into public.facilities (code, name, open_time, close_time) values (''x'', ''x'', ''06:00'', ''21:00'')', '42501');
select tests.become_super();
update public.facilities set is_active = false;
select tests.become('u2');
select tests.eq('施設: 無効化された施設は見えない', tests.cnt('select 1 from public.facilities'), 0::bigint);
select tests.eq('施設: 無効化された施設の広場も見えない', tests.cnt('select 1 from public.facility_areas'), 0::bigint);
select tests.become_super();

rollback;
