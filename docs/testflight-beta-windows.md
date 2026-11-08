# Windows から WanBuddy Beta を TestFlight で確認する

## 現在地と承認の区切り

この変更は実装と PR までです。Apple 側の登録、GitHub Environment / Secrets の作成、
macOS Actions の実行、Apple へのアップロード、main へのマージは別途確認してから行います。
以下の操作手順は、その承認後に使います。秘密情報をチャットや PR に貼らないでください。

- 配布: 自分だけの TestFlight **内部テスト**
- 構成: **Beta** / バージョン **0.2.0** / iOS 17 以降
- Bundle ID: **com.junald69.wanbuddy.beta**
- 接続先: **Development Supabase**（Beta.xcconfig の既存設定）
- 認証: 開発用メール・パスワード。Apple でのサインインは未実装
- 初期プロフィール: ユーザー別に端末の UserDefaults に保存。DB 保存や migration は不要
- App Icon: この PR の肉球アイコンは仮のもの。デザインの最終決定ではない

TestFlight への提出は App Store での一般公開ではありません。初回は外部グループ・公開リンクを作らず、
自分の App Store Connect ユーザーだけを内部グループに追加します。
端末 UDID 登録、USB 接続、デベロッパモードは不要です。各ビルドはアップロードから 90 日間利用できます。

## PR #3 からの切り替え

未署名 Debug IPA の PR #3 はマージしません。この PR は main を起点としており、PR #3 に依存しません。
#3 の未署名 IPA workflow と iLoader 用手順書は取り込みません。
iLoader / zsign / pymobiledevice3 による署名・転送は今回の手順から除外します。
本 PR を採用した後、#3 は「TestFlight 方式に置き換え」として閉じられますが、現時点では変更していません。
通常の Debug / Beta / Release ビルドは引き続き署名無効です。

## 1. Apple Developer の準備（Windows のブラウザ）

1. https://developer.apple.com/account/ を開き、加入済みの Team でログインします。
   有効な会員資格と、未同意の更新契約がないことを確認します。
2. **Certificates, Identifiers & Profiles → Identifiers → + → App IDs → App** を開きます。
   Explicit Bundle ID に **com.junald69.wanbuddy.beta** を登録します。
   説明は「WanBuddy Beta」など。今回 Sign in with Apple や Push Notifications の追加は不要です。
3. **Certificates** で有効な **Apple Distribution** 証明書を確認します。
   同じ Team の ClipHarbor 用証明書は、対応する秘密鍵入り P12 とパスワードが手元にあれば再利用可能です。
   ClipHarbor の Profile は流用できません。証明書の有無・期限はまだ確認していません。
   GitHub Secrets の登録済み値は読み戻せないため、手元の安全なバックアップを使います。
4. 証明書がなければ、Windows / WSL の OpenSSL でローカルに鍵と CSR を作り、
   Apple Distribution 証明書を発行して P12 にまとめます（下記参照）。
   Apple の .cer をダウンロードするだけでは秘密鍵は復元できません。
   証明書上限に達していても、既存証明書は無断で失効させず相談してください。
5. **Profiles → + → Distribution → App Store Connect** を選びます。
   表示が旧名称の **App Store** の場合もあります。Development / Ad Hoc は選びません。
6. Beta の App ID と使用する Apple Distribution 証明書を選び、
   例えば **WanBuddy Beta App Store Connect** という Profile を作成してダウンロードします。
   TestFlight 用なので iPhone の UDID は選択しません。

### 証明書を新規作成する場合の補足

OpenSSL が使える Windows / WSL のローカルフォルダーで作業します。
OneDrive 同期フォルダー、Git リポジトリ、共有フォルダーは避けてください。
以下は対話入力でパスワードを設定します。コマンドにパスワードを書きません。

```bash
openssl genrsa -aes256 -out WanBuddyDistribution.key 2048
openssl req -new -key WanBuddyDistribution.key -out WanBuddyDistribution.certSigningRequest
```

CSR の質問には自分の情報を入力します。CSR だけを Apple の証明書作成画面へアップロードします。
発行された証明書を distribution.cer として保存した場合:

```bash
openssl x509 -inform DER -in distribution.cer -out distribution.pem
openssl pkcs12 -export -inkey WanBuddyDistribution.key -in distribution.pem -out WanBuddyDistribution.p12
```

P12 に設定したパスワードをパスワードマネージャーに保管します。
macOS の読み込みで OpenSSL 3 の P12 互換性エラーが出た場合は、ローカルで
同じ export コマンドに `-legacy` を付けて再出力する方法を検討します。
CI が秘密鍵を平文出力して変換するフォールバックは実装していません。

## 2. App Store Connect のアプリと API Key

1. https://appstoreconnect.apple.com/ → **マイ App → + → 新規 App** を開きます。
2. プラットフォーム **iOS**、利用可能な名前（例 **WanBuddy Beta**）、主言語 **日本語**、
   Bundle ID **com.junald69.wanbuddy.beta**、SKU **wanbuddy-beta** などを指定します。
   SKU は管理用の一意な文字列です。表示される数値の Apple ID は Key ID / Team ID とは別物です。
   この Beta アプリは将来の本番 Bundle ID のアプリとは別レコードになります。
3. **ユーザとアクセス → 統合 → App Store Connect API** から Team API Key を準備します。
   初めてなら Account Holder による API 利用申請・有効化が必要になる場合があります。
   名前は「WanBuddy Beta CI」など、権限は手動署名済み IPA のアップロード用に **Developer** を基本とします。
4. **Key ID**、**Issuer ID** と、ダウンロードした秘密鍵 **AuthKey_....p8** を安全に保管します。
   P8 は通常 1 回しかダウンロードできません。API Key と署名証明書は別の役割です。
   Team API Key は専用名でも Team の他アプリにアクセス可能で、WanBuddy だけに制限できません。
   既存の ClipHarbor Key を使う場合も権限と手元の P8 を確認します。新規の専用 Key は個別失効が容易です。

内部テストのために App Store の一般公開申請や有料販売の銀行・税務設定を進める必要はありません。
Apple が求める契約・提出情報が別途表示された場合は、その内容を確認します。

## 3. GitHub の専用 Environment（承認後）

リポジトリ **Settings → Environments → New environment** で **testflight-beta** を作成します。
Deployment branches は **main のみ**に制限します。
利用プランで使える場合は Required reviewers を設定し、macOS 実行とアップロードの承認者を指定します。
自分だけの運用では自己承認制限との兼ね合いを確認してください。
private リポジトリの Environment 保護機能にはプラン制約があるため、利用可否を画面で確認します。

この workflow は main 以外ではジョブを実行しません。手動起動だけであり、PR / push からは実行しません。
ただし手動起動そのものは人による事前承認を自動保証しません。保護機能が利用できない場合も、
チャットで対象コミット・operation・費用上限の承認を受けてから起動します。
Environment が存在しないまま起動すると自動作成される場合があるため、必ず先に設定を確認します。

Environment **Secrets** に以下の 4 個だけを登録します。Repository Secrets には重複登録しません。

| 名前 | 値 |
|---|---|
| BUILD_CERTIFICATE_BASE64 | 秘密鍵入り Apple Distribution P12 の Base64 |
| P12_PASSWORD | P12 のパスワード |
| BUILD_PROVISION_PROFILE_BASE64 | Beta 専用 App Store Connect Profile の Base64 |
| APPSTORE_API_KEY_BASE64 | App Store Connect API 秘密鍵 P8 の Base64 |

Environment **Variables** には次を登録します（秘密鍵ではない識別子）。

| 名前 | 値 |
|---|---|
| APPLE_TEAM_ID | Developer の 10 桁 Team ID |
| APPSTORE_KEY_ID | Team API Key の 10 桁 Key ID |
| APPSTORE_ISSUER_ID | Team API Key の Issuer ID（UUID） |

一時 Keychain のパスワードは実行時に生成するため Secret は不要です。
Apple ID のパスワード、アプリ用パスワード、Supabase のサーバー用キー、
Supabase テストユーザーのパスワードは登録しません。
Secrets は承認済み main のジョブだけへ渡し、署名用 Secrets は準備ステップ、P8 は upload ステップだけで使用します。

### Windows で Base64 を入力する

PowerShell で、ローカルファイルからクリップボードへコピーできます。
ファイルパスだけを自分の保管場所に置き換え、GitHub の入力欄へ貼り付けます。
表示・ログ保存やオンライン Base64 変換サービスは利用しません。

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\Private\WanBuddyDistribution.p12')) | Set-Clipboard
```

Profile と P8 も同様です。貼り付け後は `Set-Clipboard -Value ''` で消し、
Windows のクリップボード履歴・他端末同期に残さないよう管理します。
Base64 は暗号化ではありません。パスワードや Base64 値を PR・チャット・スクリーンショットへ出しません。

## 4. Development のログインユーザー

1. Supabase Dashboard で **Development** を開き、URL の project ref が
   `nlvjvmymeuvbxlzikpjx`（`ios/Config/Beta.xcconfig`）と一致することを確認します。
2. プロジェクトが稼働中で、Authentication の Email / Password 認証が有効であることを確認します。
3. **Authentication → Users → Add user → Create new user** から、自分で管理する専用メールと
   パスワードを指定します。Auto Confirm User があれば Development のこのテストユーザーだけに適用します。
   メール確認要件をプロジェクト全体で無効化する必要はありません。
4. 認証情報はパスワードマネージャーに保存し、アプリへ直接入力します。

ここではプロフィール用テーブルを作りません。Production の設定や DB migration は操作しません。

## 5. 実行する前に

- PR のレビュー・Linux checks が完了し、承認後に main へマージ済みであること。
- Environment の main 制限、Variables、Secrets、Profile と証明書の期限・Team を確認済みであること。
- Xcode 26.6 が macos-26 にあること。なければ停止し、別バージョンへ無断変更しないこと。
- macOS Actions と、operation=upload の場合は Apple へのアップロードも承認済みであること。

Actions → **WanBuddy Beta TestFlight → Run workflow** で main と operation を指定します。

- **validate（既定）**: 署名、Beta Archive、エクスポート、ローカル検証まで。Apple へアップロードしません。
  ただし macOS 時間は消費し、依存取得などのネットワーク通信は発生します。
- **upload**: 同じ検証がすべて成功したら、その実行で作った IPA を Apple へ送信します。
  検証済みの過去 IPA を流用するモードではなく、毎回新しく Archive します。

初回の validate と upload を分けるとビルド 2 回分の時間が必要です。
費用を抑えるなら、準備完了後に upload の 1 回を承認し、検証失敗時はアップロードせず終了する形にできます。

ビルド番号はこの workflow の github.run_number（1〜9999）を使い、通常設定の 1 は変更しません。
validate でも番号を消費します。同じ run の再実行は同じ番号なので、アップロード済み run は再実行せず
**新しい Run workflow** を使ってください。Apple 側が既に高い番号なら番号計画を調整してから実行します。
9999 を超える前、workflow を作り直すとき、バージョン 0.2.0 を変えるときは検証コードも含めて更新します。

## 6. 実行中の検査と秘密情報

既存の check_env.sh / check_static.py と追加の Python テストを、XcodeGen より前に実行します。
Archive は必ず **-configuration Beta** とし、署名だけをコマンドラインで有効化します。
Profile の App ID prefix と Team ID は別物として検査します。
Development / Ad Hoc / Enterprise Profile、期限切れ、証明書不一致は拒否します。
エクスポート後も Bundle ID、Development URL/ref/公開クライアントキー、ビルド番号、アイコン、
Privacy Manifest、arm64、署名・entitlements・署名証明書を検査します。

P12・P8・Profile・一時 Keychain・Archive・IPA は runner の一時フォルダーに置き、終了時に削除します。
秘密鍵や署名素材は Artifact / Cache に保存しません。Artifact はコミット・構成・ビルド番号・
IPA の SHA-256 だけを含む build.json（7 日保持）です。
アップロード失敗時でも Apple が受け取った可能性があるため、再実行前に App Store Connect を確認します。

## 7. iPhone に入れる

1. Apple の Processing 完了をブラウザで待ちます。アップロード成功と処理成功は別です。
2. 輸出コンプライアンス等の質問が出たら実装に沿って回答します。
   既存 Info.plist は標準 HTTPS 等の想定で非免除暗号なしを宣言しています。独自暗号を追加した場合は再確認します。
3. TestFlight タブで内部グループ（例「自分の実機確認」）を作り、ビルドと自分のユーザーを追加します。
4. iPhone の App Store から TestFlight を入れ、招待を承諾して WanBuddy Beta をインストールします。
5. アプリで Beta 環境表示を確認し、「Appleでサインイン」から開発用メールログインを開きます。
6. ログイン → 初期プロフィール保存 → 3 タブの遷移 → 終了・再起動後の復元を確認します。
7. ログアウト → 再起動で未ログイン → 同じユーザーで再ログイン後のプロフィール復元を確認します。
   現実装はログアウトの通信エラーを表示しないため、ボタン直後の画面だけで成功と判定しません。
8. 時間をおいてセッション期限後の復元も確認します。

友達・チェックイン・公開範囲・ブロック・退会・別端末同期はまだ検証完了扱いにしません。

## 費用と所要時間

加入済み Developer Program の範囲で TestFlight の追加料金はありません。
GitHub 標準 macOS ランナーは現行の無料枠超過単価で US$0.062/分です。
20〜35 分なら約 US$1.24〜2.17/回が目安で、失敗・validate も消費します。
実行前に自分のプラン、残り無料枠、予算設定を確認します。ジョブは 35 分で打ち切ります。
Apple 側の処理待ちには macOS ジョブを待機させません。

## 参考

- https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/
- https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/
- https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/
- https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/
- https://docs.github.com/en/billing/reference/actions-runner-pricing
- https://github.com/Junald69/ClipHarbor/blob/main/.github/workflows/deploy-testflight.yml
