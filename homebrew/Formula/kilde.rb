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
    depends_on xcode: ["14.0", :build]
  end

  def install
    if build.head?
      # --disable-sandbox: Homebrew のビルド隔離内では SPM がキャッシュ書き込みに
      # 失敗する (このリポジトリの CI/検証でも同じ回避を実測済み)。
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
    assert_match version.to_s, shell_output("#{bin}/kilde --version")
    # doctor は画面収録・マイクの権限状態で結果が変わるため、終了コードを検証しない。
  end
end
