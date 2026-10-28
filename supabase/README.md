# WanBuddy v0.2 / M2 — DB基盤 + RLS(ローカル検証版)

PRD v0.2 の第4章・第7章・第10章 M2 を実装し、ローカルPostgreSQLで検証したものです。
**外部サービス(GitHub・Supabase等)には何も書き込んでいません。** すべてボックス上のファイルとローカルPostgreSQLのみです。

- 検証結果(最終): **541 PASS / 0 FAIL**(通常構成)、旧来デフォルト権限構成(`LEGACY=1`)でも **541 PASS / 0 FAIL**
- 検証したPG: PostgreSQL 16.14(Supabase CLI 想定は PG15+)

---

## 1. 前提(Supabaseプロジェクトの設定)

| 設定 | 値 | 影響 |
|---|---|---|
| 新規テーブルの自動公開(auto expose) | **OFF** | 新規テーブル/関数/シーケンスに anon/authenticated の権限は**自動付与されない**。→ migrations で必要な GRANT を**すべて明示** |
| 自動RLS | **ON** | 新規テーブルはRLS有効で作られる。→ migrations でも `enable row level security` を明示(設定に依存しない) |

方針(最優先事項: RLS抜け・security definer の権限昇格・search_path):

1. 全15テーブルでRLS有効。ポリシーは**すべて `to authenticated` を明示**、操作(select/insert/update/delete)ごとに分割、`(select auth.uid())` の initplan 形式。
2. テーブル権限は**必要な操作・必要な列だけ** authenticated に GRANT。anon には**何もGRANTしない**。
   - 直接INSERT不可: `presences` / `presence_dogs` / `friendships` / `qr_tokens` / `qr_scans`(= RPC経由のみ)。`qr_tokens` / `qr_scans` はSELECTも不可。
   - 列単位GRANT: 例 `profiles` は `avatar_path, id, nickname, user_code, visibility_owner` のみINSERT可、`profile_settings.invite_code` はUPDATE不可(再生成はRPCのみ)。
3. 関数: 全関数を `REVOKE ALL ... FROM PUBLIC, anon`(PostgreSQLの既定の PUBLIC EXECUTE も除去)し、RPCは **authenticated のみ EXECUTE**。定期処理用の2関数は **service_role のみ**。
4. `security definer` 関数は**すべて `set search_path = ''`** + 完全修飾名。内部ヘルパーは `private` スキーマ(PostgREST非公開)。
5. 「他人の友達関係/ブロック関係を探れない」ガード: `private.can_view` / `private.is_friend` は viewer = `auth.uid()` のときだけ答える。`private.is_blocked_either` / `friend_count` / `config_int` は authenticated に EXECUTE なし。
6. ビューは `security_invoker = true`(呼び出し者のRLSが効く)。

## 2. ディレクトリ構成

```
supabase/
├─ migrations/                       Supabase CLI形式の連番(本番に適用するのはここだけ)
│  ├─ 20261028120001_foundation.sql      private スキーマ, 既定権限のREVOKE, app_config(定数), app_now(), config_int()
│  ├─ 20261028120002_tables.sql          15テーブル(profiles, profile_settings, dogs, dog_instagram, friendships, blocks,
│  │                                     facilities, facility_areas, presences, presence_dogs, qr_tokens, qr_scans,
│  │                                     reports, feedback, terms_consents)+制約・部分ユニーク索引
│  ├─ 20261028120003_access_functions.sql can_view / is_friend / is_blocked_either / friend_count / 閉園時刻計算
│  ├─ 20261028120004_triggers.sql        user_code・invite_code 採番, 犬上限5頭, 最後の犬の削除禁止, ブロック時の友達削除 等
│  ├─ 20261028120005_rls_and_grants.sql  RLS有効化 + 明示GRANT(列単位含む) + ポリシー
│  ├─ 20261028120006_rpc_friends.sql     QR発行/失効/読取, 招待コード・ID申請, 承認/拒否, 受信一覧, 招待コード再生成, ID検索
│  ├─ 20261028120007_rpc_presence.sql    register/extend/end_presence, complete_expired_presences, purge_old_presence_data
│  ├─ 20261028120008_views.sql           my_friends, presence_board
│  ├─ 20261028120009_seed_facility.sql   施設マスタ(辰巳の森海浜公園ドッグラン 6:00–21:00 / エリア free・small)
│  └─ 20261028120010_storage.sql         バケット avatars / dog-photos(private)+ Storageポリシー
├─ test_support/                     ★ローカル検証専用。migrations には含めない
│  ├─ 00_supabase_stub.sql               roles(anon/authenticated/service_role), auth.users/auth.uid(), storage.*, 自動RLS(event trigger)
│  │                                     ※ デフォルト権限は付与しない(= auto expose OFF を再現)
│  ├─ 01_legacy_default_privileges.sql   (任意) 旧来のSupabase=自動付与あり を再現するストレステスト用
│  └─ 10_test_helpers.sql                private.app_now() をテスト用GUC版に差替え + tests.* ヘルパー
├─ tests/                            SQLテスト(各ファイル begin…rollback)
│  ├─ 01_security_audit.sql    RLS全有効 / anon・PUBLIC権限 / search_path / EXECUTE許可リスト / ビューinvoker / ポリシー形式 / 既定権限プローブ
│  ├─ 02_view_matrix.sql       閲覧マトリクス全ケース + 複数頭の在場表示 + ブロック
│  ├─ 03_anon.sql              anonは何もSELECT/EXECUTE/書込みできない
│  ├─ 04_profiles_dogs.sql     プロフィール・犬(上限5・最後の1頭)・Instagram・通報/フィードバック/同意・施設RLS
│  ├─ 05_qr.sql                QR発行/読取と全拒否ケース
│  ├─ 06_presence.sql          在場の状態遷移(4.5.1全遷移), 閉園, 延長, 開園時間外, cron関数, 物理削除
│  ├─ 07_friend_requests_block.sql  招待コード/ID申請, 承認/拒否, 上限, ブロック
│  ├─ 08_direct_write_denied.sql    GRANTマトリクス完全一致 + GRANTの無い操作は42501 + 直接INSERT拒否
│  └─ 09_storage.sql           Storageポリシー
├─ run_tests.sh                      PG15+を探す/用意 → stub → migrations → helpers → tests を実行
└─ README.md
```

※ 施設シード(4.12)は migration `…09` に入れています(本番にも必要なマスタのため)。テスト用データは各テストが `tests.mkuser()` 等で作成し、`rollback` で消えます(別途 seed.sql は不要)。

## 3. ローカル検証手順

```bash
cd supabase
./run_tests.sh                 # 通常(auto expose=OFF 再現)。全PASSで exit 0、FAILがあれば exit 1
LEGACY=1 ./run_tests.sh        # 旧来の「新規オブジェクトに自動GRANT」環境でも安全かの追加確認
ONLY=06 ./run_tests.sh         # 一部のテストだけ
KEEP=1 ./run_tests.sh          # 終了後もDBを残す(psql -h /tmp/wanbuddy-pgtest/sock -U postgres wanbuddy_test)
PG_BIN=/path/to/pg/bin ./run_tests.sh   # PostgreSQLの場所を指定
```

- PostgreSQL 15+ を `$PG_BIN` → `PATH` → `/usr/lib/postgresql` → `.pg-local` の順に探し、無ければ apt(rootのみ)または pip の `pixeltable-pgserver` wheel から取得して一時クラスタ(unixソケットのみ・TCPなし)を作ります。
- 各テストは `WBTEST PASS|FAIL|名前` を出力し、`run_tests.sh` が集計します。

### 時刻の差し替え
本番は `private.app_now()` = `now()`。テストでは `10_test_helpers.sql` が同関数を GUC `app.test_now` 参照に差し替え、`tests.set_now_jst('2026-10-28 20:30')` で任意の時刻にできます(期限・閉園・日次上限・物理削除のテストで使用)。**このファイルは本番に適用しないこと。**

## 4. 公開RPC・ビュー(すべて authenticated のみ EXECUTE / SELECT)

| 関数 | 用途 |
|---|---|
| `issue_qr_token()` → (qr_token, qr_expires_at) | QR発行(平文は返却時のみ。DBにはsha256のみ) |
| `revoke_qr_tokens()` | 自分の有効QRを全失効 |
| `redeem_qr_token(token)` | QR読取 → 即 accepted(method='qr') |
| `request_friend_by_invite_code(code)` / `request_friend_by_user_code(user_code)` | 承認制の申請 |
| `search_user_by_user_code(user_code)` | 完全一致のみ。searchable=true の相手の nickname/avatar のみ |
| `respond_friend_request(id, accept)` / `list_incoming_friend_requests()` | 承認/拒否・受信一覧 |
| `regenerate_invite_code()` | 招待コード再生成(旧コード即無効) |
| `register_presence(facility_id, status, dog_ids[], planned_at=null, area_code=null)` | 今いる/これから行く(置換・planned→now自動終了を同一トランザクションで) |
| `extend_presence(id)` / `end_presence(id)` | 延長(+60分、閉園まで) / 終了(nowは manual、plannedは cancelled) |
| `complete_expired_presences()`, `purge_old_presence_data()` | **service_role のみ**(pg_cron/Edge Function想定。M3以降で配線) |
| ビュー `my_friends`, `presence_board` | security_invoker。presence_board は犬ごとの公開範囲を反映した犬配列(jsonb)を返す |

エラーは SQLSTATE `WBxxx` で返す(例: WB001 QR無効 / WB002 自分自身 / WB003 既に友達 / WB004 日次上限 / WB005 友達上限 / WB006 申請済み / WB011 コード不明(ブロックも同じ) / WB102 犬0頭 / WB103 他人の犬 / WB201 開園時間外 / WB205 閉園まで延長不可 / WB206 延長不可 / WB207 在場なし)。

## 5. 定数一覧(`private.app_config`。変更は SQL で UPDATE。クライアントからは読めない)

| key | 値 | 区分 |
|---|---|---|
| max_dogs_per_user | 5 | PRD 4.2 |
| qr_ttl_minutes | 10 | 【提案値】 |
| qr_max_uses | 5 | 【提案値】 |
| qr_daily_scan_limit | 20(JST暦日) | 【提案値】 |
| max_friends | 100 | 【提案値】 |
| max_outgoing_pending_requests | 30 | 【提案値・PRD外(スパム対策)】 |
| presence_now_minutes | 180 | 【提案値】 |
| presence_extend_minutes | 60 | 【提案値】 |
| presence_planned_max_ahead_hours | 24 | 【提案値】 |
| presence_planned_grace_minutes | 60(planned の expires_at = 予定時刻 + 60分、閉園でキャップ) | 【提案値】 |
| presence_purge_after_hours | 24 | 【提案値】 |
| qr_token_purge_after_hours | 24 | 【提案値】 |
| qr_scan_log_retention_days | 7 | 【提案値】 |
| 施設 | 辰巳の森海浜公園ドッグラン 6:00–21:00 Asia/Tokyo、エリア free(1240㎡)/small(490㎡) | PRD 4.12 |
| Storage | 2MB / jpeg・png・webp / private | 【提案値】 |

## 6. PRDとの差分・実装上の判断(【提案値】含む)

- **テーブル分割**(7.1の「案」から): `profile_settings`(invite_code / searchable / accept_qr は本人のみ閲覧)、`dog_instagram`(犬ごとのInstagramを別テーブルにして列単位の公開範囲を実現)、`qr_scans`(日次上限・ログ)。
- **友達関係の見え方**: `pending` / `declined` のあいだは相手のプロフィールは見えない(accepted のみ友達扱い)。
- **ブロック**: ブロック時に友達関係を即削除(トリガー)。ブロックされた側には何も分からない(申請しても「コードが見つかりません」)。
- **在場の期限切れ**: `app_now() >= expires_at`(閉園21:00ちょうど含む)は **cron未実行でも RLS/ビューで不可視**。物理的な `ended_at` / `expired` 設定は `complete_expired_presences()`(cron)または次回の登録時の遅延完了。
- **planned の置換**: 新しい planned を登録すると旧 planned は `replaced`。同一施設の now 登録で planned は `switched_to_now`(`ended_at`=now登録時刻)。別施設の planned は影響を受けない。
- **直接書込みの扱い**: 7.2-8 の「自分の行のみINSERT/UPDATE/DELETE」と「テーブルへの直接INSERT権限は与えない」は矛盾気味 → 後者(RPCのみ)を採用し、`presences` / `presence_dogs` / `friendships` は SELECT(と friendships の DELETE)のみ。

## 7. 疑問点・矛盾・抜け(企画立案への質問)

1. **user_code は自動生成か、ユーザー指定か**: PRDが未確定。現状は「未指定ならDBが自動生成、指定も可(列GRANTあり・形式CHECK・一意)」。指定不可にする場合は `profiles.user_code` の INSERT/UPDATE 列GRANTを外すだけ。
2. **利用規約同意の強制**: `terms_consents` は記録のみ。同意が無いとRPC/書込み不可にするか?(現状は強制しない)
3. **検索結果プレビューのアイコン**: `search_user_by_user_code` は avatar_path(パス)を返すが、非友達はStorage上のアイコンを読めない(avatars の閲覧は can_view 準拠)。プレビューに画像が必要なら署名URL発行用のEdge Functionが必要。
4. **プロフィールが private の人の在場**: 現状、在場は友達に表示され nickname が null になり得る(owner の公開範囲が private の場合)。private の人は在場も出さない方がよいか?
5. **拒否(declined)後の再申請**: 拒否された側は再申請不可(WB013)、拒否した側からの申請は可能(履歴を消して新規pending)。この仕様でよいか。
6. **相互申請**: 逆向きの pending があるときの申請は自動承認。QRで読み取った場合も pending/declined は accepted に昇格(拒否したことのある相手のQRを自分が読めば友達になる)。意図通りか。
7. **QR日次上限のカウント**: JST暦日(0:00リセット)で20件。「24時間ローリング」にするか。
8. **QR失敗のレート制限なし**: 総当たり対策は 64桁hex(122bit相当+)で現実的に不可能としたが、失敗試行のレート制限(IP/ユーザー)は未実装(PRD 4.3 の「レート制限をRPC内で検査」のうち日次登録上限のみ実装)。必要ならM3でEdge Function側に。
9. **通報の対象**: `reports.target_user_id` は退会で NULL に(通報記録は残す)、reporter は退会で削除。それでよいか。
10. **Storageオブジェクトの退会/犬削除時の削除**: DBのトリガーでは行わず(Storage APIの管理外削除は非推奨のため)、Edge Function / 退会処理に任せる前提。
11. **bucket制限**: 2MB・jpeg/png/webp は【提案値】。クライアント側で縮小する前提か?
12. **planned_at の過去時刻**: 現在以前は拒否(WB203)。「今から数分前のつもり」の端末時計ズレの許容は設けていない。
13. **在場の公開範囲 (`presences.visibility`)**: PRD 7.1 は friends/private とあるが、「private なら在場を出さない」はそもそも登録しなければよいので、列は friends 固定でクライアントから変更不可にしている。残す必要があるか?
14. **施設の timezone**: 施設マスタの timezone の妥当性検証は未実装(運用者が不正値を入れると失敗する)。1施設のため許容。
15. **友達上限の非対称性**: 承認時に**申請者側**が上限に達している場合、承認側には曖昧なエラー(WB009「承認できません」)。申請者に通知する仕組みは未定。
16. **planned と now の併存**: 同一ユーザーが別施設の planned と今いるを併存可。同一施設では planned が自動終了。
17. **施設シードの置き場所**: 本番にも必要なマスタなので migration に含めた(`seed.sql` ではない)。テストデータ用の seed は無し。
18. **Supabase の auto expose=OFF の確認**: ダッシュボード設定は本ローカル環境では再現のみ。実プロジェクトに migrations を適用した際、`select * from information_schema.role_table_grants where grantee in ('anon','authenticated')` 等で意図通りか目視確認を推奨。

## 8. 未検証・注意

- **実Supabase環境**での適用(Supabase CLI `supabase db reset`、ホスティング版の `postgres` ロールは非superuser)。ローカルは superuser `postgres` で適用しているため、所有者/権限まわりの差異は未確認(特に storage スキーマへの書込み、`storage.objects` への CREATE POLICY は hosted では可能だが未確認)。
- `pg_cron` / Edge Function による `complete_expired_presences()` / `purge_old_presence_data()` の定期実行(M3以降)。
- Storage API(実アップロード・署名URL・MIME/サイズ制限の実効)、Realtime のRLS挙動。
- 同時実行(競合)テスト: `for update` / プロフィール行ロック / 部分ユニーク索引で直列化する設計だが、並行実行での実測は未実施。
- stub は Supabase 互換の近似であり、`auth.uid()` は GUC `request.jwt.claim.sub` 参照の簡易版。
