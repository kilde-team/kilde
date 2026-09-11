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
                      AudioCommand.self, InspectCommand.self]
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

/// SIGINT / SIGTERM / SIGHUP を安全停止に接続する (DESIGN.md §5 — 最重要 UX)。
/// SIGHUP はターミナル終了時に飛ぶため、これを無視するとファイナライズが省略される。
func installStopSignalHandler(_ handler: @escaping () -> Void) {
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
}
