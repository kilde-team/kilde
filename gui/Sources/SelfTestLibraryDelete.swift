import Foundation
import KildeCore

/// ライブラリの «ゴミ箱へ移す» (issue #523) の UI 無し検証。
/// 一時ディレクトリに録画とサイドカーを合成し、
/// «伴走ファイルの収集 → ゴミ箱移動 → 一覧と Spotlight の差分から消える» を
/// 確かめる。**実環境のゴミ箱は汚さない** — `FileManager.trashItem` 自体は
/// `KILDE_GUI_SELFTEST_LIBRARY_DELETE_TRASH=1` の «実ゴミ箱チェック» で別に
/// 検証し (下の runRealTrashCheck)、ここでは `LibraryRecordingCleanup.Trasher`
/// を «移動先ディレクトリへの moveItem» に差し替えて «ゴミ箱に入った» を代用する。
/// UI (コンテキストメニュー・確認ダイアログ・プレイヤーの停止) は実機確認の対象。
/// 実録画・実文字起こしが不要のため録画のスロットを占有しない
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

        // 録画 A: サイドカー一式 (5 形式 + 同フォルダ保存の書き出し)。
        // 録画 B: 削除しない対照群。ほかに «stem が一致しても対象外» のファイルを置く
        let stampA = "20270102-030405"
        let stemA = "kilde-\(stampA)"
        let recordingA = folder.appendingPathComponent("\(stemA).mov")
        // 枝番の -2.json は **このフォルダでは -2.m4a (別録画) のもの** になる —
        // 別録画が自分の stem で主張しているサイドカーは伴走に含めない
        // (companionFiles の refined ルール) ので、A の伴走には入らない。
        // «枝番が本当に A のもの» のケースは下の checkBranchWithoutTwin で
        // 別フォルダ (二重録画の無い世界) で検証する
        let companionNames = [
            "\(stemA).json",
            "\(stemA).md",      // 議事録 (要約込み)
            "\(stemA).srt",
            "\(stemA).txt",
            "\(stemA).vtt",     // ユーザーが同じフォルダに保存した書き出しも «この録画のもの»
        ]
        let branchSidecar = "\(stemA)-2.json"  // -2.m4a (音声の二重録画) のサイドカー
        let stampB = "20261231-235959"
        let stemB = "kilde-\(stampB)"
        let recordingB = folder.appendingPathComponent("\(stemB).mov")
        let companionB = folder.appendingPathComponent("\(stemB).json")

        createFile(recordingA, bytes: 64)
        for name in companionNames {
            createFile(folder.appendingPathComponent(name), bytes: 32)
        }
        createFile(folder.appendingPathComponent(branchSidecar), bytes: 32)
        createFile(recordingB, bytes: 48)
        createFile(companionB, bytes: 32)
        // «stem が一致 (枝番含む) でもサイドカー形式でない» もの — 音声の二重録画
        // (-2.m4a) とユーザーの別種ファイル (-3.log) は録画/未関連なので連れていかない。
        // -2.m4a は «枝番 stem の録画» でもあり、-2.json の持ち主になる。
        // -3.log は «録画形式でない» のでサイドカー (-3.json が無い) の主張もしない
        createFile(folder.appendingPathComponent("\(stemA)-2.m4a"), bytes: 16)
        createFile(folder.appendingPathComponent("\(stemA)-3.log"), bytes: 8)
        createFile(folder.appendingPathComponent("メモ.txt"), bytes: 8)

        checkCollection(folder: folder, recordingA: recordingA, stemA: stemA,
                        companionNames: companionNames, branchSidecar: branchSidecar)
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
        checkBranchWithoutTwin(folder: folder, trash: trash)
        checkSharedBranchSidecar(root: root, trash: trash)
        checkLogDoesNotClaim(folder: folder)
        checkUnreadableDirectory()

        try? FileManager.default.removeItem(at: root)
        print("selftest: library-delete failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    /// «FileManager.trashItem を実際に呼ぶ» 検証 (`KILDE_GUI_SELFTEST_LIBRARY_DELETE_TRASH=1`)。
    /// セルフテスト本体は Trasher を差し替えるため trashItem 自体の挙動
    /// (サンドボックス下でのシステムの仲介 — MAS ビルドの `movies.read-write`
    /// で ~/Movies のファイルをゴミ箱へ移せるか) を見ない。このモードだけは
    /// **実環境に触れる**: ダミー録画をユーザーに見える Movies
    /// (サンドボックスでは `SandboxSupport.userVisibleMoviesDirectory()`、
    /// それ以外は ~/Movies) に作り、`systemTrasher` でゴミ箱へ移し、結果を出力する。
    /// ダミーファイルはゴミ箱に残る (アプリからは元に戻せない — 復元は人手) ので、
    /// **実行のたびにユーザーのゴミ箱に 1 件残る** ことをここでも案内する。
    /// 実録画を伴わないため録画のスロットを占有しない
    static func runRealTrashCheck() {
        // «ユーザーに見える Movies» を使う — サンドボックス下では
        // FileManager の Movies がコンテナ内を返すことがある (CLAUDE.md §5-17)。
        // 非サンドボックス (直接配布ビルド) では SandboxSupport が
        // コンパイル対象外 (#if APPSTORE) なので、FileManager で実 ~/Movies を取る
        let movies: URL
        #if APPSTORE
        movies = SandboxSupport.userVisibleMoviesDirectory()
        #else
        movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        #endif
        // ダミー名は kilde- 接頭辞の既定名形式 — ライブラリの一覧に «録画» として
        // 載る形にする (実行中のライブラリに映っても自然な名前にするため)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        // 名前は UUID で一意化し、書き込みは withoutOverwriting — «たまたま同名の
        // ファイルがあった» ときにそれを壊してからゴミ箱へ移す、を防ぐ
        // (cubic レビュー指摘。秒精度の固定名は再実行・並行実行・既存ファイルと衝突する)
        let dummy = movies.appendingPathComponent(
            "kilde-\(stamp)-selftest-trash-\(UUID().uuidString).mov")
        let data = Data(repeating: 1, count: 64)
        do {
            try data.write(to: dummy, options: .withoutOverwriting)
        } catch {
            print("selftest: library-delete-trash failed to create dummy in \(movies.path): \(error)")
            exit(1)
        }
        do {
            let trashed = try LibraryRecordingCleanup.systemTrasher(dummy)
            let existed = (try? trashed.checkResourceIsReachable()) ?? false
            print("selftest: library-delete-trash OK: ~/Movies のファイルをゴミ箱へ移動できた (\(dummy.lastPathComponent) → \(trashed.path), reachable=\(existed))")
            print("selftest: library-delete-trash NOTE: ダミーファイルはゴミ箱に残っています — 復元・削除は Finder でお願いします")
            exit(0)
        } catch {
            print("selftest: library-delete-trash FAIL: trashItem が失敗 (\(error)) — ダミーファイル \(dummy.path) は手動で消してください")
            exit(1)
        }
    }

    // MARK: 検査

    /// companionFiles を実行して失敗を検査失敗に落とすヘルパー (通常経路は失敗しない)
    private static func collectCompanions(_ recording: URL, in folder: URL) -> [URL] {
        do {
            return try LibraryRecordingCleanup.companionFiles(
                forRecording: recording, in: folder)
        } catch {
            check(false, "companionFiles が失敗しない (\(error))")
            return []
        }
    }

    /// 伴走ファイルの収集。«この録画のもの» だけを集め、対照群や
    /// «別録画が主張するサイドカー» に触れないこと
    private static func checkCollection(
        folder: URL, recordingA: URL, stemA: String, companionNames: [String],
        branchSidecar: String) {
        let companions = collectCompanions(recordingA, in: folder)
        let expectedNames = Set(companionNames)
        check(Set(companions.map(\.lastPathComponent)) == expectedNames,
              "伴走ファイルはサイドカー一式だけ (実際 \(companions.map(\.lastPathComponent).sorted()))")
        check(!companions.contains(recordingA),
              "録画本体は伴走ファイルに含まれない (moveToTrash の recording と重複させない)")
        check(!companions.contains { $0.lastPathComponent == branchSidecar },
              "\(branchSidecar) は «-2.m4a (別録画) のサイドカー» なので伴走に含めない")
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
        let companions = collectCompanions(recordingA, in: folder)
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
              "この録画のサイドカー (書き出し含む) もフォルダから消える")
        // «-2.json» は «-2.m4a (別録画) のサイドカー» として残り、録画も残る —
        // «消した録画の代わりに、残った録画が文字起こしを失う» を起こさない
        check(remaining.contains("kilde-20270102-030405-2.json"),
              "別録画 (-2.m4a) が主張するサイドカー (-2.json) は残る")
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
        check(trashed.contains("kilde-20270102-030405.mov"),
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
    /// «本体が残ってサイドカーだけ消える» を作らないための契約。
    /// «サイドカーに触っていない» も試行の記録で確認する (cubic レビュー指摘 —
    /// «呼び出しが無かった» は «失敗しなかった» と違うので、順序の回帰もここで拾う)
    private static func checkAbortOnRecordingFailure(folder: URL, trash: URL) {
        let stem = "kilde-20270103-040506"
        let recording = folder.appendingPathComponent("\(stem).mov")
        let companion = folder.appendingPathComponent("\(stem).json")
        createFile(recording, bytes: 16)
        createFile(companion, bytes: 8)
        let attempted = MutexBox<[URL]>([])
        let alwaysFails: LibraryRecordingCleanup.Trasher = { url in
            attempted.with { $0.append(url) }
            throw NSError(domain: "kilde-selftest-library-delete", code: 1)
        }
        do {
            _ = try LibraryRecordingCleanup.moveToTrash(
                recording: recording, companionFiles: [companion], trasher: alwaysFails)
            check(false, "録画本体の失敗は throw として返る")
        } catch {
            check(true, "録画本体の失敗は throw として返る")
        }
        let attempts = attempted.current
        check(attempts == [recording],
              "録画本体の失敗ではサイドカーに触らない (試行 \(attempts.count) 件)")
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
    /// 再文字起こしの «-2» 重複が生えにくい、という判断の検証
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
        let companions = collectCompanions(recording, in: folder)
        check(companions.isEmpty,
              "サイドカーの無い録画の伴走ファイルは空 (実際 \(companions.count) 件)")
    }

    /// «枝番サイドカーが本当にこの録画のもの» のケース — 二重録画 (枝番 stem の
    /// 録画) がフォルダに無ければ、`-2.json` は従来どおりこの録画の枝番として
    /// 一緒に移る (refined ルールが «枝番を一切拾わない» に変わっていないことの担保)
    private static func checkBranchWithoutTwin(folder: URL, trash: URL) {
        let stem = "kilde-20270106-070809"
        let recording = folder.appendingPathComponent("\(stem).mov")
        let branch = folder.appendingPathComponent("\(stem)-2.json")
        createFile(recording, bytes: 16)
        createFile(branch, bytes: 8)
        let companions = collectCompanions(recording, in: folder)
        check(companions.map(\.lastPathComponent) == [branch.lastPathComponent],
              "二重録画が無ければ枝番サイドカーは伴走に含まれる (実際 \(companions.map(\.lastPathComponent)))")
        let stubTrasher: LibraryRecordingCleanup.Trasher = { url in
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        do {
            let leftovers = try LibraryRecordingCleanup.moveToTrash(
                recording: recording, companionFiles: companions, trasher: stubTrasher)
            check(leftovers.isEmpty && !FileManager.default.fileExists(atPath: branch.path),
                  "枝番サイドカーも一緒に移る (残り \(leftovers.count) 件)")
        } catch {
            check(false, "枝番付きの移動に成功する (エラー \(error))")
        }
    }

    /// «同じ stem の二重録画 (mov と m4a) が枝番サイドカーを共有する» ケース —
    /// ライブラリは `a-2.json` を «stem-数字» の規則でどちらの録画にも対応づける。
    /// a.mov を消すとき、残る a.m4a がその文字越しを失わないように枝番サイドカーを
    /// 守る (CodeRabbit レビュー指摘、issue #525 の PR #526 レビュー)
    private static func checkSharedBranchSidecar(root: URL, trash: URL) {
        let folder = root.appendingPathComponent("保存先2")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            print("selftest: library-delete failed to create temp dir: \(error)")
            failures += 1
            return
        }
        let stem = "kilde-20270109-111213"
        let mov = folder.appendingPathComponent("\(stem).mov")
        let m4a = folder.appendingPathComponent("\(stem).m4a")
        let branch = folder.appendingPathComponent("\(stem)-2.json")
        createFile(mov, bytes: 16)
        createFile(m4a, bytes: 16)
        createFile(branch, bytes: 8)
        let companions = collectCompanions(mov, in: folder)
        check(companions.isEmpty,
              "同じ stem の二重録画が主張する枝番サイドカーは伴走に含まれない (実際 \(companions.count) 件)")
        let stubTrasher: LibraryRecordingCleanup.Trasher = { url in
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        do {
            _ = try LibraryRecordingCleanup.moveToTrash(
                recording: mov, companionFiles: companions, trasher: stubTrasher)
            check(!FileManager.default.fileExists(atPath: mov.path),
                  "消した録画 (mov) はフォルダから消える")
        } catch {
            check(false, "録画本体だけの移動に成功する (エラー \(error))")
        }
        check(FileManager.default.fileExists(atPath: branch.path),
              "枝番サイドカー (-2.json) は残る")
        check(FileManager.default.fileExists(atPath: m4a.path),
              "残った録画 (m4a) は残る")
        let entries = LibraryStore.scan(directory: folder) ?? []
        check(entries.first?.recordingURL.lastPathComponent == m4a.lastPathComponent
              && entries.first?.transcriptURL?.lastPathComponent == branch.lastPathComponent,
              "残った録画 (m4a) は枝番サイドカーを文字越しとして保持する")
    }

    /// «録画形式でないファイルは別録画として主張しない» — `kilde-a.log` が
    /// 隣にいても `kilde-a.json` は伴走に含まれる (主張の判定は
    /// LibraryStore.recordingExtensions = 一覧に載る録画形式で絞る。cubic 指摘)
    private static func checkLogDoesNotClaim(folder: URL) {
        let stem = "kilde-20270107-090910"
        let recording = folder.appendingPathComponent("\(stem).mov")
        let log = folder.appendingPathComponent("\(stem).log")
        let sidecar = folder.appendingPathComponent("\(stem).json")
        createFile(recording, bytes: 16)
        createFile(log, bytes: 8)
        createFile(sidecar, bytes: 8)
        let companions = collectCompanions(recording, in: folder)
        // 走査の URL 表記 (/private/var/…) と組み立てた URL (/var/…) は
        // URL 同士では一致しないので、ファイル名で比べる
        check(companions.map(\.lastPathComponent) == [sidecar.lastPathComponent],
              "録画形式でないファイル (.log) はサイドカーを主張しない (実際 \(companions.map(\.lastPathComponent)))")
    }

    /// 保存先フォルダが読めなかったときは何も移さず throw する —
    /// «伴走なし» と誤認して本体だけ移す失敗を作らない (cubic 指摘)。
    /// フォルダごと消した場合を想定する
    private static func checkUnreadableDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-selftest-library-delete-missing-\(UUID().uuidString)")
        do {
            _ = try LibraryRecordingCleanup.companionFiles(
                forRecording: missing.appendingPathComponent("kilde-20270108-101112.mov"),
                in: missing)
            check(false, "読めないフォルダでは throw する")
        } catch {
            check(true, "読めないフォルダでは throw する")
        }
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

/// テスト用の小さな可変箱 (closure からの書き込みを集めるため)。
/// セルフテストは単一スレッドで動くのでロックは要らないが、
/// «closure が外の var を捕まえる» のを避ける意図は SelfTestLibraryImport と同じ
private final class MutexBox<T> {
    private var value: T
    init(_ value: T) { self.value = value }
    func with(_ body: (inout T) -> Void) {
        body(&value)
    }
    var current: T { value }
}
