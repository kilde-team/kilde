import AppKit
import Foundation
import KildeCore
import UniformTypeIdentifiers

/// 既存の音声・動画ファイルの取り込み (issue #416) のファイル操作部分。
/// UI の状態 (コピー中の表示など) は LibraryImportCoordinator、
/// UI 無しの検証は SelfTestLibraryImport が担う
enum LibraryImport {

    /// 取り込み対象の拡張子 (小文字)。エンジンが録る形式 (mov / mp4 / m4a) に
    /// 取り込みで増える音声形式を足した集合。**LibraryStore.recordingExtensions
    /// (ライブラリと «最近の録画» の一覧の判定) と同じ集合にする** — 片方だけ
    /// 足すと «取り込んだのに一覧に出ない» になる
    static let importableExtensions: Set<String> = [
        "mov", "mp4", "m4v", "m4a", "mp3", "wav", "aif", "aiff", "caf", "aac",
    ]

    /// 取り込めるファイルか (拡張子で判定)。ドロップは任意の型が来うるので、
    /// NSOpenPanel の allowedContentTypes と同じ基準でここでも弾く
    static func isImportable(_ url: URL) -> Bool {
        importableExtensions.contains(url.pathExtension.lowercased())
    }

    /// ライブラリまわりで URL を載せ替えるときの正規形 (symlink 解決 + 標準化)。
    /// **取り込みの戻り値と一覧 (LibraryStore.scan) の entry.id を同じ形に揈える**
    /// ために両方が使う — 揃えないと、保存先のパスに symlink が含まれる環境
    /// (`/var/folders/…` と `/private/var/folders/…` のような表記の揺れ) で
    /// «コピーは成功したのに一覧の選択・処理中表示が一致しない» になる。
    /// URL.resolvingSymlinksInPath は /private を縮める方向にも働く
    /// (システムディレクトリの特殊扱い) ため、両側を通すことで初めて一致する
    static func canonicalFileURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// ファイル名の接尾辞 (題名) として安全な形に整える。エンジンの
    /// RecordRequest.sanitizedTitleSuffix と同じ意図だが、あちらは internal で
    /// GUI から呼べないため、ここでは «入力が既にファイル名» (パス区切り・NUL を
    /// 含まない) であることを前提にした最小限の整えに留める:
    /// - 前後の空白・`.`・`-` を (混ざって連なっていても) 残らなくなるまで落とす
    ///   (先頭の `.` は Finder で不可視ファイルになる)
    /// - グラフェム 60 文字かつ **UTF-8 200 バイト** の上限で切り詰める (グラフェム
    ///   単位 — 結合文字の途中で切らない。ファイル名の上限 255 バイトに対し、接頭辞
    ///   `kilde-yyyyMMdd-HHmmss-` (22 バイト)・拡張子・退避の `-2` の余裕を残す。
    ///   バイト上限は絵文字など 1 文字が 4 バイトになる名前のため — 文字数だけの
    ///   上限では 255 バイトを超えてコピーに失敗する)
    /// - 整えた結果が空のときは «ファイル» を当てる (ファイル名だけでは題名が
    ///   取れないケース — 取り込み自体は妨げない)
    static func sanitizedStem(_ raw: String) -> String {
        let edges = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ".-"))
        var stem = raw
        while true {
            let trimmed = stem.trimmingCharacters(in: edges)
            if trimmed == stem { break }
            stem = trimmed
        }
        if stem.count > 60 || stem.utf8.count > 200 {
            var clipped = ""
            for grapheme in stem {
                let candidate = clipped + String(grapheme)
                if candidate.count > 60 || candidate.utf8.count > 200 { break }
                clipped = candidate
            }
            stem = clipped
            // 切り詰めで末尾が `.` / `-` に終わることがある (切った位置による) ので
            // もう一度両端を整える
            while true {
                let trimmed = stem.trimmingCharacters(in: edges)
                if trimmed == stem { break }
                stem = trimmed
            }
        }
        return stem.isEmpty ? String(localized: "ファイル") : stem
    }

    /// コピー先のファイル名 `kilde-<yyyyMMdd-HHmmss>-<元の stem>.<拡張子>` を組む。
    /// 接頭辞・時刻の形式はカレンダー連携 (issue #393) が付ける «題名つき既定名» と
    /// 同じ体裁に乗せる — これにより録ったファイルと同じ規則で
    /// ライブラリの日時解析 (LibraryStore.recordedAt) と議事録見出しの題名復元
    /// (TranscriptionCoordinator.meetingTitle) がそのまま働く。
    /// ディレクトリは canonicalFileURL で正規化する — 一覧の走査
    /// (FileManager.contentsOfDirectory) は symlink 祖先を解決した実パス表記を
    /// 返すため、戻り値 (取り込み直後の選択・処理中表示の id) と揃えるのに必要
    static func destinationURL(for source: URL, in directory: URL, at date: Date) -> URL {
        let directory = canonicalFileURL(directory)
        let formatter = DateFormatter()
        // 既定名のタイムスタンプはローカライズされない数値列 (CLI の defaultOutputName
        // と同じ) なので、環境の言語・時差に依存させない
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = sanitizedStem(source.deletingPathExtension().lastPathComponent)
        let name = "kilde-\(formatter.string(from: date))-\(stem).\(source.pathExtension)"
        return directory.appendingPathComponent(name)
    }

    /// 取り込み 1 件の本体。戻り値は «文字起こしの対象にする URL» (canonicalFileURL
    /// の正規形) — 新しくコピーした先、既に取り込んであったファイル、または元の
    /// ファイル (保存先内のとき)。throws はコピーの失敗 (読み取り不能・書き込み先の
    /// 障害など)
    ///
    /// 判定の順序:
    /// 1. **元のファイルが保存先直下の kilde- ファイル** ならコピーしない — 既に
    ///    ライブラリの対象 (録画をもう一度文字起こすときの経路。コピーすると
    ///    二重管理になる)。kilde- 接頭辞の無いファイルは一覧に出ないため、
    ///    通常のコピー経路で題名つきのコピーを作る
    /// 2. **同一ファイルを既に取り込んでいる** ならそれを返す (下の existingImport)
    /// 3. コピー先を組んでコピーする。**一時ファイルに書いてから rename する** —
    ///    容量不足などでコピーが途中で切れたときに壊れた `kilde-…` が保存先に
    ///    残り、ライブラリに «文字起こしできない録画» として出てしまうのを防ぐため
    ///    (TranscriptWriter の «最後に 1 回だけ原子的に書く» と同じ考え)。rename は
    ///    同じボリューム内なので置き換えは起こらない。同名の別ファイルがあるときは
    ///    `-2`, `-3`… と退避する (TranscriptWriter のサイドカーと同じ規則)
    static func performImport(of source: URL, into directory: URL, at date: Date = Date()) throws -> URL {
        // path 文字列で比べるのは TranscriptionCoordinator.directoryBookmarkData と同じ —
        // symlink 解決 (サンドボックスのコンテナ内 Movies が実 ~/Movies への symlink に
        // なりうる) を先にしてから標準化する
        let sourceDirectory = source.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path
        let destinationDirectory = directory
            .resolvingSymlinksInPath().standardizedFileURL.path
        if sourceDirectory == destinationDirectory,
           source.lastPathComponent.hasPrefix("kilde-") {
            // 戻り値も一覧の id と揃える (canonicalFileURL と同じ正規形)
            return Self.canonicalFileURL(source)
        }
        if let existing = existingImport(of: source, in: directory) { return existing }

        let directory = canonicalFileURL(directory)
        let preferred = destinationURL(for: source, in: directory, at: date)
        // 一時名はドット始まりで非表示にする (ライブラリ・最近の録画の走査は
        // skipsHiddenFiles なので、書き込み中の断片が一覧に露出しない)
        let temporary = directory.appendingPathComponent(
            ".kilde-import-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
        } catch {
            // 失敗したときの断片を残さない (copyItem は失敗時に残すことがある)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        // rename の宛先が競ったら (この隙間に同名ファイルができたら) 次の退避番号へ。
        // 競合以外の失敗 (権限・ボリューム障害) で退避を試みても成功しないので、
        // その場合は断片を掃って元のエラーを投げる
        var destination = uniquifiedURL(preferred)
        while true {
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
                return destination
            } catch {
                guard FileManager.default.fileExists(atPath: destination.path),
                      let next = nextEvacuatedURL(after: destination) else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw error
                }
                destination = next
            }
        }
    }

    /// 退避番号つき URL の次の候補 (`…-2.m4a` → `…-3.m4a`)。番号が 999 を超えたら
    /// nil (異常な状態 — これ以上の退避は諦める)
    private static func nextEvacuatedURL(after url: URL) -> URL? {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        guard let hyphen = stem.lastIndex(of: "-"),
              let index = Int(stem[stem.index(after: hyphen)...]), index < 999 else { return nil }
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(stem[..<hyphen])-\(index + 1).\(ext)")
    }

    /// `path` にファイルが既にあれば `-2`, `-3`… を付けた候補を返す (コピーはしない)。
    /// 退避の番号は TranscriptWriter のサイドカーと同じ形式
    private static func uniquifiedURL(_ url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for index in 2...999 {
            let candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(stem)-\(index).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    /// このファイルを既に取り込んでいるか。「同一」の判定は **元の stem と同じ題名
    /// 接尾辞を持ち、かつバイト数が一致する kilde- ファイル** — 取り込みに安定な ID
    /// (ハッシュ・ブックマーク) を残さないため、名前 + サイズの実用判定にする
    /// (取り込み済みかどうかは厳密には保証されない — 同じ題名・同じ容量の別ファイル
    /// は既存の取り込みと見なされる。UI の文言はこの条件を明示して述べる)。
    /// 題名が同じでも内容が変わった (サイズが違う) ファイルは別ファイルとして
    /// 再取り込みする。
    /// 戻り値は canonicalFileURL の正規形 (performImport の戻り値として使うため)
    static func existingImport(of source: URL, in directory: URL) -> URL? {
        let stem = sanitizedStem(source.deletingPathExtension().lastPathComponent)
        let ext = source.pathExtension.lowercased()
        guard let size = fileSize(of: source) else { return nil }
        let candidates = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        let matches = candidates
            .compactMap { url -> (url: URL, suffix: (raw: String, stripped: String))? in
                guard url.pathExtension.lowercased() == ext,
                      fileSize(of: url) == size,
                      let suffix = Self.titleSuffix(ofImport: url) else { return nil }
                return (url, suffix)
            }
        // 照合は 2 段階 (cubic 指摘)。`report-2.m4a` のような数字で終わる元の名前では、
        // 取り込み名 `kilde-…-report-2` から退避番号を除くと `report` になって一致を
        // 失う — まず **題名部分の完全一致** を引き、無いときだけ «退避番号を除いた
        // 題名» との一致 (退避コピー `kilde-…-商談メモ-2` の再取り込み) を見る
        let matched: [(url: URL, suffix: (raw: String, stripped: String))]
        let exact = matches.filter { $0.suffix.raw == stem }
        if !exact.isEmpty {
            matched = exact
        } else {
            matched = matches.filter { $0.suffix.stripped == stem }
        }
        return matched
            .sorted {
                ((try? $0.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast)
                    > ((try? $1.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast)
            }
            .first
            .map { canonicalFileURL($0.url) }
    }

    /// 取り込みが作ったファイル名 `kilde-<時刻>-<題名>[-<退避番号>]` から題名部分を
    /// 取り出す。`kilde-` 接頭辞 + 15 文字の時刻 + 区切りの `-` が揃わない名前
    /// (録画の既定名・別名録画) は nil — 題名の比較対象にしない。
    /// 時刻部の検証は TranscriptionCoordinator.meetingTitle と同じ «数字の並び»
    /// による判別 (手作りの `kilde-別名` を題名扱いにしない)。
    /// raw は退避番号を含めた題名部分、stripped は末尾の `-<番号>` を除いたもの
    /// (existingImport の 2 段階照合に使う)
    static func titleSuffix(ofImport url: URL) -> (raw: String, stripped: String)? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("kilde-") else { return nil }
        var rest = stem.dropFirst("kilde-".count)
        guard rest.count > 16 else { return nil }
        let stamp = rest.prefix(15)
        let parts = stamp.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 8, parts[1].count == 6,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              rest[rest.index(rest.startIndex, offsetBy: 15)] == "-" else { return nil }
        rest = rest.dropFirst(16)
        let raw = String(rest)
        if let lastHyphen = rest.lastIndex(of: "-") {
            let maybeIndex = rest[rest.index(after: lastHyphen)...]
            if !maybeIndex.isEmpty, maybeIndex.allSatisfy(\.isNumber) {
                return (raw, String(rest[..<lastHyphen]))
            }
        }
        return (raw, raw)
    }

    private static func fileSize(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return nil }
        return values.fileSize.map(Int64.init)
    }
}

/// 取り込みの UI 状態の持ち主 (issue #416)。LibraryView が @StateObject で持つ —
/// ライブラリウィンドウは閉じても破棄されない (isReleasedWhenClosed=false) ので、
/// コピーの途中でウィンドウを閉じても処理は完了する
@MainActor
final class LibraryImportCoordinator: ObservableObject {

    /// ファイルのコピー中 (ステータス行の表示に使う)
    @Published private(set) var isImporting = false
    /// 直近の取り込みのコピー先ディレクトリ。完了後の再走査が «今の保存先« を
    /// 見ているかの確認に使う (LibraryView.finishImport)
    @Published private(set) var importedDirectory: URL?
    /// 取り込みの結果の案内 (対応外の形式・コピーの失敗)。nil は «案内なし»。
    /// 失敗は文字起こしキューとは独立に起きる (コピーできないものは文字起こしも
    /// できない) ので、パネルの失敗表示には載せずステータス行に置く
    @Published private(set) var lastNotice: String?

    /// 取り込むファイル列。コピーは MainActor を塞がない場所で行う (GB 級の
    /// 動画のコピーに秒がかかるため)。取り込み済みの URL を 1 件ごとに
    /// onImported へ、全体の終了を onComplete へ返す (どちらも MainActor で呼ぶ)
    func importFiles(
        _ urls: [URL], into directory: URL?,
        onImported: @escaping (URL) -> Void,
        onComplete: @escaping () -> Void) {
        guard let directory else { return }
        // 文字起こしが使えない環境では取り込み全体をしない — 取り込みの目的が
        // 文字起こしであるため (設定パネルの «録画後に文字起こし» と同じ案内)。
        // ボタンは disabled だがドロップは UI を介さず届くので、ここで統一して弾く
        guard Transcriber.isSupported else {
            lastNotice = String(localized: "文字起こしは macOS 26 以降で利用できます")
            return
        }
        let importable = urls.filter(LibraryImport.isImportable)
        let skipped = urls.filter { !LibraryImport.isImportable($0) }
        guard !importable.isEmpty else {
            if !skipped.isEmpty {
                lastNotice = String(localized: "対応していない形式です: \(skipped.map(\.lastPathComponent).joined(separator: ", "))")
            }
            return
        }
        guard !isImporting else { return }
        isImporting = true
        importedDirectory = directory
        if !skipped.isEmpty {
            lastNotice = String(localized: "対応していない形式は除きました: \(skipped.map(\.lastPathComponent).joined(separator: ", "))")
        }
        let work = Task.detached { () -> ([URL], [String]) in
            var imported: [URL] = []
            var failed: [String] = []
            for url in importable {
                do {
                    imported.append(try LibraryImport.performImport(of: url, into: directory))
                } catch {
                    failed.append(url.lastPathComponent)
                }
            }
            return (imported, failed)
        }
        Task { [weak self] in
            let (imported, failed) = await work.value
            guard let self else { return }
            self.isImporting = false
            if !failed.isEmpty {
                self.lastNotice = String(
                    localized: "取り込めませんでした: \(failed.joined(separator: ", "))")
            }
            for url in imported {
                onImported(url)
            }
            onComplete()
        }
    }

    /// ライブラリウィンドウへのドロップを受け取る。NSItemProvider はファイル URL
    /// を非同期 (かつ提供元により別スレッド) で返すため、収集は 1 つのシリアル
    /// キューで直列化する。全部揃ってから importFiles に渡す — 1 件ずつ渡すと
    /// コピーの完了通知がドロップの件数分出る。ドロップは何でも来うるので、
    /// ここでは受け付けたことを返し、対応外の判定は importFiles に任せる。
    /// **URL を取得できなかった provider は黙って捨てない** — 1 件も取得できなかった
    /// ときはステータス行に案内を出す (cubic 指摘。全部の取得に失敗すると何も
    /// 起こらないように見える)
    func handleDrop(_ providers: [NSItemProvider], into directory: URL?,
                    onImported: @escaping (URL) -> Void,
                    onComplete: @escaping () -> Void) -> Bool {
        guard !providers.isEmpty else { return false }
        let collectQueue = DispatchQueue(label: "kilde.library-import.drop")
        var urls: [URL] = []
        var failedCount = 0
        var pending = providers.count
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                // macOS のドラッグはファイル URL を Data (書き出し文字列) でも URL でも
                // 渡してくる (提供元による) ので両方を受け付ける
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsurl = item as? URL {
                    url = nsurl
                }
                collectQueue.async {
                    if let url {
                        urls.append(url)
                    } else {
                        failedCount += 1
                    }
                    pending -= 1
                    guard pending == 0 else { return }
                    let collected = urls
                    let failed = failedCount
                    Task { @MainActor in
                        if collected.isEmpty {
                            if failed > 0 {
                                self.lastNotice = String(
                                    localized: "ドロップされたファイルを読み込めませんでした")
                            }
                            return
                        }
                        self.importFiles(collected, into: directory,
                                         onImported: onImported, onComplete: onComplete)
                    }
                }
            }
        }
        return true
    }
}
