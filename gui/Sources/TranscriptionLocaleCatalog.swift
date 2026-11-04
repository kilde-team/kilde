import Foundation
import Combine
import KildeCore

/// SpeechTranscriber の対応ロケールの一覧 (issue #486)。
///
/// 言語 Picker は ja-JP / en-US の固定 2 言語だったため、端末言語が SpeechTranscriber
/// 非対応の利用者 (GA4 の unsupported_locale 3 件 — issue #478 コメント) には
/// 対応言語を選ぶ導線が無かった。ここで実環境の対応ロケール
/// (`Transcriber.supportedLocales`) と言語モデルの取得状況
/// (`Transcriber.installedLocales`) を取り寄せ、Settings の Picker と警告文に供給する。
///
/// 取り寄せは macOS 26 以降の Speech API を叩くが、どちらもこの端末のローカル照会で
/// ネットワーク送信は無い。ロードは Settings を開いたとき (onAppear) と、
/// アプリが active に戻ったときに走らせる (refresh — 下のコメント参照)。
/// ウィンドウは openSettings が再利用する (閉じても解放しない) ので、StateObject も
/// アプリ生存中の 1 インスタンスで済む。
///
/// **@MainActor で隔離する理由**: @Published を SwiftUI が購読するため、API 呼び出し
/// (await) の後に来る状態更新をメインアクターに固定する — 非隔離のまま Task を作ると
/// バックグラウンド publish になり、設定画面の更新が不定になる (cubic / CodeRabbit
/// レビュー指摘)。呼び出し側 (SettingsPaneView の onAppear / onReceive) は
/// いずれもメインアクター上にある
@MainActor
final class TranscriptionLocaleCatalog: ObservableObject {
    struct Entry: Identifiable, Hashable {
        /// 正規化済み BCP 47 (エンジン `supportedLocales` の戻り値と同じ形。小文字、
        /// 例 «ja-jp»)。\ **config.json の保存値はこの形とは限らない** («ja-JP» の実績) —
        /// 表示の選択一致は SettingsPaneView.localeSelection が正規化して写す。
        /// **id を正規化形に統一する理由**: 優先表示 (ja-JP / en-US の定数) を
        /// mixed case のまま id にすると、正規化の supported 一覧と重複し、
        /// installedSet (正規化) の照合も外れるため
        let id: String
        /// «日本語 (ja-JP)» 形の表示ラベル (端末の言語でローカライズ、識別子は正準形)
        let label: String
        /// 言語モデルの取得済みフラグ。未取得のときは文字起こし実行時に
        /// installModelAsset の取得が走る (TranscriptionCoordinator) ので、
        /// «初回はダウンロードがある» の案内として未取得表示に使う
        let installed: Bool
    }

    /// ja-JP / en-US を対応一覧の先頭に出す (従来 Picker の固定 2 言語を優先表示として
    /// 踏襲)。**対応一覧に無いときは出さない** — 非対応言語の選択肢を固定で出すと、
    /// 選んだだけで unsupported_locale で落ちる罠を再び作るため
    private static let preferredIdentifiers = ["ja-JP", "en-US"]

    @Published private(set) var entries: [Entry] = []
    /// 端末ロケール (正規化形)。«端末の言語設定» の非対応警告の表示に使う
    @Published private(set) var deviceLocaleIdentifier = ""
    /// 端末ロケールが SpeechTranscriber の対応一覧に載るか。既定 true は
    /// «未ロードの間は警告を出さない» ため (ロードはローカル照会で瞬時に済むが、
    /// 未ロード状態で誤警告を出すより出さない方がよい)
    @Published private(set) var deviceLocaleSupported = true
    @Published private(set) var loaded = false

    private var refreshTask: Task<Void, Never>?

    /// Settings 表示時の取り寄せ。**毎回呼んでよい** — 初回は一覧を組み立て、
    /// 以降は installed フラグと一覧の再取得になる (2 つ目以降の呼び出しは
    /// 実行中タスクがあれば何もしない)。毎回取り直す理由: 文字起こしの実行で
    /// 言語モデルを取得したあとに «未取得» 表示が残ると誤案内になるため
    /// (cubic レビュー指摘)。ウィンドウは再利用され onAppear が再実行されない
    /// ことがあるため、didBecomeActive からも呼ぶ
    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.load()
            self?.refreshTask = nil
        }
    }

    /// 一覧の組み立てと再取得。失敗しても Picker を壊さない (entries は空のまま
    /// «端末 / 自動 / 手編集値» の従来形で動く — 機能の後退ではなく、動的列挙が
    /// 付かないだけに倒す)
    private func load() async {
        // transcriptionAvailable のゲート (RecordingSetup) を通った呼び出しが前提。
        // 非対応環境では何もしない — 非対応の案内は既存の
        // transcriptionUnsupportedReason が担う (役割を二重にしない)
        guard Transcriber.isSupported else { return }
        let supported = await Transcriber.supportedLocales()
        let installed = await Transcriber.installedLocales()
        let device = Transcriber.normalizedBCP47(Locale.current.identifier(.bcp47))
        let installedSet = Set(installed.map { Transcriber.normalizedBCP47($0) })
        var out: [Entry] = []
        var seen = Set<String>()
        // supported の要素は正規化形 (小文字) のため、優先表示の照合も正規化して行う
        // (mixed case の «ja-JP» をそのまま contains すると必ず false になり、
        // 優先表示が効かなくなる)。**id も正規化形で入れる** — mixed case の id を
        // 入れると supported (正規化) と重複し、installedSet (正規化) の照合も外れる
        for identifier in Self.preferredIdentifiers {
            let normalized = Transcriber.normalizedBCP47(identifier)
            guard supported.contains(normalized) else { continue }
            seen.insert(normalized)
            out.append(Entry(
                id: normalized,
                label: Self.label(for: normalized),
                installed: installedSet.contains(normalized)))
        }
        // 残りはローカライズ名の辞書順。localizedStandardCompare は «数値・記号の
        // 並びも読みやすい順» に揃える Finder 系の比較。**両辺を label にする** —
        // 片側を生の識別子にすると ASCII 由来の順序で並び、ラベルの辞書順にならない
        let rest = supported.filter { !seen.contains($0) }.sorted {
            Self.label(for: $0).localizedStandardCompare(Self.label(for: $1)) == .orderedAscending
        }
        for identifier in rest {
            out.append(Entry(
                id: identifier,
                label: Self.label(for: identifier),
                installed: installedSet.contains(identifier)))
        }
        entries = out
        deviceLocaleIdentifier = device
        // 空の一覧は «照会結果なし» として «対応» 扱いにする — 実行時判定
        // (TranscriptionCoordinator.isLocaleSupported) と同じ折り方。片側だけが
        // 非対応と判定すると、UI は «録音から判定» へのフォールバックを案内するのに
        // 実行時は通常の端末ロケール経路になり、利用者を誤誘導する (cubic レビュー指摘)
        deviceLocaleSupported = supported.isEmpty || supported.contains(device)
        loaded = true
    }

    /// «日本語 (ja-JP)» 形のラベル。識別子は正準形 («ja-JP» — Locale の canonical
    /// identifier は underscore 形で返るため dash に戻す) で、ローカライズ名が
    /// 取れない識別子は生値を出す (NSLocale.displayName は BCP 47 の大小・
    /// underscore のゆらぎを吸収する)。**tag は正規化形 (id) のまま** —
    /// 表示だけ Apple 風の大小にする
    static func label(for normalizedIdentifier: String) -> String {
        let canonical = displayIdentifier(normalizedIdentifier)
        let name = (Locale.current as NSLocale)
            .displayName(forKey: .identifier, value: canonical) ?? canonical
        return "\(name) (\(canonical))"
    }

    /// 正規化形 («ja-jp») から正準形 («ja-JP») を復元する
    static func displayIdentifier(_ normalizedIdentifier: String) -> String {
        Locale(identifier: normalizedIdentifier).identifier
            .replacingOccurrences(of: "_", with: "-")
    }

    /// 指定値 (手編集 config.json の値を含む) が動的一覧に正規化のうえ含まれるか。
    /// 含まれない値は Picker の «カスタム枠» に生値のまま出して選択を壊さない
    /// (既存契約 «手編集値も選択肢に出す» を踏襲)
    func containsNormalized(_ identifier: String) -> Bool {
        entries.contains { $0.id == Transcriber.normalizedBCP47(identifier) }
    }

    /// 選択値に応じた警告文 (nil = 警告なし)。**表示のみ**で挙動は変えない —
    /// «端末の言語設定» 非対応時の実行時フォールバックは TranscriptionCoordinator 側
    /// (issue #486) が担う。ロード前は nil (誤警告の出ない側に倒す)
    func selectionWarning(for selected: String?) -> String? {
        guard loaded else { return nil }
        if selected == nil {
            // «端末の言語設定»。非対応のときは実行時に録音からの判定へフォールバック
            // する (TranscriptionCoordinator) — その挙動をここで案内する
            if !deviceLocaleSupported {
                return "この Mac の言語 (\(deviceLocaleIdentifier)) は文字起こしに対応していません。«端末の言語設定» のときは録音から言語を判定します (判定できないときは文字起こししません)"
            }
            return nil
        }
        if selected?.lowercased() == "auto" { return nil }
        // «自動» 以外の明示選択が対応一覧に無い (手編集値が非対応の可能性)。
        // 実行時は modelAssetStatus の .unsupported で落ちるため、ここで先に気づけるようにする
        if let selected, !containsNormalized(selected) {
            return "選択中の言語 (\(selected)) はこの環境の文字起こしに対応していない可能性があります。別の言語を選んでください"
        }
        return nil
    }
}
