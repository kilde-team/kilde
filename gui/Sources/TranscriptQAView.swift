import AppKit
import SwiftUI
import KildeCore

/// 書き起こしの質問応答のシート (issue #540 — 第四弾 Pro)。ライブラリの録画の
/// 書き起こしについて «この会議で決まったことは?» のように質問して答えを得る。
/// 生成の実体はエンジンの `TranscriptQA.answer` (kilde-cli-swift#141) —
/// Apple Intelligence のオンデバイス処理で、入力を外部に送らない。
///
/// フォローアップ下書き (FollowupDraftSheet — issue #464) と同じ契約: 生成は
/// TranscriptionCoordinator のジョブキューに載せず、このシート内の Task で直接呼ぶ
/// («ウィンドウを閉じても続けてほしい» 性質の作業ではない — シートを閉じたら
/// キャンセルでよい。CancellationError は失敗に数えない)。
/// 質問を変えて何度でも実行できる (前の回答は新しい質問の実行時に消す —
/// 表示と «コピー» が古い質問の答えを指し続けるのを避ける)。
/// 書き起こしが長いとエンジン側で «区間ごとの抽出 → 統合回答» の複数回の
/// モデル呼び出しになる (進捗はエンジンの onProgress を受けて表示する)
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

    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answer: TranscriptAnswer?
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

            // 質問の入力欄。縦方向に伸びる (長い質問も折り返して見える)。
            // «この会議で決まったことは?» のような書き方の例を prompt に出す
            TextField(
                String(localized: "この会議で決まったことは?"),
                text: $question,
                axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .disabled(isAsking)
                // 入力欄で上限を適用する — 超過分を «答えを得る» の押下時に黙って
                // 切り捨てない (cubic レビュー指摘。エンジンの
                // TranscriptQA.maxQuestionLength と同じ値 — TranscriptQASupport の
                // コメント参照)
                .onChange(of: question) { _, newValue in
                    let normalized = TranscriptQASupport.normalizedQuestion(newValue)
                    if normalized != newValue {
                        question = normalized
                    }
                }

            if isAsking {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

            HStack(spacing: 8) {
                Button {
                    ask()
                } label: {
                    Label(
                        answer == nil
                            ? String(localized: "答えを得る")
                            : String(localized: "質問し直す"),
                        systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!TranscriptQASupport.isAskEnabled(
                    question: question, isAsking: isAsking))
                .help(TranscriptQASupport.isAskEnabled(question: question, isAsking: isAsking)
                    ? ""
                    : String(localized: "質問を入力してください"))
                if let answer {
                    Button {
                        copy(answer)
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

            if let answer {
                answerView(answer)
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

    /// 回答の表示。本文 (段落列) と、根拠 (excerpts) があるときだけ根拠セクション。
    /// 根拠はエンジンの抽出経路 (長い書き起こし) だけ返る契約 —
    /// 短い書き起こし (全体を 1 回で見た回答) では出ない (TranscriptQASupport.hasExcerpts)
    private func answerView(_ answer: TranscriptAnswer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if answer.text.isEmpty {
                        // エンジンが空の回答を返す経路は無い契約だが、
                        // «空の本文» をそのまま出すより案内を出す (防御)
                        Text(String(localized: "答えが得られませんでした"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(answer.text)
                            .font(.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if TranscriptQASupport.hasExcerpts(answer) {
                        Divider()
                        Text(String(localized: "根拠 (文字起こしの行)"))
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(Array(answer.excerpts.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 質問を実行する。«答えを得る» ボタンは Task を askTask に入れて保持する —
    /// onDisappear からのキャンセルのため (FollowupDraftSheet.generate と同じ流儀)
    private func ask() {
        let normalized = TranscriptQASupport.normalizedQuestion(question)
        // «実質空» はボタンの有効条件で防いでいるが、防御としてここでも返す
        // (エンジンの .qaEmptyQuestion に届くより UI で止める方が誤りに気づきやすい)
        guard !normalized.isEmpty, !isAsking else { return }
        isAsking = true
        progress = 0
        answer = nil
        failureText = nil
        failureDetail = nil
        hasCopied = false
        // カスタム指示の権利をここでも確認する (FollowupDraftSheet.generate と同じ
        // pre-check — issue #472)。«指示したのに指示なしで黙って実行される» は
        // 誤変換より質が悪いので、非空の指示に customInstructions の権利が
        // 無いときは実行を止めて案内する。エンジンの 2 段目ゲート
        // (kilde-cli-swift#141) が最終防護
        if let instructions, !instructions.isEmpty,
           !license.allows(.customInstructions) {
            // 権利不足の離脱を計測に残す (followup_started → fail と同じ組 —
            // エンジンのゲートが投げるのと同じ区分)
            UsageAnalytics.qaStarted()
            UsageAnalytics.qaFailed(
                KilError.failure(
                    KilError.Code.licenseRequired,
                    "カスタム指示には kilde Pro の権利が必要です"),
                processingTime: nil)
            failureText = String(localized: "カスタム指示は使えませんでした")
            failureDetail = String(localized: "kilde Pro の購入または購入の復元が必要です")
            isAsking = false
            return
        }
        UsageAnalytics.qaStarted()
        let startedAt = Date()
        askTask = Task {
            do {
                let generated = try await TranscriptQA.answer(
                    question: normalized,
                    transcript: transcript,
                    title: title,
                    license: license,
                    instructions: instructions,
                    onProgress: { value in
                        // onProgress はエンジンの非 MainActor コンテキストから
                        // 呼ばれる (@Sendable) — @State の更新はメインキューへ回す
                        DispatchQueue.main.async {
                            progress = min(max(value, 0), 1)
                        }
                    })
                answer = generated
                hasCopied = false
                UsageAnalytics.qaCompleted(
                    processingTime: Date().timeIntervalSince(startedAt))
            } catch is CancellationError {
                // シートを閉じた場合は失敗に数えない (summary_* と同じ方針)
            } catch {
                failureText = String(localized: "質問応答を実行できませんでした")
                failureDetail = String(describing: error)
                UsageAnalytics.qaFailed(
                    error, processingTime: Date().timeIntervalSince(startedAt))
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
