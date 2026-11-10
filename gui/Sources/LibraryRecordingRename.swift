import Foundation

/// ライブラリから録画の «名前を変更» する整理の導線 (issue #532) のデータ層。
/// UI (LibraryWindow.swift) とセルフテスト (SelfTestLibraryRename) から使う。
///
/// **リネーム後の名前も «kilde-» 接頭辞を保つ** (libraryStem のコメント参照) —
/// ライブラリの一覧 («kilde- 接頭辞 + 録画形式» の契約) から録画が消えない
/// ようにするため。UI は libraryStem で «入力 → 接頭辞付きの最終 stem» を
/// 組んでから rename へ渡し、rename 自体は stem に中立 (セルフテストから
/// 直接呼べる素の形)。
///
/// «録画だけ変えると文字起こしが外れる» を避けるため、リネームの対象は
/// **録画ファイル + 同じ stem の関連ファイル一式** (0.36.0 のゴミ箱移動 —
/// `LibraryRecordingCleanup.companionFiles` — と同じ «この録画のもの» の収集規則)。
/// «変えすぎない» を守るため、**録画本体が変えられなかったときは何も変えずに
/// throw して戻す** — «本体は新しい名前なのにサイドカーだけ旧名» を最小化する。
/// さらに **移動先の全冲突突を事前に検査し**、衝突があるときは何も変えない —
/// «上書きで別の録画が消える» «文字起こしが別の録画に付け替わる» を作らない。
///
/// UI 側 (LibraryView) は @MainActor だが、この enum は LibraryRecordingCleanup と
/// 同じ «グローバルアクター推論の無い» 素の enum でよい — 中身は引数と
/// ファイルシステムだけで決まり、UI の状態に触れない
enum LibraryRecordingRename {

    /// リネームの失敗。UI は «入力の問題» (invalidName / nameUnchanged) と
    /// «フォルダ・権限の問題» (conflict / directoryUnreadable / その他) を
    /// 区別して案内する — «なぜ変えられないか» が読めない案内は
    /// «黙って失敗しない» の受け入れ条件を満たさない
    enum RenameError: Error, Equatable {
        /// 名前として使えない (空・パス区切り・先頭のドット・255 バイト超)
        case invalidName
        /// 現在の名前と同じ (何もしない)
        case nameUnchanged
        /// 移動先の stem が既存ファイル (対象以外) と衝突している。
        /// 何も変えずに戻る
        case conflict
        /// 保存先フォルダの走査に失敗した (何も変えずに戻る)
        case directoryUnreadable
    }

    /// リネーム 1 件の実行者。`FileManager.moveItem` の差し替えポイント —
    /// セルフテストは **実環境を汚さない** よう、動きだけを模した実装を注入する
    /// (失敗を特定のファイルにだけ起こす注入も、«一部失敗の leftovers» の検証に使う)。
    /// 引数は (現 URL, 移動先 URL)
    typealias Renamer = (URL, URL) throws -> Void

    /// 既定のリネーム (同じディレクトリ内の moveItem = rename システムコール)。
    /// サンドボックス下でも、アプリに書き込み権限のあるファイル
    /// (~/Movies は `movies.read-write`、カスタム保存先は security-scoped
    /// bookmark の有効中) なら同じディレクトリ内の移動はできる。
    /// 権限が無い・ネットワークボリューム等で失敗したときは throw し、
    /// 呼び出し側が «Finder で変更してください» の案内を出す (黙って失敗しない)
    static let systemRenamer: Renamer = { source, destination in
        try FileManager.default.moveItem(at: source, to: destination)
    }

    /// ダイアログの入力を «stem として使える名前» に検証する。
    /// 前後の空白は除いてから判定する («会議メモ と入力した» を «会議メモ» として
    /// 受ける。Finder のリネームも前後空白はそのまま残るが、入力ミスを
    /// エラーにしないための緩め方)。
    /// 拒否するもの:
    /// - 空 (空白のみを含む) — stem の無いファイルは作れない
    /// - パス区切り `/` と `:` — `/` は POSIX の区切り、`:` は Finder が
    ///   リネームに受け付けない旧 Mac OS の区切り (表示が崩れる)
    /// - 先頭が `.` — 隠しファイルになって一覧 (skipsHiddenFiles) から消える
    /// - `.` と `..` — パスの意味を持つ名前
    /// - UTF-8 で 255 バイト超 — ファイルシステムの 1 要素の上限
    /// - 現在の stem と同じ — 変更でないので何もしない (nameUnchanged)
    ///
    /// 拡張子はここでは見ない — 呼び出し側が «入力 = stem» の契約で渡し、
    /// 拡張子は元の録画のものをそのまま使う (対応規則は LibraryStore.scan と同じ)。
    /// **ライブラリの «kilde-» 接頭辞はここでは扱わない** — «入力 = 最終 stem»
    /// で渡す経路 (セルフテストの直接呼び出し) と «入力 = ユーザーの見た名前»
    /// で渡す経路 (UI の libraryStem) の両方から使える素の検証として分けてある
    static func validatedStem(from name: String, currentStem: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RenameError.invalidName }
        guard !trimmed.contains("/") && !trimmed.contains(":") else {
            throw RenameError.invalidName
        }
        guard !trimmed.hasPrefix(".") else { throw RenameError.invalidName }
        guard trimmed != "." && trimmed != ".." else { throw RenameError.invalidName }
        guard trimmed.utf8.count <= 255 else { throw RenameError.invalidName }
        guard trimmed != currentStem else { throw RenameError.nameUnchanged }
        return trimmed
    }

    /// UI (入力ダイアログ) の入力から **ライブラリに載る stem** を組み立てる。
    ///
    /// ライブラリの一覧対象は «kilde- 接頭辞 + 録画形式の拡張子» という契約
    /// (LibraryStore.scan と «最近の録画» の RecordingSetup.reloadRecentRecordings —
    /// 保存先の ~/Movies にはユーザー自身の動画も眠るため、kilde の産物だけを
    /// 見るための絞り込み)。**接頭辞を外した stem にリネームすると、一覧・
    /// 最近の録画・Spotlight からその録画が消える** ので、リネーム後の名前も
    /// 必ず `kilde-` で始める。取り込み (issue #416) が
    /// `kilde-<時刻>-<元の stem>` の形に整えるのと同じ «接頭辞はライブラリの
    /// 家紋» の扱い。
    ///
    /// 入力欄には現在の名前 (接頭辞ごと) を満たしておくため、変換は
    /// «入力の先頭の `kilde-` を 1 回だけ剥がす → 素の検証 → `kilde-` を
    /// 付け直す» の 3 段。«1 回だけ» 剥がしてから付け直すのは、
    /// «接頭辞付きで入力した名前» («kilde-会議» と自分で打った場合) を
    /// 打ったとおりの名前に整えるため — 付け直しで «kilde-kilde-会議» に
    /// 増やさない («接頭辞を 2 つ望む» 入力は 1 つに整う)。
    /// unchanged の比較は «剥がした後» の名前同士で行う — «kilde-a» を
    /// «a» と入力し直しても «同じ名前» として何もしない
    static func libraryStem(fromUserInput input: String, currentStem: String) throws -> String {
        let prefix = "kilde-"
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let userPart = trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed
        let currentPart = currentStem.hasPrefix(prefix)
            ? String(currentStem.dropFirst(prefix.count)) : currentStem
        let stem = try validatedStem(from: userPart, currentStem: currentPart)
        let composed = prefix + stem
        // 長さの上限は **合成後の stem** で判定し直す — ファイルシステムの
        // 255 バイト制限は «1 要素全体» に掛かるため、«ユーザー部分 255 バイト»
        // を通すと «kilde-» を付けた瞬間に 261 バイトで moveItem が落ちる
        guard composed.utf8.count <= 255 else { throw RenameError.invalidName }
        return composed
    }

    /// 録画と伴走ファイルを同じ新しい stem へリネームする。
    ///
    /// 手順は **事前の全冲突突検査 → 録画本体 → 伴走** の順。
    /// 1. 保存先ディレクトリを走査し、対象以外の既存ファイル (拡張子を問わず) の
    ///    stem が «移動先の stem 系» (新しい名前 + 枝番の付け替え後の `-数字`) と
    ///    衝突したら `conflict` を投げる。走査自体が失敗したら
    ///    `directoryUnreadable` を投げる。**この時点では何も変えていない**
    ///    — «衝突で録画だけ新しい名前» を作らない
    /// 2. 録画本体をリネーム。失敗したら何も伴走に触らず throw
    ///    («本体が残ってサイドカーだけ新しい名前» を作らない — ゴミ箱移動と
    ///    同じ «本体を最初に» の契約)
    /// 3. 伴走ファイルを順にリネーム。1 件の失敗で打ち切らず最後まで試す —
    ///    «どこまで変わったか» より «残ったものを案内する» を優先する
    ///    (ゴミ箱移動の leftovers と同じ判断)
    ///
    /// 伴走の枝番 (`stem-2.json` ↔ `stem-2`) は枝番を保って
    /// `新しい名前-2.json` へ移る — 枝番は «退避・二重録画» の区別子なので
    /// 潰すと次の文字起こしの退避先と衝突しうる
    ///
    /// - Returns: リネームできなかった伴走ファイル (空配列 = 全件完了)。
    ///   録画本体の失敗は throw で返るため、戻り値に録画本体は含まれない
    static func rename(
        recording: URL, companionFiles: [URL], newStem: String, renamer: Renamer
    ) throws -> [URL] {
        let directory = recording.deletingLastPathComponent()
        let oldStem = recording.deletingPathExtension().lastPathComponent
        // «対象の現 URL» の集合 — 衝突検査と «移動先の stem 集合» の計算で
        // «自分自身» を除外するのに使う。symlink 解決で比べるのは
        // LibraryRecordingCleanup.isSameFile と同じ理由 (temporaryDirectory の
        // /var ↔ /private/var の表記ゆれ)
        let sources = [recording] + companionFiles

        // 移動先の stem 系。録画本体は newStem、伴走は «旧 stem からの差分» を
        // 保って付け替える (stem / stem-数字)。exact-stem と枝番だけが
        // companionFiles の対応なので、suffix は «""» か «"-数字»» しか来ない
        let destinationStems = Set(sources.map { source -> String in
            let sourceStem = source.deletingPathExtension().lastPathComponent
            if sourceStem == oldStem { return newStem }
            return newStem + sourceStem.dropFirst(oldStem.count)
        })

        // 事前の衝突検査。既存ファイル (対象以外、隠しファイルを含む — «衝突しうる
        // 名前» は隠し分も数えないと moveItem が後で失敗する) の stem が
        // 移動先と重なったら中断する。拡張子は見ない — «会議.mov がある» 状態で
        // «会議.mp4» へのリネームを通すと、対応規則 (RecordingSetup.transcriptSidecar)
        // が «同じ stem の 2 録画» を作り、サイドカーの持ち主があいまいになる
        let all: [URL]
        do {
            all = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                options: [])
        } catch {
            // 生の NSError を «その他の失敗» に畳むと «Finder で変更してください»
            // の案内に化ける (フォルダの消失は原因が違う) — CleanupError への
            // 畳み替えと同じ理由 (issue #525 の PR #526 レビュー)
            throw RenameError.directoryUnreadable
        }
        for url in all where !sources.contains(where: { isSameFile(url, $0) }) {
            let stem = url.deletingPathExtension().lastPathComponent
            if destinationStems.contains(stem) { throw RenameError.conflict }
        }

        // 録画本体を最初に — 失敗したら何も変えずに呼び出し側へ返す
        let recordingExtension = recording.pathExtension
        try renamer(recording, directory.appendingPathComponent(
            newStem + (recordingExtension.isEmpty ? "" : ".\(recordingExtension)")))

        // 伴走は打ち切らず最後まで試す — 失敗したものは旧名のまま残す
        var leftovers: [URL] = []
        for companion in companionFiles {
            let stem = companion.deletingPathExtension().lastPathComponent
            let suffix = stem.dropFirst(oldStem.count)  // «""» か «"-数字»»
            let extensionPart = companion.pathExtension
            let destination = directory.appendingPathComponent(
                newStem + suffix
                    + (extensionPart.isEmpty ? "" : ".\(extensionPart)"))
            do {
                try renamer(companion, destination)
            } catch {
                leftovers.append(companion)
            }
        }
        return leftovers
    }

    /// 2 つの URL が同じファイルを指すか。**symlink を解決してから比べる** —
    /// temporaryDirectory (`/var/folders/…`) と contentsOfDirectory の返す表記
    /// (`/private/var/folders/…`) は URL 同士の等価で false になる
    /// (LibraryRecordingCleanup.isSameFile と同じ正規化)
    static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
