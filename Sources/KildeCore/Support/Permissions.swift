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

    public enum MicStatus {
        case authorized
        case notDetermined
        case denied
    }

    public static var micStatus: MicStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// マイク権限を要求する (ダイアログを出し、結果を同期的に返す)。
    /// ユーザーがダイアログに応答するまで呼び出しスレッドを塞ぐので同期コンテキスト専用
    @available(*, noasync, message: "async コンテキストでは await Permissions.requestMic() を使ってください")
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

    /// マイク権限を要求する (async 版)。TCC ダイアログへの応答 (数十秒かかることもある) を
    /// 待つ間、協調プールのスレッドを塞がないため Recorder のセッションはこちらを使う (issue #35)
    @discardableResult
    public static func requestMic() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}
