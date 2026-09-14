class Kilde < Formula
  desc "Command-line screen and audio recorder for macOS"
  homepage "https://github.com/takezou621/kilde"
  url "https://github.com/takezou621/kilde/releases/download/v0.1.0/kilde-0.1.0-macos.zip"
  # v0.1.0 の実配布物のハッシュ (2026-09-13 のリリースで確定)
  sha256 "89e23d94441bcecf11b3dc51c9418831925723f8455562123208c91e1f48b242"
  license "MIT"

  depends_on macos: :sonoma
  # 配布 zip は arm64 (Apple Silicon) ビルドのみ (release workflow の macos-26
  # ランナーで swift build -c release した単体バイナリ)。universal に含まれない
  # Intel がこの Formula を拾うと起動時に落ちるため、誤 install を brew 側で
  # 拒否させる。Intel 対応 (universal binary) を始めるときはこの行と
  # README の arm64 記載を外す
  depends_on arch: :arm64

  # head ブロックは廃止 (kilde#118)。CLI のソースは kilde-team/kilde-cli-swift
  # (private) に分離されたため、外部ユーザーがこのリポジトリからソースビルドする
  # 経路が存在しない。次リリース (v0.2.0) の zip の url / sha256 をこの式に書いて
  # takezou621/homebrew-kilde へ反映する (手順は docs/RELEASE.md)

  def install
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
    # --version は "kilde 0.1.0" の形式
    assert_match(/\d+\.\d+/, shell_output("#{bin}/kilde --version"))
    # doctor は画面収録・マイクの権限状態で結果が変わるため、終了コードを検証しない。
  end
end
