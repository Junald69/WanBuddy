# WanBuddy

犬友向け iOS アプリ（SwiftUI、iOS 17 以降）の M0 / M1a 骨格です。Mac がなくても、Xcode プロジェクトは CI で `ios/project.yml` から生成します。

## 構成

- `Packages/WanBuddyCore` … モデル、設定の検査、エラー文言、リポジトリの protocol、Debug 用モック。Linux で `swift test` できます。
- `ios/` … SwiftUI アプリ。Debug / Beta は Development の Supabase、Release の Production 値は空です。
- `.github/workflows/linux.yml` … pull request と、main への push で Linux 検査。
- `.github/workflows/ios.yml` … **手動実行だけ**の macOS ビルド。Beta は入力で選んだときだけ。

## 接続先

Development の URL と publishable key は Debug / Beta の xcconfig にだけあります。Release は空のまま失敗します。Development へ自動では戻りません。サーバー専用の鍵は置きません。

## Linux で確認する

```bash
bash scripts/test_check_env.sh
python3 scripts/check_static.py
swift test --package-path Packages/WanBuddyCore
bash scripts/check_mocks_compiled_out.sh
```

## iOS ビルド

GitHub の Actions から「iOS build」を手動で実行します。XcodeGen でプロジェクトを生成し、Debug をシミュレータ向けにビルドします。Beta は「Also build the Beta configuration」をオンにしたときだけです。Production の値が空のうちは Release は失敗するのが正しい結果です。


## TestFlight の内部実機テスト

Beta 構成（Development Supabase / `com.junald69.wanbuddy.beta`）の署名・Archive・
アップロードは [Windows 向け手順書](docs/testflight-beta-windows.md)を参照してください。
`WanBuddy Beta TestFlight` は所有者による main の手動実行だけで、GitHub Free の Private でも使える
Repository Secrets / Variables を使います。実行には承認済みコミットの完全 SHA が必要です。
既定の `validate` はアップロードしません。macOS 実行・Apple 設定・Secrets 登録・アップロードは事前確認が必要です。
通常ビルドは署名無効のままです。未署名 Debug IPA の PR #3 はこの方式ではマージしません。

Free の Private では Environment と main のブランチ保護を利用できません。Repository Secrets は
workflow ごとの隔離ができないため、書き込み可能な人・App を秘密情報の利用者として信頼する必要があります。
単独の信頼済み所有者による PR・CI 確認と手動実行の運用条件は手順書を参照してください。
