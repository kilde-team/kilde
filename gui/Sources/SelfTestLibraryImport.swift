import Foundation
import KildeCore

/// ライブラリの «既存ファイルの取り込み» (issue #416) の UI 無し検証。
/// 一時ディレクトリに «保存先» と «取り込み元» を分けて作り、
/// 「取り込み先の名前組み立て → コピー → 同一ファイルの再取り込み → 一覧反映」を
/// 確かめる。NSOpenPanel・ドロップは出さない (UI を伴う経路は手動確認) —
/// パネル/ドロップから先は LibraryImport.performImport に集約されており、
/// ここではその本体と一覧の連携を検証する。
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
        // 環境で検証するのは、取り込みと一覧の URL 正規化
        // (LibraryImport.canonicalFileURL) が両側で揃っていることを実証するため —
        // «取り込みの戻り値 == 一覧の entry.id» が symlink 環境でも一致しなければ
        // ならない (揃っていないと取り込み直後の選択・処理中表示が一覧と噛み合わない)
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

        try? FileManager.default.removeItem(at: root)
        print("selftest: library-import failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
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
        check(LibraryImport.sanitizedStem("----") != "", "使えない題名は既定に置き換える")
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

        // 4. 保存先直下の kilde- ファイルはコピーしない (録画を再び文字起こす経路)
        let recording = destination.appendingPathComponent("kilde-20270101-000000.mov")
        FileManager.default.createFile(atPath: recording.path, contents: Data([1]))
        let inPlace = try? LibraryImport.performImport(of: recording, into: destination)
        check(inPlace == recording, "保存先内の kilde- ファイルはコピーしない")

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

        // 7. 一覧の判定と取り込み対象の集合は同じ (片方だけ増えると «取り込んだのに
        // 一覧に出ない» になる — 受け入れ条件の機械検証)
        check(LibraryStore.recordingExtensions == LibraryImport.importableExtensions,
              "一覧と取り込みの拡張子集合が一致する")

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
