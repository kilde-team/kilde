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
/// 開始できない場合は throw で返す (Apple の perform() の契約 — 失敗はエラーで示す)。
/// dialog で正常終了にすると、ショートカットの後続のアクションが «始まった» と
/// 見分けられず、«開始してから後続の処理» という自動化が壊れる。エラーの内容
/// (errorDescription) はショートカットの結果表示に出るので «なぜ始まらなかったか» は
/// 伝わる。録画の準備の失敗 (デバイス解決など) は非同期で、既存の失敗通知で届く
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "録画を開始"
    static let description = IntentDescription(
        "kilde で録画・録音を始めます。音声ソースと保存先はアプリのパネルの現在の選択を使います")

    @Parameter(title: "録画モード", default: .window)
    var mode: KildeRecordingMode

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appDelegate = AppDelegate.shared else {
            throw KildeIntentError.launchRequired
        }
        if let reason = appDelegate.startRecordingForIntent(mode: mode) {
            throw KildeIntentError.startFailed(reason)
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
            throw KildeIntentError.launchRequired
        }
        if let reason = appDelegate.stopRecordingForIntent() {
            throw KildeIntentError.stopFailed(reason)
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
        guard let appDelegate = AppDelegate.shared else {
            throw KildeIntentError.launchRequired
        }
        guard let text = await appDelegate.latestTranscriptForIntent() else {
            throw KildeIntentError.noTranscript
        }
        return .result(value: text, dialog: IntentDialog("最新の文字起こしを返しました"))
    }
}

enum KildeIntentError: LocalizedError {
    /// AppDelegate.shared が取れない (アプリが起動していない)
    case launchRequired
    /// 録画を開始できなかった。理由は AppDelegate 側でローカライズ済みの文字列
    case startFailed(String)
    /// 録画を停止できなかった。理由は AppDelegate 側でローカライズ済みの文字列
    case stopFailed(String)
    /// 最新の文字起こしが見つからなかった
    case noTranscript

    var errorDescription: String? {
        switch self {
        case .launchRequired:
            return String(localized: "kilde を起動してからもう一度お試しください")
        case .startFailed(let reason), .stopFailed(let reason):
            return reason
        case .noTranscript:
            return String(localized: "文字起こしが見つかりません。kilde で録画し、文字起こしを有効にすると作成されます")
        }
    }
}

/// 保存先ディレクトリから最新の文字起こしの内容を探す (issue #167)。
///
/// アプリを再起動していると `TranscriptionCoordinator.lastCompletion` は消えているため、
/// 録画と同じディレクトリに置かれるサイドカーを走査するフォールバック。候補は
/// «kilde- 接頭辞の録画ファイル» に対応するものだけに絞る — サイドカーの拡張子
/// (md / srt / vtt / txt / json) は普通のテキストファイルと被るので、接頭辞と
/// 拡張子だけだと無関係なファイルを «文字起こし» として返しうるため。
/// ペア判定は `RecordingSetup.transcriptSidecar` (stem 完全一致または `<stem>-<数字>`)
/// をそのまま使う。MainActor に隔離しない — AppDelegate の窓口から Task.detached で
/// 呼び、ディレクトリの走査とテキストの読み込みを MainActor の外に置くため
/// (保存先が遅いボリュームでもメニューバーの UI を止めない)
nonisolated enum TranscriptLookup {
    /// 録画ファイルの拡張子。KildeCore は一覧を公開していないため GUI 側で持つ
    /// (既定名 kilde-yyyyMMdd-HHmmss.{mov,mp4,m4a} — DESIGN.md §6 の出力名契約)。
    /// «最近の録画» (RecordingSetup.reloadRecentRecordings) と同じ集合
    private static let recordingExtensions: Set<String> = ["mov", "mp4", "m4a"]

    /// directory 内で録画に対応するサイドカーを探し、読めたテキストを返す。
    /// 対応するサイドカーが無い録画・読めない (空の) サイドカーは飛ばして古い録画の
    /// サイドカーへ進む — 1 つの読み取り失敗で «文字起こしなし» にしないため。
    /// 対応する録画が無ければ nil
    static func latestText(in directory: URL) -> String? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let contents = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return nil }
        let regular = contents.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        // サイドカーの候補は 1 回の走査で済ませて transcriptSidecar に渡す
        // («最近の録画» と同じ手順 — ペア判定の規則をそこに集約している)
        let sidecars = regular.filter {
            RecordingSetup.transcriptSidecarExtensions.contains($0.pathExtension.lowercased())
        }
        let recordings = regular.filter {
            $0.lastPathComponent.hasPrefix("kilde-")
                && recordingExtensions.contains($0.pathExtension.lowercased())
        }
        // 新しい録画に対応するサイドカーから順に読む («最新» は録画の新しい順)
        for recording in recordings.sorted(by: { modificationDate(of: $0) > modificationDate(of: $1) }) {
            guard let sidecar = RecordingSetup.transcriptSidecar(for: recording, among: sidecars),
                  let text = try? String(contentsOf: sidecar, encoding: .utf8),
                  !text.isEmpty else {
                continue
            }
            return text
        }
        return nil
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
