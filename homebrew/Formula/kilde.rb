class Kilde < Formula
  desc "Command-line screen and audio recorder for macOS"
  homepage "https://github.com/kilde-team/kilde"
  url "https://github.com/kilde-team/kilde/releases/download/v0.26.0/kilde-0.26.0-macos.zip"
  # v0.26.0 の実配布物のハッシュ (Release からダウンロードした zip で計算)。
  # DMG や zip 名からハッシュを推測して書かないこと (#369 の事故注意)
  sha256 "9e948ec6dfda758887f970a67d665f2a4a5d3c80114c6872f7c43b77d044f8e0"
  # CLI バイナリは kilde-team/kilde-cli-swift (private) で開発されたプロプライエタリ
  # のため MIT ではない (README の License 節 — takezou621/kilde#377 で実態に合わせた)。
  # Homebrew の license 構文でプロプライエタリを表す値は :cannot_represent
  license :cannot_represent

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
  # kilde-team/homebrew-kilde へ反映する (手順は docs/RELEASE.md「Homebrew tap の更新」)。
  # この正本は 0.13.0 で止まり、0.15.0 / 0.16.0 は tap 直接更新だけが行われた
  # (0.17.0 で drift を一括解消 — issue #378)。次回以降は正本を先に PR で上げてから
  # tap に反映する順序を守ること

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
