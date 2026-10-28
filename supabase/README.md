# WanBuddy v0.2 / M2 — DB基盤 + RLS(ローカル検証版)

PRD v0.2 の第4章・第7章・第10章 M2 を実装し、ローカルPostgreSQLで検証したものです。
**外部サービス(GitHub・Supabase等)には何も書き込んでいません。** すべてボックス上のファイルとローカルPostgreSQLのみです。

- 検証結果(最終・レビュー指摘反映後): **780 PASS / 0 FAIL**(通常構成)、旧来デフォルト権限構成(`LEGACY=1`)でも **780 PASS / 0 FAIL**
  (SQLテスト12ファイル751件 + 並行実行テスト(L-1)12件 + `verify_grants.sql` 17項目)
- 検証したPG: PostgreSQL 16.14(Supabase CLI 想定は PG15+)

---

## 1. 前提(Supabaseプロジェクトの設定)

| 設定 | 値 | 影響 |
|---|---|---|
| 新規テーブルの自動公開(auto expose) | **OFF** | 新規テーブル/関数/シーケンスに anon/authenticated の権限は**自動付与されない**。→ migrations で必要な GRANT を**すべて明示** |
| 自動RLS | **ON** | 新規テーブルはRLS有効で作られる。→ migrations でも `enable row level security` を明示(設定に依存しない) |

方針(最優先事項: RLS抜け・security definer の権限昇格・search_path):

1. 全15テーブル(+内部用 `private.daily_counters`)でRLS有効。ポリシーは**すべて `to authenticated` を明示**、操作(select/insert/update/delete)ごとに分割、`(select auth.uid())` の initplan 形式。
2. テーブル権限は**必要な操作・必要な列だけ** authenticated に GRANT。anon には**何もGRANTしない**。
   - 直接INSERT不可: `presences` / `presence_dogs` / `friendships` / `qr_tokens` / `qr_scans`(= RPC経由のみ)。`qr_tokens` / `qr_scans` はSELECTも不可。
   - 列単位GRANT: 例 `profiles` は INSERT=`avatar_path, id, nickname, visibility_owner` / UPDATE=`avatar_path, nickname, visibility_owner`(**`user_code` はクライアントから INSERT/UPDATE とも不可**=DB自動生成のみ)、`profile_settings.invite_code` はUPDATE不可(再生成はRPCのみ)。
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
├─ verify_grants.sql                 ★本番適用後に流す権限確認SQL(読み取り専用。17項目 PASS/FAIL/WARN)
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
│  ├─ 09_storage.sql           Storageポリシー
│  ├─ 10_readonly_rpc.sql      H-1: 読み取り専用トランザクション(PostgREST GET相当)で STABLE/IMMUTABLE の全RPC・ビュー・判定関数が動く
│  ├─ 11_presence_visibility_dogs.sql  M-1 在場の公開範囲(private/friends × 閲覧者 × ブロック) / M-2 set_presence_dogs
│  └─ 12_limits_schema.sql     L-3 has_avatar / L-4 施設TZ CHECK / L-5 FK索引 / L-6 通報・意見の1日上限
├─ tests_concurrency/
│  └─ l1_lock_order.sh         L-1: 相互QR読取・申請交差・同時申請でデッドロックしないことを実セッション並行で検証(コミット済みDBをテンプレート複製して実行)
├─ run_tests.sh                      PG15+を探す/用意 → stub → migrations → helpers → tests → verify_grants → 並行実行テスト
└─ README.md
```

※ 施設シード(4.12)は migration `…09` に入れています(本番にも必要なマスタのため)。テスト用データは各テストが `tests.mkuser()` 等で作成し、`rollback` で消えます(別途 seed.sql は不要)。

## 3. ローカル検証手順

```bash
cd supabase
./run_tests.sh                 # 通常(auto expose=OFF 再現)。全PASSで exit 0、FAILがあれば exit 1
LEGACY=1 ./run_tests.sh        # 旧来の「新規オブジェクトに自動GRANT」環境でも安全かの追加確認
ONLY=06 ./run_tests.sh         # 一部のテストだけ(ONLY=conc: 並行実行テスト / ONLY=verify_grants: 権限確認SQL)
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
| `search_user_by_user_code(user_code)` → (nickname, has_avatar) | 完全一致のみ。searchable=true の相手の nickname と **アイコン有無(boolean)** のみ。avatar_path は返さない(L-3)。STABLE(読み取り専用トランザクションで動く) |
| `respond_friend_request(id, accept)` / `list_incoming_friend_requests()` | 承認/拒否・受信一覧 |
| `regenerate_invite_code()` | 招待コード再生成(旧コード即無効) |
| `register_presence(facility_id, status, dog_ids[], planned_at=null, area_code=null, visibility='friends')` | 今いる/これから行く(置換・planned→now自動終了を同一トランザクションで)。`visibility` は `'friends'`(既定)/`'private'`(本人のみ)。それ以外は WB106(M-1)。planned_at は現在-2分まで許容(L: WB203) |
| `set_presence_dogs(presence_id, dog_ids[])` | 自分の**有効な**在場の犬を差し替え(1頭以上・自分の犬のみ・`expires_at` 不変)(M-2) |
| `extend_presence(id)` / `end_presence(id)` | 延長(+60分、閉園まで) / 終了(nowは manual、plannedは cancelled) |
| `complete_expired_presences()`, `purge_old_presence_data()` | **service_role のみ**(pg_cron/Edge Function想定。M3以降で配線)。purge は古い `daily_counters` も削除(戻り値に `counters_deleted` 追加) |
| ビュー `my_friends`, `presence_board` | security_invoker。presence_board は犬ごとの公開範囲を反映した犬配列(jsonb)を返す。**承認済みの友達の nickname は、相手のプロフィールが private でも返す**(M-3 / PRD 4.4「全頭が見えない場合は飼い主名のみ」)。非友達・ブロック関係は従来どおり何も出ない |

エラーは SQLSTATE `WBxxx` で返す(例: WB001 QR無効 / WB002 自分自身 / WB003 既に友達 / WB004 日次上限 / WB005 友達上限 / WB006 申請済み / WB011 コード不明(ブロックも同じ) / WB102 犬0頭 / WB103 他人の犬 / WB106 visibility不正 / WB201 開園時間外 / WB205 閉園まで延長不可 / WB206 延長不可 / WB207 在場なし / WB301 通報の1日上限 / WB302 意見の1日上限)。

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
| presence_planned_past_tolerance_minutes | 2(planned_at が現在より最大2分前までは許容。それより前は WB203) | レビュー確定(Q12) |
| report_daily_limit | 20(JST暦日・ユーザー単位) | 【提案値】 |
| feedback_daily_limit | 10(JST暦日・送信者単位。匿名で送っても送信者の枠に数える) | 【提案値】 |
| presence_purge_after_hours | 24 | 【提案値】 |
| qr_token_purge_after_hours | 24 | 【提案値】 |
| qr_scan_log_retention_days | 7 | 【提案値】 |
| 施設 | 辰巳の森海浜公園ドッグラン 6:00–21:00 Asia/Tokyo、エリア free(1240㎡)/small(490㎡) | PRD 4.12 |
| Storage | 2MB / jpeg・png・webp / private | レビュー確定(Q11) |

## 6. PRDとの差分・実装上の判断(【提案値】含む)

- **テーブル分割**(7.1の「案」から): `profile_settings`(invite_code / searchable / accept_qr は本人のみ閲覧)、`dog_instagram`(犬ごとのInstagramを別テーブルにして列単位の公開範囲を実現)、`qr_scans`(日次上限・ログ)。
- **友達関係の見え方**: `pending` / `declined` のあいだは相手のプロフィールは見えない(accepted のみ友達扱い)。
- **ブロック**: ブロック時に友達関係を即削除(トリガー)。ブロックされた側には何も分からない(申請しても「コードが見つかりません」)。
- **在場の期限切れ**: `app_now() >= expires_at`(閉園21:00ちょうど含む)は **cron未実行でも RLS/ビューで不可視**。物理的な `ended_at` / `expired` 設定は `complete_expired_presences()`(cron)または次回の登録時の遅延完了。
- **planned の置換**: 新しい planned を登録すると旧 planned は `replaced`。同一施設の now 登録で planned は `switched_to_now`(`ended_at`=now登録時刻)。別施設の planned は影響を受けない。
- **友達の nickname(M-3)**: `private.display_name(owner)` が「本人 / 承認済みの友達 / can_view が真」のときだけ nickname を返す(security definer・`search_path=''`・viewer = `auth.uid()` 固定)。ブロック関係では `is_friend` が偽になるため(ブロック時に友達行は削除。不整合で残っていても同様)何も出ない。
- **QRでの昇格(M-4)**: 既存の友達行が `pending`、または `declined` で**拒否した側が QR 提示者**のときだけ accepted に昇格。それ以外の declined(= 読み取る側が拒否した相手)は他の拒否理由と同じ文言(WB001)で拒否。
- **並行実行(L-1)**: プロフィール行のロックを `FOR UPDATE` → `FOR NO KEY UPDATE`(friendships INSERT の FK が相手のプロフィール行に取る `FOR KEY SHARE` と衝突しない)に変更し、2者間フローは `pg_advisory_xact_lock(ペア)` で直列化。旧実装では A↔B の同時操作で `40P01 deadlock` を再現(`tests_concurrency/l1_lock_order.sh` で再現→解消を確認)。
- **日次上限(L-6)**: `reports` / `feedback` の BEFORE INSERT トリガーが `private.daily_counters`(user_id, kind, JST日, n)をアトミックに加算し、上限超過で WB301/WB302。**`auth.uid()` が無い挿入(service_role/運営SQL)は対象外**。トリガーは `created_at` をアプリ時刻(`app_now()`)で上書きする。失敗した挿入(CHECK違反等)は枠を消費しない。
- **読み取り専用(H-1)**: `private.current_profile()`(ロック無し・存在確認のみ)を STABLE RPC に使用。`require_profile()`(行ロック有り)は書き込みRPCのみ。STABLE/IMMUTABLE関数にロック文・`require_profile` が無いことは `10_readonly_rpc.sql` が静的にも検査。
- **直接書込みの扱い**: 7.2-8 の「自分の行のみINSERT/UPDATE/DELETE」と「テーブルへの直接INSERT権限は与えない」は矛盾気味 → 後者(RPCのみ)を採用し、`presences` / `presence_dogs` / `friendships` は SELECT(と friendships の DELETE)のみ。

## 7. 疑問点・矛盾・抜け(質問リスト)と Reviewer 回答の反映

| # | 論点 | 回答(Reviewer)と現在の実装 |
|---|---|---|
| 1 | user_code は自動生成か指定可か | **自動生成のみ**。`profiles.user_code` の INSERT/UPDATE 列GRANTを削除(L-2)。変更用RPCは作らない。形式CHECK・一意制約はDBに残る |
| 2 | 利用規約同意の強制 | **M3で対応**(現状は記録のみ・強制しない) |
| 3 | 検索プレビューのアイコン | **パスは返さない**。`search_user_by_user_code` は `has_avatar boolean`(L-3)。画像表示が必要なら署名URL(Edge Function)を M3 で |
| 4 | 公開範囲が private の人の在場/名前 | **友達にはニックネームを返す**(M-3 実装済み)。非友達・ブロックは何も出ない |
| 5 | declined 後の再申請 | **現仕様のまま**(拒否された側は再申請不可 WB013、拒否した側からは可) |
| 6 | 相互申請・QRでの昇格 | 相互申請は自動承認のまま。**QR昇格は pending / QR提示者が拒否した declined のみ**(M-4 実装済み) |
| 7 | QR日次上限の数え方 | **JSTの暦日**で確定 |
| 8 | QR失敗のレート制限 | **M3 の Edge Function** で実装(IP/ユーザー単位) |
| 9 | 通報の保持方針 | **保持期間180日はTBD → PRD側で決定**。現状は退会で target を NULL(記録は残す)、reporter は削除。通報/意見は1日上限あり(L-6) |
| 10 | Storageオブジェクトの退会/犬削除時の削除 | **M3 のチェックリストに追加**(退会処理/Edge Function) |
| 11 | bucket制限 | **2MB・jpeg/png/webp** で確定 |
| 12 | planned_at の過去時刻 | **現在-2分までは許容**(`p_planned_at < app_now() - 2分` で WB203)。実装済み |
| 13 | 在場の公開範囲 | **残す**(実装済み: `register_presence(..., p_visibility)`。M-1) |
| 14 | 施設 timezone の検証 | **CHECK を追加**(L-4。`private.is_valid_timezone` が `pg_timezone_names` を参照) |
| 15 | 友達上限の非対称エラー | **現状のまま**(承認側には曖昧なエラー WB009) |
| 16 | planned と now の併存 | 同一ユーザーが別施設の planned と今いるを併存可。同一施設では planned が自動終了(変更なし) |
| 17 | 施設シードの置き場所 | 本番にも必要なマスタなので migration に含める(変更なし) |
| 18 | auto expose=OFF の確認 | `supabase/verify_grants.sql` を本番適用後に実行(下記) |

### 新たに生じた/残っている論点(実装者から)
- **Q9 保持期間**: 通報・意見・日次カウンタの保持(カウンタは前日分まで保持して purge で削除)。通報の180日保持は cron 側が未実装(TBD)。
- **匿名の意見**: `user_id` を NULL で保存しつつ上限を数えるため、内部カウンタ表 `private.daily_counters` を使用(「誰が送ったか」は feedback には残らないが、カウンタ表には日単位で残る)。許容か?
- **友達上限(max_friends)の競合**: 同時に複数人が承認すると 100 を超え得る(件数チェックは直列化していない)。実害が小さいため未対応。必要なら `lock_pair` と同様のユーザー単位 advisory lock を追加。
- **`list_incoming_friend_requests` / `my_friends` の avatar_path**: 検索は has_avatar にしたが、受信一覧・友達一覧は友達関係/申請関係がある相手のため従来どおり avatar_path を返す(Storage側は can_view 準拠で非友達は読めない)。揃えるべきか?

## 8. 未検証・注意

- **PostgRESTでの実機実行**: STABLE関数が GET(READ ONLY トランザクション)で動くことは `begin read only` + `set local role authenticated` で再現・検証したが、実際の PostgREST(HTTP・JWT・`request.jwt.claims` の設定経路・スキーマキャッシュ)経由での実行は未確認。M3 の最初に実機で GET/POST 両方の疎通確認が必要。
- **本番適用後の権限確認SQL**: `supabase/verify_grants.sql` を作成済み(ローカルでは全17項目PASS、権限を壊した変異でFAILになることも確認)。**実プロジェクトでの実行は未実施**。適用後に SQL Editor で実行し、FAIL が無いこと(WARNは内容確認)を確認すること。ホスティング版では Supabase が管理する別ロール(`supabase_admin` 等)のデフォルト権限が残っている場合があり、C17(WARN)で検出される。
- **実Supabase環境**での適用(Supabase CLI `supabase db reset`、ホスティング版の `postgres` ロールは非superuser)。ローカルは superuser `postgres` で適用しているため、所有者/権限まわりの差異は未確認(特に storage スキーマへの書込み、`storage.objects` への CREATE POLICY は hosted では可能だが未確認)。
- `pg_cron` / Edge Function による `complete_expired_presences()` / `purge_old_presence_data()` の定期実行(M3以降)。
- Storage API(実アップロード・署名URL・MIME/サイズ制限の実効)、Realtime のRLS挙動。
- 同時実行: L-1 の相互操作デッドロックは実セッション並行で再現・解消を確認済み。ただし 友達上限の競合・QR使用回数の競合(`for update` トークン行ロックで直列化する設計)の多数並行での負荷試験は未実施。
- stub は Supabase 互換の近似であり、`auth.uid()` は GUC `request.jwt.claim.sub` 参照の簡易版。

## 9. 変更履歴

| 日付 | 内容 |
|---|---|
| 2026-10-28 | 初版(M2: DB基盤+RLS+RPC+テスト 541件) |
| 2026-10-28 | **Reviewer 指摘反映**(migrationsを直接修正。未適用のため): |
| | **H-1** `private.current_profile()`(ロック無し)新設し `search_user_by_user_code` / `list_incoming_friend_requests` に使用。全関数を監査(他にSTABLE/IMMUTABLEでロックを取るものは無し)。`require_profile()` は `FOR NO KEY UPDATE`(L-1)。読み取り専用トランザクションの全RPC実行テストを追加 |
| | **M-1** `register_presence` に `p_visibility`('friends'既定/'private'、他はWB106)。presences/presence_board/presence_dogs が private を本人以外に見せないことを 全status × 全閲覧者(友達・他人・ブロック+不整合な友達行)でテスト |
| | **M-2** `set_presence_dogs(presence_id, dog_ids[])` 新設(自分の有効な在場のみ・1頭以上・自分の犬のみ・expires_at不変・authenticatedのみEXECUTE) |
| | **M-3** `my_friends` / `presence_board` の nickname を `private.display_name()` 経由に(承認済みの友達には private でも返す) |
| | **M-4** QR昇格を pending / QR提示者が拒否した declined のみに制限(他は WB001 同一文言) |
| | **L-1** プロフィール行ロックを NO KEY UPDATE 化 + ペア advisory lock。デッドロックを再現するテスト(旧実装で 40P01 → 現実装で解消)を追加。dogs トリガーのロックも NO KEY UPDATE に |
| | **L-2** `profiles.user_code` の INSERT/UPDATE 列GRANTを削除(自動生成のみ) |
| | **L-3** `search_user_by_user_code` を `(nickname, has_avatar)` に変更 |
| | **L-4** `facilities.timezone` に CHECK(`private.is_valid_timezone`。service_role にも EXECUTE を付与しCHECK評価が通るようにした) |
| | **L-5** FK索引: qr_scans(owner_id, token_id) / reports(reporter_id, target_user_id) / feedback(user_id)。ほか未索引だった presences(user_id, started_at) / presences(facility_id, area_code) / qr_tokens(user_id) も追加。「public の全FKに非部分索引がある」ことを一般則でテスト |
| | **L-6** 通報20/日・意見10/日(JST暦日、`app_config`)。BEFORE INSERT トリガー + `private.daily_counters`。WB301/WB302 |
| | **その他** planned_at の過去許容を2分に(`presence_planned_past_tolerance_minutes`)。`verify_grants.sql` 追加。README質問リスト更新 |
