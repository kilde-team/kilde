import Foundation
import KildeCore

/// ライブラリの «既存ファイルの取り込み» (issue #416) の UI 無し検証。
/// 一時ディレクトリに «保存先» と «取り込み元» を分けて作り、
/// 「取り込み先の名前組み立て → コピー → 同一ファイルの再取り込み → 一覧反映」に
/// 加え、**ドロップの収集経路 (LibraryImportCoordinator.handleDrop)** を
/// NSItemProvider との直接呼び出しで確かめる (issue #424)。NSOpenPanel と
/// 実ドラッグの権限 (サンドボックスの drag-and-drop) は実機確認の対象 —
/// そこから先 (performImport・収集・案内) はここで機械検証する。
/// 実録画・実文字起こしを伴わないため、録画のスロット (画面収録・マイクの権限、
/// スピーカー) を占有しない
///
/// 使い方: `KILDE_GUI_SELFTEST_LIBRARY_IMPORT=1 <GUI>` (AppDelegate.runIfRequested から配線)
@MainActor
enum SelfTestLibraryImport {

    private static var failures = 0

    /// 決定論的な名前の検査に使う固定の日時。LibraryStore.recordedAt と同じ
    /// (ロケール・書式・既定のタイムゾーン) で組み立てる — 実行環境のタイムゾーンに
    /// よらず «名前 → 日時の往復« が一致する
    private static let fixedDate: Date = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: "20270102-030405")!
    }()

    static func run() {
        // 一時ディレクトリ (`/var/folders/…`) は **symlink 祖先を持つ** —
        // ライブラリの走査 (FileManager.contentsOfDirectory) は `/private/var/…` の
        // 実パス表記を返すのに対し、URL の組み立ては与えた表記を保つ。あえてこの
        // 環境で検証するのは、取り込みが **走査結果の表記をそのまま使う**
        // (performImport の listedDirectory) 設計で «取り込みの戻り値 == 一覧の
        // entry.id» が symlink 環境でも一致することを実証するため — URL を
        // symlink 解決で書き換えるやり方は security-scoped bookmark の表記と
        // 食うため採っていない (LibraryImport.isSameFile のコメント)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-selftest-library-import-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("保存先")
        let source = root.appendingPathComponent("元フォルダ")
        // defer で消さない — run() は必ず exit() で終わるため defer は一度も走らず、
        // 一時ディレクトリが残る (SelfTestLibraryExport と同じ契約)。exit の前に消す
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        } catch {
            print("selftest: library-import failed to create temp dirs: \(error)")
            try? FileManager.default.removeItem(at: root)
            exit(1)
        }

        checkNaming()
        checkSanitization()
        performImportChecks(destination: destination, source: source)
        checkListing(destination: destination)

        // ドロップ経路の検証は MainActor の Task の完了を待つ必要がある —
        // RunLoop.main.run(until:) では Swift Concurrency の main executor が
        // 進まないため (SelfTest.swift の reportNotifyTargets と同じ知見)。
        // 従来の同期検査の後に回して、終わったところでまとめて掃除・集計・exit する
        Task { @MainActor in
            await checkDropPath(destination: destination, source: source)
            try? FileManager.default.removeItem(at: root)
            print("selftest: library-import failures=\(failures)")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// ドロップの収集経路 (LibraryImportCoordinator.handleDrop) の検証 (issue #424)。
    /// 実際のドラッグ操作は出せないが、NSItemProvider を直接与えることで
    /// «provider の収集 → 対応判定 → 取り込み → 案内» までを確かめられる
    private static func checkDropPath(destination: URL, source: URL) async {
        // onImported / onComplete は非同期で MainActor に届くので、受け取り先は
        // 参照型の箱にまとめる (クロージャが captures して書き戻す)
        final class DropOutcome {
            var imported: [URL] = []
            var done = false
        }
        let coordinator = LibraryImportCoordinator()

        // 1. 対応 2 件 (m4a / wav) + 非対応 1 件 (txt) のドロップ
        let m4a = source.appendingPathComponent("ドロップ会議.m4a")
        let wav = source.appendingPathComponent("ドロップ録音.wav")
        let text = source.appendingPathComponent("説明.txt")
        FileManager.default.createFile(atPath: m4a.path, contents: Data(repeating: 1, count: 64))
        FileManager.default.createFile(atPath: wav.path, contents: Data(repeating: 2, count: 48))
        FileManager.default.createFile(atPath: text.path, contents: Data("説明".utf8))
        var providers: [NSItemProvider] = []
        for url in [m4a, wav, text] {
            guard let provider = NSItemProvider(contentsOf: url) else {
                check(false, "NSItemProvider を作れる (\(url.lastPathComponent))")
                return
            }
            providers.append(provider)
        }
        let outcome = DropOutcome()
        _ = coordinator.handleDrop(
            providers, into: destination,
            onImported: { outcome.imported.append($0) },
            onComplete: { outcome.done = true })
        await wait(until: { outcome.done }, timeout: 30, label: "混在ドロップの完了")
        check(outcome.imported.count == 2,
              "対応形式 2 件だけを取り込む (実際 \(outcome.imported.count) 件)")
        let names = outcome.imported.map { $0.lastPathComponent }
        check(names.contains(where: { $0.hasSuffix("ドロップ会議.m4a") })
                  && names.contains(where: { $0.hasSuffix("ドロップ録音.wav") }),
              "取り込んだファイルの名前 (実際 \(names.joined(separator: ", ")))")
        check(!coordinator.isImporting, "完了後に «取り込んでいます» の表示が戻る")
        check(coordinator.lastNotice?.contains("対応していない形式は除きました") == true,
              "対応外の形式の案内が出る (実際 \(coordinator.lastNotice ?? "nil"))")

        // 2. URL を 1 件も取得できないドロップ — 黙って何も起きない、に終わらないこと
        // (provider が file-url を返せないケース。実 UI では SwiftUI の受け付け型で
        // 大半は届かないが、UTType.fileURL を受けるようにしたため防御の意味もある)
        let expectedNotice = String(localized: "ドロップされたファイルを読み込めませんでした")
        let unnoticeable = DropOutcome()
        _ = coordinator.handleDrop(
            [NSItemProvider()], into: destination,
            onImported: { _ in unnoticeable.done = true },
            onComplete: { unnoticeable.done = true })
        await wait(until: { coordinator.lastNotice == expectedNotice }, timeout: 30,
                   label: "読み込み失敗の案内")
        check(coordinator.lastNotice == expectedNotice,
              "1 件も読めないドロップの案内が出る (実際 \(coordinator.lastNotice ?? "nil"))")
        check(!unnoticeable.done, "読めないドロップでは取り込みが始まらない")
    }

    /// 条件が成立するまで待つ (Swift Concurrency の完了待ち — RunLoop では観測
    /// できないため await のループにする)。タイムアウトしたら検査 1 件の失敗として
    /// 数える (続く検査も失敗になるが、二重計上より «止まった« ことが分かる方が大事)
    private static func wait(until condition: () -> Bool, timeout: TimeInterval, label: String) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if !condition() {
            check(false, "\(label) が \(Int(timeout)) 秒で確定しなかった")
        }
    }

    /// コピー先の名前組み立て (受け入れ条件: `kilde-<時刻>-<元の stem>.<拡張子>`)
    private static func checkNaming() {
        let directory = URL(fileURLWithPath: "/tmp")
        let source = directory.appendingPathComponent("週次会議.m4a")
        let url = LibraryImport.destinationURL(for: source, in: directory, at: fixedDate)
        check(url.lastPathComponent == "kilde-20270102-030405-週次会議.m4a",
              "コピー先の名前 (実際 \(url.lastPathComponent))")
        // 題名の復元 (議事録の見出し) と日時の解析 (一覧の並び) が録ったファイルと
        // 同じ規則で働くか — 取り込みの名前がカレンダー連携 (#393) の体裁に乗っている証
        check(TranscriptionCoordinator.meetingTitle(fromRecordingName: url) == "週次会議",
              "題名を復元できる (実際 \(TranscriptionCoordinator.meetingTitle(fromRecordingName: url) ?? "nil"))")
        check(LibraryStore.recordedAt(of: url, fallback: .distantPast) == fixedDate,
              "ファイル名から日時を解析できる")
    }

    /// 題名の整え (長すぎる名前・前後の空白・使えない題名・バイト上限)
    private static func checkSanitization() {
        check(LibraryImport.sanitizedStem("  会議メモ ") == "会議メモ", "前後の空白を落とす")
        check(LibraryImport.sanitizedStem(". hidden") == "hidden", "前後のドットを落とす")
        check(LibraryImport.sanitizedStem("----") == String(localized: "ファイル"),
              "使えない題名は既定 («ファイル») に置き換える")
        let long = String(repeating: "あ", count: 100)
        check(LibraryImport.sanitizedStem(long).count == 60, "60 文字に切り詰める")
        // 1 文字が 4 バイトになる絵文字 — 文字数上限だけでは 255 バイトのファイル名上限を
        // 超える (cubic 指摘)。バイト上限でも切り詰めること
        let emoji = String(repeating: "🎧", count: 100)
        let clipped = LibraryImport.sanitizedStem(emoji)
        check(clipped.count <= 60 && clipped.utf8.count <= 200,
              "バイト上限でも切り詰める (実際 \(clipped.count) 文字 / \(clipped.utf8.count) バイト)")
    }

    /// 取り込みの本体: コピー・同一ファイルの再取り込み・保存先内のファイル・退避
    private static func performImportChecks(destination: URL, source: URL) {
        // 元ファイル (取り込み元フォルダに置く)。サイズの一致も検査に使うので
        // 中身のあるファイルにする
        let meeting = source.appendingPathComponent("商談メモ.m4a")
        let payload = Data((0..<128).map { UInt8($0 % 251) })
        FileManager.default.createFile(atPath: meeting.path, contents: payload)

        // 1. 通常の取り込み = 保存先へのコピー
        let imported: URL
        do {
            imported = try LibraryImport.performImport(of: meeting, into: destination, at: fixedDate)
        } catch {
            check(false, "取り込みのコピー (\(error))")
            return
        }
        check(imported.lastPathComponent == "kilde-20270102-030405-商談メモ.m4a",
              "コピー先のファイル名 (実際 \(imported.lastPathComponent))")
        check(FileManager.default.fileExists(atPath: imported.path), "コピー先にファイルがある")
        check((try? Data(contentsOf: imported)) == payload, "コピーの内容が元と一致する")
        check(FileManager.default.fileExists(atPath: meeting.path), "元のファイルはそのまま残る")

        // 2. 同一ファイルの再取り込み = 重複を作らない (受け入れ条件)
        let again = try? LibraryImport.performImport(of: meeting, into: destination, at: fixedDate.addingTimeInterval(60))
        check(again == imported, "再取り込みは既存のファイルを返す (実際 \(again?.lastPathComponent ?? "nil"))")
        let kildeFiles = listKildeFiles(in: destination)
        check(kildeFiles.count == 1, "重複コピーが無い (実際 \(kildeFiles.count) 件)")

        // 3. 内容が変わった (サイズが違う) 同名ファイルは別ファイルとして取り込む。
        // 時刻は «2. の再取り込み« と同じにする — 同じ時刻・同じ題名でもサイズが
        // 違えば «同一ファイル« と判定されない (= 名前だけでなくサイズを見ている) ことの検証
        let modified = source.appendingPathComponent("商談メモ.m4a")
        let larger = payload + Data(repeating: 7, count: 64)
        FileManager.default.createFile(atPath: modified.path, contents: larger)
        let reimported = try? LibraryImport.performImport(of: modified, into: destination, at: fixedDate.addingTimeInterval(60))
        check(reimported != nil && reimported != imported,
              "内容が変わったファイルは別ファイルとして取り込む (実際 \(reimported?.lastPathComponent ?? "nil"))")

        // 4. 保存先直下の kilde- ファイルはコピーしない (録画を再び文字起こす経路)。
        //    戻り値は走査表記 (この環境では /private/var/…) なので、同一性は
        //    isSameFile で確かめる (表記の違いで == は成立しない)
        let recording = destination.appendingPathComponent("kilde-20270101-000000.mov")
        FileManager.default.createFile(atPath: recording.path, contents: Data([1]))
        let inPlace = try? LibraryImport.performImport(of: recording, into: destination)
        check(inPlace.map({ LibraryImport.isSameFile($0, recording) }) == true,
              "保存先内の kilde- ファイルはコピーしない")

        // 5. 同名の別ファイルが既にあるときの退避 (-2)
        let collision = source.appendingPathComponent("衝突.m4a")
        FileManager.default.createFile(atPath: collision.path, contents: Data(repeating: 9, count: 32))
        // 先に «本来のコピー先« を作っておくと、取り込みは -2 に退避する
        let preferred = LibraryImport.destinationURL(for: collision, in: destination, at: fixedDate)
        FileManager.default.createFile(atPath: preferred.path, contents: Data(repeating: 1, count: 1))
        let evacuated = try? LibraryImport.performImport(of: collision, into: destination, at: fixedDate)
        check(evacuated?.lastPathComponent == "kilde-20270102-030405-衝突-2.m4a",
              "同名の別ファイルがあるときは -2 に退避する (実際 \(evacuated?.lastPathComponent ?? "nil"))")

        // 6. 数字で終わる元のファイル名の再取り込み (cubic 指摘)。取り込み名
        //    `kilde-…-report-2` から退避番号を単純に除くと `report` になって一致を
        //    失う — 題名部分の完全一致を優先する照合で重複排除できなければならない
        let numbered = source.appendingPathComponent("report-2.m4a")
        FileManager.default.createFile(atPath: numbered.path, contents: Data(repeating: 5, count: 48))
        let numberedFirst = try? LibraryImport.performImport(of: numbered, into: destination, at: fixedDate)
        let numberedAgain = try? LibraryImport.performImport(of: numbered, into: destination, at: fixedDate.addingTimeInterval(90))
        check(numberedFirst != nil && numberedAgain == numberedFirst,
              "数字で終わる名前の再取り込みも重複排除できる (実際 \(numberedAgain?.lastPathComponent ?? "nil"))")

        // 7. 一覧の判定と取り込み対象の集合は、必要な形式を過不足なく含むか
        //    (同一の定数を比較するだけでは内容の回帰を見逃すため、期待する内容を
        //    明示する — cubic 指摘)
        let expected: Set<String> = [
            "mov", "mp4", "m4a",  // エンジンが録る形式
            "m4v", "mp3", "wav", "aif", "aiff", "caf", "aac",  // 取り込みで増えた形式
        ]
        check(LibraryStore.recordingExtensions == expected
                  && LibraryImport.importableExtensions == expected,
              "一覧と取り込みの拡張子集合が期待どおり (実際 \(LibraryStore.recordingExtensions.sorted()))")

        // 8. コピーの一時ファイルが残っていない (コピーは一時名 → rename なので、
        //    成功時は断片が保存先に残らない)。一時名はドット始まりで hidden 扱いに
        //    なるため、走査は skipsHiddenFiles を付けない
        let allFiles = (try? FileManager.default.contentsOfDirectory(
            at: destination, includingPropertiesForKeys: nil)) ?? []
        check(!allFiles.contains { $0.lastPathComponent.hasPrefix(".kilde-import-") },
              "コピーの一時ファイルが残っていない")
    }

    /// 取り込んだファイルがライブラリの一覧に出る (受け入れ条件)
    private static func checkListing(destination: URL) {
        let entries = LibraryStore.scan(directory: destination)
        let names = Set(entries.map { $0.recordingURL.lastPathComponent })
        check(names.contains("kilde-20270102-030405-商談メモ.m4a"), "取り込んだ m4a が一覧に出る")
        // mp3 のような «エンジンが録らない形式« も一覧の対象であること (wav で確認)
        let wavSource = destination.deletingLastPathComponent().appendingPathComponent("元フォルダ/メモ.wav")
        FileManager.default.createFile(atPath: wavSource.path, contents: Data(repeating: 3, count: 16))
        _ = try? LibraryImport.performImport(of: wavSource, into: destination, at: fixedDate)
        let rescaned = LibraryStore.scan(directory: destination)
        let rescanedNames = Set(rescaned.map { $0.recordingURL.lastPathComponent })
        check(rescanedNames.contains("kilde-20270102-030405-メモ.wav"), "取り込んだ wav が一覧に出る")
    }

    private static func listKildeFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("kilde-") }
    }

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("selftest: library-import OK: \(label)")
        } else {
            failures += 1
            print("selftest: library-import FAIL: \(label)")
        }
    }
}
