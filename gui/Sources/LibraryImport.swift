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

    /// ファイル名の接尾辞 (題名) として安全な形に整える。エンジンの
    /// RecordRequest.sanitizedTitleSuffix と同じ意図だが、あちらは internal で
    /// GUI から呼べないため、ここでは «入力が既にファイル名» (パス区切り・NUL を
    /// 含まない) であることを前提にした最小限の整えに留める:
    /// - 前後の空白・`.`・`-` を (混ざって連なっていても) 残らなくなるまで落とす
    ///   (先頭の `.` は Finder で不可視ファイルになる)
    /// - 上限 60 文字 (グラフェム単位で切り詰める — 結合文字の途中で切らないため)。
    ///   ファイル名の上限 255 バイト (UTF-8) に対し、接頭辞 `kilde-yyyyMMdd-HHmmss-`
    ///   (22 バイト)・拡張子・退避の `-2` の余裕を残す
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
        if stem.count > 60 { stem = String(stem.prefix(60)) }
        return stem.isEmpty ? String(localized: "ファイル") : stem
    }

    /// コピー先のファイル名 `kilde-<yyyyMMdd-HHmmss>-<元の stem>.<拡張子>` を組む。
    /// 接頭辞・時刻の形式はカレンダー連携 (issue #393) が付ける «題名つき既定名» と
    /// 同じ体裁に乗せる — これにより録ったファイルと同じ規則で
    /// ライブラリの日時解析 (LibraryStore.recordedAt) と議事録見出しの題名復元
    /// (TranscriptionCoordinator.meetingTitle) がそのまま働く。
    /// ディレクトリは最後の構成要素が symlink のとき実パスに揃える (SandboxSupport
    /// の保存先と同じ考え — コンテナ内 Movies が実 ~/Movies への symlink になりうる)。
    /// 一覧 (FileManager.contentsOfDirectory) と完全に同じ正規形を保証するものでは
    /// ないが、実運用の保存先 (~/Movies・NSOpenPanel で選んだフォルダ) には
    /// symlink 祖先が無く差は生じない (セルフテストは側で同じ形に整えている)
    static func destinationURL(for source: URL, in directory: URL, at date: Date) -> URL {
        let directory = directory.resolvingSymlinksInPath()
        let formatter = DateFormatter()
        // 既定名のタイムスタンプはローカライズされない数値列 (CLI の defaultOutputName
        // と同じ) なので、環境の言語・時差に依存させない
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = sanitizedStem(source.deletingPathExtension().lastPathComponent)
        let name = "kilde-\(formatter.string(from: date))-\(stem).\(source.pathExtension)"
        return directory.appendingPathComponent(name)
    }

    /// 取り込み 1 件の本体。戻り値は «文字起こしの対象にする URL» — 新しくコピー
    /// した先、既に取り込んであったファイル、または元のファイル (保存先内のとき)。
    /// throws はコピーの失敗 (読み取り不能・書き込み先の障害など)
    ///
    /// 判定の順序:
    /// 1. **元のファイルが保存先直下の kilde- ファイル** ならコピーしない — 既に
    ///    ライブラリの対象 (録画をもう一度文字起こすときの経路。コピーすると
    ///    二重管理になる)。kilde- 接頭辞の無いファイルは一覧に出ないため、
    ///    通常のコピー経路で題名つきのコピーを作る
    /// 2. **同一ファイルを既に取り込んでいる** ならそれを返す (下の existingImport)
    /// 3. コピー先を組んでコピーする。同名の別ファイルがあるときは `-2`, `-3`… と
    ///    退避する (TranscriptWriter のサイドカーと同じ規則)
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
            // 戻り値も一覧の id と揃える (destinationURL と同じ理由で symlink を解決)
            return source.resolvingSymlinksInPath()
        }
        if let existing = existingImport(of: source, in: directory) { return existing }

        let preferred = destinationURL(for: source, in: directory, at: date)
        let destination = uniquifiedURL(preferred)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
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
    /// (ハッシュ・ブックマーク) を残さないため、名前 + サイズの実用判定にする。
    /// 題名が同じでも内容が変わった (サイズが違う) ファイルは別ファイルとして
    /// 再取り込みする
    static func existingImport(of source: URL, in directory: URL) -> URL? {
        let stem = sanitizedStem(source.deletingPathExtension().lastPathComponent)
        let ext = source.pathExtension.lowercased()
        guard let size = fileSize(of: source) else { return nil }
        let candidates = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        // 複数見つかったら更新日時が新しい方 (直近の取り込み) を返す
        return candidates
            .filter { url in
                url.pathExtension.lowercased() == ext
                    && fileSize(of: url) == size
                    && Self.titleSuffix(ofImport: url) == stem
            }
            .sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast)
            }
            .first
    }

    /// 取り込みが作ったファイル名 `kilde-<時刻>-<題名>[-<退避番号>]` から題名部分を
    /// 取り出す。`kilde-` 接頭辞 + 15 文字の時刻 + 区切りの `-` が揃わない名前
    /// (録画の既定名・別名録画) は nil — 題名の比較対象にしない。
    /// 時刻部の検証は TranscriptionCoordinator.meetingTitle と同じ «数字の並び»
    /// による判別 (手作りの `kilde-別名` を題名扱いにしない)
    static func titleSuffix(ofImport url: URL) -> String? {
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
        // 退避の `-<番号>` は題名から除く (退避したファイルも同一ファイル扱いにする)
        if let lastHyphen = rest.lastIndex(of: "-") {
            let maybeIndex = rest[rest.index(after: lastHyphen)...]
            if !maybeIndex.isEmpty, maybeIndex.allSatisfy(\.isNumber) {
                rest = rest[..<lastHyphen]
            }
        }
        return String(rest)
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
    /// ここでは受け付けたことを返し、対応外の判定は importFiles に任せる
    func handleDrop(_ providers: [NSItemProvider], into directory: URL?,
                    onImported: @escaping (URL) -> Void,
                    onComplete: @escaping () -> Void) -> Bool {
        guard !providers.isEmpty else { return false }
        let collectQueue = DispatchQueue(label: "kilde.library-import.drop")
        var urls: [URL] = []
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
                    if let url { urls.append(url) }
                    pending -= 1
                    guard pending == 0, !urls.isEmpty else { return }
                    let collected = urls
                    Task { @MainActor in
                        self.importFiles(collected, into: directory,
                                         onImported: onImported, onComplete: onComplete)
                    }
                }
            }
        }
        return true
    }
}
