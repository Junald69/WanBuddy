-- 01: セキュリティ監査(カタログ検査)。RLS抜け/権限昇格/search_path/anon権限/ポリシー形式を機械的に検査する
\set ON_ERROR_STOP on
begin;

-- 1) public の全テーブルで RLS 有効
select tests.ok('RLS有効: public全テーブル(' || count(*) || '個)',
                count(*) > 0 and bool_and(c.relrowsecurity))
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind in ('r', 'p');

select tests.ok('RLS有効: private.app_config',
                (select relrowsecurity from pg_class where oid = 'private.app_config'::regclass));
select tests.ok('RLS有効: storage.objects',
                (select relrowsecurity from pg_class where oid = 'storage.objects'::regclass));

-- 2) anon / PUBLIC は public・private の どのテーブル/ビュー/シーケンスにも権限なし(列権限含む)
select tests.ok('anonは public/private の全リレーションに権限なし',
  not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('public', 'private') and c.relkind in ('r', 'v', 'm', 'p', 'S')
       and (has_any_column_privilege('anon', c.oid, 'select,insert,update,references')
            or has_table_privilege('anon', c.oid, 'select,insert,update,delete,truncate,references,trigger'))
  ));
select tests.ok('anonは private/public スキーマの USAGE が無い(publicスキーマはSupabase既定でUSAGEあり)',
                not has_schema_privilege('anon', 'private', 'usage'));

-- 3) authenticated: 直接書き込み不可のテーブル(RPC専用)
select tests.ok('authenticated は ' || t || ' に INSERT/UPDATE/DELETE/TRUNCATE 権限なし',
  not has_any_column_privilege('authenticated', ('public.' || t)::regclass, 'insert,update')
  and not has_table_privilege('authenticated', ('public.' || t)::regclass, 'delete,truncate'))
from unnest(array['presences', 'presence_dogs', 'qr_tokens', 'qr_scans', 'facilities', 'facility_areas']) t;

select tests.ok('authenticated は friendships に INSERT/UPDATE 権限なし(DELETEのみ)',
  not has_any_column_privilege('authenticated', 'public.friendships'::regclass, 'insert,update')
  and has_table_privilege('authenticated', 'public.friendships'::regclass, 'delete'));

select tests.ok('authenticated は qr_tokens / qr_scans を SELECT もできない',
  not has_any_column_privilege('authenticated', 'public.qr_tokens'::regclass, 'select')
  and not has_any_column_privilege('authenticated', 'public.qr_scans'::regclass, 'select'));

select tests.ok('authenticated は private.app_config に権限なし',
  not has_any_column_privilege('authenticated', 'private.app_config'::regclass, 'select,insert,update')
  and not has_table_privilege('authenticated', 'private.app_config'::regclass, 'delete'));

select tests.ok('profiles/profile_settings/dogs: 列単位GRANT(権限昇格列 created_at 等は更新不可)',
  not has_column_privilege('authenticated', 'public.profiles', 'created_at', 'update')
  and not has_column_privilege('authenticated', 'public.profile_settings', 'invite_code', 'update')
  and not has_column_privilege('authenticated', 'public.profile_settings', 'user_id', 'update')
  and not has_column_privilege('authenticated', 'public.dogs', 'owner_id', 'update')
  and not has_table_privilege('authenticated', 'public.profiles', 'delete'));

select tests.ok('reports/feedback/terms_consents: authenticated は SELECT/UPDATE/DELETE 不可(terms_consentsのSELECT除く)',
  not has_any_column_privilege('authenticated', 'public.reports'::regclass, 'select,update')
  and not has_table_privilege('authenticated', 'public.reports'::regclass, 'delete')
  and not has_any_column_privilege('authenticated', 'public.feedback'::regclass, 'select,update')
  and not has_table_privilege('authenticated', 'public.feedback'::regclass, 'delete')
  and not has_any_column_privilege('authenticated', 'public.terms_consents'::regclass, 'update')
  and not has_table_privilege('authenticated', 'public.terms_consents'::regclass, 'delete'));

-- 4) 関数: security definer は search_path 固定
select tests.ok('security definer関数は全て search_path 固定(' || count(*) || '個)',
                count(*) > 0 and bool_and(coalesce(p.proconfig::text, '') ~ 'search_path='))
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in ('public', 'private') and p.prosecdef;

select tests.ok('public/private の全関数が search_path 固定(' || count(*) || '個)',
                bool_and(coalesce(p.proconfig::text, '') ~ 'search_path='))
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in ('public', 'private')
   and p.prokind = 'f'
   and p.proname <> 'app_now';   -- app_now は now() のみ(search_path 不要。テストで差し替えるため除外)

select tests.ok('固定した search_path は空(= 全て修飾名で参照)',
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'private') and p.prosecdef
       and not ('search_path=""' = any (coalesce(p.proconfig, '{}')))
  ));

-- 5) 関数: anon / PUBLIC は実行不可
select tests.ok('anonは public/private/storage独自の全関数を実行不可',
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'private') and has_function_privilege('anon', p.oid, 'execute')
  ));

-- 6) authenticated が実行できる関数は許可リスト(RPC/判定関数)のみ
select tests.ok('authenticatedが実行できる public/private 関数は許可リストと一致',
  (select array_agg(n.nspname || '.' || p.proname order by n.nspname, p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private')
      and has_function_privilege('authenticated', p.oid, 'execute'))
  = array[
    'private.app_now', 'private.can_view', 'private.display_name', 'private.is_friend',
    'private.storage_can_read_avatar', 'private.storage_can_read_dog_photo',
    'private.storage_is_own_dog_folder', 'private.storage_path_uuid',
    'public.end_presence', 'public.extend_presence', 'public.issue_qr_token',
    'public.list_incoming_friend_requests', 'public.redeem_qr_token', 'public.regenerate_invite_code',
    'public.register_presence', 'public.request_friend_by_invite_code', 'public.request_friend_by_user_code',
    'public.respond_friend_request', 'public.revoke_qr_tokens', 'public.search_user_by_user_code',
    'public.set_presence_dogs'
  ]);

select tests.ok('メンテナンス関数は service_role のみ実行可',
  has_function_privilege('service_role', 'public.complete_expired_presences()', 'execute')
  and has_function_privilege('service_role', 'public.purge_old_presence_data()', 'execute')
  and not has_function_privilege('authenticated', 'public.complete_expired_presences()', 'execute')
  and not has_function_privilege('authenticated', 'public.purge_old_presence_data()', 'execute'));

select tests.ok('内部関数(require_profile/current_profile/lock_pair/config_int等)は authenticated・anon が実行不可',
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'private'
       and p.proname in ('require_profile', 'current_profile', 'lock_pair', 'config_int', 'is_blocked_either',
                         'friend_count', 'random_code', 'is_valid_timezone', 'trg_daily_limit', 'complete_user_expired')
       and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))
  ));

select tests.ok('private.is_valid_timezone は service_role のみ(facilities CHECK 用)',
  has_function_privilege('service_role', 'private.is_valid_timezone(text)', 'execute')
  and not has_function_privilege('authenticated', 'private.is_valid_timezone(text)', 'execute')
  and not has_function_privilege('anon', 'private.is_valid_timezone(text)', 'execute'));

select tests.ok('private.daily_counters: RLS有効・authenticated/anon 権限なし',
  (select relrowsecurity from pg_class where oid = 'private.daily_counters'::regclass)
  and not has_any_column_privilege('authenticated', 'private.daily_counters'::regclass, 'select,insert,update')
  and not has_any_column_privilege('anon', 'private.daily_counters'::regclass, 'select,insert,update'));

-- 7) ビューは security_invoker
select tests.ok('public のビューは全て security_invoker=true(' || count(*) || '個)',
                count(*) > 0 and bool_and(coalesce(c.reloptions::text, '') ~ 'security_invoker=true'))
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'v';

-- 8) ポリシー: ALL なし / to authenticated のみ / auth.uid() は (select auth.uid()) 形式
select tests.ok('ポリシーに cmd=ALL が無い(操作ごとに分離)',
  not exists (select 1 from pg_policies where schemaname in ('public', 'storage') and cmd = 'ALL'));

select tests.ok('全ポリシーが to authenticated のみ(' || count(*) || '個)',
                count(*) > 0 and bool_and(roles = array['authenticated']::name[]))
  from pg_policies where schemaname in ('public', 'storage');

select tests.ok('(select auth.uid()) 形式: 裸の auth.uid() を含むポリシーが無い',
  not exists (
    select 1 from pg_policies
     where schemaname in ('public', 'storage')
       and regexp_replace(coalesce(qual, '') || ' ' || coalesce(with_check, ''),
                          '\( SELECT auth\.uid\(\) AS uid\)', '', 'gi') ~* 'auth\.uid\(\)'
  ));

-- 9) 全テーブルのポリシー網羅(操作ごとの有無)
select tests.ok('presences/presence_dogs/friendships(INSERT)/qr系 に INSERT ポリシーが無い',
  not exists (
    select 1 from pg_policies
     where schemaname = 'public' and cmd = 'INSERT'
       and tablename in ('presences', 'presence_dogs', 'friendships', 'qr_tokens', 'qr_scans', 'facilities', 'facility_areas'))
  and not exists (select 1 from pg_policies where schemaname = 'public' and tablename in ('qr_tokens', 'qr_scans')));

-- 10) FK/所有: 生成された public 関数の所有者は postgres(= migration 実行者)
select tests.ok('Storageバケットは avatars / dog-photos とも private',
  (select count(*) from storage.buckets where id in ('avatars', 'dog-photos') and public = false) = 2
  and not exists (select 1 from storage.buckets where public));

-- 11) 定数(サーバー側設定)
select tests.ok('定数 ' || k || ' が設定済み', exists (select 1 from private.app_config where key = k))
from unnest(array['max_dogs_per_user','qr_ttl_minutes','qr_max_uses','qr_daily_scan_limit','max_friends',
                  'presence_now_minutes','presence_extend_minutes','presence_purge_after_hours',
                  'presence_planned_past_tolerance_minutes','report_daily_limit','feedback_daily_limit']) k;

-- 12) 新規オブジェクトのデフォルト権限(Supabaseが自動付与する anon/authenticated を除去済み)
create table public.zz_default_priv_probe (id int);
create function public.zz_default_priv_probe_fn() returns int language sql as 'select 1';
select tests.ok('新規テーブルに anon/authenticated 権限が自動付与されない',
  not has_table_privilege('anon', 'public.zz_default_priv_probe', 'select')
  and not has_table_privilege('authenticated', 'public.zz_default_priv_probe', 'select'));
select tests.ok('新規関数に anon/authenticated/PUBLIC の EXECUTE が自動付与されない',
  not has_function_privilege('anon', 'public.zz_default_priv_probe_fn()', 'execute')
  and not has_function_privilege('authenticated', 'public.zz_default_priv_probe_fn()', 'execute'));

rollback;
