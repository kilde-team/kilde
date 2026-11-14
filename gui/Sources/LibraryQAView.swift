import AppKit
import SwiftUI
import KildeCore

/// ライブラリ横断の質問応答のシート (issue #547 — 第五弾 Pro。連続対話は
/// issue #556 — 第六弾 Pro)。ライブラリ内の複数の録画を横断して
/// «この 2 週間の会議で予算の話は出た?» のように質問し、根拠 («会議名: 行»)
/// つきで答えを得る。生成の実体はエンジンの `LibraryQA.answer`
/// (kilde-cli-swift#145 / #147) — Apple Intelligence のオンデバイス処理で、
/// 入力を外部に送らない。
///
/// 単一録画版 (TranscriptQASheet — issue #540) と同じ契約: 生成はこのシート内の
/// Task で直接呼び、シートを閉じたらキャンセル (CancellationError は失敗に
/// 数えない)。
///
/// 0.40.0 から**連続対話** (issue #556 — エンジン kilde-cli-swift#147): 以前の
/// «前の回答は新しい質問の実行時に消す» をやめ、«質問 → 回答» をシート内の履歴に
/// 積み、新しい質問は履歴を `history` としてエンジンに渡す («その会議についてもっと
/// 詳しく» «じゃあ B社の件は?» のような追質問が前の文脈を踏まえる)。履歴の正規化と
/// 上限切り詰め (新しいものから 4 往復) はエンジン側 (QATurn.normalizeHistory /
/// fittingHistory)。**録画の選定 (`LibraryQA.selectRecordings`) は履歴を使わない**
/// (質問語と検索語のみ — エンジンの契約)。履歴はシートの寿命 — 閉じたら消える。
/// 失敗した質問は履歴に積まない (単一録画版と同じ)
struct LibraryQASheet: View {
    /// 質問の対象になる録画列 (**書き起こしを持つ録画だけ** — LibraryQASupport.recordings
    /// が保証する。ボタンの有効条件も «書き起こし済み 1 件以上» で開く経路を守る)
    let recordings: [LibraryRecording]
    /// Pro の権利。UI で事前判定済みだが、エンジンのゲートが最終防護
    /// (シートを開いたままの間に権利が変わっても licenseRequired で落ちるだけ)
    let license: LicenseContext
    /// 検索欄に入力された語 (任意)。nil は «絞り込みなし»。エンジンの選定
    /// (`LibraryQA.selectRecordings`) はこの語を含む録画を優先する
    /// — «検索で絞り込んだうえで質問» というライブラリの自然な操作を
    /// そのまま精度に繋げるため
    var searchTerms: [String]? = nil
    /// カスタム指示 (issue #472 — 第三弾 Pro)。nil は «未指定» で従来どおり。
    /// 呼び出し側 (LibraryView) が customInstructions の権利を確認してから渡す
    /// (TranscriptQASheet と同じ契約)
    var instructions: ComposerInstructions? = nil

    /// 履歴の 1 項目。単一録画版 (TranscriptQASheet.ChatEntry) と同じ構成 —
    /// エンジンには `QATurn` (question + 回答本文) として渡し、表示は根拠つき
    private struct ChatEntry: Identifiable {
        let id = UUID()
        let question: String
        let answer: LibraryAnswer
    }

    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    /// これまでの «質問 → 回答»。新しい質問の実行時に消さない (issue #556)
    @State private var entries: [ChatEntry] = []
    @State private var isAsking = false
    /// 生成の進捗 (0.0〜1.0)。エンジンの onProgress から来る — «録画 × チャンク»
    /// の抽出が複数回のモデル呼び出しになるため、indeterminate ではなく値で見せる
    @State private var progress: Double = 0
    @State private var failureText: String?
    @State private var failureDetail: String?
    @State private var hasCopied = false
    /// 実行中の Task。シートを閉じたらキャンセルする (TranscriptQASheet と同じ —
    /// 保持しないと閉じた後もモデル呼び出しが走り続ける)
    @State private var askTask: Task<Void, Never>?
    /// 履歴の末尾へのスクロール anchor (ScrollViewReader 用の固定 id)
    private let bottomAnchor = "library-qa-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "books.vertical")
                    .foregroundStyle(.secondary)
                Text(String(localized: "ライブラリへの質問"))
                    .font(.headline)
                Spacer()
                if isAsking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(String(localized: "ライブラリ内の録画 (\(recordings.count) 件) を横断して質問します (端末内で処理します)"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 履歴 («質問 → 回答» の積み重ね — 新しい往復が下)。初問前は
            // スペースを取らない。進捗と入力欄は履歴の下 (画面の下側) に置く —
            // 単一録画版 (TranscriptQASheet) と同じ «チャット» の流れ
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

            // 質問の入力欄 (履歴の下 — チャットの入力位置)。単一録画版と同じ
            // «上限を入力欄で適用» («答えを得る» の押下時に黙って切り捨てない)
            TextField(
                String(localized: "これらの会議で決まったことは?"),
                text: $question,
                axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .disabled(isAsking)
                .onChange(of: question) { _, newValue in
                    // 入力 «中» は前後の空白を保つ — 正規化 (trim) を入力ごとに
                    // 行うと «文末の空白を入れた瞬間に消える» ので質問文が
                    // 編集しにくい (CodeRabbit レビュー指摘)。上限を超えたときだけ
                    // 切り詰め、«実質空» の正規化は «答えを得る» の押下時
                    // (ask の normalizedQuestion) に行う。単一録画版
                    // (TranscriptQASheet) は trim を入力ごとに行っているが、
                    // こちらは «押下時に正規化» に寄せた — エンジンの
                    // normalizeQuestion が最終的な正本なので挙動の差は
                    // 利用者に見えない
                    if newValue.count > LibraryQASupport.maxQuestionLength {
                        // 上限超過のときは **切り詰めだけ** を行う — trim まで
                        // 行うと «文末の空白を入れた瞬間に消える» が上限超過の
                        // 編集でも起き、この変更の意図 («入力中は空白を保つ»)
                        // と矛盾するため (cubic 再レビュー指摘)。trim は
                        // «答えを得る» の押下時 (ask の normalizedQuestion) に
                        // 限定する
                        question = String(newValue.prefix(LibraryQASupport.maxQuestionLength))
                    }
                }

            HStack(spacing: 8) {
                Button {
                    ask()
                } label: {
                    Label(String(localized: "答えを得る"), systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!LibraryQASupport.isAskEnabled(
                    question: question, isAsking: isAsking))
                .help(LibraryQASupport.isAskEnabled(question: question, isAsking: isAsking)
                    ? ""
                    : String(localized: "質問を入力してください"))
                // «コピー» は**最新の回答** (根拠 «会議名: 行» つき) を対象にする
                // (issue #556 — 単一録画版と同じ対象。履歴全体のコピーは対象外)
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
                // 実行をキャンセルする («閉じたらキャンセルでよい» の契約。
                // TranscriptQASheet と同じ cubic レビュー経緯)
                Button(String(localized: "閉じる")) { dismiss() }
                    .buttonStyle(.borderless)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 560, height: 520)
        .onDisappear {
            // シートを閉じたら実行をキャンセルする (CancellationError は
            // fail に数えない — ask の catch 参照)
            askTask?.cancel()
        }
    }

    /// 履歴の表示。新しい回答が積まれたら末尾へスクロールする
    /// (単一録画版と同じ — withAnimation なし)
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
    /// 根拠はライブラリ版では常に集まる契約 («見つからない» のときだけ空) —
    /// «どの会議の根拠か» が 1 文字列で分かる形で並べる
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
            if LibraryQASupport.hasExcerpts(entry.answer) {
                Text(String(localized: "根拠 (会議と行)"))
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
    /// onDisappear からのキャンセルのため (TranscriptQASheet.ask と同じ流儀)。
    /// 履歴がある (追質問の) ときは計測を `qa_chat_*` に切り替える — 初問は
    /// `library_qa_*` のまま (両シートで共通の追質問イベント名 —
    /// UsageAnalytics.qaChatStarted の doc コメント参照)
    private func ask() {
        let normalized = LibraryQASupport.normalizedQuestion(question)
        // «実質空» はボタンの有効条件で防いでいるが、防御としてここでも返す
        guard !normalized.isEmpty, !isAsking else { return }
        isAsking = true
        progress = 0
        failureText = nil
        failureDetail = nil
        hasCopied = false
        let isFollowUp = !entries.isEmpty
        // カスタム指示の権利をここでも確認する (TranscriptQASheet.ask と同じ
        // pre-check — issue #472)。«指示したのに指示なしで黙って実行される» を
        // 避ける。エンジンの 2 段目ゲート (kilde-cli-swift#145) が最終防護
        if let instructions, !instructions.isEmpty,
           !license.allows(.customInstructions) {
            // 権利不足の離脱を計測に残す (qa_* / qa_chat_* と同じ組)
            let licenseError = KilError.failure(
                KilError.Code.licenseRequired,
                "カスタム指示には kilde Pro の権利が必要です")
            if isFollowUp {
                UsageAnalytics.qaChatStarted()
                UsageAnalytics.qaChatFailed(licenseError, processingTime: nil)
            } else {
                UsageAnalytics.libraryQAStarted()
                UsageAnalytics.libraryQAFailed(licenseError, processingTime: nil)
            }
            failureText = String(localized: "カスタム指示は使えませんでした")
            failureDetail = String(localized: "kilde Pro の購入または購入の復元が必要です")
            isAsking = false
            return
        }
        if isFollowUp {
            UsageAnalytics.qaChatStarted()
        } else {
            UsageAnalytics.libraryQAStarted()
        }
        let startedAt = Date()
        // 履歴をエンジンの型へ写す (回答本文だけを文脈に使う — 根拠 excerpts は
        // 載せない。正規化・上限切り詰め・予算への収めはエンジン側が担う。
        // **選定は履歴を使わない** — 質問語と検索語のみ、というエンジンの契約)
        let history = entries.map { QATurn(question: $0.question, answer: $0.answer.text) }
        askTask = Task {
            do {
                let generated = try await LibraryQA.answer(
                    question: normalized,
                    recordings: recordings,
                    searchTerms: searchTerms,
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
                // 単一録画版と同じ)。質問欄はクリアする
                entries.append(ChatEntry(question: normalized, answer: generated))
                question = ""
                hasCopied = false
                if isFollowUp {
                    UsageAnalytics.qaChatCompleted(
                        processingTime: Date().timeIntervalSince(startedAt))
                } else {
                    UsageAnalytics.libraryQACompleted(
                        processingTime: Date().timeIntervalSince(startedAt))
                }
            } catch is CancellationError {
                // シートを閉じた場合は失敗に数えない (qa_* と同じ方針)
            } catch {
                failureText = String(localized: "ライブラリへの質問を実行できませんでした")
                failureDetail = String(describing: error)
                if isFollowUp {
                    UsageAnalytics.qaChatFailed(
                        error, processingTime: Date().timeIntervalSince(startedAt))
                } else {
                    UsageAnalytics.libraryQAFailed(
                        error, processingTime: Date().timeIntervalSince(startedAt))
                }
            }
            isAsking = false
        }
    }

    /// 回答をペーストボードへコピーする。全文 (本文 + 根拠) を 1 テキストとして
    /// 置く (LibraryQASupport.clipboardText の契約)
    private func copy(_ answer: LibraryAnswer) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            LibraryQASupport.clipboardText(for: answer), forType: .string)
        hasCopied = true
    }
}
