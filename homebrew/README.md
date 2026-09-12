# Homebrew tap for kilde

このディレクトリは、将来 `takezou621/homebrew-kilde` tap に移す Formula の準備用です。
通常版は v0.1.0 のリリース後に利用できます。

## インストール

tap を追加してからインストールします。

```sh
brew tap takezou621/kilde
brew install kilde
```

tap の追加とインストールを 1 コマンドで行うこともできます。

```sh
brew install takezou621/kilde/kilde
```

## HEAD 版

最新の `main` ブランチをソースからビルドする場合は `--HEAD` を指定します。
Xcode 15.0 以降が必要です (swift-tools-version 5.10 の要件)。

```sh
brew install --HEAD takezou621/kilde/kilde
```

## BlackHole

BlackHole は必須ではありません。録音しながら同じ音を聞くモニター経路を使う場合だけ、
次のコマンドで追加してください。

```sh
brew install --cask blackhole-2ch
```

インストール後、初回は `kilde doctor` で画面収録・マイクの権限を確認してください。
