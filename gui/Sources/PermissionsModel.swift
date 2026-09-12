import AppKit
import Combine
import KildeCore

/// 画面収録・マイクの TCC 権限の状態と案内 (issue #19)。
/// 判定は CLI の `kilde doctor` と同じ `KildeCore.Permissions` を使う — GUI 側で
/// 独自に判定すると、doctor が「あり」と言うのに GUI が止まる (あるいはその逆) が起きるため
@MainActor
final class PermissionsModel: ObservableObject {

    /// 録画の構成ごとに「何の権限が要るか」。必要な権限だけを案内するために使う
    /// (音声のみ + マイク無しの録音に画面収録権限を求めない)
    enum Requirement: Hashable {
        case screen
        case mic
    }

    @Published private(set) var screenGranted = false
    @Published private(set) var micStatus = Permissions.MicStatus.denied
    /// 画面収録を一度要求したか。macOS は許可してもプロセスを再起動するまで
    /// `CGPreflightScreenCaptureAccess()` が false のままなので、案内文を変えるために持つ
    @Published private(set) var didRequestScreen = false

    init() {
        refresh()
    }

    /// 検証用に権限を「無い」ことにする指定 (`KILDE_GUI_SELFTEST_DENY=screen,mic`)。
    /// 許可を実際に外さないと案内も開始禁止も踏めず、**自分の失敗経路を確かめられない**。
    /// issue #18 のセルフテストで、失敗経路を踏まないまま「閉じ失敗を成功と誤判定する」回帰を
    /// 見逃した前例があるので、ここでは最初から踏めるようにしておく
    private static let forcedDenials: Set<Requirement> = {
        let raw = ProcessInfo.processInfo.environment["KILDE_GUI_SELFTEST_DENY"] ?? ""
        var result: Set<Requirement> = []
        for token in raw.split(separator: ",") {
            switch token.trimmingCharacters(in: .whitespaces) {
            case "screen": result.insert(.screen)
            case "mic": result.insert(.mic)
            default: break
            }
        }
        return result
    }()

    /// 権限の状態を取り直す。macOS 15 以降は画面収録権限が定期的に再確認され (DESIGN.md F4)、
    /// 一度許可した後でも失効しうるので、ポップオーバーを開くたびと録画開始の直前に呼ぶ
    func refresh() {
        screenGranted = Permissions.hasScreenCapture && !Self.forcedDenials.contains(.screen)
        micStatus = Self.forcedDenials.contains(.mic) ? .denied : Permissions.micStatus
    }

    /// この構成で不足している権限。空なら開始できる
    func missing(for request: RecordRequest) -> [Requirement] {
        var result: [Requirement] = []
        if Self.needsScreen(request), !screenGranted { result.append(.screen) }
        if Self.needsMic(request), micStatus != .authorized { result.append(.mic) }
        return result
    }

    /// SCK を使う構成か。**判定は `RecordRequest` が持つ** — ここに書き写すと
    /// `Recorder` 側とずれて、録画できる構成を GUI が止めてしまう (issue #72)
    static func needsScreen(_ request: RecordRequest) -> Bool {
        request.usesScreenCapture
    }

    /// マイク (AVCaptureSession) を使う構成か。既定のマイクだけでなく、
    /// 任意の入力デバイスを選んだ場合も TCC のマイク権限が要る
    static func needsMic(_ request: RecordRequest) -> Bool {
        request.captureMic || !request.inputDevices.isEmpty
    }

    /// 画面収録権限を要求する。ダイアログかシステム設定が開く。
    /// 許可は再起動後に反映されるため、ここでは状態が変わらないのが正常
    func requestScreen() {
        Permissions.requestScreenCapture()
        didRequestScreen = true
        refresh()
    }

    /// マイク権限を要求する。未設定ならダイアログが出て、その場で反映される。
    /// 拒否済みのときはダイアログが出ないので、呼び出し側はシステム設定へ誘導する
    func requestMic() async {
        // sync 版は応答までスレッドを塞ぐので async 版を使う (CLAUDE.md §6 / issue #35)
        _ = await Permissions.requestMic()
        refresh()
    }

    func openScreenSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func openMicSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
