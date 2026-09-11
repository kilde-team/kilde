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

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, mode: Mode,
         handler: @escaping (CMSampleBuffer, SCStreamOutputType) -> Void) {
        self.handler = handler
        super.init()
        let s = SCStream(filter: filter, configuration: configuration, delegate: nil)
        do {
            if mode == .screenAndAudio {
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: outQueue)
            }
            if configuration.capturesAudio {
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: outQueue)
            }
        } catch {
            // 初期化失敗は start 時に検出できないためここで致命扱い
            fatalError("SCStream addStreamOutput 失敗: \(error)")
        }
        stream = s
    }

    func start() throws {
        guard let stream else { return }
        try awaitSync { try await stream.startCapture() }
    }

    func stop() {
        guard let stream else { return }
        let s = stream
        _ = try? awaitSync { try await s.stopCapture() }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
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
