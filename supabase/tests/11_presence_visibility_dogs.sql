-- 11: M-1 在場の公開範囲(register_presence の p_visibility) / M-2 set_presence_dogs
\set ON_ERROR_STOP on
begin;

select tests.facility() as fid \gset
select tests.set_now_jst('2026-10-28 12:00');
select tests.mkuser('own'); select tests.mkdog('own', 2); select tests.mkdog('own', 3);
select tests.mkuser('fr');         -- own の友達
select tests.mkuser('st');         -- 他人(非友達)
select tests.mkuser('bl');         -- own にブロックされている(友達行が不整合に残っている状態も作る)
select tests.mkuser('bl2');        -- own をブロックしている(同上)
select tests.befriend('own', 'fr');
select tests.block('own', 'bl');   select tests.befriend('own', 'bl');
select tests.block('bl2', 'own');  select tests.befriend('own', 'bl2');
select tests.mkuser('oth'); select tests.mkdog('oth', 2);

-- ================= M-1: p_visibility =================
select tests.become('own');
select tests.eq('M-1 visibility不正(public)は WB106', tests.errstate(format('select public.register_presence(%L, ''now'', array[%L]::uuid[], null, null, ''public'')', :'fid', tests.dog_uid('own', 1))), 'WB106');
select tests.eq('M-1 visibility不正(空文字)は WB106', tests.errstate(format('select public.register_presence(%L, ''now'', array[%L]::uuid[], null, null, '''')', :'fid', tests.dog_uid('own', 1))), 'WB106');
select tests.eq('M-1 visibility不正(大文字 Private)は WB106', tests.errstate(format('select public.register_presence(%L, ''now'', array[%L]::uuid[], null, null, ''Private'')', :'fid', tests.dog_uid('own', 1))), 'WB106');
select tests.eq('M-1 visibility NULL は WB106', tests.errstate(format('select public.register_presence(%L, ''now'', array[%L]::uuid[], null, null, null)', :'fid', tests.dog_uid('own', 1))), 'WB106');
select tests.eq('M-1 不正なvisibilityでは在場が作られない', (select count(*) from public.presences), 0::bigint);

-- 既定は 'friends'(引数なしの呼び出しは従来どおり)
select public.register_presence(:'fid', 'now', array[tests.dog_uid('own', 1)]) as p_def \gset
select tests.eq('M-1 既定の visibility は friends', (select visibility from public.presences where id = :'p_def'), 'friends');

-- 全組み合わせ: status(now/planned) × visibility(friends/private) × 閲覧者
do $$
declare
  r record;
  v_id uuid;
  v_fid uuid := tests.facility();
  v_dog uuid := tests.dog_uid('own', 1);
  v_ok boolean;
  w text;
  v_expect boolean;
  v_rows bigint; v_board bigint; v_dogs bigint;
begin
  for r in select s, v from (values ('now'), ('planned')) a(s) cross join (values ('friends'), ('private')) b(v) loop
    perform tests.become('own');
    if r.s = 'now' then
      v_id := public.register_presence(v_fid, 'now', array[v_dog], null, null, r.v);
    else
      v_id := public.register_presence(v_fid, 'planned', array[v_dog], tests.jst('2026-10-28 13:00'), null, r.v);
    end if;
    perform tests.eq(format('M-1 [%s/%s] 保存された visibility', r.s, r.v),
                     (select visibility from public.presences where id = v_id), r.v);
    foreach w in array array['own', 'fr', 'st', 'bl', 'bl2'] loop
      perform tests.become(w);
      -- 本人は常に見える / friends: 友達のみ / private: 本人のみ / 非友達・ブロック関係(友達行が残っていても)は見えない
      v_expect := (w = 'own') or (r.v = 'friends' and w = 'fr');
      select count(*) into v_rows  from public.presences where id = v_id;
      select count(*) into v_board from public.presence_board where presence_id = v_id;
      select count(*) into v_dogs  from public.presence_dogs where presence_id = v_id;
      perform tests.eq(format('M-1 [%s/%s] %s: presences の可視', r.s, r.v, w), v_rows, v_expect::int::bigint);
      perform tests.eq(format('M-1 [%s/%s] %s: presence_board の可視', r.s, r.v, w), v_board, v_expect::int::bigint);
      perform tests.eq(format('M-1 [%s/%s] %s: presence_dogs の可視', r.s, r.v, w), v_dogs, v_expect::int::bigint);
    end loop;
  end loop;
  perform tests.become_super();
end $$;
select tests.become('fr');
select tests.eq('M-1 友達視点: 直近の private(planned) 在場は友達に見えない',
  (select count(*) from public.presence_board where user_id = tests.uid('own')), 0::bigint);
select tests.become_super();

-- 再登録で private → friends に戻せる(置き換えられた旧在場は誰にも見えない)
select tests.become('own');
select public.register_presence(:'fid', 'now', array[tests.dog_uid('own', 1)], null, null, 'friends') as p_f \gset
select tests.become('fr');
select tests.eq('M-1 private → friends へ再登録すると友達に見える(旧在場は終了済みで見えない)',
  (select count(*) from public.presence_board where user_id = tests.uid('own') and status = 'now'), 1::bigint);
select tests.become_super();

-- 直接 UPDATE で公開範囲を広げられない(presences に UPDATE 権限なし)
select tests.become('own');
select tests.throws('M-1 presences.visibility の直接UPDATEは不可', 'update public.presences set visibility = ''friends''', '42501');
select tests.become_super();

-- ================= M-2: set_presence_dogs =================
select tests.set_now_jst('2026-10-28 12:00');
update public.presences set ended_at = now(), ended_reason = 'cancelled' where user_id = tests.uid('own') and ended_at is null;
select tests.become('own');
select public.register_presence(:'fid', 'now', array[tests.dog_uid('own', 1)], null, null, 'friends') as pn \gset
select expires_at as exp0 from public.presences where id = :'pn' \gset

select tests.lives('M-2 自分の有効な在場の犬を差し替えられる(1頭→2頭)',
  format('select public.set_presence_dogs(%L, array[%L, %L]::uuid[])', :'pn', tests.dog_uid('own', 2), tests.dog_uid('own', 3)));
select tests.ok('M-2 差し替え後の犬が正確(dog2, dog3 のみ。dog1 は外れる)',
  (select array_agg(dog_id order by dog_id) from public.presence_dogs where presence_id = :'pn')
  = (select array_agg(x order by x) from unnest(array[tests.dog_uid('own', 2), tests.dog_uid('own', 3)]) x));
select tests.eq('M-2 expires_at は変わらない', (select expires_at from public.presences where id = :'pn'), :'exp0'::timestamptz);
select tests.ok('M-2 status/started_at/visibility/ended_at も変わらない',
  (select status = 'now' and started_at = tests.jst('2026-10-28 12:00') and visibility = 'friends' and ended_at is null
     from public.presences where id = :'pn'));
select tests.lives('M-2 重複指定・同じ犬の再指定もOK(重複除去)',
  format('select public.set_presence_dogs(%L, array[%L, %L, %L]::uuid[])', :'pn', tests.dog_uid('own', 1), tests.dog_uid('own', 1), tests.dog_uid('own', 2)));
select tests.eq('M-2 重複は除去され2頭', (select count(*) from public.presence_dogs where presence_id = :'pn'), 2::bigint);

-- 友達からの見え方が追従する(犬の公開範囲 friends)
select tests.become('fr');
select tests.eq('M-2 友達視点: ボードの犬が差し替え後の2頭',
  (select jsonb_array_length(dogs)::bigint from public.presence_board where presence_id = :'pn'), 2::bigint);
select tests.become('own');

-- 検証エラー(失敗時は元のまま)
select tests.eq('M-2 犬0頭(空配列)は WB102', tests.errstate(format('select public.set_presence_dogs(%L, ''{}''::uuid[])', :'pn')), 'WB102');
select tests.eq('M-2 犬NULLは WB102', tests.errstate(format('select public.set_presence_dogs(%L, null)', :'pn')), 'WB102');
select tests.eq('M-2 NULL要素のみも WB102', tests.errstate(format('select public.set_presence_dogs(%L, array[null]::uuid[])', :'pn')), 'WB102');
select tests.eq('M-2 他人の犬は WB103', tests.errstate(format('select public.set_presence_dogs(%L, array[%L]::uuid[])', :'pn', tests.dog_uid('oth', 1))), 'WB103');
select tests.eq('M-2 自分の犬+他人の犬の混在も WB103', tests.errstate(format('select public.set_presence_dogs(%L, array[%L, %L]::uuid[])', :'pn', tests.dog_uid('own', 1), tests.dog_uid('oth', 1))), 'WB103');
select tests.eq('M-2 存在しない犬は WB103', tests.errstate(format('select public.set_presence_dogs(%L, array[%L]::uuid[])', :'pn', gen_random_uuid())), 'WB103');
select tests.eq('M-2 失敗後も犬は直前の2頭のまま', (select count(*) from public.presence_dogs where presence_id = :'pn'), 2::bigint);
select tests.ok('M-2 失敗後も他人の犬は混入していない',
  not exists (select 1 from public.presence_dogs pd join public.dogs d on d.id = pd.dog_id where pd.presence_id = :'pn' and d.owner_id <> tests.uid('own')));

-- 他人の在場・存在しない在場: 区別不可(WB207)
select tests.become('oth');
select public.register_presence(:'fid', 'now', array[tests.dog_uid('oth', 1)]) as po \gset
select tests.become('own');
select tests.eq('M-2 他人の在場は WB207', tests.errstate(format('select public.set_presence_dogs(%L, array[%L]::uuid[])', :'po', tests.dog_uid('own', 1))), 'WB207');
select tests.eq('M-2 存在しない在場は WB207(他人の在場と同じコード)', tests.errstate(format('select public.set_presence_dogs(%L, array[%L]::uuid[])', gen_random_uuid(), tests.dog_uid('own', 1))), 'WB207');
select tests.become_super();
select tests.eq('M-2 他人の在場の犬は変わっていない', (select array_agg(dog_id) from public.presence_dogs where presence_id = :'po'), array[tests.dog_uid('oth', 1)]);
select tests.become('own');

-- planned の在場も変更できる
select public.register_presence(:'fid', 'planned', array[tests.dog_uid('own', 1)], tests.jst('2026-10-28 15:00')) as pp \gset
select tests.lives('M-2 planned の在場の犬も変更できる', format('select public.set_presence_dogs(%L, array[%L]::uuid[])', :'pp', tests.dog_uid('own', 3)));
select tests.eq('M-2 planned: 変更後の犬', (select dog_id from public.presence_dogs where presence_id = :'pp'), tests.dog_uid('own', 3));

-- 終了済み・期限切れ: WB206
select public.end_presence(:'pn');
select tests.eq('M-2 終了済み(manual)の在場は WB206', tests.errstate(format('select public.set_presence_dogs(%L, array[%L]::uuid[])', :'pn', tests.dog_uid('own', 1))), 'WB206');
select tests.become_super();
select tests.set_now_jst('2026-10-28 16:00');   -- planned(15:00+60分=16:00)が失効
select tests.become('own');
select tests.eq('M-2 期限切れの在場は WB206', tests.errstate(format('select public.set_presence_dogs(%L, array[%L]::uuid[])', :'pp', tests.dog_uid('own', 1))), 'WB206');

-- 権限: 直接書き込みは不可のまま / anon・PUBLIC は実行不可 / authenticatedのみ実行可
select tests.throws('M-2 presence_dogs の直接 INSERT は不可', format('insert into public.presence_dogs values (%L, %L)', :'pn', tests.dog_uid('own', 1)), '42501');
select tests.throws('M-2 presence_dogs の直接 DELETE は不可', 'delete from public.presence_dogs', '42501');
select tests.become_super();
select tests.ok('M-2 set_presence_dogs の EXECUTE: authenticated のみ(anon/PUBLIC 不可)',
  has_function_privilege('authenticated', 'public.set_presence_dogs(uuid, uuid[])', 'execute')
  and not has_function_privilege('anon', 'public.set_presence_dogs(uuid, uuid[])', 'execute')
  and not exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                   where p.oid = 'public.set_presence_dogs(uuid, uuid[])'::regprocedure and a.grantee = 0));
select tests.ok('M-2 set_presence_dogs は security definer・search_path 固定・VOLATILE',
  (select prosecdef and provolatile = 'v' and 'search_path=""' = any (proconfig)
     from pg_proc where oid = 'public.set_presence_dogs(uuid, uuid[])'::regprocedure));
select tests.become_authenticated_no_sub();
select tests.eq('M-2 sub無しは WB401', tests.errstate(format('select public.set_presence_dogs(%L, array[%L]::uuid[])', gen_random_uuid(), gen_random_uuid())), 'WB401');
select tests.become_super();
insert into auth.users (id, email) values (tests.uid('noprof'), 'noprof@example.test');
select tests.become('noprof');
select tests.eq('M-2 プロフィール未作成は WB402', tests.errstate(format('select public.set_presence_dogs(%L, array[%L]::uuid[])', gen_random_uuid(), gen_random_uuid())), 'WB402');
select tests.become_super();

rollback;
