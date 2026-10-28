-- 12: L-3 検索の has_avatar / L-4 施設TZ CHECK / L-5 FK索引 / L-6 通報・意見の1日上限
\set ON_ERROR_STOP on
begin;

select tests.set_now_jst('2026-10-28 12:00');
select tests.mkuser('r1'); select tests.mkuser('r2'); select tests.mkuser('r3'); select tests.mkuser('r4');

-- ================= L-3: search_user_by_user_code は avatar_path を返さない(has_avatar のみ) =================
update public.profile_settings set searchable = true where user_id in (tests.uid('r2'), tests.uid('r3'));
update public.profiles set avatar_path = tests.uid('r3')::text || '/avatar.png' where id = tests.uid('r3');
select user_code as c2 from public.profiles where id = tests.uid('r2') \gset
select user_code as c3 from public.profiles where id = tests.uid('r3') \gset
select tests.ok('L-3 戻り値の列は (nickname, has_avatar) のみ',
  (select pg_get_function_result('public.search_user_by_user_code(text)'::regprocedure)) = 'TABLE(nickname text, has_avatar boolean)');
select tests.become('r1');
select tests.eq('L-3 アイコン無し: has_avatar=false', (select has_avatar from public.search_user_by_user_code(:'c2')), false);
select tests.eq('L-3 アイコン有り: has_avatar=true', (select has_avatar from public.search_user_by_user_code(:'c3')), true);
select tests.eq('L-3 アイコン有りでも nickname が返る', (select nickname from public.search_user_by_user_code(:'c3')), 'r3');
select tests.eq('L-3 avatar_path 列は参照できない', tests.errstate(format('select avatar_path from public.search_user_by_user_code(%L)', :'c3')), '42703');
select tests.become_super();

-- ================= L-4: facilities.timezone の CHECK =================
select tests.ok('L-4 CHECK制約が存在する',
  exists (select 1 from pg_constraint where conrelid = 'public.facilities'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%is_valid_timezone%'));
select tests.lives('L-4 Asia/Tokyo は有効', 'insert into public.facilities (code, name, open_time, close_time, timezone) values (''tz-ok1'', ''x'', ''06:00'', ''21:00'', ''Asia/Tokyo'')');
select tests.lives('L-4 UTC は有効', 'insert into public.facilities (code, name, open_time, close_time, timezone) values (''tz-ok2'', ''x'', ''06:00'', ''21:00'', ''UTC'')');
select tests.lives('L-4 America/New_York は有効', 'insert into public.facilities (code, name, open_time, close_time, timezone) values (''tz-ok3'', ''x'', ''06:00'', ''21:00'', ''America/New_York'')');
select tests.lives('L-4 省略時の既定値(Asia/Tokyo)で作成できる', 'insert into public.facilities (code, name, open_time, close_time) values (''tz-ok4'', ''x'', ''06:00'', ''21:00'')');
select tests.throws('L-4 存在しないTZは拒否(Mars/Phobos)', 'insert into public.facilities (code, name, open_time, close_time, timezone) values (''tz-ng1'', ''x'', ''06:00'', ''21:00'', ''Mars/Phobos'')', '23514');
select tests.throws('L-4 空文字は拒否', 'insert into public.facilities (code, name, open_time, close_time, timezone) values (''tz-ng2'', ''x'', ''06:00'', ''21:00'', '''')', '23514');
select tests.throws('L-4 打ち間違い(Asia/Tokio)は拒否', 'insert into public.facilities (code, name, open_time, close_time, timezone) values (''tz-ng3'', ''x'', ''06:00'', ''21:00'', ''Asia/Tokio'')', '23514');
select tests.throws('L-4 NULL は拒否(NOT NULL)', 'insert into public.facilities (code, name, open_time, close_time, timezone) values (''tz-ng4'', ''x'', ''06:00'', ''21:00'', null)', '23502');
select tests.throws('L-4 UPDATE でも不正TZは拒否', 'update public.facilities set timezone = ''Nowhere/City'' where code = ''tz-ok1''', '23514');
select tests.eq('L-4 UPDATE 拒否後も値は変わらない', (select timezone from public.facilities where code = 'tz-ok1'), 'Asia/Tokyo');
select tests.ok('L-4 既存シード施設は有効なTZ', (select bool_and(private.is_valid_timezone(timezone)) from public.facilities));
select tests.eq('L-4 is_valid_timezone(NULL)=false', private.is_valid_timezone(null), false);
-- service_role(運営用)でも CHECK が評価できる(関数の EXECUTE 権限不足で落ちない)
select tests.become_service();
select tests.lives('L-4 service_role での施設登録(CHECK評価に EXECUTE 権限が足りている)', 'insert into public.facilities (code, name, open_time, close_time, timezone) values (''tz-svc'', ''x'', ''06:00'', ''21:00'', ''Asia/Tokyo'')');
select tests.throws('L-4 service_role でも不正TZは拒否', 'insert into public.facilities (code, name, open_time, close_time, timezone) values (''tz-svc2'', ''x'', ''06:00'', ''21:00'', ''Bad/Zone'')', '23514');
select tests.become_super();
-- クライアントは施設を書き換えられない(従来どおり)
select tests.become('r1');
select tests.throws('L-4 authenticated は facilities へ INSERT 不可', 'insert into public.facilities (code, name, open_time, close_time) values (''tz-c'', ''x'', ''06:00'', ''21:00'')', '42501');
select tests.become_super();

-- ================= L-5: FK列の索引 =================
select tests.ok('L-5 指定の5索引が存在する(qr_scans.owner_id/token_id, reports.reporter_id/target_user_id, feedback.user_id)',
  (select count(*) from pg_indexes where schemaname = 'public'
     and ((tablename = 'qr_scans'  and indexdef ~ '\(owner_id\)$')
       or (tablename = 'qr_scans'  and indexdef ~ '\(token_id\)$')
       or (tablename = 'reports'   and indexdef ~ '\(reporter_id\)$')
       or (tablename = 'reports'   and indexdef ~ '\(target_user_id\)$')
       or (tablename = 'feedback'  and indexdef ~ '\(user_id\)$'))) = 5);
-- 一般則: public の全 FK について、FK列を先頭に持つ「部分索引でない」索引が存在する(部分索引は FK 参照チェックに使えない)
select tests.ok('L-5 全FK(' || count(*) || '本)に、FK列を先頭列とする非部分索引がある',
  count(*) > 0 and bool_and(exists (
    select 1 from pg_index i
     where i.indrelid = c.conrelid and i.indpred is null and i.indisvalid
       and (select array_agg(k order by ord) from unnest(i.indkey::int2[]) with ordinality t(k, ord) where ord <= cardinality(c.conkey))
           @> c.conkey::int2[]
       and cardinality(c.conkey) <= i.indnatts
  )))
  from pg_constraint c where c.contype = 'f' and c.connamespace = 'public'::regnamespace;

-- ================= L-6: 通報 20/日・意見 10/日(JST暦日) =================
select tests.ok('L-6 上限は app_config の定数(通報20・意見10)',
  (select value from private.app_config where key = 'report_daily_limit') = '20'
  and (select value from private.app_config where key = 'feedback_daily_limit') = '10');
select tests.become('r1');
do $$
declare i int; v_st text;
begin
  for i in 1..20 loop
    insert into public.reports (reporter_id, target_user_id, reason) values (tests.uid('r1'), tests.uid('r2'), 'other');
  end loop;
  perform tests.ok('L-6 通報: 20件までは登録できる', true);
end $$;
select tests.eq('L-6 通報: 21件目は WB301', tests.errstate(format('insert into public.reports (reporter_id, target_user_id, reason) values (%L, %L, ''other'')', tests.uid('r1'), tests.uid('r2'))), 'WB301');
select tests.eq('L-6 通報: 上限超過後も拒否が続く(別の対象でも)', tests.errstate(format('insert into public.reports (reporter_id, target_user_id, reason) values (%L, %L, ''harassment'')', tests.uid('r1'), tests.uid('r3'))), 'WB301');
select tests.eq('L-6 通報: 上限超過のエラー文言(WB301 は利用者向け文言)', tests.errmsg(format('insert into public.reports (reporter_id, target_user_id, reason) values (%L, %L, ''other'')', tests.uid('r1'), tests.uid('r2'))) is not null, true);
select tests.become('r2');
select tests.lives('L-6 通報: 他のユーザーは影響を受けない', format('insert into public.reports (reporter_id, target_user_id, reason) values (%L, %L, ''other'')', tests.uid('r2'), tests.uid('r3')));
-- 不正な挿入(CHECK違反)は枠を消費しない
select tests.eq('L-6 通報: 不正な値で失敗しても枠を消費しない(1件目の後)', tests.errstate(format('insert into public.reports (reporter_id, target_user_id, reason) values (%L, %L, ''lol'')', tests.uid('r2'), tests.uid('r3'))), '23514');
select tests.become_super();
select tests.eq('L-6 通報: r1 の登録は20件ちょうど(21件目は入っていない)', (select count(*) from public.reports where reporter_id = tests.uid('r1')), 20::bigint);
select tests.eq('L-6 通報: カウンタは r1=20, r2=1(失敗した挿入は加算されない)',
  (select jsonb_object_agg(user_id::text, n) from private.daily_counters where kind = 'report' and user_id in (tests.uid('r1'), tests.uid('r2')))::text,
  jsonb_build_object(tests.uid('r1')::text, 20, tests.uid('r2')::text, 1)::text);
select tests.eq('L-6 created_at はアプリ時刻(app_now)', (select min(created_at) from public.reports where reporter_id = tests.uid('r1')), tests.jst('2026-10-28 12:00'));

-- JST 暦日が変わると再び登録できる(23:59 → 00:01)
select tests.set_now_jst('2026-10-28 23:59');
select tests.become('r1');
select tests.eq('L-6 通報: 同じ日の23:59はまだ拒否', tests.errstate(format('insert into public.reports (reporter_id, target_user_id, reason) values (%L, %L, ''other'')', tests.uid('r1'), tests.uid('r2'))), 'WB301');
select tests.set_now_jst('2026-10-29 00:01');
select tests.lives('L-6 通報: JSTの日付が変わると再び登録できる', format('insert into public.reports (reporter_id, target_user_id, reason) values (%L, %L, ''other'')', tests.uid('r1'), tests.uid('r2')));
select tests.become_super();

-- 意見: 10件/日。匿名(user_id NULL)で送っても送信者の枠に数える
select tests.set_now_jst('2026-10-28 12:00');
select tests.become('r3');
do $$
declare i int;
begin
  for i in 1..5 loop
    insert into public.feedback (user_id, kind, body) values (tests.uid('r3'), 'bug', 'b' || i);
  end loop;
  for i in 6..10 loop
    insert into public.feedback (kind, body) values ('other', '匿名' || i);   -- user_id NULL
  end loop;
  perform tests.ok('L-6 意見: 実名5件+匿名5件=10件まで登録できる', true);
end $$;
select tests.eq('L-6 意見: 11件目(匿名)は WB302', tests.errstate('insert into public.feedback (kind, body) values (''other'', ''11'')'), 'WB302');
select tests.eq('L-6 意見: 11件目(実名)も WB302', tests.errstate(format('insert into public.feedback (user_id, kind, body) values (%L, ''bug'', ''11'')', tests.uid('r3'))), 'WB302');
select tests.become('r4');
select tests.lives('L-6 意見: 他のユーザーは影響を受けない(匿名でも)', 'insert into public.feedback (kind, body) values (''other'', ''r4'')');
select tests.eq('L-6 意見: 不正入力(空本文)の失敗は枠を消費しない', tests.errstate('insert into public.feedback (kind, body) values (''other'', '''')'), '23514');
select tests.become_super();
select tests.eq('L-6 意見: r3 の保存件数は10件', (select count(*) from public.feedback where user_id = tests.uid('r3') or body ~ '^匿名'), 10::bigint);
select tests.eq('L-6 意見: カウンタ r3=10, r4=1',
  (select jsonb_object_agg(user_id::text, n) from private.daily_counters where kind = 'feedback' and user_id in (tests.uid('r3'), tests.uid('r4')))::text,
  jsonb_build_object(tests.uid('r3')::text, 10, tests.uid('r4')::text, 1)::text);
-- 設定値を変えると上限が変わる(定数は app_config)
update private.app_config set value = '11' where key = 'feedback_daily_limit';
select tests.become('r3');
select tests.lives('L-6 意見: 上限を11にすると11件目が通る(設定値が効く)', 'insert into public.feedback (kind, body) values (''other'', ''11'')');
select tests.eq('L-6 意見: 12件目は拒否', tests.errstate('insert into public.feedback (kind, body) values (''other'', ''12'')'), 'WB302');
select tests.become_super();
update private.app_config set value = '10' where key = 'feedback_daily_limit';

-- 通報と意見の枠は別々
select tests.become('r1');
select tests.set_now_jst('2026-10-30 12:00');
select tests.lives('L-6 通報の枠と意見の枠は別々(意見)', 'insert into public.feedback (kind, body) values (''bug'', ''x'')');
select tests.become_super();

-- ops/service_role(auth.uid() が無い)からの INSERT は制限しない(運営の一括投入を妨げない)
select tests.become_service();
select tests.lives('L-6 service_role の挿入は上限の対象外', 'insert into public.feedback (kind, body) select ''other'', ''svc'' || g from generate_series(1, 15) g');
select tests.become_super();

-- 古いカウンタの定期削除
select tests.set_now_jst('2026-11-05 10:00');
select tests.become_service();
select tests.ok('L-6 purge: 古い日のカウンタが削除される', (select counters_deleted > 0 from public.purge_old_presence_data()));
select tests.become_super();
select tests.eq('L-6 purge後: 古いカウンタは残らない', (select count(*) from private.daily_counters where day < date '2026-11-04'), 0::bigint);

-- カウンタ表は client から見えない・触れない
select tests.become('r1');
select tests.throws('L-6 authenticated は daily_counters を参照できない', 'select * from private.daily_counters', '42501');
select tests.throws('L-6 authenticated は daily_counters を更新できない', 'update private.daily_counters set n = 0', '42501');
select tests.become_super();

rollback;
