class Kilde < Formula
  desc "Command-line screen and audio recorder for macOS"
  homepage "https://github.com/takezou621/kilde"
  url "https://github.com/takezou621/kilde/releases/download/v0.2.0/kilde-0.2.0-macos.zip"
  # v0.2.0 の実配布物のハッシュ (2026-09-15 のリリースで確定)
  sha256 "4acde2ea78ca39d9b75bdeb233cf2d4b2fc898472a23251f0a4c2ee5f5be822a"
  license "MIT"

  # 配布 zip は arm64 (Apple Silicon) ビルドのみ (release workflow の macos-26
  # ランナーで swift build -c release した単体バイナリ)。universal に含まれない
  # Intel がこの Formula を拾うと起動時に落ちるため、誤 install を brew 側で
  # 拒否させる。Intel 対応 (universal binary) を始めるときはこの行と
  # README の arm64 記載を外す
  depends_on arch: :arm64
  depends_on macos: :sonoma

  # head ブロックは廃止 (kilde#118)。CLI のソースは kilde-team/kilde-cli-swift
  # (private) に分離されたため、外部ユーザーがこのリポジトリからソースビルドする
  # 経路が存在しない。リリースごとに url / sha256 を更新し
  # takezou621/homebrew-kilde へ反映する (手順は docs/RELEASE.md「Homebrew tap の更新」)

  def install
    # zip 内のバイナリは ditto --keepParent のため release/kilde に入っているが、
    # Homebrew は zip 展開後に単一のトップレベル dir へ chdir するため
    # "kilde" で参照できる (v0.1.0 の実 install でも同じ動作を確認済み)。
    # zip の作り方 (階層数) を変えるときはここも見直すこと
    bin.install "kilde"
  end

  def caveats
    <<~EOS
      BlackHole は任意です。モニター経路を使う場合にだけインストールしてください:
        brew install --cask blackhole-2ch

      初回は doctor で画面収録・マイクの権限を確認してください:
        kilde doctor

      CLI のソースコードは kilde-team/kilde-cli-swift で開発されています
      (private のため、現時点でソースからのビルドは提供していません)
    EOS
  end

  test do
    # --version は "kilde 0.2.0" の形式。version.to_s は url 由来の formula
    # バージョンなので、url とバイナリの組がずれるとここで検知できる
    # (CodeRabbit 指摘 — 任意の "\d+\.\d+" を許すより厳しい)。
    # head ブロック廃止により version がコミットハッシュになる経路は存在しない
    assert_match version.to_s, shell_output("#{bin}/kilde --version")
    # doctor は画面収録・マイクの権限状態で結果が変わるため、終了コードを検証しない。
  end
end
