import AppKit
import SwiftUI
import KildeCore

/// 書き起こしの質問応答のシート (issue #540 — 第四弾 Pro。連続対話は issue #556 —
/// 第六弾 Pro)。ライブラリの録画の書き起こしについて «この会議で決まったことは?»
/// のように質問して答えを得る。生成の実体はエンジンの `TranscriptQA.answer`
/// (kilde-cli-swift#141 / #147) — Apple Intelligence のオンデバイス処理で、
/// 入力を外部に送らない。
///
/// フォローアップ下書き (FollowupDraftSheet — issue #464) と同じ契約: 生成は
/// TranscriptionCoordinator のジョブキューに載せず、このシート内の Task で直接呼ぶ
/// («ウィンドウを閉じても続けてほしい» 性質の作業ではない — シートを閉じたら
/// キャンセルでよい。CancellationError は失敗に数えない)。
///
/// 0.40.0 から**連続対話** (issue #556 — エンジン kilde-cli-swift#147): 以前の
/// «前の回答は新しい質問の実行時に消す» をやめ、«質問 → 回答» をシート内の履歴に
/// 積み、新しい質問は履歴を `history` としてエンジンに渡す («その金額は?» «じゃあ
/// B社の件は?» のような追質問が前の文脈を踏まえる)。履歴の正規化 («実質空» の
/// 往復を捨てる) と上限切り詰め (新しいものから 4 往復・回答本文 800 字) は
/// エンジン側 (QATurn.normalizeHistory / fittingHistory)。履歴はシートの寿命 —
/// 閉じたら消える。失敗した質問は履歴に積まない (失敗の言い方が次の回答の
/// 文脈に入るのを避けるため)
struct TranscriptQASheet: View {
    /// 質問の対象になる書き起こし (シートを開く時点でボタンの有効条件が
    /// 書き起こしの存在を保証している)
    let transcript: [TranscriptSegment]
    /// 会議名 (録画ファイルのベース名)。回答の文脈に使う
    let title: String
    /// Pro の権利。UI で事前判定済みだが、エンジンのゲートが最終防護
    /// (シートを開いたままの間に権利が変わっても licenseRequired で落ちるだけ)
    let license: LicenseContext
    /// カスタム指示 (issue #472 — 第三弾 Pro)。nil は «未指定» で従来どおり。
    /// 呼び出し側 (LibraryWindow) が customInstructions の権利を確認してから渡す —
    /// 権利のないときに «指示したのに反映されない» を避けるため
    /// (FollowupDraftSheet と同じ契約)
    var instructions: ComposerInstructions? = nil

    /// 履歴の 1 項目 («質問 → 回答» の 1 往復 + 表示用の id)。エンジンには
    /// `QATurn` (question + 回答本文) として渡す — 根拠の excerpts は履歴に
    /// 載せない (エンジンの契約: 文脈に使うのは回答本文だけ)。表示は根拠つき —
    /// «どこに書いてあったか» をたどれるのは 0.39.0 までと同じ価値のため
    private struct ChatEntry: Identifiable {
        let id = UUID()
        let question: String
        let answer: TranscriptAnswer
    }

    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    /// これまでの «質問 → 回答»。新しい質問の実行時に消さない (issue #556)
    @State private var entries: [ChatEntry] = []
    @State private var isAsking = false
    /// 生成の進捗 (0.0〜1.0)。エンジンの onProgress から来る — 長い書き起こしの
    /// «抽出 → 統合» は複数回のモデル呼び出しになるため、indeterminate ではなく
    /// 値で見せる (1 チャンクの直接回答は即 1.0 に到達する)
    @State private var progress: Double = 0
    @State private var failureText: String?
    @State private var failureDetail: String?
    @State private var hasCopied = false
    /// 実行中の Task。シートを閉じたらキャンセルする (FollowupDraftSheet と同じ —
    /// 保持しないと閉じた後もモデル呼び出しが走り続ける)
    @State private var askTask: Task<Void, Never>?
    /// 履歴の末尾へのスクロール anchor (ScrollViewReader 用の固定 id)
    private let bottomAnchor = "transcript-qa-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.secondary)
                Text(String(localized: "質問応答"))
                    .font(.headline)
                Spacer()
                if isAsking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(String(localized: "この録画の文字起こしについて質問します (端末内で処理します)"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 履歴 («質問 → 回答» の積み重ね — 新しい往復が下に)。初問前は
            // スペースを取らない。進捗と入力欄は履歴の下 (画面の下側) に置く —
            // チャットの流れをそのまま見せるため
            if !entries.isEmpty {
                historyView
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

            if isAsking {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

            HStack(spacing: 8) {
                Button {
                    ask()
                } label: {
                    Label(String(localized: "答えを得る"), systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!TranscriptQASupport.isAskEnabled(
                    question: question, isAsking: isAsking))
                .help(TranscriptQASupport.isAskEnabled(question: question, isAsking: isAsking)
                    ? ""
                    : String(localized: "質問を入力してください"))
                // «コピー» は**最新の回答** (根拠つき) を対象にする (issue #556 —
                // 履歴全体のコピーは対象外。0.39.0 までの «回答のコピー» と同じ対象)
                if let last = entries.last {
                    Button {
                        copy(last.answer)
                    } label: {
                        Label(
                            hasCopied
                                ? String(localized: "コピーしました")
                                : String(localized: "コピー"),
                            systemImage: hasCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isAsking)
                }
                Spacer()
                // «閉じる» は実行中でも押せる — 押すとシートが閉じて onDisappear が
                // 実行をキャンセルする («閉じたらキャンセルでよい» の契約)。
                // 実行中に無効化すると «途中で止めて閉じる» 手段がなくなり、
                // この契約と矛盾するため (cubic レビュー指摘)
                Button(String(localized: "閉じる")) { dismiss() }
                    .buttonStyle(.borderless)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 560, height: 520)
        .onDisappear {
            // シートを閉じたら実行をキャンセルする (結果は使わないため。
            // CancellationError は fail に数えない — ask の catch 参照)
            askTask?.cancel()
        }
    }

    /// 履歴の表示。新しい回答が積まれたら末尾へスクロールする —
    /// «チャット» の流れをそのまま見せるため (withAnimation なし —
    /// 長い履歴のスクロールアニメーションはちらつきの元)
    private var historyView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(entries) { entry in
                        entryView(entry)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: entries.count) { _, _ in
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    /// 履歴の 1 往復。質問 (キャプション) と回答 (本文 + 根拠)。
    /// 根拠はエンジンの抽出経路 (長い書き起こし) だけ返る契約 —
    /// 短い書き起こし (全体を 1 回で見た回答) では出ない (TranscriptQASupport.hasExcerpts)
    private func entryView(_ entry: ChatEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label {
                Text(entry.question)
                    .font(.caption.bold())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "questionmark.bubble")
                    .foregroundStyle(.secondary)
            }
            if entry.answer.text.isEmpty {
                // エンジンが空の回答を返す経路は無い契約だが、
                // «空の本文» をそのまま出すより案内を出す (防御)
                Text(String(localized: "答えが得られませんでした"))
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                Text(entry.answer.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if TranscriptQASupport.hasExcerpts(entry.answer) {
                Text(String(localized: "根拠 (文字起こしの行)"))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(Array(entry.answer.excerpts.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 質問を実行する。«答えを得る» ボタンは Task を askTask に入れて保持する —
    /// onDisappear からのキャンセルのため (FollowupDraftSheet.generate と同じ流儀)。
    /// 履歴がある (追質問の) ときは計測を `qa_chat_*` に切り替える — 初問は
    /// `qa_*` のまま («連続対話の利用» を初問と区別して数えるため。両シートで
    /// 共通のイベント名 — UsageAnalytics.qaChatStarted の doc コメント参照)
    private func ask() {
        let normalized = TranscriptQASupport.normalizedQuestion(question)
        // «実質空» はボタンの有効条件で防いでいるが、防御としてここでも返す
        // (エンジンの .qaEmptyQuestion に届くより UI で止める方が誤りに気づきやすい)
        guard !normalized.isEmpty, !isAsking else { return }
        isAsking = true
        progress = 0
        failureText = nil
        failureDetail = nil
        hasCopied = false
        let isFollowUp = !entries.isEmpty
        // カスタム指示の権利をここでも確認する (FollowupDraftSheet.generate と同じ
        // pre-check — issue #472)。«指示したのに指示なしで黙って実行される» は
        // 誤変換より質が悪いので、非空の指示に customInstructions の権利が
        // 無いときは実行を止めて案内する。エンジンの 2 段目ゲート
        // (kilde-cli-swift#141) が最終防護
        if let instructions, !instructions.isEmpty,
           !license.allows(.customInstructions) {
            // 権利不足の離脱を計測に残す (followup_started → fail と同じ組 —
            // エンジンのゲートが投げるのと同じ区分)
            let licenseError = KilError.failure(
                KilError.Code.licenseRequired,
                "カスタム指示には kilde Pro の権利が必要です")
            if isFollowUp {
                UsageAnalytics.qaChatStarted()
                UsageAnalytics.qaChatFailed(licenseError, processingTime: nil)
            } else {
                UsageAnalytics.qaStarted()
                UsageAnalytics.qaFailed(licenseError, processingTime: nil)
            }
            failureText = String(localized: "カスタム指示は使えませんでした")
            failureDetail = String(localized: "kilde Pro の購入または購入の復元が必要です")
            isAsking = false
            return
        }
        if isFollowUp {
            UsageAnalytics.qaChatStarted()
        } else {
            UsageAnalytics.qaStarted()
        }
        let startedAt = Date()
        // 履歴をエンジンの型へ写す (回答本文だけを文脈に使う — 根拠 excerpts は
        // 載せない。«実質空» の往復の除外・上限への切り詰め・文字数予算への
        // 収めはエンジン側 (QATurn.normalizeHistory / fittingHistory) が担う)
        let history = entries.map { QATurn(question: $0.question, answer: $0.answer.text) }
        askTask = Task {
            do {
                let generated = try await TranscriptQA.answer(
                    question: normalized,
                    transcript: transcript,
                    title: title,
                    history: history,
                    license: license,
                    instructions: instructions,
                    onProgress: { value in
                        // onProgress はエンジンの非 MainActor コンテキストから
                        // 呼ばれる (@Sendable) — @State の更新はメインキューへ回す
                        DispatchQueue.main.async {
                            progress = min(max(value, 0), 1)
                        }
                    })
                // 成功した質問だけを履歴に積む (失敗した質問は積まない —
                // 失敗のやり取りが次の回答の文脈に入るのを避けるため)。
                // 質問欄はクリアする — «答えを得る» の対象を次の質問に変えるため
                entries.append(ChatEntry(question: normalized, answer: generated))
                question = ""
                hasCopied = false
                if isFollowUp {
                    UsageAnalytics.qaChatCompleted(
                        processingTime: Date().timeIntervalSince(startedAt))
                } else {
                    UsageAnalytics.qaCompleted(
                        processingTime: Date().timeIntervalSince(startedAt))
                }
            } catch is CancellationError {
                // シートを閉じた場合は失敗に数えない (summary_* と同じ方針)
            } catch {
                failureText = String(localized: "質問応答を実行できませんでした")
                failureDetail = String(describing: error)
                if isFollowUp {
                    UsageAnalytics.qaChatFailed(
                        error, processingTime: Date().timeIntervalSince(startedAt))
                } else {
                    UsageAnalytics.qaFailed(
                        error, processingTime: Date().timeIntervalSince(startedAt))
                }
            }
            isAsking = false
        }
    }

    /// 回答をペーストボードへコピーする。全文 (本文 + 根拠) を 1 テキストとして
    /// 置く (TranscriptQASupport.clipboardText の契約)
    private func copy(_ answer: TranscriptAnswer) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            TranscriptQASupport.clipboardText(for: answer), forType: .string)
        hasCopied = true
    }
}
