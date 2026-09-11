import Foundation
import AVFoundation
import CoreMedia

/// マイク (または任意の入力デバイス) を AVCaptureSession 経由で CMSampleBuffer として受け取る。
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "spike.mic")
    private let startQueue = DispatchQueue(label: "spike.mic.start")
    private let sink: (CMSampleBuffer) -> Void

    init(deviceUniqueID: String? = nil, sink: @escaping (CMSampleBuffer) -> Void) throws {
        self.sink = sink
        super.init()
        let device: AVCaptureDevice?
        if let id = deviceUniqueID {
            device = AVCaptureDevice(uniqueID: id)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device else { throw SpikeError("オーディオ入力デバイスが見つかりません (uniqueID=\(deviceUniqueID ?? "default"))") }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func start() {
        startQueue.sync { session.startRunning() }
    }

    func stop() {
        startQueue.sync { session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        sink(sampleBuffer)
    }
}

func ensureMicPermission() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .notDetermined:
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            granted = ok
            sem.signal()
        }
        sem.wait()
        return granted
    default:
        return false
    }
}
