-- 09: Storage(avatars / dog-photos)のバケット設定とポリシー
\set ON_ERROR_STOP on
begin;

select tests.mkuser('o');                                  -- 公開範囲 friends
select tests.mkuser('pub', 'public', 'public');
select tests.mkuser('priv', 'private', 'private');
select tests.mkuser('fr'); select tests.mkuser('st'); select tests.mkuser('bl'); select tests.mkuser('rg');
select tests.befriend('o', 'fr'); select tests.befriend('pub', 'fr'); select tests.befriend('priv', 'fr');
select tests.befriend('o', 'bl'); select tests.befriend('o', 'rg');
select tests.block('o', 'bl');   -- ブロックで友達関係は削除される

-- 既存オブジェクト(service_role/アップロード済み想定)
insert into storage.objects (bucket_id, name, owner_id) values
  ('avatars',    tests.uid('o') || '/a.jpg', tests.uid('o')::text),
  ('avatars',    tests.uid('pub') || '/a.jpg', tests.uid('pub')::text),
  ('avatars',    tests.uid('priv') || '/a.jpg', tests.uid('priv')::text),
  ('dog-photos', tests.uid('o') || '/' || tests.dog_uid('o', 1) || '/d.jpg', tests.uid('o')::text),
  ('dog-photos', tests.uid('pub') || '/' || tests.dog_uid('pub', 1) || '/d.jpg', tests.uid('pub')::text),
  ('dog-photos', tests.uid('priv') || '/' || tests.dog_uid('priv', 1) || '/d.jpg', tests.uid('priv')::text);

select tests.ok('バケットは private・2MB・jpeg/png/webp のみ',
  (select bool_and(not public and file_size_limit = 2097152 and allowed_mime_types @> array['image/jpeg','image/png','image/webp'] and cardinality(allowed_mime_types) = 3)
     from storage.buckets where id in ('avatars', 'dog-photos'))
  and (select count(*) from storage.buckets where id in ('avatars', 'dog-photos')) = 2);

-- ---- 閲覧(avatars) ----------------------------------------------------------------------------------
select tests.become('o');
select tests.eq('avatars: 本人は自分のアイコンが見える', tests.cnt(format('select 1 from storage.objects where bucket_id = ''avatars'' and name = %L', tests.uid('o') || '/a.jpg')), 1::bigint);
select tests.eq('avatars: 本人は private プロフィールの他人は見えない', tests.cnt(format('select 1 from storage.objects where bucket_id = ''avatars'' and name like %L', tests.uid('priv') || '/%')), 0::bigint);
select tests.become('fr');
select tests.eq('avatars: 友達は friends のアイコンが見える', tests.cnt(format('select 1 from storage.objects where bucket_id = ''avatars'' and name like %L', tests.uid('o') || '/%')), 1::bigint);
select tests.eq('avatars: 友達でも private は見えない', tests.cnt(format('select 1 from storage.objects where bucket_id = ''avatars'' and name like %L', tests.uid('priv') || '/%')), 0::bigint);
select tests.eq('avatars: 友達は public が見える', tests.cnt(format('select 1 from storage.objects where bucket_id = ''avatars'' and name like %L', tests.uid('pub') || '/%')), 1::bigint);
select tests.become('st');
select tests.eq('avatars: 登録済み非友達は friends のアイコンが見えない', tests.cnt(format('select 1 from storage.objects where bucket_id = ''avatars'' and name like %L', tests.uid('o') || '/%')), 0::bigint);
select tests.eq('avatars: 登録済み非友達は public が見える', tests.cnt(format('select 1 from storage.objects where bucket_id = ''avatars'' and name like %L', tests.uid('pub') || '/%')), 1::bigint);
select tests.become('bl');
select tests.eq('avatars: ブロックされた人は public でも(ブロックした相手の)アイコンが見えない…o は friends なので不可', tests.cnt(format('select 1 from storage.objects where bucket_id = ''avatars'' and name like %L', tests.uid('o') || '/%')), 0::bigint);

-- ---- 閲覧(dog-photos) -------------------------------------------------------------------------------
select tests.become('fr');
select tests.eq('dog-photos: 友達は friends の犬の写真が見える', tests.cnt(format('select 1 from storage.objects where bucket_id = ''dog-photos'' and name like %L', tests.uid('o') || '/%')), 1::bigint);
select tests.eq('dog-photos: 友達でも private の犬は見えない', tests.cnt(format('select 1 from storage.objects where bucket_id = ''dog-photos'' and name like %L', tests.uid('priv') || '/%')), 0::bigint);
select tests.become('st');
select tests.eq('dog-photos: 非友達は friends が見えない', tests.cnt(format('select 1 from storage.objects where bucket_id = ''dog-photos'' and name like %L', tests.uid('o') || '/%')), 0::bigint);
select tests.eq('dog-photos: 非友達は public が見える', tests.cnt(format('select 1 from storage.objects where bucket_id = ''dog-photos'' and name like %L', tests.uid('pub') || '/%')), 1::bigint);
select tests.become('bl');
select tests.eq('dog-photos: ブロックされた人は見えない', tests.cnt(format('select 1 from storage.objects where bucket_id = ''dog-photos'' and name like %L', tests.uid('o') || '/%')), 0::bigint);
select tests.become('priv');
select tests.eq('dog-photos: 本人は private でも自分の分が見える', tests.cnt(format('select 1 from storage.objects where bucket_id = ''dog-photos'' and name like %L', tests.uid('priv') || '/%')), 1::bigint);

-- 不正なパス形式は読めない
select tests.become_super();
insert into storage.objects (bucket_id, name) values
  ('avatars', tests.uid('pub') || '/sub/a.jpg'),       -- 階層が深い
  ('avatars', 'top-level.jpg'),                         -- フォルダなし
  ('avatars', 'not-a-uuid/a.jpg'),
  ('dog-photos', tests.uid('pub') || '/a.jpg'),         -- 犬フォルダなし
  ('dog-photos', tests.uid('pub') || '/' || tests.dog_uid('o', 1) || '/x.jpg');   -- 他人の犬のIDを混ぜたパス
select tests.become('st');
select tests.eq('不正なパス形式のオブジェクトは誰にも読めない(avatars: 深い階層/フォルダなし/非UUID)',
  tests.cnt('select 1 from storage.objects where bucket_id = ''avatars'' and (name in (''top-level.jpg'', ''not-a-uuid/a.jpg'') or name like ''%/sub/a.jpg'')'), 0::bigint);
select tests.eq('不正なパス形式のオブジェクトは誰にも読めない(dog-photos: 犬フォルダなし/他人の犬IDを混ぜたパス)',
  tests.cnt('select 1 from storage.objects where bucket_id = ''dog-photos'' and (name = ' || quote_literal(tests.uid('pub') || '/a.jpg') || ' or name like ' || quote_literal('%/' || tests.dog_uid('o', 1) || '/x.jpg') || ')'), 0::bigint);

-- ---- 書き込み -----------------------------------------------------------------------------------------
select tests.become('st');
select tests.lives('avatars: 自分のフォルダへはアップロードできる', format('insert into storage.objects (bucket_id, name, owner_id) values (''avatars'', %L, %L)', tests.uid('st') || '/me.png', tests.uid('st')::text));
select tests.eq('avatars: 他人のフォルダへは書けない', tests.errstate(format('insert into storage.objects (bucket_id, name) values (''avatars'', %L)', tests.uid('o') || '/evil.png')), '42501');
select tests.eq('avatars: フォルダなし/深い階層は書けない', tests.errstate('insert into storage.objects (bucket_id, name) values (''avatars'', ''evil.png'')'), '42501');
select tests.eq('avatars: 深い階層は書けない', tests.errstate(format('insert into storage.objects (bucket_id, name) values (''avatars'', %L)', tests.uid('st') || '/x/y.png')), '42501');
select tests.eq('avatars: 他人のファイルは更新できない(0行)', tests.affected(format('update storage.objects set metadata = ''{}''::jsonb where bucket_id = ''avatars'' and name = %L', tests.uid('pub') || '/a.jpg')), 0::bigint);
select tests.eq('avatars: 自分のファイルは更新できる', tests.affected(format('update storage.objects set metadata = ''{}''::jsonb where bucket_id = ''avatars'' and name = %L', tests.uid('st') || '/me.png')), 1::bigint);
select tests.eq('avatars: 他人のフォルダへ移動(UPDATE)できない', tests.errstate(format('update storage.objects set name = %L where bucket_id = ''avatars'' and name = %L', tests.uid('o') || '/moved.png', tests.uid('st') || '/me.png')), '42501');
select tests.eq('avatars: 他人のファイルは削除できない(0行)', tests.affected(format('delete from storage.objects where bucket_id = ''avatars'' and name = %L', tests.uid('pub') || '/a.jpg')), 0::bigint);
select tests.eq('avatars: 自分のファイルは削除できる', tests.affected(format('delete from storage.objects where bucket_id = ''avatars'' and name = %L', tests.uid('st') || '/me.png')), 1::bigint);

select tests.become('o');
select tests.lives('dog-photos: 自分の犬のフォルダへはアップロードできる', format('insert into storage.objects (bucket_id, name, owner_id) values (''dog-photos'', %L, %L)', tests.uid('o') || '/' || tests.dog_uid('o', 1) || '/new.webp', tests.uid('o')::text));
select tests.eq('dog-photos: 自分のフォルダでも存在しない/他人の犬IDは書けない', tests.errstate(format('insert into storage.objects (bucket_id, name) values (''dog-photos'', %L)', tests.uid('o') || '/' || tests.dog_uid('pub', 1) || '/evil.webp')), '42501');
select tests.eq('dog-photos: 他人のフォルダ(他人の犬)へは書けない', tests.errstate(format('insert into storage.objects (bucket_id, name) values (''dog-photos'', %L)', tests.uid('pub') || '/' || tests.dog_uid('pub', 1) || '/evil.webp')), '42501');
select tests.eq('dog-photos: 犬フォルダのない階層は書けない', tests.errstate(format('insert into storage.objects (bucket_id, name) values (''dog-photos'', %L)', tests.uid('o') || '/x.webp')), '42501');
select tests.eq('dog-photos: 他人の写真は削除できない(0行)', tests.affected(format('delete from storage.objects where bucket_id = ''dog-photos'' and name like %L', tests.uid('pub') || '/%')), 0::bigint);
select tests.eq('dog-photos: 自分の写真は削除できる', tests.affected(format('delete from storage.objects where bucket_id = ''dog-photos'' and name like %L', tests.uid('o') || '/%')), 2::bigint);
select tests.eq('他バケット(未定義)へは書けない', tests.errstate(format('insert into storage.objects (bucket_id, name) values (''avatars2'', %L)', tests.uid('o') || '/x.png')), '42501');

-- ---- anon -----------------------------------------------------------------------------------------------
select tests.become_anon();
select tests.eq('anon: avatars/dog-photos は1件も見えない(public設定のプロフィールでも)', tests.cnt('select 1 from storage.objects'), 0::bigint);
select tests.eq('anon: アップロードできない', tests.errstate(format('insert into storage.objects (bucket_id, name) values (''avatars'', %L)', tests.uid('o') || '/x.png')), '42501');
select tests.eq('anon: 削除は0行', tests.affected('delete from storage.objects'), 0::bigint);

-- ---- ストレージ用ヘルパー関数 ----------------------------------------------------------------------------------
select tests.throws('anon: storage 用の private 関数を実行できない', format('select private.storage_can_read_avatar(%L)', tests.uid('pub')::text), '42501');
select tests.become('st');
select tests.eq('storage_path_uuid: 不正文字列は例外を出さず NULL', (select private.storage_path_uuid('zzz')) is null, true);
select tests.eq('storage_can_read_avatar: 不正パスは false', private.storage_can_read_avatar('zzz'), false);

rollback;
