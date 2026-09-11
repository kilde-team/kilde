import Foundation
import ScreenCaptureKit
import CoreMedia

/// SCStream のラッパ。映像 (.screen) と音声 (.audio) の出力を 1 つのシリアルキューで受ける。
final class SckCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let sink: (CMSampleBuffer, SCStreamOutputType) -> Void
    private let outQueue = DispatchQueue(label: "spike.sck.out")

    /// - Parameter observeScreen: false のとき .screen 出力を登録しない (S8: 音声のみ取得の可否検証)
    init(filter: SCContentFilter, configuration: SCStreamConfiguration,
         audio: Bool, observeScreen: Bool = true,
         sink: @escaping (CMSampleBuffer, SCStreamOutputType) -> Void) {
        self.sink = sink
        super.init()
        let s = SCStream(filter: filter, configuration: configuration, delegate: nil)
        do {
            if observeScreen {
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: outQueue)
            }
            if audio {
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: outQueue)
            }
        } catch {
            fail("addStreamOutput 失敗: \(error)")
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

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        if type == .screen {
            // .idle / .blank 等の不完全フレームを除外
            guard sampleBuffer.isValid else { return }
            guard let atts = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusNum = atts.first?[SCStreamFrameInfo.status] as? NSNumber,
                  statusNum.intValue == SCFrameStatus.complete.rawValue else { return }
        }
        sink(sampleBuffer, type)
    }
}
