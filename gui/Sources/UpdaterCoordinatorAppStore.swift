#if APPSTORE
import Combine
import KildeCore

/// App Store 配布ビルド用の UpdaterCoordinator スタブ (issue #126)。
/// MAS ではストア外自己更新 (Sparkle) がガイドラインで禁止されているため、
/// 実体を持たない。本物の実装 (UpdaterCoordinator.swift、#if !APPSTORE 側) と
/// 同じ API だけを用意し、AppDelegate / ContentView / SelfTest の呼び出し側を
/// 条件分岐なしで共有する。更新 UI 自体は ContentView 側で非表示にする
@MainActor
final class UpdaterCoordinator: ObservableObject {

    /// 常に false。ボタンの disabled 判定に使われるが、更新 UI ごと非表示なので
    /// この値が UI に出ることはない
    @Published private(set) var canCheckForUpdates = false

    /// KildeGUI 側と同じシグネチャを保つ。startUpdater は無視する
    init(recording: RecordingController, startUpdater: Bool) {}

    /// 呼ばれない (更新 UI が無い)。保険として no-op にしておく
    func checkForUpdates() {}
}
#endif
