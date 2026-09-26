import AppIntents
import Foundation
import KildeCore

/// ショートカット (AppIntents) の «何を録るか» の選択肢 (issue #167)。
///
/// 音声ソース・トラック方針・保存先はパネルの現在の選択 (`RecordingSetup.request`) を
/// 引き継ぎ、録画の対象だけをここで差し替える — ショートカット経路の実体は
/// AppDelegate の窓口メソッドがボタン・ホットキーと同じ判定を通して `RecordingController`
/// に start する。録画の持ち主は AppDelegate のまま (CLAUDE.md §5-3)
/// **String を継承するのは RawRepresentable の要件** (AppEnum の RawValue は
/// LosslessStringConvertible)。この値はショートカットがパラメータを保存するときの
/// 安定した識別子にもなるので、表示名 (日本語) とは切り離して英語の短い名前にする
enum KildeRecordingMode: String, AppEnum {
    /// 画面またはウィンドウを録画する (パネルで選ばれている対象)
    case window
    /// 音声のみを録音する
    case audioOnly

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "録画モード")
    }

    static var caseDisplayRepresentations: [KildeRecordingMode: DisplayRepresentation] {
        [
            .window: DisplayRepresentation(title: "画面 / ウィンドウを録画"),
            .audioOnly: DisplayRepresentation(title: "音声のみを録音"),
        ]
    }
}

/// «録画を開始» (issue #167)。パネルを開かずに録画・録音を始める。
/// 開始できたかどうかは dialog で返す — **throws にしない**のは、ショートカットの
/// 実行をエラー終了にすると «なぜ始まらなかったか» が読みにくく、後続のアクション
/// (通知の検査など) に繋げにくいため。録画の準備の失敗 (デバイス解決など) は非同期で、
/// 既存の失敗通知で届く
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "録画を開始"
    static let description = IntentDescription(
        "kilde で録画・録音を始めます。音声ソースと保存先はアプリのパネルの現在の選択を使います")

    @Parameter(title: "録画モード", default: .window)
    var mode: KildeRecordingMode

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appDelegate = AppDelegate.shared else {
            return .result(dialog: IntentDialog("kilde を起動してからもう一度お試しください"))
        }
        if let reason = appDelegate.startRecordingForIntent(mode: mode) {
            return .result(dialog: IntentDialog("開始できません: \(reason)"))
        }
        // «開始します» に留める — start() は準備をかけただけで、実際に収録が
        // 始まったかは非同期。«始まりました» と言い切ると、直後に失敗通知が届いた
        // ときに食い違う (MeetingAutoRecorder.pendingStartNotice と同じ理由)
        return .result(dialog: IntentDialog("録画を開始します"))
    }
}

/// «録画を停止» (issue #167)。停止をかけるとファイナライズが走り、完了は
/// 既存の録画完了通知で届く (Ctrl+C でもファイナライズされる契約と同じ経路)
struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "録画を停止"
    static let description = IntentDescription(
        "kilde の録画・録音を停止してファイルを保存します。保存の完了は通知でお知らせします")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appDelegate = AppDelegate.shared else {
            return .result(dialog: IntentDialog("kilde を起動してからもう一度お試しください"))
        }
        if let reason = appDelegate.stopRecordingForIntent() {
            // 動的文字列は StringLiteral/補間の経路で渡す (init(_:) は LocalizedStringResource 専用)
            return .result(dialog: IntentDialog("\(reason)"))
        }
        return .result(dialog: IntentDialog("録画を停止しています"))
    }
}

/// «最新の文字起こしを取得» (issue #167)。最後に文字起こしした録画のテキストを
/// 返す — ショートカットの後続のアクション (クリップボードへのコピー・要約など) に
/// そのまま渡せるよう、全文を ReturnsValue で返す
struct GetLatestTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "最新の文字起こしを取得"
    static let description = IntentDescription(
        "kilde で最後に文字起こしした録画のテキストを返します")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let appDelegate = AppDelegate.shared,
              let text = appDelegate.latestTranscriptForIntent() else {
            throw KildeIntentError.noTranscript
        }
        return .result(value: text, dialog: IntentDialog("最新の文字起こしを返しました"))
    }
}

enum KildeIntentError: LocalizedError {
    case noTranscript

    var errorDescription: String? {
        switch self {
        case .noTranscript:
            return "文字起こしが見つかりません。kilde で録画し、文字起こしを有効にすると作成されます"
        }
    }
}

/// 保存先ディレクトリから最新の文字起こしサイドカーを探す (issue #167)。
///
/// アプリを再起動していると `TranscriptionCoordinator.lastCompletion` は消えているため、
/// 録画と同じディレクトリに置かれるサイドカーを走査するフォールバック。
/// MainActor に隔離しない (AppDelegate の窓口から同期的に呼び、ファイルの一覧取得は
/// MainActor の外に置きたいため)
nonisolated enum TranscriptLookup {
    /// サイドカーの拡張子は `TranscriptOutputFormat` の rawValue と同じ
    /// (`TranscriptWriter.sidecarURL(forRecording:format:)` の契約)
    private static let sidecarExtensions: Set<String> =
        Set(TranscriptOutputFormat.allCases.map(\.fileExtension))

    /// directory 内の kilde-* のサイドカーのうち、更新日時が最も新しいもの。無ければ nil
    static func latestSidecar(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        return contents
            .filter { url in
                url.isFileURL
                    && url.lastPathComponent.hasPrefix("kilde-")
                    && sidecarExtensions.contains(url.pathExtension.lowercased())
            }
            .max { modificationDate(of: $0) < modificationDate(of: $1) }
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
    }
}

/// ショートカット App / Siri に提示する既定のショートカット (issue #167)。
/// アプリのインストール後にショートカット App に自動で現れる。
/// フレーズは開発地域 (ja) の言語で書く。英語など他言語向けのローカライズは
/// AppShortcuts.strings の導入が別途必要 (現時点では未導入 — 英語環境でも
/// 既定のフレーズで動くが、翻訳されたフレーズは無い)
struct KildeAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["\(.applicationName) で録画を開始"],
            shortTitle: "録画を開始",
            systemImageName: "record.circle")
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["\(.applicationName) で録画を停止"],
            shortTitle: "録画を停止",
            systemImageName: "stop.circle")
        AppShortcut(
            intent: GetLatestTranscriptIntent(),
            phrases: ["\(.applicationName) で最新の文字起こしを取得"],
            shortTitle: "最新の文字起こしを取得",
            systemImageName: "text.bubble")
    }
}
