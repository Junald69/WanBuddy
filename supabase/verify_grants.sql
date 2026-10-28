-- =============================================================================
-- WanBuddy v0.2 / verify_grants.sql — 本番(またはステージング)適用後の権限確認SQL
--
--   読み取り専用(SELECTのみ。何も変更しない)。Supabase の SQL Editor / psql どちらでも実行できる(psqlメタコマンド不使用)。
--   結果は「チェック1つ = 1行」。status が FAIL の行があれば権限が想定とずれている(offenders に該当オブジェクト)。
--     FAIL = 想定外の権限(セキュリティ上の問題) / WARN = 要確認 / PASS = 想定どおり
--
--   前提とする設計(migrations で明示GRANT。auto expose=OFF でも ON でも同じ結果になること):
--     * anon / PUBLIC は public・private の どのテーブル・ビュー・シーケンス・関数にも権限を持たない
--     * authenticated は下の exp_table / exp_col に書いた権限だけを持つ(RPC専用テーブルへの INSERT/UPDATE/DELETE は無い)
--     * RPC(public の関数)の EXECUTE は authenticated のみ。private の関数は exp_fn に挙げたものだけ(RLS/ビュー内部用)
--     * public・private の全テーブルで RLS 有効 / ビューは security_invoker / security definer 関数は search_path 固定
--
--   ※ 権限を追加・変更する migration を入れたら、この expected リストも同じPRで更新すること
--     (ローカルでは tests/01_security_audit.sql と tests/08_direct_write_denied.sql が同じ内容を検査している)。
--   使い方:  psql "$DATABASE_URL" -f supabase/verify_grants.sql     /  SQL Editor に貼り付けて Run
-- =============================================================================

with
-- ---- 想定: authenticated のテーブルレベル権限 -----------------------------------------------------------------
exp_table(rel, priv) as (values
  ('blocks', 'SELECT'), ('blocks', 'DELETE'),
  ('dog_instagram', 'SELECT'), ('dog_instagram', 'DELETE'),
  ('dogs', 'SELECT'), ('dogs', 'DELETE'),
  ('facilities', 'SELECT'), ('facility_areas', 'SELECT'),
  ('friendships', 'SELECT'), ('friendships', 'DELETE'),
  ('my_friends', 'SELECT'), ('presence_board', 'SELECT'),
  ('presence_dogs', 'SELECT'), ('presences', 'SELECT'),
  ('profile_settings', 'SELECT'), ('profiles', 'SELECT'),
  ('terms_consents', 'SELECT')
),
-- ---- 想定: authenticated の列レベル権限(INSERT/UPDATE が可能な列。user_code・status・created_at 等は含まれない) ------------
exp_col(rel, priv, col) as (
  select rel, priv, unnest(string_to_array(cols, ',')) from (values
    ('blocks',           'INSERT', 'blocked_id,blocker_id'),
    ('dog_instagram',    'INSERT', 'dog_id,handle,visibility'),
    ('dog_instagram',    'UPDATE', 'handle,visibility'),
    ('dogs',             'INSERT', 'birthday,breed,id,name,owner_id,personality,photo_path,sort_order,visibility_dog'),
    ('dogs',             'UPDATE', 'birthday,breed,name,personality,photo_path,sort_order,visibility_dog'),
    ('feedback',         'INSERT', 'body,kind,user_id'),
    ('profile_settings', 'UPDATE', 'accept_qr,searchable'),
    ('profiles',         'INSERT', 'avatar_path,id,nickname,visibility_owner'),
    ('profiles',         'UPDATE', 'avatar_path,nickname,visibility_owner'),
    ('reports',          'INSERT', 'comment,reason,reporter_id,target_user_id'),
    ('terms_consents',   'INSERT', 'terms_version,user_id')
  ) v(rel, priv, cols)
),
-- ---- 想定: authenticated が EXECUTE できる関数(これ以外は全て不可) ------------------------------------------------------
exp_fn(sig) as (values
  ('private.app_now()'),
  ('private.can_view(viewer uuid, owner uuid, visibility text)'),
  ('private.display_name(p_owner uuid)'),
  ('private.is_friend(a uuid, b uuid)'),
  ('private.storage_can_read_avatar(p_owner text)'),
  ('private.storage_can_read_dog_photo(p_owner text, p_dog text)'),
  ('private.storage_is_own_dog_folder(p_owner text, p_dog text)'),
  ('private.storage_path_uuid(p text)'),
  ('public.end_presence(p_presence_id uuid)'),
  ('public.extend_presence(p_presence_id uuid)'),
  ('public.issue_qr_token()'),
  ('public.list_incoming_friend_requests()'),
  ('public.redeem_qr_token(p_token text)'),
  ('public.regenerate_invite_code()'),
  ('public.register_presence(p_facility_id uuid, p_status text, p_dog_ids uuid[], p_planned_at timestamp with time zone, p_area_code text, p_visibility text)'),
  ('public.request_friend_by_invite_code(p_code text)'),
  ('public.request_friend_by_user_code(p_user_code text)'),
  ('public.respond_friend_request(p_friendship_id uuid, p_accept boolean)'),
  ('public.revoke_qr_tokens()'),
  ('public.search_user_by_user_code(p_user_code text)'),
  ('public.set_presence_dogs(p_presence_id uuid, p_dog_ids uuid[])')
),

-- ---- 実際の状態 -----------------------------------------------------------------------------------------------------
-- 対象オブジェクト(public / private の 通常テーブル・ビュー・シーケンス)。拡張が作ったものは除く。
rels as (
  select c.oid, n.nspname as sch, c.relname as rel, c.relkind, c.relrowsecurity, c.reloptions
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('public', 'private')
     and c.relkind in ('r', 'p', 'v', 'm', 'f', 'S')
     and not exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e')
),
fns as (
  select p.oid, n.nspname as sch,
         n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as sig,
         p.prosecdef, p.proconfig, p.prokind
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private')
     and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
),
-- テーブルレベル権限: information_schema.role_table_grants(ビュー含む)
tbl_grants as (
  select g.table_schema as sch, g.table_name as rel, g.grantee, g.privilege_type as priv
    from information_schema.role_table_grants g
   where g.table_schema in ('public', 'private') and g.grantee in ('anon', 'authenticated', 'PUBLIC')
),
-- 列レベル権限(列だけに付与されたもの): pg_attribute.attacl
col_grants as (
  select r.sch, r.rel, case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end as grantee,
         a.privilege_type as priv, att.attname as col
    from rels r
    join pg_attribute att on att.attrelid = r.oid and att.attnum > 0 and not att.attisdropped and att.attacl is not null
    cross join lateral aclexplode(att.attacl) a
   where a.grantee = 0 or a.grantee::regrole::text in ('anon', 'authenticated')
),
-- 全チェックの違反一覧: (check_id, offender)
v(check_id, offender) as (
  -- C01 anon / PUBLIC のテーブル・ビュー権限(テーブルレベル)
  select 'C01', sch || '.' || rel || ' ' || grantee || ':' || priv from tbl_grants where grantee in ('anon', 'PUBLIC')
  union all
  -- C02 anon / PUBLIC の列レベル権限
  select 'C02', sch || '.' || rel || '.' || col || ' ' || grantee || ':' || priv from col_grants where grantee in ('anon', 'PUBLIC')
  union all
  -- C03 authenticated のテーブルレベル権限が想定外(private スキーマの表は1つも許可しない)
  select 'C03', g.sch || '.' || g.rel || ' authenticated:' || g.priv
    from tbl_grants g
   where g.grantee = 'authenticated'
     and not (g.sch = 'public' and exists (select 1 from exp_table e where e.rel = g.rel and e.priv = g.priv))
  union all
  -- C04 authenticated のテーブルレベル権限の不足(想定した権限が付いていない = アプリが動かない)
  select 'C04', 'public.' || e.rel || ' authenticated:' || e.priv || ' (不足)'
    from exp_table e
   where not exists (select 1 from tbl_grants g where g.sch = 'public' and g.rel = e.rel and g.grantee = 'authenticated' and g.priv = e.priv)
  union all
  -- C05 authenticated の列レベル権限が想定外(余分な列)
  select 'C05', c.sch || '.' || c.rel || '.' || c.col || ' authenticated:' || c.priv
    from col_grants c
   where c.grantee = 'authenticated'
     and not (c.sch = 'public' and exists (select 1 from exp_col e where e.rel = c.rel and e.priv = c.priv and e.col = c.col))
  union all
  -- C06 authenticated の列レベル権限の不足
  select 'C06', 'public.' || e.rel || '.' || e.col || ' authenticated:' || e.priv || ' (不足)'
    from exp_col e
   where not exists (select 1 from col_grants c where c.sch = 'public' and c.rel = e.rel and c.col = e.col and c.grantee = 'authenticated' and c.priv = e.priv)
     and not exists (select 1 from tbl_grants g where g.sch = 'public' and g.rel = e.rel and g.grantee = 'authenticated' and g.priv = e.priv)
  union all
  -- C07 シーケンス(anon / authenticated / PUBLIC のいずれにも権限なし)
  select 'C07', r.sch || '.' || r.rel || ' ' || case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end || ':' || a.privilege_type
    from pg_class c join rels r on r.oid = c.oid
    cross join lateral aclexplode(c.relacl) a
   where r.relkind = 'S' and (a.grantee = 0 or a.grantee::regrole::text in ('anon', 'authenticated'))
  union all
  -- C08 関数: anon / PUBLIC に EXECUTE がある(has_function_privilege + PUBLIC は ACL で確認)
  select 'C08', f.sig || ' → anon'   from fns f where has_function_privilege('anon', f.oid, 'execute') and f.prokind = 'f'
  union all
  select 'C08', f.sig || ' → PUBLIC' from fns f
   where f.prokind = 'f' and exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where p.oid = f.oid and a.grantee = 0 and a.privilege_type = 'EXECUTE')
  union all
  -- C09 関数: authenticated が EXECUTE できるのは exp_fn の関数だけ
  select 'C09', f.sig || ' → authenticated(想定外)'
    from fns f
   where f.prokind = 'f' and has_function_privilege('authenticated', f.oid, 'execute') and f.sig not in (select sig from exp_fn)
  union all
  -- C10 関数: 想定した関数が authenticated から実行できない(不足 = アプリが動かない)
  select 'C10', e.sig || ' (不足)'
    from exp_fn e
   where not exists (select 1 from fns f where f.sig = e.sig and has_function_privilege('authenticated', f.oid, 'execute'))
  union all
  -- C11 public の RPC は authenticated のみ(service_role を除き anon/PUBLIC 不可は C08)。private の「内部用」関数が authenticated に漏れていない(C09に含む)。
  -- C11 スキーマ権限: anon/PUBLIC が private を使える / anon・authenticated・PUBLIC が public・private に CREATE できる
  select 'C11', n.nspname || ' ' || coalesce(nullif(a.grantee::regrole::text, '-'), 'PUBLIC') || ':' || a.privilege_type
    from pg_namespace n cross join lateral aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a
   where n.nspname in ('public', 'private')
     and (a.grantee = 0 or a.grantee::regrole::text in ('anon', 'authenticated'))
     and (a.privilege_type = 'CREATE' or (n.nspname = 'private' and a.privilege_type = 'USAGE' and (a.grantee = 0 or a.grantee::regrole::text = 'anon')))
  union all
  -- C12 RLS が無効なテーブル(public / private の全テーブル)
  select 'C12', sch || '.' || rel from rels where relkind in ('r', 'p') and not relrowsecurity
  union all
  -- C13 security_invoker でないビュー(RLSを迂回してしまう)
  select 'C13', sch || '.' || rel from rels
   where relkind = 'v' and not coalesce('security_invoker=true' = any (reloptions) or 'security_invoker=on' = any (reloptions), false)
  union all
  -- C14 security definer 関数で search_path が固定されていない(権限昇格の足場になる)
  select 'C14', sig from fns
   where prosecdef and not exists (select 1 from unnest(coalesce(proconfig, '{}')) cfg where cfg like 'search_path=%')
  union all
  -- C15 public のポリシーが anon / PUBLIC を対象にしている(ポリシーは to authenticated 明示のはず)
  select 'C15', schemaname || '.' || tablename || ' policy ' || policyname || ' roles=' || roles::text
    from pg_policies
   where schemaname = 'public' and (roles && array['public'::name, 'anon'::name])
  union all
  -- C16 public の RLS 有効テーブルにポリシーが1つも無い(= 常に0行/拒否。意図したもの以外は漏れ)。INSERT専用表等は想定どおり SELECT ポリシー無し
  select 'C16', r.sch || '.' || r.rel from rels r
   where r.sch = 'public' and r.relkind in ('r', 'p')
     and r.rel not in ('qr_tokens', 'qr_scans')   -- RPC専用(security definer 関数のみが読み書き)。ポリシー無し=全拒否が意図
     and not exists (select 1 from pg_policies p where p.schemaname = r.sch and p.tablename = r.rel)
  union all
  -- C17 新規オブジェクトへの自動付与(デフォルト権限)が anon / authenticated / PUBLIC に残っている
  select 'C17', 'default ACL: role=' || d.defaclrole::regrole::text || ' schema=' || coalesce(nullif(d.defaclnamespace::regnamespace::text, '-'), '(all)') || ' type=' || d.defaclobjtype::text || ' → ' || a.grantee::regrole::text
    from pg_default_acl d cross join lateral aclexplode(d.defaclacl) a
   where d.defaclnamespace in ('public'::regnamespace, 'private'::regnamespace)
     and (a.grantee = 0 or a.grantee::regrole::text in ('anon', 'authenticated'))
),
-- ---- チェック定義(severity と説明)-------------------------------------------------------------------------------------
defs(check_id, severity, what) as (values
  ('C01', 'FAIL', 'anon/PUBLIC にテーブル・ビューの権限が無い(public/private)'),
  ('C02', 'FAIL', 'anon/PUBLIC に列レベル権限が無い'),
  ('C03', 'FAIL', 'authenticated のテーブルレベル権限が想定どおり(余分な権限が無い。private は0)'),
  ('C04', 'FAIL', 'authenticated のテーブルレベル権限が足りている'),
  ('C05', 'FAIL', 'authenticated の列レベル権限に余分な列が無い(user_code/status/created_at 等へ書けない)'),
  ('C06', 'FAIL', 'authenticated の列レベル権限が足りている'),
  ('C07', 'FAIL', 'シーケンスに anon/authenticated/PUBLIC の権限が無い'),
  ('C08', 'FAIL', 'anon/PUBLIC が public・private のどの関数も実行できない'),
  ('C09', 'FAIL', 'authenticated が実行できる関数は想定リストのみ(内部関数・cron用関数が漏れていない)'),
  ('C10', 'FAIL', '想定した RPC/判定関数を authenticated が実行できる'),
  ('C11', 'FAIL', 'スキーマ権限: anon/PUBLIC が private を使えない / anon・authenticated・PUBLIC が CREATE できない'),
  ('C12', 'FAIL', 'public/private の全テーブルで RLS が有効'),
  ('C13', 'FAIL', 'public のビューが全て security_invoker'),
  ('C14', 'FAIL', 'security definer 関数は全て search_path 固定'),
  ('C15', 'FAIL', 'public のポリシーに anon/PUBLIC 対象が無い(to authenticated 明示)'),
  ('C16', 'WARN', 'public の全テーブルに最低1つポリシーがある(RPC専用の qr_tokens/qr_scans を除く。無い表は全操作が拒否される)'),
  ('C17', 'WARN', '新規オブジェクトへの自動付与(デフォルト権限)が anon/authenticated/PUBLIC に残っていない')
)
select d.check_id,
       case when count(v.*) = 0 then 'PASS' else d.severity end as status,
       d.what,
       count(v.*) as violations,
       left(string_agg(v.offender, E'\n' order by v.offender), 2000) as offenders
  from defs d left join v on v.check_id = d.check_id
 group by d.check_id, d.severity, d.what
 order by d.check_id;
