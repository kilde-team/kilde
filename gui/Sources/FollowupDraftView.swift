import AppKit
import SwiftUI
import KildeCore

/// フォローアップ下書きのシート (issue #464 — 第二弾 Pro)。ライブラリの議事録
/// (.md) の要約から、参加者へ送るメッセージの下書きを生成する。生成の実体は
/// エンジンの `FollowupComposer` (kilde-cli-swift#137) — Apple Intelligence の
/// オンデバイス処理で、入力を外部に送らない。
///
/// 生成は要約を元にした 1 回のモデル呼び出し (進捗の段階が無い) のため、
/// TranscriptionCoordinator のジョブキューには載せず、このシート内の Task で
/// 直接呼ぶ — 文字起こしと違って «ウィンドウを閉じても続けてほしい» 性質の
/// 作業ではない (シートを閉じたらキャンセルでよい — CancellationError は
/// 失敗に数えない。summary_* と同じ方針)
struct FollowupDraftSheet: View {
    /// 下書きの元になる要約 (シートを開く時点でボタンの有効条件が
    /// `.summary` を保証している)
    let summary: MeetingSummary
    /// 会議名 (録画ファイルのベース名)。件名や書き出しの文脈に使う
    let title: String
    /// Pro の権利。UI で事前判定済みだが、エンジンのゲートが最終防護
    /// (シートを開いたままの間に権利が変わっても licenseRequired で落ちるだけ)
    let license: LicenseContext
    /// カスタム指示 (issue #472 — 第三弾 Pro)。nil は «未指定» で従来どおり。
    /// 呼び出し側 (LibraryWindow) が customInstructions の権利を確認してから渡す —
    /// 権利のないときに «指示したのに反映されない» を避けるため
    var instructions: ComposerInstructions? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var style: FollowupDraftStyle = .email
    @State private var draft: FollowupDraft?
    @State private var isGenerating = false
    @State private var failureText: String?
    @State private var failureDetail: String?
    @State private var hasCopied = false
    /// 生成中の Task。シートを閉じたらキャンセルする («閉じたらキャンセルでよい» の
    /// 契約を Task でも守るため — 保持しないと閉じた後もモデル呼び出しが走り続ける)
    @State private var generationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "envelope")
                    .foregroundStyle(.secondary)
                Text(String(localized: "フォローアップの下書き"))
                    .font(.headline)
                Spacer()
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(String(localized: "議事録の要約から、参加者へ送るメッセージの下書きを生成します (端末内で処理します)"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker(String(localized: "形式"), selection: $style) {
                Text(String(localized: "メール")).tag(FollowupDraftStyle.email)
                Text(String(localized: "チャット")).tag(FollowupDraftStyle.chat)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            .disabled(isGenerating)

            HStack(spacing: 8) {
                Button {
                    generationTask = Task { await generate() }
                } label: {
                    Label(
                        draft == nil
                            ? String(localized: "下書きを生成")
                            : String(localized: "作り直す"),
                        systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating)
                if let draft {
                    Button {
                        copy(draft)
                    } label: {
                        Label(
                            hasCopied
                                ? String(localized: "コピーしました")
                                : String(localized: "コピー"),
                            systemImage: hasCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isGenerating)
                }
                Spacer()
                Button(String(localized: "閉じる")) { dismiss() }
                    .buttonStyle(.borderless)
                    .disabled(isGenerating)
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

            if let draft {
                draftView(draft)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 560, height: 480)
        .onDisappear {
            // シートを閉じたら生成をキャンセルする (結果は使わないため。
            // CancellationError は fail に数えない — generate の catch 参照)
            generationTask?.cancel()
        }
        .onChange(of: style) { _, _ in
            // 形式を切り替えたら前の形式で生成した下書きを消す — 残したままだと
            // 表示と «コピー» が選択中の形式と食い違う (cubic レビュー指摘)。
            // 生成中の切り替えも同様に止めて、結果を捨てる
            generationTask?.cancel()
            draft = nil
            failureText = nil
            failureDetail = nil
            hasCopied = false
        }
    }

    /// 生成済みの下書きの表示。件名はメールスタイルのときだけ (チャットは本文のみ)
    private func draftView(_ draft: FollowupDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let subject = draft.subject {
                        Text(subject)
                            .font(.body.bold())
                            .textSelection(.enabled)
                    }
                    Text(draft.body)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func generate() async {
        // 呼び出し側 (ボタン) は Task を generationTask に入れて保持する —
        // onDisappear / onChange(of: style) からのキャンセルのため
        isGenerating = true
        failureText = nil
        failureDetail = nil
        UsageAnalytics.followupStarted()
        let startedAt = Date()
        do {
            let generated = try await FollowupComposer.compose(
                summary: summary, title: title, style: style, license: license,
                instructions: instructions)
            draft = generated
            hasCopied = false
            UsageAnalytics.followupCompleted(
                processingTime: Date().timeIntervalSince(startedAt))
        } catch is CancellationError {
            // シートを閉じた・付け替えた場合は失敗に数えない (summary_* と同じ方針)
        } catch {
            failureText = String(localized: "下書きを生成できませんでした")
            failureDetail = String(describing: error)
            UsageAnalytics.followupFailed(
                error, processingTime: Date().timeIntervalSince(startedAt))
        }
        isGenerating = false
    }

    /// 下書きをペーストボードへコピーする。全文 (件名 + 本文) を 1 テキストとして
    /// 置く (FollowupDraftSupport.clipboardText の契約)
    private func copy(_ draft: FollowupDraft) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            FollowupDraftSupport.clipboardText(for: draft), forType: .string)
        hasCopied = true
    }
}
