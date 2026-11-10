# Windows から WanBuddy Beta を TestFlight で確認する

## 現在地と承認の区切り

この変更は実装と PR までです。Apple 側の登録、GitHub Secrets / Variables の登録、
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

## 3. GitHub Free / Private の Repository Secrets（承認後）

### プランの制約と採用する方式

GitHub 公式資料を 2026-11-10 に確認した結果:

| 機能 | Free の Private | この PR の対応 |
|---|---|---|
| Repository Secrets / Repository Variables | 利用可能 | 採用 |
| Environment / Environment Secrets / Deployment branches | 利用不可（Private は Pro / Team / Enterprise が必要） | workflow の environment 指定を削除 |
| Environment の Required reviewers / Wait timer | Free / Pro / Team では Public のみ | Private の自動承認ゲートとして使わない |
| main の Protected branches / Branch・Tag Rulesets | Free の Private では利用不可 | 下記の単独運用ルールで補完 |

有料プランへの加入やリポジトリの公開化は今回の前提にしません。
個人所有リポジトリの Private 保護は Pro、組織所有なら Team などの契約で利用可能ですが、
その場合でも Environment の Required reviewers が Private で使えるとは限りません。
現在のアカウントの契約・共同編集者・App 権限はこの調査で監査していません。

### Secrets の本当のアクセス境界（登録前に確認）

**Repository Secrets は特定の workflow、main、所有者だけに隔離できません。**
GitHub の画面から値を読み戻せなくても、書き込み権限を持つ人・App は別の branch や workflow を作り、
Secrets を参照できます。この PR の if 条件、SHA 入力、read-only GITHUB_TOKEN は、
この workflow の誤実行を防ぎますが、その迂回を防ぐ権限境界ではありません。
所有者だけに Run workflow を制限しても、この限界は変わりません。
同一リポジトリ内の PR の変更も信頼済みコードとして扱う必要があります。

Free のまま採用する条件は、**書き込み可能なすべての人・App・PAT を秘密情報の利用者として信頼できること**です。
最小構成は所有者 Junald69 だけが書き込み・マージ・実行する運用です。
Settings の Collaborators と、個人設定の Installed GitHub Apps / PAT のアクセスを確認し、
不要な Contents / Workflows 書き込み権限は登録前に見直します。これは手順であり、本 PR で設定は変更していません。
アカウントは 2FA / パスキーを使用し、共有ログインは避けます。

他の書き込み利用者を信頼できない場合は、Secrets を登録しないでください。
無料の代案として所有者だけが書ける別の Private 配布リポジトリに署名ジョブを分離できますが、
取得するソースコミット・依存物まで含む別設計が必要です。本 PR の設定だけで同等の隔離ができるとは説明しません。

### main と workflow の運用・起動制限

Free / Private では「main に直接 Push できない」「CI が通るまでマージできない」を GitHub 側で
強制できません。次の運用を所有者が守ります。CODEOWNERS を置くだけでも強制にはなりません。

1. main へ直接 Push / force-push / 削除をせず、すべて PR 経由にします。
2. Linux checks 成功と差分レビュー後に、別途承認して main へマージします。
   .github/workflows、署名・検査スクリプト、依存の変更を重点確認します。
3. Repository の Actions 設定は通常の GITHUB_TOKEN を read-only にし、不要な PR 作成・承認権限を与えません。
   Fork PR に write token / Secrets を渡す設定を有効化しません。
   ただし同一リポジトリの workflow 編集者への隔離にはなりません。
4. 配布 workflow はこのリポジトリの main / workflow_dispatch だけ、起動者と再実行者の両方が
   所有者 Junald69 の場合だけ進みます。PR / push / schedule / workflow_run では起動しません。
5. 承認した main の完全な 40 桁コミット SHA、operation、費用上限を記録します。
   Run workflow の approved_commit に同じ SHA を入力します。対象 SHA が一致しないジョブはスキップされます。
   Checkout も実行の SHA に固定します。SHA 入力は承認記録との照合であり、人の承認自体を自動証明しません。
6. 既定は validate（アップロードなし）。upload は Apple へのアップロードも別途承認済みの場合だけ選びます。

将来 Private のブランチ保護が使えるプランにする場合は、main に PR 必須、Linux checks 必須、
レビュー必須（単独運用で承認者がいない点は考慮）、force-push / 削除禁止、管理者の迂回も制限、を設定します。
その場合も Repository Secrets の workflow 単位の隔離はできないため、書き込み権限の管理は必要です。

### Repository に登録する項目

**Settings → Secrets and variables → Actions → Secrets → New repository secret** に以下の 4 個だけを登録します。
Environment は作成しません。Organization Secrets は Free の Private への代替にはなりません。

| 名前 | 値 |
|---|---|
| BUILD_CERTIFICATE_BASE64 | 秘密鍵入り Apple Distribution P12 の Base64 |
| P12_PASSWORD | P12 のパスワード |
| BUILD_PROVISION_PROFILE_BASE64 | Beta 専用 App Store Connect Profile の Base64 |
| APPSTORE_API_KEY_BASE64 | App Store Connect API 秘密鍵 P8 の Base64 |

同じ Actions ページの **Variables → New repository variable** に次を登録します。

| 名前 | 値 |
|---|---|
| APPLE_TEAM_ID | Developer の 10 桁 Team ID |
| APPSTORE_KEY_ID | Team API Key の 10 桁 Key ID |
| APPSTORE_ISSUER_ID | Team API Key の Issuer ID（UUID） |

一時 Keychain のパスワードは実行時に生成するため Secret は不要です。
Apple ID のパスワード、アプリ用パスワード、Supabase のサーバー用キー、
Supabase テストユーザーのパスワードは登録しません。
本 workflow では署名用 Secrets は準備ステップ、P8 は upload ステップだけに渡します。
これは渡す範囲を狭める措置であり、他 workflow からのアクセスを禁止する設定ではありません。
Environment に同名の値がある場合も自動で移行されません。設定変更は別途確認してから行います。

### ClipHarbor の証明書・API Key を再利用する条件

- **Distribution P12**: 同じ Apple Developer Team、Apple Distribution の種類、有効期限内・未失効で、
  対応する秘密鍵入り P12 とパスワードを手元に保有すること。Apple の .cer だけでは署名できません。
  証明書は通常 Team の複数アプリで使えますが、WanBuddy Beta 専用の App Store Connect Profile を
  新規に作り、その証明書と com.junald69.wanbuddy.beta を選ぶ必要があります。
  Profile の App ID prefix と Team ID は別に検証します。ClipHarbor の Profile は流用できません。
- **API Key**: App Store Connect の同じ Team / Provider に属し、有効・未失効で、対象 Beta アプリへ
  ビルドをアップロードできる権限を持つこと。今回の実装は Team API Key の P8・Key ID・Issuer ID の組を前提にします。
  Individual API Key はこの手順へそのまま置き換えません。アップロードには Developer 権限を基本とし、
  このためだけに Admin 権限へ広げません。手元に P8 がなければ新規 Key を準備します。
- GitHub に保存済みの ClipHarbor Secrets を読み戻したり、リポジトリ間で自動参照したりはできません。
  信頼できるローカルバックアップから WanBuddy の Repository Secrets に別途登録します。
- 同じ証明書・API Key を共有すると、流出・失効・更新の影響が ClipHarbor にも及びます。
  Team API Key は専用名でも全アプリが権限範囲になり得ます。配布用途の新しい Developer Key を
  分けると個別失効は容易ですが、Team 内のアプリ範囲を限定できるわけではありません。
- 流用時は漏えい・更新・失効の連絡先と両アプリの更新手順を決めます。
  証明書上限を空ける目的で既存証明書を失効したり、既存 API Key を置き換えたりはしません。
  現在の P12 / P8 の保有、有効性、権限は未確認であり、再利用可能と断定していません。

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
- 書き込み権限の信頼条件、Repository Variables / Secrets、Profile と証明書の期限・Team を確認済みであること。
- Xcode 26.6 が macos-26 にあること。なければ停止し、別バージョンへ無断変更しないこと。
- macOS Actions と、operation=upload の場合は Apple へのアップロードも承認済みであること。

所有者 Junald69 が Actions → **WanBuddy Beta TestFlight → Run workflow** を開き、
main、operation、承認済み main の完全 SHA（approved_commit）を指定します。
マージコミットの SHA を使い、PR ブランチの古い SHA は使いません。

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

### GitHub Free / Private の根拠

- https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments
- https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets
- https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches
- https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets
- https://docs.github.com/en/actions/reference/security/secure-use
