import Foundation
import ScreenCaptureKit
import CoreMedia

/// SCStream のラッパ。映像 (.screen) とシステム音声 (.audio) を 1 つのシリアルキューで受ける。
/// `.audio` のみ登録すれば音声のみの取得も可能 (SPIKE-NOTES F-A / S8)。
public final class ScreenAudioStream: NSObject, SCStreamOutput {

    public enum Mode {
        /// 映像 + システム音声 (capturesAudio が有効な場合)
        case screenAndAudio
        /// 音声のみ (.screen 出力を登録しない — S8 で実証)
        case audioOnly
    }

    private var stream: SCStream?
    private let handler: (CMSampleBuffer, SCStreamOutputType) -> Void
    private let outQueue = DispatchQueue(label: "kilde.sck.out")
    /// stop() 以降のコールバックを捨てるためのゲート。outQueue 上でだけ読み書きする (ロック不要)
    private var stopped = false

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, mode: Mode,
         handler: @escaping (CMSampleBuffer, SCStreamOutputType) -> Void) throws {
        self.handler = handler
        super.init()
        let s = SCStream(filter: filter, configuration: configuration, delegate: nil)
        var screenRegistered = false
        var audioRegistered = false
        do {
            if mode == .screenAndAudio {
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: outQueue)
                screenRegistered = true
            }
            if configuration.capturesAudio {
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: outQueue)
                audioRegistered = true
            }
        } catch {
            // 登録済みの出力を解除してから投げ直す。
            // fatalError は Recorder.run() の catch や monitor の後始末を飛ばすため使わない。
            if screenRegistered { try? s.removeStreamOutput(self, type: .screen) }
            if audioRegistered { try? s.removeStreamOutput(self, type: .audio) }
            throw KilError.failed("SCStream addStreamOutput 失敗: \(error.localizedDescription)")
        }
        stream = s
    }

    /// キャプチャを開始する。async にしているのは、startCapture の完了待ちで
    /// 協調プールのスレッドを塞がないため (issue #35。以前は awaitSync で同期的に待っていた)
    func start() async throws {
        guard let stream else { return }
        try await stream.startCapture()
    }

    /// **サンプルの配送だけを止める (replayd とは話さない)。** issue #95 の対処の要。
    ///
    /// **これを呼んでもキャプチャは止まらない。** replayd 側のセッションは動き続け、
    /// 画面収録インジケータも点いたままになる。停止まで伝えるには `stopCapture()` を
    /// 別途呼ぶこと (`stop()` は両方を順に呼ぶ)。
    ///
    /// 戻った後に handler が呼ばれないことは保証する — `MovieWriter.finish()` の後に
    /// append が走らないようにするため (`MicStream.stop()` の `queue.sync {}` と
    /// 同じ役割。CLAUDE.md §6)
    ///
    /// 停止シーケンスは `stopCapture()` が replayd との XPC から戻らないことがあり
    /// (2 プロセスの停止が重なると実測 8/10)、そこで固まるとファイナライズに辿り着けず
    /// **未完了ファイルが残る**。そこで「配送を止める」と「replayd に停止を伝える」を
    /// 分け、**前者だけを先に済ませてからファイナライズする**。
    /// こうすれば `stopCapture()` がハングしても、そのときには**ファイルは完成済み**になる。
    ///
    /// ここは `outQueue` にブロックを積んで `stopped` を立てるだけで、SCK の API を
    /// 一切呼ばない。シリアルキューなので、このブロックが走る時点で積み残しの
    /// コールバックは処理済みになっている
    func suspendDelivery() async {
        guard stream != nil else { return }
        StopTrace.mark("sck.drain 開始 (stopCapture は呼ばない)")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            outQueue.async {
                StopTrace.mark("sck.outQueue drain 実行")
                self.stopped = true
                done.resume()
            }
        }
        StopTrace.mark("sck.drain 完了")
    }

    /// **replayd にキャプチャの停止を伝える。** ここがハングしうる区間 (issue #95)。
    /// `suspendDelivery()` を先に済ませてある前提なので、ここで固まっても
    /// 出力ファイルは既にファイナライズ済みで、壊れたファイルは残らない。
    ///
    /// - Returns: 失敗した場合そのエラー。成功なら `nil` (issue #107)。
    ///
    /// **投げずに返す。** 投げると呼び出し側が `finish()` を飛ばしかねず、
    /// 「Ctrl+C でも必ずファイナライズする」(DESIGN.md §5) を壊す事故を招く —
    /// それが元々 `try?` で握り潰していた理由だった。かといって捨ててしまうと、
    /// **停止できていないのに成功として扱われ**、replayd 側でキャプチャが走り続ける
    /// (画面収録インジケータが点いたまま、次の録画と重なりうる)。
    /// 戻り値なら呼び出し側が「ファイナライズを終えた後で」判断できる
    @discardableResult
    func stopCapture() async -> Error? {
        guard let stream else { return nil }
        StopTrace.mark("sck.stopCapture 呼び出し前")
        do {
            try await stream.stopCapture()
            StopTrace.mark("sck.stopCapture 戻り")
            return nil
        } catch {
            StopTrace.mark("sck.stopCapture 失敗: \(error.localizedDescription)")
            return error
        }
    }

    func stop() async {
        // 旧来の順序 (replayd に伝えてから配送を止める) を保つ呼び出し口。
        // **#95 の対処を入れる前の比較対照として残す** — 修正前後を同じ実験装置で
        // 測るために、両方の順序を選べる必要がある。
        //
        // **ここでは停止の失敗を報告しない (issue #107)。** この順序では
        // `stopCapture()` が**ファイナライズより前**に走るため、警告を積んでも
        // その後の `finish()` が失敗すれば録画自体が失敗になり、警告は埋もれる。
        // 失敗を伝えるのは新順序 (`Recorder.notifyReplaydStopIfNeeded`) の責任で、
        // あちらは**ファイルが完成した後**に呼ぶので「録画は成功・後始末に問題」
        // という `cleanupWarning` の定義にぴったり合う
        await stopCapture()
        await suspendDelivery()
        StopTrace.mark("sck.stop 完了")
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        // outQueue 上で呼ばれる。stop() 後 (停止に失敗した場合を含む) のコールバックは writer へ渡さない
        guard !stopped else { return }
        if type == .screen {
            // .idle / .blank 等の不完全フレームを除外
            guard sampleBuffer.isValid else { return }
            guard let atts = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusNum = atts.first?[SCStreamFrameInfo.status] as? NSNumber,
                  statusNum.intValue == SCFrameStatus.complete.rawValue else { return }
        }
        handler(sampleBuffer, type)
    }
}

// stop() の drain で self を outQueue.async に渡すため Sendable が要る。可変状態の `stopped` は
// outQueue 上でだけ読み書きし、`stream` は init でしか設定しないので、実質的にデータ競合はない
extension ScreenAudioStream: @unchecked Sendable {}
