-- 10: H-1 読み取り専用トランザクション(PostgRESTの GET = STABLE/IMMUTABLE 関数は READ ONLY で実行される)
--   STABLE/IMMUTABLE な RPC・判定関数・ビュー・テーブル読み取りが、読み取り専用トランザクションで成功することを確認する。
\set ON_ERROR_STOP on
begin;

select tests.set_now_jst('2026-10-28 12:00');
select tests.mkuser('ro_a'); select tests.mkuser('ro_b'); select tests.mkuser('ro_c');
select tests.befriend('ro_a', 'ro_c');
update public.profile_settings set searchable = true where user_id = tests.uid('ro_b');
insert into public.friendships (requester_id, addressee_id, status, method)
values (tests.uid('ro_b'), tests.uid('ro_a'), 'pending', 'request');
insert into public.presences (id, user_id, facility_id, status, started_at, expires_at)
values (tests.dog_uid('ro_c', 100), tests.uid('ro_c'), tests.facility(), 'now', now(), now() + interval '2 hours');
insert into public.presence_dogs values (tests.dog_uid('ro_c', 100), tests.dog_uid('ro_c', 1));
select user_code as ro_b_code from public.profiles where id = tests.uid('ro_b') \gset

-- ---- 静的監査: STABLE/IMMUTABLE 関数(public/private全部)に行ロック・require_profile が無い -------------------
select tests.ok('STABLE/IMMUTABLE関数(' || count(*) || '個)に FOR UPDATE/FOR NO KEY UPDATE/FOR SHARE・require_profile が無い',
  count(*) > 0 and bool_and(p.prosrc !~* '\mfor\s+(no\s+key\s+)?(update|share|key\s+share)\M' and p.prosrc !~* 'require_profile'))
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in ('public', 'private') and p.provolatile in ('s', 'i') and p.prokind = 'f';

-- クライアント(authenticated)が呼べる STABLE/IMMUTABLE な public RPC は想定の2本のみ(増えたらこのテストに追加する)
select tests.eq('authenticatedが呼べる STABLE/IMMUTABLE な public RPC の一覧',
  (select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.provolatile in ('s', 'i') and has_function_privilege('authenticated', p.oid, 'execute')),
  array['list_incoming_friend_requests', 'search_user_by_user_code']);
-- 書き込みをする RPC は VOLATILE(STABLEにすると PostgREST が GET で呼べてしまい、読み取り専用でも落ちる/副作用が隠れる)
select tests.ok('書き込みRPCは全て VOLATILE',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname in ('issue_qr_token', 'revoke_qr_tokens', 'redeem_qr_token',
                 'request_friend_by_invite_code', 'request_friend_by_user_code', 'respond_friend_request',
                 'regenerate_invite_code', 'register_presence', 'extend_presence', 'end_presence', 'set_presence_dogs')
                 and p.provolatile <> 'v'));

-- ---- 読み取り専用トランザクションでの実行 --------------------------------------------------------------------
select tests.become('ro_a');
set transaction read only;
select tests.eq('(前提)READ ONLY トランザクションになっている', current_setting('transaction_read_only'), 'on');

select tests.eq('H-1 search_user_by_user_code が読み取り専用で動く',
  (select nickname from public.search_user_by_user_code(:'ro_b_code')), 'ro_b');
select tests.eq('H-1 search_user_by_user_code: has_avatar',
  (select has_avatar from public.search_user_by_user_code(:'ro_b_code')), false);
select tests.eq('H-1 list_incoming_friend_requests が読み取り専用で動く',
  (select from_nickname from public.list_incoming_friend_requests()), 'ro_b');
select tests.eq('H-1 search_user_by_user_code(NULL): 0行', tests.cnt('select 1 from public.search_user_by_user_code(null)'), 0::bigint);

-- 判定関数(RLS・ビュー経由でも使われる)
select tests.ok('H-1 can_view / is_friend / display_name / app_now / storage系 が読み取り専用で動く',
  private.can_view(tests.uid('ro_a'), tests.uid('ro_c'), 'friends')
  and private.is_friend(tests.uid('ro_a'), tests.uid('ro_c'))
  and private.display_name(tests.uid('ro_c')) = 'ro_c'
  and private.app_now() is not null
  and private.storage_path_uuid(tests.uid('ro_a')::text) = tests.uid('ro_a')
  and not private.storage_can_read_avatar(tests.uid('ro_b')::text)
  and private.storage_can_read_avatar(tests.uid('ro_c')::text)
  and private.storage_can_read_dog_photo(tests.uid('ro_c')::text, tests.dog_uid('ro_c', 1)::text)
  and private.storage_is_own_dog_folder(tests.uid('ro_a')::text, tests.dog_uid('ro_a', 1)::text));

-- テーブル/ビュー(RLSポリシー内の関数も含めて)の読み取り
select tests.ok('H-1 RLS付きテーブル・ビューの SELECT が読み取り専用で動く',
  (select count(*) from public.profiles) >= 1
  and (select count(*) from public.dogs) >= 1
  and (select count(*) from public.friendships) >= 1
  and (select count(*) from public.presences) >= 1
  and (select count(*) from public.presence_dogs) >= 1
  and (select count(*) from public.facilities) >= 1
  and (select count(*) from public.my_friends) = 1
  and (select count(*) from public.presence_board) = 1);

-- 書き込みRPCは読み取り専用では失敗する(= このテストが本当に READ ONLY で実行されている証拠)
select tests.eq('(対照)書き込みRPCは READ ONLY で 25006', tests.errstate('select public.revoke_qr_tokens()'), '25006');
select tests.eq('(対照)register_presence も READ ONLY で 25006',
  tests.errstate(format('select public.register_presence(%L, ''now'', array[%L]::uuid[])', tests.facility(), tests.dog_uid('ro_a', 1))), '25006');

-- 未ログイン/プロフィール未作成のエラーも読み取り専用で正しいSQLSTATE
select tests.become_authenticated_no_sub();
select tests.eq('H-1 sub無し: search WB401', tests.errstate('select * from public.search_user_by_user_code(''abc'')'), 'WB401');
select tests.eq('H-1 sub無し: list WB401', tests.errstate('select * from public.list_incoming_friend_requests()'), 'WB401');

rollback;
