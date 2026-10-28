-- 03: anon(未ログイン)は何も取得/実行できない
\set ON_ERROR_STOP on
begin;

select tests.mkuser('alice');
select tests.mkuser('bob', 'public', 'public');
select tests.befriend('alice', 'bob');

select tests.facility() as fid \gset
select tests.become_anon();

-- 全テーブル/ビュー: SELECT は permission denied(42501)
do $$
declare r record;
begin
  for r in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'v', 'p') order by 1
  loop
    perform tests.eq('anon: SELECT public.' || r.relname || ' は拒否',
                     tests.errstate('select * from public.' || quote_ident(r.relname)), '42501');
  end loop;
end $$;

-- 書き込み拒否
select tests.throws('anon: profiles INSERT 拒否', format('insert into public.profiles (id, nickname) values (%L, ''x'')', gen_random_uuid()), '42501');
select tests.throws('anon: dogs INSERT 拒否', format('insert into public.dogs (owner_id, name) values (%L, ''x'')', tests.uid('bob')), '42501');
select tests.throws('anon: blocks INSERT 拒否', format('insert into public.blocks values (%L, %L)', tests.uid('bob'), tests.uid('alice')), '42501');
select tests.throws('anon: feedback INSERT 拒否', 'insert into public.feedback (kind, body) values (''bug'', ''x'')', '42501');
select tests.throws('anon: reports INSERT 拒否', format('insert into public.reports (reporter_id, target_user_id, reason) values (%L, %L, ''other'')', tests.uid('bob'), tests.uid('alice')), '42501');
select tests.throws('anon: terms_consents INSERT 拒否', format('insert into public.terms_consents (user_id, terms_version) values (%L, ''v1'')', tests.uid('alice')), '42501');
select tests.throws('anon: dogs UPDATE 拒否', 'update public.dogs set name = ''hack''', '42501');
select tests.throws('anon: dogs DELETE 拒否', 'delete from public.dogs', '42501');

-- RPC 全て実行不可
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
  loop
    perform tests.ok('anon: EXECUTE 不可 ' || r.sig, not has_function_privilege('anon', r.sig::regprocedure, 'execute'));
  end loop;
end $$;
select tests.throws('anon: issue_qr_token() 呼び出し拒否', 'select * from public.issue_qr_token()', '42501');
select tests.throws('anon: redeem_qr_token 呼び出し拒否', 'select * from public.redeem_qr_token(''aaaaaaaaaaaaaaaaaaaaaaaa'')', '42501');
select tests.throws('anon: register_presence 呼び出し拒否', format('select public.register_presence(%L, ''now'', array[%L]::uuid[])', (:'fid'), tests.dog_uid('bob', 1)), '42501');
select tests.throws('anon: private.can_view 呼び出し拒否', format('select private.can_view(%L, %L, ''public'')', tests.uid('bob'), tests.uid('alice')), '42501');
select tests.throws('anon: private.app_now 呼び出し拒否', 'select private.app_now()', '42501');
select tests.throws('anon: private.app_config 参照拒否', 'select * from private.app_config', '42501');
select tests.throws('anon: complete_expired_presences 呼び出し拒否', 'select public.complete_expired_presences()', '42501');

-- Storage: anon はポリシー無し → 0件/書き込み拒否
select tests.eq('anon: storage.objects は0件', tests.cnt('select 1 from storage.objects'), 0::bigint);
select tests.throws('anon: storage.objects INSERT 拒否',
  format('insert into storage.objects (bucket_id, name) values (''avatars'', %L)', tests.uid('bob')::text || '/a.jpg'), '42501');

-- 認証済みだが sub が無い(不正なJWT想定)
select tests.become_authenticated_no_sub();
select tests.eq('sub無しの authenticated: profiles は0件', tests.cnt('select 1 from public.profiles'), 0::bigint);
select tests.eq('sub無しの authenticated: dogs は0件(publicでも)', tests.cnt('select 1 from public.dogs'), 0::bigint);
select tests.eq('sub無しの authenticated: facilities は見える(施設マスタは全ログインユーザー向け)', tests.cnt('select 1 from public.facilities') >= 1, true);
select tests.eq('sub無しの authenticated: issue_qr_token → WB401', tests.errstate('select * from public.issue_qr_token()'), 'WB401');
select tests.eq('sub無しの authenticated: redeem_qr_token → WB401', tests.errstate('select * from public.redeem_qr_token(''aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'')'), 'WB401');

select tests.become_super();
rollback;
