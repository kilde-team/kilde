class Kilde < Formula
  desc "Command-line screen and audio recorder for macOS"
  homepage "https://github.com/takezou621/kilde"
  url "https://github.com/takezou621/kilde/releases/download/v0.1.0/kilde-0.1.0-macos.zip"
  # issue #25 で v0.1.0 の配布物を公開した時点で、実ファイルの値を設定する。
  # sha256 "リリース時に確定する SHA-256"
  license "MIT"

  depends_on macos: :sonoma

  head do
    url "https://github.com/takezou621/kilde.git", branch: "main"
    # swift-tools-version:5.10 のマニフェストを解釈できるのは Swift 5.10 ツールチェーン
    # (Xcode 15.3 以降)。15.0〜15.2 は Swift 5.9 で "not supported" になり失敗する
    depends_on xcode: ["15.3", :build]
  end

  def install
    if build.head?
      # --disable-sandbox: Homebrew のビルド隔離内では SPM がキャッシュ書き込みに
      # 失敗する (ローカル検証で同一の失敗とこの回避を確認済み)。
      # ソースは tap で固定された本家リポジトリのみ
      system "swift", "build", "-c", "release", "--disable-sandbox"
      bin.install ".build/release/kilde"
    else
      bin.install "kilde"
    end
  end

  def caveats
    <<~EOS
      BlackHole は任意です。モニター経路を使う場合にだけインストールしてください:
        brew install --cask blackhole-2ch

      初回は doctor で画面収録・マイクの権限を確認してください:
        kilde doctor
    EOS
  end

  test do
    # --version は "kilde 0.1.0" の形式。HEAD ビルドでは Homebrew の version が
    # ブランチのハッシュになるため version.to_s と一致しない — バージョン番号の
    # 存在だけを確認する
    assert_match(/\d+\.\d+/, shell_output("#{bin}/kilde --version"))
    # doctor は画面収録・マイクの権限状態で結果が変わるため、終了コードを検証しない。
  end
end
