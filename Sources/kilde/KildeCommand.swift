import Foundation
import ArgumentParser
import KildeCore

struct KildeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kilde",
        abstract: "macOS 画面 + 音声 録画ツール",
        discussion: """
        QuickTime Player では録れないシステム音声を含めた録画・録音を提供します。
        音声ソースごとのトラック分離、複数ソースのミックス、ウィンドウ単位の
        収録 (音声もそのアプリにスコープ) に対応します。
        """,
        version: "0.1.0",
        subcommands: [RecCommand.self, DevicesCommand.self, DoctorCommand.self,
                      AudioCommand.self, InspectCommand.self, ConfigCommand.self]
    )

    func run() throws {
        throw CleanExit.helpRequest()
    }
}

// MARK: - 共通ヘルパ

/// KilError を終了コード付きで CLI のエラーに変換する
func cliError(_ error: Error) -> Never {
    if let e = error as? KilError {
        FileHandle.standardError.write("ERROR: \(e)\n".data(using: .utf8)!)
        exit(e.exitCode)
    }
    FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
    exit(1)
}

private var signalSources: [DispatchSourceSignal] = []

/// SIGUSR1 を一時停止 / 再開のトグルに接続する (issue #11)。
/// 端末が無い実行 (スクリプト・GUI から起動した子プロセス) でも
/// `kill -USR1 <pid>` で一時停止できるようにするため、キー入力とは別に用意する
func installPauseSignalHandler(_ handler: @escaping () -> Void) {
    signal(SIGUSR1, SIG_IGN)
    let q = DispatchQueue(label: "kilde.signal.pause")
    let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: q)
    src.setEventHandler(handler: handler)
    src.resume()
    signalSources.append(src)
}

/// SIGINT / SIGTERM / SIGHUP を安全停止に接続する (DESIGN.md §5 — 最重要 UX)。
/// SIGHUP はターミナル終了時に飛ぶため、これを無視するとファイナライズが省略される。
/// 以前は先に SIG_IGN を設定してから DispatchSource を resume していたが、SIG_IGN 中に
/// 届いたシグナルは pending にならずその場で破棄されるため、起動直後の Ctrl+C が
/// 取りこぼされて録画が止まらなかった (issue #67)。正しい順序は:
///   1. 呼び出しスレッド (メイン) を pthread_sigmask でブロック — プロセス宛
///      シグナルはどのスレッドにも配送されうるため、他スレッドが走り出す前に
///      この設置を済ませることで窓のシグナルを pending に溜められる
///   2. SIG_IGN を設定 — ブロック直後なら pending はほぼ確実に空で、POSIX の
///      「SIG_IGN 設定時に pending が破棄される」に引っかからない
///   3. DispatchSource を作成して resume (kevent 登録。SIG_IGN でも発火する)
///   4. アンブロック — pending したシグナルが kevent 経由で handler に届く
func installStopSignalHandler(_ handler: @escaping () -> Void) {
    var block = sigset_t()
    sigemptyset(&block)
    sigaddset(&block, SIGINT)
    sigaddset(&block, SIGTERM)
    sigaddset(&block, SIGHUP)
    pthread_sigmask(SIG_BLOCK, &block, nil)

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signal(SIGHUP, SIG_IGN)

    let q = DispatchQueue(label: "kilde.signal")
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        let src = DispatchSource.makeSignalSource(signal: sig, queue: q)
        src.setEventHandler(handler: handler)
        src.resume()
        signalSources.append(src)
    }

    pthread_sigmask(SIG_UNBLOCK, &block, nil)
}
