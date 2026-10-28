-- 08: GRANTマトリクス(auto expose=OFF 前提: 明示GRANTしたものだけが許可される)と、直接書込み/権限なし操作の拒否
--   ・テーブル権限/列権限の「期待値」をここにハードコードし、実際の権限と完全一致することを検証する
--   ・GRANTの無い操作が 42501(permission denied) になることを実際に実行して確認する
\set ON_ERROR_STOP on
begin;

select tests.mkuser('u1'); select tests.mkuser('u2'); select tests.befriend('u1', 'u2');
select tests.facility() as fid \gset
select tests.set_now_jst('2026-10-28 12:00');
select tests.become('u1');
select public.register_presence(:'fid', 'now', array[tests.dog_uid('u1', 1)]) as pr1 \gset
select tests.become_super();
select id as fs1 from public.friendships limit 1 \gset

-- ================= 1. テーブル権限マトリクス(authenticated) =================
create temp table _exp_tbl (rel text, priv text);   -- テーブル全体への権限(期待値)
insert into _exp_tbl values
  ('blocks','SELECT'),('blocks','DELETE'),
  ('dog_instagram','SELECT'),('dog_instagram','DELETE'),
  ('dogs','SELECT'),('dogs','DELETE'),
  ('facilities','SELECT'),('facility_areas','SELECT'),
  ('friendships','SELECT'),('friendships','DELETE'),
  ('my_friends','SELECT'),('presence_board','SELECT'),
  ('presence_dogs','SELECT'),('presences','SELECT'),
  ('profile_settings','SELECT'),('profiles','SELECT'),
  ('terms_consents','SELECT');
create temp table _exp_col (rel text, priv text, cols text);   -- 列単位の権限(期待値)
insert into _exp_col values
  ('blocks','INSERT','blocked_id,blocker_id'),
  ('dog_instagram','INSERT','dog_id,handle,visibility'),('dog_instagram','UPDATE','handle,visibility'),
  ('dogs','INSERT','birthday,breed,id,name,owner_id,personality,photo_path,sort_order,visibility_dog'),
  ('dogs','UPDATE','birthday,breed,name,personality,photo_path,sort_order,visibility_dog'),
  ('feedback','INSERT','body,kind,user_id'),
  ('profile_settings','UPDATE','accept_qr,searchable'),
  ('profiles','INSERT','avatar_path,id,nickname,user_code,visibility_owner'),
  ('profiles','UPDATE','avatar_path,nickname,user_code,visibility_owner'),
  ('reports','INSERT','comment,reason,reporter_id,target_user_id'),
  ('terms_consents','INSERT','terms_version,user_id');
grant select on _exp_tbl, _exp_col to public;

select tests.ok('GRANT表: テーブル権限(authenticated)が期待値と完全一致(過不足なし)',
  not exists (
    (select c.relname::text, p from pg_class c join pg_namespace n on n.oid = c.relnamespace
       cross join unnest(array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p
      where n.nspname = 'public' and c.relkind in ('r','v','m','p') and has_table_privilege('authenticated', c.oid, p)
     except select rel, priv from _exp_tbl)
    union all
    (select rel, priv from _exp_tbl
     except select c.relname::text, p from pg_class c join pg_namespace n on n.oid = c.relnamespace
       cross join unnest(array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p
      where n.nspname = 'public' and has_table_privilege('authenticated', c.oid, p))));

select tests.ok('GRANT表: 列権限(INSERT/UPDATE。テーブル全体の権限が無いもの)が期待値と完全一致',
  not exists (
    (select c.relname::text, p, string_agg(a.attname, ',' order by a.attname)
       from pg_class c join pg_namespace n on n.oid = c.relnamespace
       join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
       cross join unnest(array['INSERT','UPDATE']) p
      where n.nspname = 'public' and c.relkind = 'r'
        and has_column_privilege('authenticated', c.oid, a.attnum, p)
      group by 1, 2
     except select rel, priv, cols from _exp_col)
    union all
    (select rel, priv, cols from _exp_col
     except select c.relname::text, p, string_agg(a.attname, ',' order by a.attname)
       from pg_class c join pg_namespace n on n.oid = c.relnamespace
       join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
       cross join unnest(array['INSERT','UPDATE']) p
      where n.nspname = 'public' and c.relkind = 'r'
        and has_column_privilege('authenticated', c.oid, a.attnum, p)
      group by 1, 2)));

select tests.ok('GRANT表: SELECT の列権限のみ(テーブル全体のSELECTなし)のテーブルは存在しない(feedback/reports/qr_* は読めない)',
  not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
               where n.nspname = 'public' and c.relkind = 'r' and not has_table_privilege('authenticated', c.oid, 'SELECT')
                 and has_any_column_privilege('authenticated', c.oid, 'SELECT')));

select tests.ok('GRANT表: anon にはどのテーブル/ビュー/列/シーケンスにも権限がない',
  not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
               cross join unnest(array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p
               where n.nspname in ('public','private') and c.relkind in ('r','v','m','p') and has_table_privilege('anon', c.oid, p))
  and not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
               join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
               cross join unnest(array['SELECT','INSERT','UPDATE']) p
               where n.nspname in ('public','private') and c.relkind in ('r','v') and has_column_privilege('anon', c.oid, a.attnum, p)));

select tests.ok('GRANT表: private スキーマのテーブル/シーケンスにauthenticatedの権限なし',
  not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
               cross join unnest(array['SELECT','INSERT','UPDATE','DELETE']) p
               where n.nspname = 'private' and c.relkind in ('r','v') and has_table_privilege('authenticated', c.oid, p)));
select tests.ok('GRANT表: service_role は public の全テーブルに権限を持つ(RLSバイパスの前提)',
  not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
               where n.nspname = 'public' and c.relkind in ('r','v') and not has_table_privilege('service_role', c.oid, 'SELECT')));

-- ================= 2. GRANTの無い操作は 42501 =================
select tests.become('u1');
-- INSERT 不可(RPC経由のみ)
select tests.throws('INSERT拒否: presences', format('insert into public.presences (user_id, facility_id, status, started_at, expires_at) values (%L, %L, ''now'', now(), now() + interval ''1 hour'')', tests.uid('u1'), :'fid'), '42501');
select tests.throws('INSERT拒否: presence_dogs', format('insert into public.presence_dogs (presence_id, dog_id) values (%L, %L)', :'pr1', tests.dog_uid('u1', 1)), '42501');
select tests.throws('INSERT拒否: friendships(accepted を直接作って友達になれない)', format('insert into public.friendships (requester_id, addressee_id, status, method) values (%L, %L, ''accepted'', ''request'')', tests.uid('u1'), gen_random_uuid()), '42501');
select tests.throws('INSERT拒否: qr_tokens', format('insert into public.qr_tokens (user_id, token_hash, expires_at, max_uses) values (%L, ''\x01'', now() + interval ''1 day'', 1000)', tests.uid('u1')), '42501');
select tests.throws('INSERT拒否: qr_scans', format('insert into public.qr_scans (scanner_id) values (%L)', tests.uid('u1')), '42501');
select tests.throws('INSERT拒否: facilities', 'insert into public.facilities (code, name, open_time, close_time) values (''zz'', ''zz'', ''00:00'', ''23:59'')', '42501');
select tests.throws('INSERT拒否: facility_areas', format('insert into public.facility_areas (facility_id, code, name) values (%L, ''zz'', ''zz'')', :'fid'), '42501');
select tests.throws('INSERT拒否: profile_settings(列 invite_code を指定)', format('insert into public.profile_settings (user_id, invite_code) values (%L, ''AAAAAAAAAA'')', tests.uid('u1')), '42501');
select tests.throws('INSERT拒否: profiles の許可外の列(created_at)', format('insert into public.profiles (id, nickname, created_at) values (%L, ''x'', now())', tests.uid('u1')), '42501');
select tests.throws('INSERT拒否: terms_consents の許可外の列(consented_at を偽装)', format('insert into public.terms_consents (user_id, terms_version, consented_at) values (%L, ''v1'', now() - interval ''1 year'')', tests.uid('u1')), '42501');
-- UPDATE 不可
select tests.throws('UPDATE拒否: presences(期限の書換え)', format('update public.presences set expires_at = now() + interval ''100 years'' where id = %L', :'pr1'), '42501');
select tests.throws('UPDATE拒否: presences(user_id)', format('update public.presences set user_id = %L where id = %L', tests.uid('u2'), :'pr1'), '42501');
select tests.throws('UPDATE拒否: presence_dogs', format('update public.presence_dogs set dog_id = %L where presence_id = %L', tests.dog_uid('u2', 1), :'pr1'), '42501');
select tests.throws('UPDATE拒否: friendships(status を自分で accepted に)', format('update public.friendships set status = ''accepted'' where id = %L', :'fs1'), '42501');
select tests.throws('UPDATE拒否: blocks', 'update public.blocks set created_at = now()', '42501');
select tests.throws('UPDATE拒否: profile_settings.invite_code(再生成はRPCのみ)', 'update public.profile_settings set invite_code = ''AAAAAAAAAA''', '42501');
select tests.throws('UPDATE拒否: profile_settings.user_id', format('update public.profile_settings set user_id = %L', tests.uid('u2')), '42501');
select tests.throws('UPDATE拒否: dogs.owner_id(犬の付け替え)', format('update public.dogs set owner_id = %L', tests.uid('u2')), '42501');
select tests.throws('UPDATE拒否: profiles.created_at/id', format('update public.profiles set id = %L', gen_random_uuid()), '42501');
select tests.throws('UPDATE拒否: dog_instagram.dog_id(付け替え)', format('update public.dog_instagram set dog_id = %L', tests.dog_uid('u2', 1)), '42501');
select tests.throws('UPDATE拒否: facilities', 'update public.facilities set close_time = ''23:59''', '42501');
select tests.throws('UPDATE拒否: reports / feedback / terms_consents', 'update public.reports set comment = ''x''', '42501');
select tests.throws('UPDATE拒否: feedback', 'update public.feedback set body = ''x''', '42501');
select tests.throws('UPDATE拒否: terms_consents', 'update public.terms_consents set terms_version = ''x''', '42501');
-- DELETE 不可
select tests.throws('DELETE拒否: presences', 'delete from public.presences', '42501');
select tests.throws('DELETE拒否: presence_dogs', 'delete from public.presence_dogs', '42501');
select tests.throws('DELETE拒否: profiles(退会はEdge Function/service_role)', 'delete from public.profiles', '42501');
select tests.throws('DELETE拒否: profile_settings', 'delete from public.profile_settings', '42501');
select tests.throws('DELETE拒否: facilities', 'delete from public.facilities', '42501');
select tests.throws('DELETE拒否: reports', 'delete from public.reports', '42501');
select tests.throws('DELETE拒否: feedback', 'delete from public.feedback', '42501');
select tests.throws('DELETE拒否: terms_consents', 'delete from public.terms_consents', '42501');
select tests.throws('DELETE拒否: qr_tokens', 'delete from public.qr_tokens', '42501');
-- SELECT 不可
select tests.throws('SELECT拒否: qr_tokens', 'select * from public.qr_tokens', '42501');
select tests.throws('SELECT拒否: qr_scans', 'select * from public.qr_scans', '42501');
select tests.throws('SELECT拒否: reports(通報内容は本人にも返さない)', 'select * from public.reports', '42501');
select tests.throws('SELECT拒否: feedback', 'select * from public.feedback', '42501');
select tests.throws('SELECT拒否: private.app_config', 'select * from private.app_config', '42501');
-- TRUNCATE / REFERENCES / TRIGGER
select tests.throws('TRUNCATE拒否: presences', 'truncate public.presences', '42501');
select tests.throws('TRUNCATE拒否: friendships', 'truncate public.friendships', '42501');
select tests.throws('TRUNCATE拒否: blocks(DELETE権限があってもTRUNCATEは不可)', 'truncate public.blocks', '42501');
select tests.throws('DDL拒否: public にテーブルを作れない(CREATE権限なし)', 'create table public.zz_evil (id int)', '42501');
select tests.throws('DDL拒否: private にテーブルを作れない', 'create table private.zz_evil (id int)', '42501');
select tests.throws('DDL拒否: private.app_now を差し替えられない', 'create or replace function private.app_now() returns timestamptz language sql as $f$ select now() $f$', '42501');

-- 失敗した操作で実データが変わっていない
select tests.become_super();
select tests.ok('拒否された操作で実データは変化していない',
  (select expires_at = tests.jst('2026-10-28 15:00') and user_id = tests.uid('u1') from public.presences where id = :'pr1')
  and (select status = 'accepted' from public.friendships where id = :'fs1')
  and (select count(*) from public.facilities) = 1);

-- ================= 3. 許可された操作は自分の行だけ(RLS) =================
select tests.become('u1');
select tests.eq('許可操作でもRLSで他人の行は更新できない(dogs.name)', tests.affected(format('update public.dogs set name = ''hacked'' where owner_id = %L', tests.uid('u2'))), 0::bigint);
select tests.eq('他人のプロフィール更新は0行', tests.affected(format('update public.profiles set nickname = ''hacked'' where id = %L', tests.uid('u2'))), 0::bigint);
select tests.eq('他人のprofile_settings更新は0行', tests.affected(format('update public.profile_settings set searchable = true where user_id = %L', tests.uid('u2'))), 0::bigint);
select tests.eq('他人名義のfeedbackは作れない(RLS)', tests.errstate(format('insert into public.feedback (user_id, kind, body) values (%L, ''bug'', ''x'')', tests.uid('u2'))), '42501');
select tests.eq('他人名義のreportは作れない(RLS)', tests.errstate(format('insert into public.reports (reporter_id, target_user_id, reason) values (%L, %L, ''spam'')', tests.uid('u2'), tests.uid('u1'))), '42501');
select tests.eq('他人名義のterms_consentは作れない(RLS)', tests.errstate(format('insert into public.terms_consents (user_id, terms_version) values (%L, ''v1'')', tests.uid('u2'))), '42501');
select tests.eq('他人の犬は作れない(RLS)', tests.errstate(format('insert into public.dogs (owner_id, name) values (%L, ''x'')', tests.uid('u2'))), '42501');
select tests.eq('他人の犬のInstagramは作れない(RLS)', tests.errstate(format('insert into public.dog_instagram (dog_id, handle) values (%L, ''abc'')', tests.dog_uid('u2', 1))), '42501');
select tests.eq('友達の削除は当事者のみ(第三者が友達関係を消せない)', (select count(*) from public.friendships), 1::bigint);

-- ================= 4. 関数のEXECUTE(anon/PUBLICは何も実行できない) =================
select tests.become_anon();
select tests.throws('anon: register_presence を実行できない', format('select public.register_presence(%L, ''now'', array[%L]::uuid[])', :'fid', tests.dog_uid('u1', 1)), '42501');
select tests.throws('anon: redeem_qr_token を実行できない', 'select * from public.redeem_qr_token(''x'')', '42501');
select tests.throws('anon: private.can_view を実行できない', format('select private.can_view(%L, %L, ''public'')', tests.uid('u1'), tests.uid('u2')), '42501');
select tests.throws('anon: complete_expired_presences を実行できない', 'select public.complete_expired_presences()', '42501');
select tests.throws('anon: private.app_now を実行できない', 'select private.app_now()', '42501');
select tests.become('u1');
select tests.throws('authenticated: 内部関数 private.is_blocked_either は実行不可', format('select private.is_blocked_either(%L, %L)', tests.uid('u1'), tests.uid('u2')), '42501');
select tests.throws('authenticated: private.request_friend(内部)は実行不可', format('select private.request_friend(%L, %L, ''code'')', tests.uid('u1'), tests.uid('u2')), '42501');
select tests.throws('authenticated: purge_old_presence_data は実行不可', 'select * from public.purge_old_presence_data()', '42501');

-- 全関数: PUBLIC に EXECUTE が残っていない(public/private スキーマ。tests スキーマは除外)
select tests.become_super();
select tests.ok('全関数(public/private): PUBLIC への EXECUTE なし・anon への EXECUTE なし',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname in ('public','private')
                 and (has_function_privilege('anon', p.oid, 'EXECUTE')
                      or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
                 and p.proname !~ '^(gtrgm|gin_|gist_|similarity|word_similarity|strict_word|show_trgm|set_limit|show_limit)'));

rollback;
