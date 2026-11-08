# Windows から未署名 Debug IPA を実機確認する

## この PR の範囲

`.github/workflows/build-ios-debug-unsigned.yml` は手動実行専用です。
macOS Actions の使用は実行ごとに事前承認を得てください。この PR 作成では実行していません。
手動実行という制限は人の承認操作を自動で強制する仕組みではありません。

- 構成: Debug / Development Supabase
- Bundle ID: `com.junald69.wanbuddy.dev`
- iPhone: iOS 17 以降
- 成果物: `WanBuddy-debug-unsigned.ipa`、SHA-256、ビルドのコミット情報
- Artifact の保持期間: 7 日
- 署名用 Secrets、Apple ID、証明書、Provisioning Profile は GitHub に登録しません。
- 既存の環境検査、Production 設定、アプリの起動時検査は変更しません。

## 実行前の確認

1. PR の差分と Linux checks の結果を確認します。main へのマージは管理者が別途判断してください。
2. 新規 workflow の `workflow_dispatch` は、workflow ファイルがデフォルトブランチに存在する必要があります。この PR だけの状態では通常の手動実行はできません。回避のための push / pull request トリガーは追加しません。
3. 実行する ref / コミットと macOS Actions の利用承認を確認します。
4. 指定された `macos-26` に `/Applications/Xcode_26.6.app` があることを確認します。なければ停止し、バージョンを無断変更しません。
5. 下記の iLoader の Bundle ID 問題を解消してから、インストールへ進みます。
6. Development プロジェクトとテストユーザーを確認します。DB migration は不要です。

## iLoader の Bundle ID 問題（インストール前の阻害要因）

公式 iLoader の現行ソース（Cargo.toml は 2.4.1）は isideload 0.5.2 を使用します。
isideload の現行ソース（Cargo.toml は 0.5.2）には、署名前に元の Bundle ID と Team ID を
`<元のBundle ID>.<Team ID>` として結合し、アプリの Bundle ID を更新する処理があります。

WanBuddy は起動時に `com.junald69.wanbuddy.dev` との完全一致を検査します。
同じ処理が使用中の iLoader に含まれる場合、インストール後に起動時検査で停止します。
本 PR は生成する IPA の Bundle ID を固定し、この検査を緩めません。

使用中の iLoader のバージョンと対応するソースを確認し、Bundle ID を保持できる経路があるか確認が必要です。
保持できない場合は、この方式のまま起動できるとは判断せず、Apple Development / Ad Hoc 署名など
Bundle ID を保持する別経路を別途検討・承認します。既存証明書の失効や再発行も無断で行いません。
LiveContainer 内の起動ではなく、WanBuddy を独立したアプリとして確認します。

参考:
- https://iloader.app/ （署名してから端末へ転送・インストールする流れ）
- https://github.com/nab138/iloader/blob/main/src-tauri/Cargo.toml
- https://github.com/nab138/isideload/blob/main/isideload/src/sideload/sideloader.rs
- https://github.com/nab138/isideload/blob/main/isideload/src/sideload/application.rs

## Development のテストユーザーを準備する（手動）

このアプリには新規登録画面はありません。最初は Supabase Dashboard で
メール・パスワード認証用ユーザーを 1 件用意します。ここでは操作手順だけを示します。

1. Supabase Dashboard にログインし、**Development** プロジェクトを開きます。
   ブラウザ URL の project ref が `ios/Config/Debug.xcconfig` の
   `SUPABASE_PROJECT_REF` と一致することを確認してください。
   現在の Development ref は `nlvjvmymeuvbxlzikpjx` です。
   プロジェクト名やブランチ名だけで判定せず、Production なら操作を止めます。
2. プロジェクトが稼働中であることを確認します。
3. **Authentication → Sign In / Providers → Email**（画面によっては Providers）で
   Email / Password 認証が有効か確認します。無効なら Development に限り、変更内容を確認して有効化します。
   今回のためにプロジェクト全体のメール確認要件を無効化する必要はありません。
4. **Authentication → Users** で既存のテストユーザーを確認します。
   利用できるものがなければ **Add user → Create new user** を選びます
   （Dashboard の表示名は更新で変わることがあります）。
5. 自分が管理するテスト用メールアドレスと、パスワードマネージャーで生成した専用パスワードを入力します。
   **Auto Confirm User** があれば、この Development のテストユーザー 1 件だけに指定して作成します。
   確認済みであることをユーザー詳細で確認します。招待メールだけではパスワード設定まで終わらないため、
   初回はメール・パスワードを指定する作成方法を使います。
6. メール・パスワードは自分のパスワードマネージャーに保管します。
   チャット、PR、ソース、GitHub Secrets、スクリーンショットへ記載しないでください。
   サーバー管理用キー、SQL、migration は不要です。

メール確認が未完了ならユーザーの確認状態を見直します。
ログインに失敗しても Production へ切り替えたり、認証の安全設定を一括で無効化したりしません。
プロフィールのテーブルが無くても、今回の認証と端末内保存の確認はできます。

参考:
- https://supabase.com/docs/guides/auth/users
- https://supabase.com/docs/guides/auth/passwords

## 承認後の IPA 取得とインストール

1. GitHub Actions の **Build unsigned Debug IPA** を開き、承認済みの ref で Run workflow を実行します。
2. 完了した run の Artifact をダウンロードします。外側の ZIP を展開し、中の
   `WanBuddy-debug-unsigned.ipa` を取り出します。ビルド情報のコミットも確認します。
3. PowerShell の `Get-FileHash .\WanBuddy-debug-unsigned.ipa -Algorithm SHA256` の結果を
   同梱の `.sha256` と照合します。
4. Bundle ID 問題が解消済みであることを確認してから、ClipHarbor で利用中の Windows / iLoader 環境で
   iPhone を接続し、IPA を Import します。署名・インストールは Windows 側です。
5. 必要に応じてデベロッパモードと開発元の信頼を設定します。

## 実機チェックリスト

- 初回起動で Development 表示を確認する。
- 「Appleでサインイン」を押し、開発用メール・パスワード画面からログインする（Apple 認証ではありません）。
- ニックネーム、犬、規約同意を入力し、初期プロフィールを保存する。
- ホーム / 図鑑 / マイページの遷移、犬情報の表示を確認する。
- アプリを終了・再起動し、セッションとプロフィールが復元することを確認する。
- セッション期限経過後も復元できるか、別途確認する。
- ログアウト後に再起動して、未ログイン状態であることを確認する。
  現実装はログアウトの通信エラーを表示しないため、ボタン直後の画面だけで成功と判断しない。
- 同じユーザーで再ログインし、端末内プロフィールが再表示されることを確認する。

プロフィールは UserDefaults のユーザー別保存です。別端末への同期、DB 保存、
友達登録、チェックイン、ブロック、退会はこの検証では完了扱いにしません。
