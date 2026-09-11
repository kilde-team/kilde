import AppKit
import KildeCore

/// 検証用のセルフテスト (issue #18): 環境変数が指定されたときだけ、UI を操作せずに
/// GUI と同じ経路 (RecordingSetup → RecordRequest → RecordingController → Recorder) で
/// ディスプレイ 0 + システム音声を録画して終了する。
///
///     KILDE_GUI_SELFTEST_RECORD=<秒> KILDE_GUI_SELFTEST_OUTPUT=<保存先ディレクトリ> \
///         KildeGUI.app/Contents/MacOS/KildeGUI
///
/// 完了すると出力パスを stdout に出して終了コード 0、失敗なら stderr に理由を出して 1。
/// ターミナルから実行ファイルを直接起動すると TCC の画面収録権限はターミナル側のものが使われる
/// (`open` で起動したアプリとは別扱い) ため、KildeGUI 自体に権限を付けなくても検証できる。
/// 「GUI から開始した録画が CLI と同じ Recorder を通り、同等のファイルが生成される」を
/// 機械的に確かめるためのもので、通常起動では何もしない
enum SelfTest {
    @MainActor
    static func runIfRequested(setup: RecordingSetup, recording: RecordingController) {
        let env = ProcessInfo.processInfo.environment
        guard let text = env["KILDE_GUI_SELFTEST_RECORD"] else { return }
        guard let seconds = Double(text), seconds > 0 else {
            fail("KILDE_GUI_SELFTEST_RECORD は正の秒数で指定してください: \(text)")
        }
        if let dir = env["KILDE_GUI_SELFTEST_OUTPUT"] {
            setup.request.outputDirectory = URL(fileURLWithPath: dir, isDirectory: true)
        }
        setup.request.target = .display(index: 0)
        // KILDE_GUI_SELFTEST_AUDIO: system (既定) / none / device:<UID or 名前>。
        // none は音声出力が使えない環境 (既定出力が鳴らないデバイスだと SCK の音声開始が -3818 で
        // 失敗する) でも GUI → Recorder の経路を確かめるため。device: は BlackHole ループバックのように
        // スピーカーを介さずに信号を入れて検証するため (既定の出力デバイスを変えずに済む)
        setup.request.captureMic = false
        setup.request.inputDevices = []
        switch env["KILDE_GUI_SELFTEST_AUDIO"] ?? "system" {
        case "system":
            setup.request.captureSystemAudio = true
        case "none":
            setup.request.captureSystemAudio = false
        case let value where value.hasPrefix("device:"):
            setup.request.captureSystemAudio = false
            setup.request.inputDevices = [String(value.dropFirst("device:".count))]
        case let other:
            fail("KILDE_GUI_SELFTEST_AUDIO は system / none / device:<名前> を指定してください: \(other)")
        }

        let options: RecordOptions
        do {
            options = try setup.makeOptions()
        } catch {
            fail("録画オプションを作れません: \(error)")
        }
        recording.whenSessionEnds {
            switch recording.phase {
            case .finished(let url):
                print("selftest: finished \(url.path)")
                fflush(stdout)
                exit(0)
            case .failed(let message):
                fail("録画に失敗: \(message)")
            default:
                fail("想定外の状態で終了: \(recording.phase)")
            }
        }
        recording.start(options)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            recording.stop()
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("selftest: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}
