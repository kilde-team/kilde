import Foundation
import AVFoundation
import CoreMedia

/// マイク / 任意の入力デバイス (BlackHole 等) を AVCaptureSession 経由で受け取る
public final class MicStream: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "kilde.mic")
    private let startQueue = DispatchQueue(label: "kilde.mic.start")
    private let handler: (CMSampleBuffer) -> Void

    /// - Parameter deviceUniqueID: nil なら既定の入力デバイス
    init(deviceUniqueID: String? = nil, handler: @escaping (CMSampleBuffer) -> Void) throws {
        self.handler = handler
        super.init()
        let device: AVCaptureDevice?
        if let id = deviceUniqueID {
            device = AVCaptureDevice(uniqueID: id)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device else {
            throw KilError.deviceNotFound("オーディオ入力デバイスが見つかりません (uniqueID=\(deviceUniqueID ?? "default"))")
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// マイクは開始に ~370ms かかるため、SCStream より先に開始すること (SPIKE-NOTES F-E)
    func start() {
        startQueue.sync { session.startRunning() }
    }

    func stop() {
        startQueue.sync { session.stopRunning() }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        handler(sampleBuffer)
    }
}
