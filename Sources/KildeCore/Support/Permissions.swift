import Foundation
import CoreGraphics
import AVFoundation

public enum Permissions {
    /// 画面収録権限 (付与済みかどうか。ダイアログは出ない)
    public static var hasScreenCapture: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 画面収録権限を要求する (システム設定/ダイアログが開く。許可後の再実行が必要)
    @discardableResult
    public static func requestScreenCapture() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static var hasMic: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// マイク権限を要求する (ダイアログを出し、結果を同期的に返す)
    @discardableResult
    public static func requestMic() -> Bool {
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
}
