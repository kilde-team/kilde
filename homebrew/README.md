# Homebrew formula for kilde

`Formula/kilde.rb` は Homebrew tap ([takezou621/homebrew-kilde](https://github.com/takezou621/homebrew-kilde))
の正本 (このリポジトリに置かれているオリジナル) です。次回リリース時に tap 側へ
反映します (手順は [docs/RELEASE.md](../docs/RELEASE.md))。

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

Formula は GitHub Releases のビルド済み zip (arm64 / Apple Silicon) をインストールします。
Intel Mac には非対応です (zip が arm64 のみのため、Intel への誤 install を防ぐため
`depends_on arch: :arm64` を置いています)。ソースからのビルド (`--HEAD` 等) は
提供していません — CLI のソースは [kilde-team/kilde-cli-swift](https://github.com/kilde-team/kilde-cli-swift)
(private) にあり、外部ユーザーがビルドできるソースがこのリポジトリに無いためです (kilde#118)。

## BlackHole

BlackHole は必須ではありません。録音しながら同じ音を聞くモニター経路を使う場合だけ、
次のコマンドで追加してください。

```sh
brew install --cask blackhole-2ch
```

インストール後、初回は `kilde doctor` で画面収録・マイクの権限を確認してください。
