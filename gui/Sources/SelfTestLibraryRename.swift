import Foundation
import KildeCore

/// ライブラリの «名前を変更» (issue #532) の UI 無し検証。
/// 一時ディレクトリに録画とサイドカーを合成し、
/// «名前の検証 → 事前の衝突検査 → 録画 + サイドカー一式のリネーム →
/// 一覧と Spotlight の差分に現れる» を確かめる。**実環境の保存先は汚さない** —
/// `LibraryRecordingRename.Renamer` を «同じディレクトリ内への moveItem» に
/// 差し替えて «リネームされた» を検証する。`FileManager.moveItem` 自体と
/// サンドボックス下の挙動 (MAS ビルドの `movies.read-write` の範囲) は
/// `KILDE_GUI_SELFTEST_LIBRARY_RENAME_REAL=1` の «実リネームチェック» で
/// 別に検証する (下の runRealRenameCheck — ゴミ箱移動の DELETE_TRASH と同じ
/// 二段構え)。UI (入力ダイアログ・選択の維持) は実機確認の対象。
/// 実録画・実文字起こしが不要のため録画のスロットを占有しない
///
/// 使い方: `KILDE_GUI_SELFTEST_LIBRARY_RENAME=1 <GUI>` (AppDelegate.runIfRequested から配線)
@MainActor
enum SelfTestLibraryRename {

    private static var failures = 0

    static func run() {
        // 一時ディレクトリは run() の最後で消す (exit するため defer は使わない —
        // SelfTestLibraryDelete と同じ契約)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-selftest-library-rename-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("保存先")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            print("selftest: library-rename failed to create temp dirs: \(error)")
            try? FileManager.default.removeItem(at: root)
            exit(1)
        }

        // 録画 A: サイドカー一式 (5 形式 + 同フォルダ保存の書き出し)。
        // 録画 B: リネームしない対照群。«stem が一致 (枝番含む) でも対象外» の
        // ファイルも置く — 構成は SelfTestLibraryDelete と同じにして、
        // «companionFiles の規則をそのまま使える» ことを確かめる
        let stemA = "kilde-20270102-030405"
        let recordingA = folder.appendingPathComponent("\(stemA).mov")
        let sidecarExtensions = ["json", "md", "srt", "txt", "vtt"]
        let companionNames = sidecarExtensions.map { "\(stemA).\($0)" }
        let stemB = "kilde-20261231-235959"
        let recordingB = folder.appendingPathComponent("\(stemB).mov")
        let companionB = folder.appendingPathComponent("\(stemB).json")

        createFile(recordingA, bytes: 64)
        for name in companionNames {
            createFile(folder.appendingPathComponent(name), bytes: 32)
        }
        createFile(recordingB, bytes: 48)
        createFile(companionB, bytes: 32)
        // «stem が一致 (枝番含む) でも対象外» のもの — 音声の二重録画 (-2.m4a) は
        // «枝番 stem の録画» として -2.json の持ち主になり、-3.log は無関係。
        // 削除 (issue #523) の合成フォルダと同じ構成
        createFile(folder.appendingPathComponent("\(stemA)-2.m4a"), bytes: 16)
        createFile(folder.appendingPathComponent("\(stemA)-2.json"), bytes: 32)
        createFile(folder.appendingPathComponent("\(stemA)-3.log"), bytes: 8)
        createFile(folder.appendingPathComponent("メモ.txt"), bytes: 8)

        // «別録画 (-2.m4a) が主張するサイドカーは伴走に含まれない» をまず確かめる —
        // 削除と同じ構成で «companionFiles をそのまま使い、refined ルール
        // (issue #525 の PR #526 レビュー) もそのまま効く» ことの担保
        checkCollection(folder: folder, recordingA: recordingA, companionNames: companionNames)

        // «リネーム前» の一覧と manifest を取っておく — «旧名の削除 + 新名の追加»
        // が Spotlight の差分に現れることの検証に使う。identifier は走査の
        // URL 表記 (/private/var/…) で組まれるため、比較にも **走査側の表記** を使う
        let initialEntries = LibraryStore.scan(directory: folder) ?? []
        let initialAPath = initialEntries.first {
            $0.recordingURL.lastPathComponent == recordingA.lastPathComponent
        }?.recordingURL.path ?? recordingA.path
        let initialPlan = SpotlightItemFactory.diff(manifest: [:], entries: initialEntries)

        checkRenameFamily(folder: folder, recordingA: recordingA, stemA: stemA,
                          sidecarExtensions: sidecarExtensions, recordingB: recordingB)
        checkScanAndSpotlight(folder: folder, initialManifest: initialPlan.manifest,
                              initialAPath: initialAPath, recordingB: recordingB)
        checkBranchCompanion(root: root)
        checkValidation()
        checkLibraryStem()
        checkConflict(folder: folder)
        checkAbortOnRecordingFailure(folder: folder)
        checkLeftoverCompanion(folder: folder)
        checkUnreadableDirectory()

        try? FileManager.default.removeItem(at: root)
        print("selftest: library-rename failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    /// «FileManager.moveItem を実際に呼ぶ» 検証 (`KILDE_GUI_SELFTEST_LIBRARY_RENAME_REAL=1`)。
    /// セルフテスト本体は Renamer を差し替えるため moveItem 自体の挙動
    /// (サンドボックス下での `movies.read-write` の範囲内の移動) を見ない。
    /// このモードだけは **実環境に触れる**: ダミー録画をユーザーに見える Movies
    /// (サンドボックスでは `SandboxSupport.userVisibleMoviesDirectory()`、
    /// それ以外は ~/Movies) に作り、`systemRenamer` でリネームし、検証後に
    /// `LibraryRecordingCleanup.systemTrasher` でゴミ箱へ移して Movies を
    /// きれいにして終わる。**ダミーファイルは (リネーム後の名前で) ゴミ箱に
    /// 残る** ので、実行のたびにユーザーのゴミ箱に 1 件残ることをここでも
    /// 案内する。実録画を伴わないため録画のスロットを占有しない
    static func runRealRenameCheck() {
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
        // 載る形にする (実行中のライブラリに映っても自然な名前にするため)。
        // 名前は UUID で一意化し、書き込みは withoutOverwriting — «たまたま同名の
        // ファイルがあった» ときにそれを壊さない (DELETE_TRASH と同じ理由)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let dummy = movies.appendingPathComponent(
            "kilde-\(stamp)-selftest-rename-\(UUID().uuidString).mov")
        let data = Data(repeating: 1, count: 64)
        do {
            try data.write(to: dummy, options: .withoutOverwriting)
        } catch {
            print("selftest: library-rename-real failed to create dummy in \(movies.path): \(error)")
            exit(1)
        }
        do {
            let renamed = dummy.deletingLastPathComponent()
                .appendingPathComponent("\(dummy.deletingPathExtension().lastPathComponent)-renamed.mov")
            try LibraryRecordingRename.systemRenamer(dummy, renamed)
            let existed = (try? renamed.checkResourceIsReachable()) ?? false
            check(existed, "リネーム後のファイルが読める")
            check(!FileManager.default.fileExists(atPath: dummy.path),
                  "リネーム元の名前は消える")
            // 後始末はゴミ箱経由 — アプリから復元できない削除を勝手にしないため、
            // 0.36.0 の整理導線 (systemTrasher) で迂回する
            let trashed = try LibraryRecordingCleanup.systemTrasher(renamed)
            print("selftest: library-rename-real OK: Movies 内のリネームができた (\(dummy.lastPathComponent) → \(renamed.lastPathComponent) → ゴミ箱 \(trashed.lastPathComponent))")
            print("selftest: library-rename-real NOTE: ダミーファイルはゴミ箱に残っています — 復元・削除は Finder でお願いします")
            exit(failures == 0 ? 0 : 1)
        } catch {
            print("selftest: library-rename-real FAIL: moveItem が失敗 (\(error)) — ダミーファイル \(dummy.path) は手動で消してください")
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
    /// «別録画が主張するサイドカー» に触れない — 削除 (issue #523) と
    /// 同じ規則をそのまま使うことの担保
    private static func checkCollection(folder: URL, recordingA: URL, companionNames: [String]) {
        // この合成フォルダでは -2.m4a (音声の二重録画) が -2.json を主張するため、
        // A の伴走は «exact-stem の 5 形式» だけになる (枝番は «-2.m4a のもの»)
        let expected = Set(companionNames)
        let companions = collectCompanions(recordingA, in: folder)
        check(Set(companions.map(\.lastPathComponent)) == expected,
              "伴走ファイルは «exact-stem のサイドカー一式» (別録画の枝番サイドカーを含まない) (実際 \(companions.map(\.lastPathComponent).sorted()))")
    }

    /// リネームの本体。stub の Renamer は «同じディレクトリ内での名前替え» で
    /// «リネームされた» を代用する — «何がどこへ変わったか» も確かめられる
    private static func checkRenameFamily(
        folder: URL, recordingA: URL, stemA: String, sidecarExtensions: [String],
        recordingB: URL) {
        let stubRenamer: LibraryRecordingRename.Renamer = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
        let newStem = "kilde-定例会議"  // «kilde-» 接頭辞はライブラリの契約 (libraryStem のコメント)
        let companions = collectCompanions(recordingA, in: folder)
        do {
            let leftovers = try LibraryRecordingRename.rename(
                recording: recordingA,
                companionFiles: companions,
                newStem: newStem,
                renamer: stubRenamer)
            check(leftovers.isEmpty, "サイドカー一式は全部リネームされる (残り \(leftovers.count) 件)")
        } catch {
            check(false, "録画本体とサイドカーのリネームに成功する (エラー \(error))")
        }
        let names = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? [])
            .map(\.lastPathComponent)
        check(!names.contains(recordingA.lastPathComponent), "旧名の録画は消える")
        check(names.contains("\(newStem).mov"), "録画本体が新しい stem になる (拡張子と «kilde-» 接頭辞を保つ)")
        for ext in sidecarExtensions {
            check(names.contains("\(newStem).\(ext)"),
                  "\(newStem).\(ext) が並ぶ (サイドカーも新しい stem になる)")
            check(!names.contains("\(stemA).\(ext)"),
                  "旧 stem の \(stemA).\(ext) は残らない")
        }
        // «対象外» の対照群は一切変わらない
        check(names.contains(recordingB.lastPathComponent), "対照の録画 B は残る")
        check(names.contains("kilde-20261231-235959.json"), "対照の録画 B のサイドカーは残る")
        check(names.contains("\(stemA)-2.m4a"), "音声の二重録画 (-2.m4a) はリネームしない")
        check(names.contains("\(stemA)-2.json"),
              "別録画 (-2.m4a) が主張する枝番サイドカー (-2.json) は旧名のまま残る")
        check(names.contains("\(stemA)-3.log"), "サイドカー形式でない枝番 (-3.log) はリネームしない")
        check(names.contains("メモ.txt"), "stem が違うファイルは触らない")
    }

    /// «リネームされた» ことがライブラリの一覧と Spotlight の差分に現れること。
    /// Spotlight の反映は既存の差分同期 (SpotlightItemFactory.diff) が行う —
    /// «manifest にあって走査に無い» が旧名の削除、«走査にあって manifest に無い»
    /// が新名の追加として現れることの検証 (UI は reload するだけ)
    private static func checkScanAndSpotlight(
        folder: URL, initialManifest: [String: String], initialAPath: String,
        recordingB: URL) {
        let entries = LibraryStore.scan(directory: folder) ?? []
        let expected = Set(["kilde-定例会議.mov", "kilde-20270102-030405-2.m4a",
                            recordingB.lastPathComponent])
        check(Set(entries.map { $0.recordingURL.lastPathComponent }) == expected,
              "リネーム後の一覧は «新名 + 音声の二重録画 + 対照の録画 B» (実際 \(entries.map { $0.recordingURL.lastPathComponent }.sorted()))")
        let renamed = entries.first { $0.recordingURL.lastPathComponent == "kilde-定例会議.mov" }
        // «どの形式のサイドカーに対応づくか» は既存の規則 (transcriptSidecar) に
        // 従う — 同じ stem のサイドカーが 5 形式並ぶフォルダでは «最も新しいもの» が
        // 選ばれる (ここでは companions を名前順に moveItem したため .vtt が最新)。
        // 対応づくのは «新しい stem のサイドカー» であることだけを契約として見る
        let transcript = renamed?.transcriptURL
        check(transcript != nil
              && transcript?.deletingPathExtension().lastPathComponent == "kilde-定例会議"
              && RecordingSetup.transcriptSidecarExtensions.contains(
                  transcript?.pathExtension.lowercased() ?? ""),
              "リネーム後の録画は新しい stem の文字起こしに対応づく (既存の «最新のサイドカー» 規則。実際 \(transcript?.lastPathComponent ?? "nil"))")
        let plan = SpotlightItemFactory.diff(manifest: initialManifest, entries: entries)
        check(plan.delete == [initialAPath],
              "旧名が Spotlight の削除対象になる (実際 \(plan.delete))")
        check(plan.index.contains {
            $0.uniqueIdentifier != initialAPath
                && $0.attributeSet.title == "kilde-定例会議"
        },
        "新名が Spotlight の索引対象になる (title = 接頭辞ごとの新しい stem)")
    }

    /// «枝番サイドカーが本当にこの録画のもの» のケース — 二重録画 (枝番 stem の
    /// 録画) がフォルダに無ければ、`-2.json` は伴走に含まれ、**枝番を保ったまま**
    /// «新しい名前-2.json» に移る (削除の checkBranchWithoutTwin と同じ分岐)。
    /// 別フォルダ (二重録画の無い世界) で検証する
    private static func checkBranchCompanion(root: URL) {
        let folder = root.appendingPathComponent("保存先2")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            print("selftest: library-rename failed to create temp dir: \(error)")
            failures += 1
            return
        }
        let stem = "kilde-20270106-070809"
        let recording = folder.appendingPathComponent("\(stem).mov")
        let branch = folder.appendingPathComponent("\(stem)-2.json")
        createFile(recording, bytes: 16)
        createFile(branch, bytes: 8)
        let companions = collectCompanions(recording, in: folder)
        check(companions.map(\.lastPathComponent) == [branch.lastPathComponent],
              "二重録画が無ければ枝番サイドカーは伴走に含まれる (実際 \(companions.map(\.lastPathComponent)))")
        let stubRenamer: LibraryRecordingRename.Renamer = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
        do {
            let leftovers = try LibraryRecordingRename.rename(
                recording: recording,
                companionFiles: companions,
                newStem: "kilde-枝番会議",
                renamer: stubRenamer)
            check(leftovers.isEmpty, "枝番付きのリネームに成功する (残り \(leftovers.count) 件)")
        } catch {
            check(false, "枝番付きのリネームに成功する (エラー \(error))")
        }
        let names = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [])) ?? [])
            .map(\.lastPathComponent)
        check(names.contains("kilde-枝番会議.mov") && names.contains("kilde-枝番会議-2.json"),
              "枝番サイドカーは «kilde-新しい名前-2.json» に移る (枝番と接頭辞を保つ) (実際 \(names.sorted()))")
        check(!names.contains("\(stem)-2.json"), "旧 stem の枝番サイドカーは残らない")
    }

    /// 名前の検証 (validatedStem)。«ダイアログの入力をそのまま stem に使わない»
    /// ための門 — 拒否理由ごとにエラーの種類が分かれることまで確かめる
    /// («空» と «衝突» で案内を分けるのは UI の受け入れ条件)
    private static func checkValidation() {
        let current = "kilde-20270102-030405"
        func assertThrows(_ name: String, _ expected: LibraryRecordingRename.RenameError,
                          _ label: String) {
            do {
                _ = try LibraryRecordingRename.validatedStem(from: name, currentStem: current)
                check(false, label)
            } catch let error as LibraryRecordingRename.RenameError {
                check(error == expected, "\(label) (\(error) が返る)")
            } catch {
                check(false, "\(label) (想定外のエラー \(error))")
            }
        }
        do {
            let stem = try LibraryRecordingRename.validatedStem(
                from: "  定例会議 \n", currentStem: current)
            check(stem == "定例会議", "前後の空白は除いて受け付ける (実際 «\(stem)»)")
        } catch {
            check(false, "前後の空白だけの入力は受け付ける (エラー \(error))")
        }
        assertThrows("", .invalidName, "空の名前は拒否する")
        assertThrows("   ", .invalidName, "空白のみの名前は拒否する")
        assertThrows("会議/予備", .invalidName, "パス区切り «/» は拒否する")
        assertThrows("会議:予備", .invalidName, "パス区切り «:» は拒否する")
        assertThrows(".会議", .invalidName, "先頭が «.» の名前は拒否する (隠しファイル化の防止)")
        assertThrows(".", .invalidName, "«.» は拒否する")
        assertThrows("..", .invalidName, "«..» は拒否する")
        assertThrows(current, .nameUnchanged, "現在の名前と同じ入力は nameUnchanged")
        // «あ» は UTF-8 で 3 バイト。85 文字 = 255 バイト (通す)、86 文字 = 258 バイト (拒否)
        assertThrows(String(repeating: "あ", count: 86), .invalidName,
                     "UTF-8 で 255 バイト超の名前は拒否する")
        do {
            let stem = try LibraryRecordingRename.validatedStem(
                from: String(repeating: "あ", count: 85), currentStem: current)
            check(stem.utf8.count == 255,
                  "255 バイトちょうどの名前は受け付ける (実際 \(stem.utf8.count) バイト)")
        } catch {
            check(false, "255 バイトちょうどの名前は受け付ける (エラー \(error))")
        }
    }

    /// UI の入口 (libraryStem) の検証。«kilde-» 接頭辞の付け直しと、
    /// «ライブラリに載る stem» の契約 (一覧から消えない) を確かめる —
    /// セルフテストで «定例会議.mov が一覧から消える» を実際に起こした
    /// (2026-11-11 の初回実装の失敗) ことの再発防止の検査でもある
    private static func checkLibraryStem() {
        let current = "kilde-20270102-030405"
        func assertThrows(_ input: String, _ expected: LibraryRecordingRename.RenameError,
                          _ label: String) {
            do {
                _ = try LibraryRecordingRename.libraryStem(
                    fromUserInput: input, currentStem: current)
                check(false, label)
            } catch let error as LibraryRecordingRename.RenameError {
                check(error == expected, "\(label) (\(error) が返る)")
            } catch {
                check(false, "\(label) (想定外のエラー \(error))")
            }
        }
        do {
            // 接頭辞なしの入力は «kilde-» を付けて返す
            let stem = try LibraryRecordingRename.libraryStem(
                fromUserInput: "定例会議", currentStem: current)
            check(stem == "kilde-定例会議",
                  "接頭辞なしの入力には «kilde-» を付けて返す (実際 «\(stem)»)")
            // 接頭辞ごと入力した場合は打ったとおりに整える (二重化しない)
            let stem2 = try LibraryRecordingRename.libraryStem(
                fromUserInput: "kilde-定例会議", currentStem: current)
            check(stem2 == "kilde-定例会議",
                  "接頭辞ごとの入力は «kilde-» を 1 回剥がして付け直す (実際 «\(stem2)»)")
            // «剥がした後» の名前同士で unchanged を判定する
            do {
                _ = try LibraryRecordingRename.libraryStem(
                    fromUserInput: "20270102-030405", currentStem: current)
                check(false, "«kilde-» を剥がした名前が現在名と同じなら nameUnchanged")
            } catch let error as LibraryRecordingRename.RenameError {
                check(error == .nameUnchanged,
                      "«kilde-» を剥がした名前が現在名と同じなら nameUnchanged (\(error) が返る)")
            }
            // 長さの上限は «合成後の stem» で判定する — «あ» は 3 バイト。
            // 81 文字 = 243 バイト + «kilde-» 6 バイト = 249 (通す)、
            // 83 文字 = 249 バイト + 6 = 255 (通す)、84 文字 = 252 + 6 = 258 (拒否)
            let ok = try LibraryRecordingRename.libraryStem(
                fromUserInput: String(repeating: "あ", count: 83), currentStem: current)
            check(ok.utf8.count == 255,
                  "«kilde-» 込みで 255 バイトちょうどの名前は受け付ける (実際 \(ok.utf8.count) バイト)")
            assertThrows(String(repeating: "あ", count: 84), .invalidName,
                         "«kilde-» 込みで 255 バイト超の名前は拒否する")
        } catch {
            check(false, "libraryStem の通常経路に成功する (エラー \(error))")
        }
    }

    /// 事前の衝突検査。移動先の stem が «対象以外の既存ファイル» と重なるときは
    /// **何も変えずに** `conflict` を投げる — «録画だけ変わり文字起こしが外れる»
    /// «上書きで消える» を作らないための契約
    private static func checkConflict(folder: URL) {
        let stem = "kilde-20270110-121314"
        let recording = folder.appendingPathComponent("\(stem).mov")
        let companion = folder.appendingPathComponent("\(stem).json")
        createFile(recording, bytes: 16)
        createFile(companion, bytes: 8)
        // 衝突源: «衝突» という stem の既存ファイル。拡張子は録画と違う (.json) が
        // それでも衝突とみなす — «同じ stem の別録画» を作らないため
        let collidee = folder.appendingPathComponent("kilde-衝突.json")
        createFile(collidee, bytes: 8)
        let attempted = RenameMutexBox<[String]>([])
        let neverReached: LibraryRecordingRename.Renamer = { source, _ in
            attempted.with { $0.append(source.lastPathComponent) }
            throw NSError(domain: "kilde-selftest-library-rename", code: 1)
        }
        do {
            _ = try LibraryRecordingRename.rename(
                recording: recording,
                companionFiles: [companion],
                newStem: "kilde-衝突",
                renamer: neverReached)
            check(false, "移動先の stem 衝突は conflict で拒否する")
        } catch let error as LibraryRecordingRename.RenameError {
            check(error == .conflict,
                  "移動先の stem 衝突は conflict で拒否する (\(error) が返る)")
        } catch {
            check(false, "移動先の stem 衝突は conflict で拒否する (想定外のエラー \(error))")
        }
        check(attempted.current.isEmpty,
              "衝突のときは 1 件もリネームを試みない (試行 \(attempted.current.count) 件)")
        check(FileManager.default.fileExists(atPath: recording.path),
              "衝突のときは録画が旧名のまま残る")
        check(FileManager.default.fileExists(atPath: companion.path),
              "衝突のときはサイドカーが旧名のまま残る")
        check(FileManager.default.fileExists(atPath: collidee.path),
              "衝突の相手のファイルは無傷で残る")
        // «枝番も衝突源になる» — «新しい名前-2» という stem が既存のときは
        // «-2.json» (伴走の枝番) の移動先が埋まっているので中断する
        let branchCompanion = folder.appendingPathComponent("\(stem)-2.json")
        createFile(branchCompanion, bytes: 8)
        let branchCollidee = folder.appendingPathComponent("kilde-衝突2-2.srt")
        createFile(branchCollidee, bytes: 8)
        do {
            _ = try LibraryRecordingRename.rename(
                recording: recording,
                companionFiles: [companion, branchCompanion],
                newStem: "kilde-衝突2",
                renamer: neverReached)
            check(false, "枝番の移動先の衝突 («衝突2-2» が既存) も conflict で拒否する")
        } catch let error as LibraryRecordingRename.RenameError {
            check(error == .conflict,
                  "枝番の移動先の衝突 («衝突2-2» が既存) も conflict で拒否する (\(error) が返る)")
        } catch {
            check(false, "枝番の移動先の衝突 («衝突2-2» が既存) も conflict で拒否する (想定外のエラー \(error))")
        }
        check(FileManager.default.fileExists(atPath: branchCollidee.path),
              "枝番の衝突の相手も無傷で残る")
    }

    /// 録画本体が変えられないときは **何も変えずに** throw する —
    /// «本体は新しい名前なのにサイドカーだけ旧名» を作らないための契約。
    /// «サイドカーに触っていない» も試行の記録で確認する (削除の
    /// checkAbortOnRecordingFailure と同じ作り)
    private static func checkAbortOnRecordingFailure(folder: URL) {
        let stem = "kilde-20270103-040506"
        let recording = folder.appendingPathComponent("\(stem).mov")
        let companion = folder.appendingPathComponent("\(stem).json")
        createFile(recording, bytes: 16)
        createFile(companion, bytes: 8)
        let attempted = RenameMutexBox<[URL]>([])
        let alwaysFails: LibraryRecordingRename.Renamer = { url, _ in
            attempted.with { $0.append(url) }
            throw NSError(domain: "kilde-selftest-library-rename", code: 2)
        }
        do {
            _ = try LibraryRecordingRename.rename(
                recording: recording, companionFiles: [companion],
                newStem: "失敗会議", renamer: alwaysFails)
            check(false, "録画本体の失敗は throw として返る")
        } catch {
            check(true, "録画本体の失敗は throw として返る")
        }
        let attempts = attempted.current
        check(attempts == [recording],
              "録画本体の失敗ではサイドカーに触らない (試行 \(attempts.count) 件)")
        check(FileManager.default.fileExists(atPath: recording.path),
              "録画本体の失敗では録画が旧名のまま残る")
        check(FileManager.default.fileExists(atPath: companion.path),
              "録画本体の失敗ではサイドカーに触らない")
    }

    /// 伴走の 1 件が変えられなかったときは打ち切らず、**残りを返す** —
    /// «本体は新しい名前» の状態では «残ったサイドカー» を案内する方が
    /// 次の一手 («Finder で変える» «もう一度文字起こし») に進みやすい、
    /// という判断の検証 (削除の checkLeftoverCompanion と同じ枠組み)
    private static func checkLeftoverCompanion(folder: URL) {
        let stem = "kilde-20270104-050607"
        let recording = folder.appendingPathComponent("\(stem).mov")
        let json = folder.appendingPathComponent("\(stem).json")
        let srt = folder.appendingPathComponent("\(stem).srt")
        createFile(recording, bytes: 16)
        createFile(json, bytes: 8)
        createFile(srt, bytes: 8)
        let failsForSRT: LibraryRecordingRename.Renamer = { source, destination in
            if source.lastPathComponent.hasSuffix(".srt") {
                throw NSError(domain: "kilde-selftest-library-rename", code: 3)
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        do {
            let leftovers = try LibraryRecordingRename.rename(
                recording: recording,
                companionFiles: [json, srt],
                newStem: "kilde-部分会議",
                renamer: failsForSRT)
            check(leftovers == [srt],
                  "変えられなかったサイドカーだけが返る (実際 \(leftovers.map(\.lastPathComponent)))")
        } catch {
            check(false, "サイドカーの失敗では throw しない (エラー \(error))")
        }
        check(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("kilde-部分会議.mov").path),
            "サイドカーの失敗があっても録画本体は «kilde-部分会議.mov» になる")
        check(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("kilde-部分会議.json").path),
            "失敗しなかったサイドカーは新しい名前になる")
        check(FileManager.default.fileExists(atPath: srt.path),
              "失敗したサイドカーは旧名のまま残る")
    }

    /// 保存先フォルダが読めなかったときは何も変えずに throw する —
    /// «衝突なし» と誤認して進むと、後段の moveItem で初めて失敗し
    /// «録画だけ新しい名前» を作りかねない («何も変えない» の契約)。
    /// フォルダごと消した場合を想定する
    private static func checkUnreadableDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-selftest-library-rename-missing-\(UUID().uuidString)")
        do {
            _ = try LibraryRecordingRename.rename(
                recording: missing.appendingPathComponent("kilde-20270108-101112.mov"),
                companionFiles: [],
                newStem: "どっかの会議",
                renamer: LibraryRecordingRename.systemRenamer)
            check(false, "読めないフォルダでは throw する")
        } catch let error as LibraryRecordingRename.RenameError {
            check(error == .directoryUnreadable,
                  "読めないフォルダでは directoryUnreadable を投げる (\(error) が返る)")
        } catch {
            check(false, "読めないフォルダでは throw する (想定外のエラー \(error))")
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
            print("selftest: library-rename OK: \(label)")
        } else {
            failures += 1
            print("selftest: library-rename FAIL: \(label)")
        }
    }
}

/// テスト用の小さな可変箱 (closure からの書き込みを集めるため)。
/// SelfTestLibraryDelete の MutexBox と同じ契約 — セルフテストは単一スレッドで
/// 動くのでロックは要らないが、«closure が外の var を捕まえる» のを避ける。
/// 名前を変えているのは **型名がモジュールで 1 つ** (アクセス修飾子は
/// 名前空間を作らない) ので、同名だと SelfTestLibraryDelete 側の定義と
/// 再定義エラーになるため
private final class RenameMutexBox<T> {
    private var value: T
    init(_ value: T) { self.value = value }
    func with(_ body: (inout T) -> Void) {
        body(&value)
    }
    var current: T { value }
}
