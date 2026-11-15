import AppKit
import SwiftUI
import KildeCore

/// 書き起こしの翻訳のシート (issue #564 — 第七弾 Pro)。ライブラリの録画の
/// 書き起こしを、選んだ言語へまるごと翻訳する。生成の実体はエンジンの
/// `TranscriptTranslator.translate` (kilde-cli-swift#149) — Apple Intelligence の
/// オンデバイス処理で、入力を外部に送らない。
///
/// フォローアップ下書き (FollowupDraftSheet)・質問応答 (TranscriptQASheet) と
/// 同じ契約: 生成は TranscriptionCoordinator のジョブキューに載せず、このシート内の
/// Task で直接呼ぶ («ウィンドウを閉じても続けてほしい» 性質の作業ではない —
/// シートを閉じたらキャンセルでよい。CancellationError は失敗に数えない)。
///
/// v1 は **«翻訳 → 表示 → コピー»** のみ: 翻訳結果のサイドカー書き出しや
/// 元の書き起こしの上書きはしない (issue #564 «スコープ外»)。
/// 翻訳先の言語はシート内の Picker で選び、«最後に使った言語» が次回の既定に
/// なる (TranscriptTranslateSupport.lastLanguage — 設定パネルには置かない)。
/// 時刻表示 ([MM:SS]) と話者名はエンジンの指示で原文のまま保たれる —
/// 原文の行との対応を読める形で翻訳を見せる
struct TranscriptTranslateSheet: View {
    /// 翻訳の対象になる書き起こし (シートを開く時点でボタンの有効条件が
    /// 書き起こしの存在を保証している)
    let transcript: [TranscriptSegment]
    /// 会議名 (録画ファイルのベース名)。エンジンの prompt の文脈に使う
    let title: String
    /// Pro の権利。UI で事前判定済みだが、エンジンのゲートが最終防護
    /// (シートを開いたままの間に権利が変わっても licenseRequired で落ちるだけ)
    let license: LicenseContext

    @Environment(\.dismiss) private var dismiss
    /// 翻訳先の言語。初期値は «最後に使った言語» (記憶が無ければ表示言語に対応)
    @State private var language = TranscriptTranslateSupport.lastLanguage
    @State private var translatedText: String?
    @State private var isTranslating = false
    /// 生成の進捗 (0.0〜1.0)。エンジンの onProgress から来る — 長い書き起こしの
    /// 翻訳はチャンク単位で進むため、indeterminate ではなく値で見せる
    /// (TranscriptQASheet と同じ方針)
    @State private var progress: Double = 0
    @State private var failureText: String?
    @State private var failureDetail: String?
    @State private var hasCopied = false
    /// 実行中の Task。シートを閉じたらキャンセルする (TranscriptQASheet と同じ —
    /// 保持しないと閉じた後もモデル呼び出しが走り続ける)
    @State private var translateTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "translate")
                    .foregroundStyle(.secondary)
                Text(String(localized: "翻訳"))
                    .font(.headline)
                Spacer()
                if isTranslating {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(String(localized: "この録画の書き起こしを、選んだ言語へ翻訳します (端末内で処理します)"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 翻訳結果。時刻表示と話者名は原文のまま残る (エンジンの指示 —
            // kilde-cli-swift#149)。長い翻訳もスクロールで読める
            if let translatedText {
                ScrollView {
                    Text(translatedText.isEmpty
                        ? String(localized: "翻訳できませんでした")
                        : translatedText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let failureText {
                VStack(alignment: .leading, spacing: 2) {
                    Label(failureText, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    if let failureDetail {
                        Text(failureDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }

            if isTranslating {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

            HStack(spacing: 8) {
                // 翻訳先の言語。実行中は変えられない («変えても今の実行には
                // 反映されない» 混乱を防ぐため。実行中に無効化する流儀は
                // «答えを得る» と同じ)
                Picker(String(localized: "翻訳先"), selection: $language) {
                    ForEach(TranslationLanguage.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                .disabled(isTranslating)
                Button {
                    translate()
                } label: {
                    Label(String(localized: "翻訳する"), systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                // 再入防止 («実行中は押せない» — TranscriptQASheet の
                // isAskEnabled と同じ流儀。書き起こしは有効条件で保証済み)
                .disabled(isTranslating)
                if translatedText != nil {
                    Button {
                        copyTranslation()
                    } label: {
                        Label(
                            hasCopied
                                ? String(localized: "コピーしました")
                                : String(localized: "コピー"),
                            systemImage: hasCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTranslating)
                }
                Spacer()
                // «閉じる» は実行中でも押せる — 押すとシートが閉じて onDisappear が
                // 実行をキャンセルする («閉じたらキャンセルでよい» の契約)。
                // 実行中に無効化すると «途中で止めて閉じる» 手段がなくなり、
                // この契約と矛盾するため (TranscriptQASheet と同じ cubic レビュー指摘)
                Button(String(localized: "閉じる")) { dismiss() }
                    .buttonStyle(.borderless)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 560, height: 520)
        .onDisappear {
            // シートを閉じたら実行をキャンセルする (結果は使わないため。
            // CancellationError は fail に数えない — translate の catch 参照)
            translateTask?.cancel()
        }
    }

    /// 翻訳を実行する。«翻訳する» ボタンは Task を translateTask に入れて保持する —
    /// onDisappear からのキャンセルのため (TranscriptQASheet.ask と同じ流儀)。
    /// 送信時に «最後に使った言語» を記憶する (TranscriptTranslateSupport.lastLanguage)
    private func translate() {
        guard !isTranslating else { return }
        isTranslating = true
        progress = 0
        failureText = nil
        failureDetail = nil
        hasCopied = false
        UsageAnalytics.translationStarted()
        TranscriptTranslateSupport.lastLanguage = language
        let startedAt = Date()
        translateTask = Task {
            do {
                let result = try await TranscriptTranslator.translate(
                    transcript: transcript,
                    targetLanguage: language,
                    title: title,
                    license: license,
                    onProgress: { value in
                        // onProgress はエンジンの非 MainActor コンテキストから
                        // 呼ばれる (@Sendable) — @State の更新はメインキューへ回す
                        DispatchQueue.main.async {
                            progress = min(max(value, 0), 1)
                        }
                    })
                translatedText = result
                UsageAnalytics.translationCompleted(
                    processingTime: Date().timeIntervalSince(startedAt))
            } catch is CancellationError {
                // シートを閉じた場合は失敗に数えない (qa_* と同じ方針)
            } catch {
                failureText = String(localized: "翻訳を実行できませんでした")
                failureDetail = String(describing: error)
                UsageAnalytics.translationFailed(
                    error, processingTime: Date().timeIntervalSince(startedAt))
            }
            isTranslating = false
        }
    }

    /// 翻訳の全文をクリップボードへコピーする。対象は翻訳の全文のみ —
    /// 根拠 excerpts は存在しない設計 (エンジンの翻訳は «素材の選別» を伴わない
    /// map のみの経路で、QA の回答と違い «根拠» が別に返らない)。
    /// 貼り先での再編集は利用者側の自由 — 全文を 1 つの文字列にする
    private func copyTranslation() {
        guard let translatedText, !translatedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translatedText, forType: .string)
        hasCopied = true
        // «コピーしました» の表示は次の操作まで (TranscriptQASheet.copy と同じ)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            hasCopied = false
        }
    }
}
