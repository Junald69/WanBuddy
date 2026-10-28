-- 06: 在場(今いるよ/これから行くよ)の状態遷移(PRD 4.5.1)・閉園時刻・延長・開園時間外・複数頭
--   時刻は tests.set_now_jst() で差し替え(private.app_now のテスト用上書き)
\set ON_ERROR_STOP on
begin;

select tests.facility() as fid \gset
select tests.mkuser('p'); select tests.mkdog('p', 2);
select tests.mkuser('q');
select tests.mkuser('f');                  -- p の友達
select tests.befriend('p', 'f');
select tests.mkuser('stranger');

-- 別施設(planned が他施設では影響を受けないことの確認用)
insert into public.facilities (code, name, open_time, close_time) values ('other-run', 'other', '06:00', '21:00');
select id as fid2 from public.facilities where code = 'other-run' \gset

-- ================= 登録: 入力検証 =================
select tests.set_now_jst('2026-10-28 12:00');
select tests.become('p');
select tests.eq('犬0頭(空配列)は拒否 WB102', tests.errstate(format('select public.register_presence(%L, ''now'', ''{}''::uuid[])', :'fid')), 'WB102');
select tests.eq('犬NULLは拒否 WB102', tests.errstate(format('select public.register_presence(%L, ''now'', null)', :'fid')), 'WB102');
select tests.eq('他人の犬は拒否 WB103', tests.errstate(format('select public.register_presence(%L, ''now'', array[%L]::uuid[])', :'fid', tests.dog_uid('q', 1))), 'WB103');
select tests.eq('自分の犬+他人の犬の混在も拒否 WB103', tests.errstate(format('select public.register_presence(%L, ''now'', array[%L, %L]::uuid[])', :'fid', tests.dog_uid('p', 1), tests.dog_uid('q', 1))), 'WB103');
select tests.eq('存在しない犬は拒否 WB103', tests.errstate(format('select public.register_presence(%L, ''now'', array[%L]::uuid[])', :'fid', gen_random_uuid())), 'WB103');
select tests.eq('status不正は拒否 WB104', tests.errstate(format('select public.register_presence(%L, ''away'', array[%L]::uuid[])', :'fid', tests.dog_uid('p', 1))), 'WB104');
select tests.eq('存在しない施設は拒否 WB101', tests.errstate(format('select public.register_presence(%L, ''now'', array[%L]::uuid[])', gen_random_uuid(), tests.dog_uid('p', 1))), 'WB101');
select tests.eq('存在しない広場は拒否 WB202', tests.errstate(format('select public.register_presence(%L, ''now'', array[%L]::uuid[], null, ''vip'')', :'fid', tests.dog_uid('p', 1))), 'WB202');
select tests.become_super();
update public.facilities set is_active = false where code = 'other-run';
select tests.become('p');
select tests.eq('無効な施設は拒否 WB101', tests.errstate(format('select public.register_presence(%L, ''now'', array[%L]::uuid[])', :'fid2', tests.dog_uid('p', 1))), 'WB101');
select tests.become_super();
update public.facilities set is_active = true where code = 'other-run';

-- ================= now: 登録・期限・複数頭 =================
select tests.become('p');
select public.register_presence(:'fid', 'now', array[tests.dog_uid('p', 1), tests.dog_uid('p', 2), tests.dog_uid('p', 1)], null, 'small') as n1 \gset
select tests.become_super();
select tests.eq('now: 12:00登録 → 3時間後(15:00)に失効', (select expires_at from public.presences where id = :'n1'), tests.jst('2026-10-28 15:00'));
select tests.eq('now: 犬は重複除去され2頭', (select count(*) from public.presence_dogs where presence_id = :'n1'), 2::bigint);
select tests.ok('now: status=now / started_at=現在 / area=small / visibility=friends',
  (select status = 'now' and started_at = tests.jst('2026-10-28 12:00') and area_code = 'small' and visibility = 'friends' and ended_at is null
     from public.presences where id = :'n1'));

-- 友達には見え、非友達には見えない
select tests.become('f');
select tests.eq('友達: presence_board に犬2頭で見える', (select jsonb_array_length(dogs)::bigint from public.presence_board where presence_id = :'n1'), 2::bigint);
select tests.become('stranger');
select tests.eq('非友達: 見えない', tests.cnt('select 1 from public.presence_board'), 0::bigint);
select tests.become_super();

-- 延長: +60分
select tests.set_now_jst('2026-10-28 14:00');
select tests.become('p');
select tests.eq('延長: +60分(15:00→16:00)', public.extend_presence(:'n1'), tests.jst('2026-10-28 16:00'));
select tests.become('q');
select tests.eq('他人の在場は延長できない WB207', tests.errstate(format('select public.extend_presence(%L)', :'n1')), 'WB207');
select tests.eq('他人の在場は終了できない WB207', tests.errstate(format('select public.end_presence(%L)', :'n1')), 'WB207');
select tests.become_super();

-- now → now(置換): 旧nowは replaced
select tests.set_now_jst('2026-10-28 14:30');
select tests.become('p');
select public.register_presence(:'fid', 'now', array[tests.dog_uid('p', 1)]) as n2 \gset
select tests.become_super();
select tests.eq('now→now: 旧nowは replaced', (select ended_reason from public.presences where id = :'n1'), 'replaced');
select tests.eq('now→now: 旧nowの ended_at は置換時刻', (select ended_at from public.presences where id = :'n1'), tests.jst('2026-10-28 14:30'));
select tests.eq('now→now: 有効なnowは常に1件', (select count(*) from public.presences where user_id = tests.uid('p') and status = 'now' and ended_at is null), 1::bigint);
select tests.eq('now→now: 犬は新しい選択(1頭)', (select count(*) from public.presence_dogs where presence_id = :'n2'), 1::bigint);

-- 手動終了(manual) / 冪等
select tests.set_now_jst('2026-10-28 15:00');
select tests.become('p');
select public.end_presence(:'n2');
select tests.become_super();
select tests.eq('now→手動終了: manual', (select ended_reason from public.presences where id = :'n2'), 'manual');
select tests.eq('now→手動終了: ended_at=現在', (select ended_at from public.presences where id = :'n2'), tests.jst('2026-10-28 15:00'));
select tests.become('p');
select tests.lives('終了済みの再終了は冪等(エラーにならない)', format('select public.end_presence(%L)', :'n2'));
select tests.eq('終了済みは延長できない WB206', tests.errstate(format('select public.extend_presence(%L)', :'n2')), 'WB206');
select tests.become('f');
select tests.eq('終了した在場は友達に見えない', tests.cnt('select 1 from public.presence_board'), 0::bigint);
select tests.become_super();
select tests.eq('再終了しても ended_reason / ended_at は変わらない', (select ended_at from public.presences where id = :'n2'), tests.jst('2026-10-28 15:00'));

-- ================= planned =================
select tests.set_now_jst('2026-10-28 12:00');
select tests.become('p');
select tests.eq('planned: planned_at 未指定は拒否 WB105', tests.errstate(format('select public.register_presence(%L, ''planned'', array[%L]::uuid[])', :'fid', tests.dog_uid('p', 1))), 'WB105');
select tests.eq('planned: 過去時刻は拒否 WB203', tests.errstate(format('select public.register_presence(%L, ''planned'', array[%L]::uuid[], %L)', :'fid', tests.dog_uid('p', 1), tests.jst('2026-10-28 11:59'))), 'WB203');
select tests.eq('planned: 現在時刻ちょうども拒否 WB203', tests.errstate(format('select public.register_presence(%L, ''planned'', array[%L]::uuid[], %L)', :'fid', tests.dog_uid('p', 1), tests.jst('2026-10-28 12:00'))), 'WB203');
select tests.eq('planned: 24時間より先は拒否 WB204', tests.errstate(format('select public.register_presence(%L, ''planned'', array[%L]::uuid[], %L)', :'fid', tests.dog_uid('p', 1), tests.jst('2026-10-29 12:01'))), 'WB204');
select tests.eq('planned: 開園前(翌5:00)は拒否 WB201', tests.errstate(format('select public.register_presence(%L, ''planned'', array[%L]::uuid[], %L)', :'fid', tests.dog_uid('p', 1), tests.jst('2026-10-29 05:00'))), 'WB201');
select tests.eq('planned: 閉園後(21:30)は拒否 WB201', tests.errstate(format('select public.register_presence(%L, ''planned'', array[%L]::uuid[], %L)', :'fid', tests.dog_uid('p', 1), tests.jst('2026-10-28 21:30'))), 'WB201');
select tests.eq('planned: 21:00ちょうどは拒否 WB201', tests.errstate(format('select public.register_presence(%L, ''planned'', array[%L]::uuid[], %L)', :'fid', tests.dog_uid('p', 1), tests.jst('2026-10-28 21:00'))), 'WB201');

select public.register_presence(:'fid', 'planned', array[tests.dog_uid('p', 1), tests.dog_uid('p', 2)], tests.jst('2026-10-28 14:00')) as pl1 \gset
select tests.become_super();
select tests.ok('planned: planned_at=14:00 / 失効=15:00(予定+60分) / started_at=登録時刻',
  (select status = 'planned' and planned_at = tests.jst('2026-10-28 14:00') and expires_at = tests.jst('2026-10-28 15:00')
          and started_at = tests.jst('2026-10-28 12:00') and ended_at is null from public.presences where id = :'pl1'));
select tests.become('f');
select tests.eq('planned: 友達に status=planned で見える', (select status from public.presence_board where presence_id = :'pl1'), 'planned');
select tests.become('p');
select tests.eq('planned は延長できない WB206', tests.errstate(format('select public.extend_presence(%L)', :'pl1')), 'WB206');

-- planned → planned(置換): replaced
select public.register_presence(:'fid', 'planned', array[tests.dog_uid('p', 1)], tests.jst('2026-10-28 16:00')) as pl2 \gset
select tests.become_super();
select tests.eq('planned→planned: 旧plannedは replaced', (select ended_reason from public.presences where id = :'pl1'), 'replaced');
select tests.eq('planned→planned: 有効なplannedは1件', (select count(*) from public.presences where user_id = tests.uid('p') and status = 'planned' and ended_at is null), 1::bigint);

-- 他施設のplanned は 同一ユーザーでも別枠…(有効なplannedは1ユーザー1件のため replaced になる)。ここでは now との関係を確認
-- 同一施設の planned → now: switched_to_now(同一トランザクションで終了)
select tests.set_now_jst('2026-10-28 15:30');
select tests.become('p');
select public.register_presence(:'fid', 'now', array[tests.dog_uid('p', 1)]) as n3 \gset
select tests.become_super();
select tests.eq('planned→now(同一施設): plannedは switched_to_now', (select ended_reason from public.presences where id = :'pl2'), 'switched_to_now');
select tests.eq('planned→now: ended_at = now登録時刻(同一トランザクション)', (select ended_at from public.presences where id = :'pl2'), tests.jst('2026-10-28 15:30'));
select tests.eq('planned→now: 有効な在場はnow1件のみ', (select count(*) from public.presences where user_id = tests.uid('p') and ended_at is null), 1::bigint);
select tests.ok('planned→now: 新nowが作られている', (select status = 'now' and ended_at is null from public.presences where id = :'n3'));

-- 別施設のplanned は、同一ユーザーが他施設で now にしても終了しない
select tests.set_now_jst('2026-10-28 16:00');
select tests.become('p');
select public.register_presence(:'fid2', 'planned', array[tests.dog_uid('p', 1)], tests.jst('2026-10-28 18:00')) as pl3 \gset
select tests.become_super();
select tests.ok('別施設のplanned登録: 既存nowには影響しない', (select ended_at is null from public.presences where id = :'n3'));
select tests.become('p');
select public.register_presence(:'fid', 'now', array[tests.dog_uid('p', 1)]) as n4 \gset
select tests.become_super();
select tests.ok('別施設のplannedは、他施設でのnow登録では終了しない', (select ended_at is null from public.presences where id = :'pl3'));
select tests.eq('(続き)前のnowは replaced', (select ended_reason from public.presences where id = :'n3'), 'replaced');

-- plannedの手動取消(cancelled)
select tests.become('p');
select public.end_presence(:'pl3');
select tests.become_super();
select tests.eq('planned→手動取消: cancelled', (select ended_reason from public.presences where id = :'pl3'), 'cancelled');

-- ================= 閉園時刻(21:00) =================
select tests.become_super();
update public.presences set ended_at = private.app_now(), ended_reason = 'manual' where ended_at is null and user_id = tests.uid('p');

select tests.set_now_jst('2026-10-28 20:30');
select tests.become('p');
select public.register_presence(:'fid', 'now', array[tests.dog_uid('p', 1)]) as c1 \gset
select tests.become_super();
select tests.eq('20:30登録 → 21:00に失効(3時間後の23:30にならない)', (select expires_at from public.presences where id = :'c1'), tests.jst('2026-10-28 21:00'));
select tests.become('p');
select tests.eq('20:30登録: 21:00を超える延長は拒否 WB205', tests.errstate(format('select public.extend_presence(%L)', :'c1')), 'WB205');
select tests.become_super();
select tests.eq('(続き)失効時刻は変わらない', (select expires_at from public.presences where id = :'c1'), tests.jst('2026-10-28 21:00'));

-- 20:59 / 21:00 の境界
select tests.set_now_jst('2026-10-28 20:59');
select tests.become('f');
select tests.eq('20:59: 友達にはまだ見える', tests.cnt('select 1 from public.presence_board'), 1::bigint);
select tests.set_now_jst('2026-10-28 21:00');
select tests.eq('21:00: 友達には見えない(閉園で解除。cron未実行でもビュー/RLSで不可視)', tests.cnt('select 1 from public.presence_board'), 0::bigint);
select tests.eq('21:00: presences も見えない', tests.cnt(format('select 1 from public.presences where id = %L', :'c1')), 0::bigint);
select tests.become('p');
select tests.eq('21:00: nowは開園時間外のため登録不可 WB201', tests.errstate(format('select public.register_presence(%L, ''now'', array[%L]::uuid[])', :'fid', tests.dog_uid('p', 1))), 'WB201');
select tests.eq('21:00: 期限切れの在場は延長不可 WB206', tests.errstate(format('select public.extend_presence(%L)', :'c1')), 'WB206');
select tests.become_service();
select tests.ok('閉園時刻の在場は cron(complete_expired_presences)で完了される', public.complete_expired_presences() >= 1);
select tests.become_super();
select tests.eq('(続き)reason=expired', (select ended_reason from public.presences where id = :'c1'), 'expired');
select tests.eq('(続き)ended_at は失効時刻(21:00)', (select ended_at from public.presences where id = :'c1'), tests.jst('2026-10-28 21:00'));

-- 開園時間外
select tests.set_now_jst('2026-10-28 05:59');
select tests.become('p');
select tests.eq('05:59: 開園前は拒否 WB201', tests.errstate(format('select public.register_presence(%L, ''now'', array[%L]::uuid[])', :'fid', tests.dog_uid('p', 1))), 'WB201');
select tests.set_now_jst('2026-10-28 23:00');
select tests.eq('23:00: 閉園後は拒否 WB201', tests.errstate(format('select public.register_presence(%L, ''now'', array[%L]::uuid[])', :'fid', tests.dog_uid('p', 1))), 'WB201');
select tests.set_now_jst('2026-10-29 00:00');
select tests.eq('0:00: 拒否 WB201', tests.errstate(format('select public.register_presence(%L, ''now'', array[%L]::uuid[])', :'fid', tests.dog_uid('p', 1))), 'WB201');
select tests.set_now_jst('2026-10-29 06:00');
select tests.lives('06:00ちょうどは登録できる', format('select public.register_presence(%L, ''now'', array[%L]::uuid[])', :'fid', tests.dog_uid('p', 1)));
select tests.become_super();
select tests.eq('06:00登録: 失効=09:00', (select expires_at from public.presences where user_id = tests.uid('p') and ended_at is null and status = 'now'), tests.jst('2026-10-29 09:00'));

-- 延長の段階: 17:30登録 → 20:30 → 延長で21:00(21:30にならない) → さらに延長は不可
update public.presences set ended_at = private.app_now(), ended_reason = 'manual' where ended_at is null and user_id = tests.uid('p');
select tests.set_now_jst('2026-10-29 17:30');
select tests.become('p');
select public.register_presence(:'fid', 'now', array[tests.dog_uid('p', 1)]) as c2 \gset
select tests.become_super();
select tests.eq('17:30登録 → 20:30失効', (select expires_at from public.presences where id = :'c2'), tests.jst('2026-10-29 20:30'));
select tests.become('p');
select tests.eq('延長: 20:30+60分=21:30 ではなく閉園の21:00で打ち止め', public.extend_presence(:'c2'), tests.jst('2026-10-29 21:00'));
select tests.eq('再延長は拒否 WB205', tests.errstate(format('select public.extend_presence(%L)', :'c2')), 'WB205');
select tests.become_super();

-- planned の閉園キャップ
update public.presences set ended_at = private.app_now(), ended_reason = 'manual' where ended_at is null and user_id = tests.uid('p');
select tests.set_now_jst('2026-10-29 12:00');
select tests.become('p');
select public.register_presence(:'fid', 'planned', array[tests.dog_uid('p', 1)], tests.jst('2026-10-29 20:30')) as c3 \gset
select tests.become_super();
select tests.eq('planned 20:30 → 失効は21:00(予定+60分=21:30でキャップ)', (select expires_at from public.presences where id = :'c3'), tests.jst('2026-10-29 21:00'));
-- 翌日の planned(24時間以内): 翌日の閉園時刻を基準
update public.presences set ended_at = private.app_now(), ended_reason = 'manual' where ended_at is null and user_id = tests.uid('p');
select tests.set_now_jst('2026-10-29 20:00');
select tests.become('p');
select public.register_presence(:'fid', 'planned', array[tests.dog_uid('p', 1)], tests.jst('2026-10-30 07:00')) as c4 \gset
select tests.become_super();
select tests.eq('翌朝7:00のplanned → 失効は8:00', (select expires_at from public.presences where id = :'c4'), tests.jst('2026-10-30 08:00'));

-- ================= 完了/物理削除(cron想定) =================
update public.presences set ended_at = private.app_now(), ended_reason = 'manual' where ended_at is null and user_id = tests.uid('p');
select tests.set_now_jst('2026-10-30 10:00');
select tests.become('q');
select public.register_presence(:'fid', 'now', array[tests.dog_uid('q', 1)]) as d1 \gset
select tests.become('p');
select public.register_presence(:'fid', 'planned', array[tests.dog_uid('p', 1)], tests.jst('2026-10-30 11:00')) as d2 \gset
select tests.become_super();
select tests.set_now_jst('2026-10-30 14:00');   -- qのnow(→13:00)もpのplanned(→12:00)も失効済み
select tests.become('p');
select tests.throws('一般ユーザーは complete_expired_presences を呼べない', 'select public.complete_expired_presences()', '42501');
select tests.throws('一般ユーザーは purge_old_presence_data を呼べない', 'select * from public.purge_old_presence_data()', '42501');
select tests.become_service();
select tests.eq('complete_expired_presences: 2件を完了', public.complete_expired_presences(), 2);
select tests.become_super();
select tests.eq('now→期限切れ: expired', (select ended_reason from public.presences where id = :'d1'), 'expired');
select tests.eq('planned→期限切れ: expired', (select ended_reason from public.presences where id = :'d2'), 'expired');
select tests.eq('expired の ended_at は失効時刻(13:00)', (select ended_at from public.presences where id = :'d1'), tests.jst('2026-10-30 13:00'));
select tests.become_service();
select tests.eq('2回目の complete は0件(冪等)', public.complete_expired_presences(), 0);
select tests.become_super();

select tests.set_now_jst('2026-10-31 12:59');   -- 終了(13:00)から24時間未満
select tests.become_service();
select 1 from public.purge_old_presence_data();
select tests.become_super();
select tests.ok('24時間未満(13:00終了→翌12:59): 物理削除されない', exists (select 1 from public.presences where id = :'d1'));
select tests.set_now_jst('2026-10-31 13:01');   -- 24時間超
select tests.become_service();
select tests.ok('24時間経過: d1(13:00終了)が物理削除される', (select presences_deleted >= 1 from public.purge_old_presence_data()));
select tests.become_super();
select tests.ok('(続き)d1とそのpresence_dogsが消える',
  not exists (select 1 from public.presences where id = :'d1') and not exists (select 1 from public.presence_dogs where presence_id = :'d1'));

-- 有効な在場は purge で消えない
select tests.set_now_jst('2026-10-31 13:30');
select tests.become('q');
select public.register_presence(:'fid', 'now', array[tests.dog_uid('q', 1)]) as d3 \gset
select tests.become_service();
select 1 from public.purge_old_presence_data();
select tests.become_super();
select tests.ok('有効なnowは purge の対象外', exists (select 1 from public.presences where id = :'d3' and ended_at is null));

-- ================= 犬削除との整合 =================
select tests.become('q');
select tests.eq('犬1頭だけのユーザーは最後の犬を消せない(在場中でも) WB108', tests.errstate(format('delete from public.dogs where id = %L', tests.dog_uid('q', 1))), 'WB108');
select tests.become_super();

-- ================= DBの一意制約(多層防御) =================
select tests.throws('DB制約: 有効なnowの重複は作れない(23505)',
  format('insert into public.presences (user_id, facility_id, status, started_at, expires_at) values (%L, %L, ''now'', now(), now() + interval ''1 hour'')', tests.uid('q'), :'fid'), '23505');
select tests.throws('DB制約: planned_at のない planned は作れない(23514)',
  format('insert into public.presences (user_id, facility_id, status, started_at, expires_at) values (%L, %L, ''planned'', now(), now() + interval ''1 hour'')', tests.uid('f'), :'fid'), '23514');
select tests.throws('DB制約: 在場に他人の犬は入れられない(WB103)',
  format('insert into public.presence_dogs (presence_id, dog_id) values (%L, %L)', :'d3', tests.dog_uid('p', 1)), 'WB103');

rollback;
