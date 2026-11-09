import Foundation
import KildeCore

/// ライブラリの «ゴミ箱へ移す» (issue #523) の UI 無し検証。
/// 一時ディレクトリに録画とサイドカーを合成し、
/// «伴走ファイルの収集 → ゴミ箱移動 → 一覧と Spotlight の差分から消える» を
/// 確かめる。**実環境のゴミ箱は汚さない** — `FileManager.trashItem` 自体
/// (とサンドボックス下でのシステムの仲介) は実機確認の対象で、ここでは
/// `LibraryRecordingCleanup.Trasher` を «移動先ディレクトリへの moveItem» に
/// 差し替えて «ゴミ箱に入った» を代用する。UI (コンテキストメニュー・
/// 確認ダイアログ・プレイヤーの停止) は実機確認の対象。
/// 実録画・実文字越しが不要のため録画のスロットを占有しない
///
/// 使い方: `KILDE_GUI_SELFTEST_LIBRARY_DELETE=1 <GUI>` (AppDelegate.runIfRequested から配線)
@MainActor
enum SelfTestLibraryDelete {

    private static var failures = 0

    static func run() {
        // 一時ディレクトリは run() の最後で消す (exit するため defer は使わない —
        // SelfTestLibraryImport と同じ契約)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-selftest-library-delete-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("保存先")
        let trash = root.appendingPathComponent("ゴミ箱 (テスト用)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        } catch {
            print("selftest: library-delete failed to create temp dirs: \(error)")
            try? FileManager.default.removeItem(at: root)
            exit(1)
        }

        // 録画 A: サイドカー一式 (5 形式 + 枝番 + 同フォルダ保存の書き出し)。
        // 録画 B: 削除しない対照群。ほかに «stem が一致しても対象外» のファイルを置く
        let stampA = "20270102-030405"
        let stemA = "kilde-\(stampA)"
        let recordingA = folder.appendingPathComponent("\(stemA).mov")
        let companionNames = [
            "\(stemA).json",
            "\(stemA)-2.json",  // 再文字越しの枝番 (RecordingSetup.transcriptSidecar と同じ規則)
            "\(stemA).md",      // 議事録 (要約込み)
            "\(stemA).srt",
            "\(stemA).txt",
            "\(stemA).vtt",     // ユーザーが同じフォルダに保存した書き出しも «この録画のもの»
        ]
        let stampB = "20261231-235959"
        let stemB = "kilde-\(stampB)"
        let recordingB = folder.appendingPathComponent("\(stemB).mov")
        let companionB = folder.appendingPathComponent("\(stemB).json")

        createFile(recordingA, bytes: 64)
        for name in companionNames {
            createFile(folder.appendingPathComponent(name), bytes: 32)
        }
        createFile(recordingB, bytes: 48)
        createFile(companionB, bytes: 32)
        // «stem が一致 (枝番含む) でもサイドカー形式でない» もの — 音声の二重録画
        // (-2.m4a) とユーザーの別種ファイル (-3.log) は録画/未関連なので連れていかない
        createFile(folder.appendingPathComponent("\(stemA)-2.m4a"), bytes: 16)
        createFile(folder.appendingPathComponent("\(stemA)-3.log"), bytes: 8)
        createFile(folder.appendingPathComponent("メモ.txt"), bytes: 8)

        checkCollection(folder: folder, recordingA: recordingA, stemA: stemA, companionNames: companionNames)
        // 削除 «前» の一覧と manifest を取っておく — «ゴミ箱へ移した» ことが
        // 一覧と Spotlight の差分に現れることの検証に使う。identifier は走査の
        // URL 表記 (/private/var/…) で組まれるため、比較にも **走査側の表記** を使う
        let initialEntries = LibraryStore.scan(directory: folder) ?? []
        // 走査は /private/var/… (実パス表記) を返し、こちらで組み立てた URL は
        // /var/… のため URL 同士では一致しない — ファイル名で探す
        let initialAPath = initialEntries.first {
            $0.recordingURL.lastPathComponent == recordingA.lastPathComponent
        }?.recordingURL.path ?? recordingA.path
        let initialPlan = SpotlightItemFactory.diff(manifest: [:], entries: initialEntries)

        checkTrashMove(folder: folder, trash: trash, recordingA: recordingA,
                       companionNames: companionNames, recordingB: recordingB)
        checkScanAndSpotlight(folder: folder, initialManifest: initialPlan.manifest,
                              initialAPath: initialAPath,
                              recordingA: recordingA, recordingB: recordingB)
        checkAbortOnRecordingFailure(folder: folder, trash: trash)
        checkLeftoverCompanion(folder: folder, trash: trash)
        checkNoCompanion(folder: folder)

        try? FileManager.default.removeItem(at: root)
        print("selftest: library-delete failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: 検査

    /// 伴走ファイルの収集。«この録画のもの» だけを集め、対照群に触れないこと
    private static func checkCollection(
        folder: URL, recordingA: URL, stemA: String, companionNames: [String]) {
        let companions = LibraryRecordingCleanup.companionFiles(
            forRecording: recordingA, in: folder)
        let expectedNames = Set(companionNames)
        check(Set(companions.map(\.lastPathComponent)) == expectedNames,
              "伴走ファイルはサイドカー一式だけ (実際 \(companions.map(\.lastPathComponent).sorted()))")
        check(!companions.contains(recordingA),
              "録画本体は伴走ファイルに含まれない (moveToTrash の recording と重複させない)")
    }

    /// ゴミ箱移動の本体。stub の Trasher は «移動先ディレクトリへの moveItem» で
    /// «ゴミ箱に入った» を代用する — «どこへ行ったか» も確かめられる
    private static func checkTrashMove(
        folder: URL, trash: URL, recordingA: URL, companionNames: [String],
        recordingB: URL) {
        let stubTrasher: LibraryRecordingCleanup.Trasher = { url in
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        let companions = LibraryRecordingCleanup.companionFiles(
            forRecording: recordingA, in: folder)
        do {
            let leftovers = try LibraryRecordingCleanup.moveToTrash(
                recording: recordingA, companionFiles: companions, trasher: stubTrasher)
            check(leftovers.isEmpty, "サイドカー一式は全部移動する (残り \(leftovers.count) 件)")
        } catch {
            check(false, "録画本体とサイドカーの移動に成功する (エラー \(error))")
        }
        check(!FileManager.default.fileExists(atPath: recordingA.path),
              "録画本体がフォルダから消える")
        let remaining = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? [])
            .map(\.lastPathComponent)
        check(!remaining.contains { companionNames.contains($0) },
              "この録画のサイドカー (枝番・書き出し含む) もフォルダから消える")
        // «-2.m4a» (音声の二重録画) と «-3.log» は «サイドカー形式でない» ので残る
        check(remaining.contains("kilde-20270102-030405-2.m4a"),
              "同じ stem の録画形式 (-2.m4a) は連れていかない")
        check(remaining.contains("kilde-20270102-030405-3.log"),
              "サイドカー形式でない枝番 (-3.log) は連れていかない")
        check(remaining.contains("メモ.txt"),
              "stem が違うファイルは触らない")
        check(FileManager.default.fileExists(atPath: recordingB.path),
              "対照の録画 B は残る")
        let trashed = ((try? FileManager.default.contentsOfDirectory(
            at: trash, includingPropertiesForKeys: nil,
            options: [])) ?? []).map(\.lastPathComponent)
        check(trashed.contains("kilde-20270102-030405.mov")
                  && trashed.contains("kilde-20270102-030405-2.json"),
              "stub の移動先に «ゴミ箱に入った» ファイルが並ぶ (実際 \(trashed.count) 件)")
    }

    /// «ゴミ箱へ移した» ことがライブラリの一覧と Spotlight の差分に現れること。
    /// Spotlight の索引削除は既存の差分同期 (SpotlightItemFactory.diff) が
    /// «manifest にあって走査に無い» で拾う — ファイルが無くなる経路が
    /// removeItem から trashItem に変わっても同じことが成立する、の検証。
    /// «-2.m4a» (音声の二重録画 — 削除対象外) は **一覧には残る** 別録画
    private static func checkScanAndSpotlight(
        folder: URL, initialManifest: [String: String], initialAPath: String,
        recordingA: URL, recordingB: URL) {
        let entries = LibraryStore.scan(directory: folder) ?? []
        let expectedNames = Set(["kilde-20270102-030405-2.m4a", recordingB.lastPathComponent])
        check(Set(entries.map { $0.recordingURL.lastPathComponent }) == expectedNames,
              "削除後の一覧は «音声の二重録画 + 対照の録画 B» (実際 \(entries.map { $0.recordingURL.lastPathComponent }.sorted()))")
        let plan = SpotlightItemFactory.diff(manifest: initialManifest, entries: entries)
        check(plan.delete == [initialAPath],
              "消えた録画 A が Spotlight の削除対象になる (実際 \(plan.delete))")
        check(!plan.index.contains(where: { $0.uniqueIdentifier == initialAPath }),
              "消えた録画 A は索引対象にならない")
    }

    /// 録画本体が移せないときは **何も移さず** throw する —
    /// «本体が残ってサイドカーだけ消える» を作らないための契約
    private static func checkAbortOnRecordingFailure(folder: URL, trash: URL) {
        let stem = "kilde-20270103-040506"
        let recording = folder.appendingPathComponent("\(stem).mov")
        let companion = folder.appendingPathComponent("\(stem).json")
        createFile(recording, bytes: 16)
        createFile(companion, bytes: 8)
        let alwaysFails: LibraryRecordingCleanup.Trasher = { _ in
            throw NSError(domain: "kilde-selftest-library-delete", code: 1)
        }
        do {
            _ = try LibraryRecordingCleanup.moveToTrash(
                recording: recording, companionFiles: [companion], trasher: alwaysFails)
            check(false, "録画本体の失敗は throw として返る")
        } catch {
            check(true, "録画本体の失敗は throw として返る")
        }
        check(FileManager.default.fileExists(atPath: recording.path),
              "録画本体の失敗では録画が残る")
        check(FileManager.default.fileExists(atPath: companion.path),
              "録画本体の失敗ではサイドカーに触らない")
        let trashed = ((try? FileManager.default.contentsOfDirectory(
            at: trash, includingPropertiesForKeys: nil, options: [])) ?? [])
        check(trashed.allSatisfy { $0.lastPathComponent.hasPrefix("kilde-20270102-030405") },
              "失敗した移動では何もゴミ箱に入らない")
    }

    /// サイドカーの 1 件が移せなかったときは打ち切らず、**残りを返す** —
    /// «本体は消えた» 状態では «消えなかったサイドカー» を案内する方が
    /// 再文字越しの «-2» 重複が生えにくい、という判断の検証
    private static func checkLeftoverCompanion(folder: URL, trash: URL) {
        let stem = "kilde-20270104-050607"
        let recording = folder.appendingPathComponent("\(stem).mov")
        let json = folder.appendingPathComponent("\(stem).json")
        let srt = folder.appendingPathComponent("\(stem).srt")
        createFile(recording, bytes: 16)
        createFile(json, bytes: 8)
        createFile(srt, bytes: 8)
        let failsForSRT: LibraryRecordingCleanup.Trasher = { url in
            if url.lastPathComponent.hasSuffix(".srt") {
                throw NSError(domain: "kilde-selftest-library-delete", code: 2)
            }
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        do {
            let leftovers = try LibraryRecordingCleanup.moveToTrash(
                recording: recording, companionFiles: [json, srt], trasher: failsForSRT)
            check(leftovers == [srt], "移せなかったサイドカーだけが返る (実際 \(leftovers.map(\.lastPathComponent)))")
        } catch {
            check(false, "サイドカーの失敗では throw しない (エラー \(error))")
        }
        check(!FileManager.default.fileExists(atPath: recording.path),
              "サイドカーの失敗があっても録画本体は移る")
        check(!FileManager.default.fileExists(atPath: json.path),
              "失敗しなかったサイドカーは移る")
        check(FileManager.default.fileExists(atPath: srt.path),
              "失敗したサイドカーは残る")
    }

    /// サイドカーの無い録画の収集は空 (削除は録画本体だけで完結する)
    private static func checkNoCompanion(folder: URL) {
        let recording = folder.appendingPathComponent("kilde-20270105-060708.mp4")
        createFile(recording, bytes: 16)
        let companions = LibraryRecordingCleanup.companionFiles(
            forRecording: recording, in: folder)
        check(companions.isEmpty,
              "サイドカーの無い録画の伴走ファイルは空 (実際 \(companions.count) 件)")
    }

    // MARK: 支援

    /// 合成ファイルの作成。中身は «非ゼロのダミー» — サイズ 0 だと
    /// fingerprint (size) の対照にならないため
    private static func createFile(_ url: URL, bytes: Int) {
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 1, count: bytes))
    }

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("selftest: library-delete OK: \(label)")
        } else {
            failures += 1
            print("selftest: library-delete FAIL: \(label)")
        }
    }
}
