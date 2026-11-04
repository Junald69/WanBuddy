# WanBuddy

犬友向け iOS アプリ（SwiftUI、iOS 17 以降）の M0 / M1a 骨格です。Mac がなくても、Xcode プロジェクトは CI で `ios/project.yml` から生成します。

## 構成

- `Packages/WanBuddyCore` … モデル、設定の検査、エラー文言、リポジトリの protocol、Debug 用モック。Linux で `swift test` できます。
- `ios/` … SwiftUI アプリ。Debug / Beta は Development の Supabase、Release の Production 値は空です。
- `.github/workflows/linux.yml` … pull request と push で Linux 検査。
- `.github/workflows/ios.yml` … **手動実行だけ**の macOS ビルド。

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

GitHub の Actions から「iOS build」を手動で実行します。XcodeGen でプロジェクトを生成し、Debug と Beta をシミュレータ向けにビルドします。Production の値が空のうちは Release は失敗するのが正しい結果です。
