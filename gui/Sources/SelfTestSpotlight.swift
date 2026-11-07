import Foundation
import CoreSpotlight

/// Spotlight 対応 (issue #502) の UI 無し検証。
/// «CSSearchableItem の生成» «差分計算 (manifest 台帳)» «Spotlight アクティビティからの
/// URL 復元» の純関数を、一時ディレクトリの合成録画で確かめる。
///
/// **実機の Spotlight 索引には書き込まない** — 触れるのは SpotlightItemFactory
/// (純関数) と SpotlightPreferences だけで、CSSearchableIndex への反映
/// (SpotlightExporter.sync / clearAll) はこのテストから呼ばない。
/// «実際に Spotlight で見つかるか» «クリックでライブラリが開くか» は手動確認
/// (issue #502 の受け入れ条件) — 索引への書き込みはシステムの状態に依存し、
/// 自動検証には向かないため。
///
/// 実録画を伴わないため、録画のスロット (画面収録・マイクの権限、スピーカー) を
/// 占有しない — 並行する録画テストと同時に回せる。
///
/// 使い方: `KILDE_GUI_SELFTEST_SPOTLIGHT=1 <GUI>` (AppDelegate.runIfRequested から配線)
@MainActor
enum SelfTestSpotlight {

    private static var failures = 0

    static func run() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-selftest-spotlight-\(UUID().uuidString)")
        // defer で消さない — run() は必ず exit() で終わるため defer は一度も走らず
        // 一時ディレクトリが残る (SelfTestLibrarySearch と同じ流儀)。exit の前に明示的に消す
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("selftest: spotlight failed to create temp dir: \(error)")
            try? FileManager.default.removeItem(at: directory)
            exit(1)
        }

        // 合成録画 4 件: A (txt サイドカー) / B (json サイドカー) / C (サイドカーなし) /
        // D (巨大セグメント 1 件 — textContent 上限の検証)
        let stampA = "20261101-100000"
        let stampB = "20261102-110000"
        let stampC = "20261103-120000"
        let stampD = "20261104-130000"
        writeRecording(directory: directory, stem: "kilde-\(stampA)", ext: "mov")
        writeSidecar(
            directory: directory, stem: "kilde-\(stampA)", ext: "txt",
            body: """
            [00:00:00] 予算の話を始めます
            [00:00:10] スポットライト対応を進めます
            """)
        writeRecording(directory: directory, stem: "kilde-\(stampB)", ext: "mp4")
        writeJSONSidecar(directory: directory, stem: "kilde-\(stampB)")
        writeRecording(directory: directory, stem: "kilde-\(stampC)", ext: "mov")
        writeRecording(directory: directory, stem: "kilde-\(stampD)", ext: "mov")
        // 切り詰めの方向を検証できるように、本文の先頭と末尾に **別の** マーカーを置く
        // (cubic レビュー指摘 — «あ» だけだと prefix されても本文が同じで分からない)
        writeSidecar(
            directory: directory, stem: "kilde-\(stampD)", ext: "txt",
            body: "[00:00:00] 冒頭マーカー\(String(repeating: "あ", count: SpotlightItemFactory.textContentLimit + 5_000))末尾マーカー")

        // scan は «ディレクトリが読めない» と «空» を区別する (issue #502) が、
        // ここは存在する一時ディレクトリなので nil にならず、nil なら下の検証が落とす
        let entries = LibraryStore.scan(directory: directory) ?? []
        check(entries.count == 4, "合成録画 4 件を走査できる (実際 \(entries.count) 件)")

        // MARK: 初回の差分 — 全部 «新規»
        let initial = SpotlightItemFactory.diff(manifest: [:], entries: entries)
        check(initial.delete.isEmpty, "空の manifest からの初回は削除 0 件 (実際 \(initial.delete.count) 件)")
        check(initial.index.count == 4, "初回は 4 件すべて索引対象 (実際 \(initial.index.count) 件)")
        check(initial.manifest.count == 4, "manifest に 4 件の fingerprint が載る (実際 \(initial.manifest.count) 件)")

        // MARK: アイテムの中身 (txt の A)
        // «期待するパス» は **走査結果そのもの** から取る — 一時ディレクトリの
        // /var → /private/var の symlink 表記は contentsOfDirectory の返り値と
        // «resolvingSymlinksInPath() の結果» が一致しない実測があるため
        // (2026-11-07 実測: resolvingSymlinksInPath は /var を解決しなかった)。
        // identifier は走査結果の表記そのもの (絶対パス) なので、突合も同じ表記で行う
        let scannedURLs = Dictionary(
            entries.map { ($0.recordingURL.lastPathComponent, $0.recordingURL) },
            uniquingKeysWith: { a, _ in a })
        let missing = URL(fileURLWithPath: "/nonexistent-for-selftest")
        let byID = Dictionary(initial.index.map { ($0.uniqueIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        let urlA = scannedURLs["kilde-\(stampA).mov"] ?? missing
        let itemA = byID[urlA.path]
        check(itemA != nil, "録画 A が identifier (絶対パス) で索引対象に入る")
        if itemA == nil {
            // デバッグ: identifier の表記の違い (/var と /private/var、末尾の空白等) を
            // 出しておく — «走査結果の表記» と «resolvingSymlinksInPath の結果» の突合
            for key in byID.keys.sorted() { print("selftest: spotlight DEBUG byID key=\(key)") }
            print("selftest: spotlight DEBUG urlA.path=\(urlA.path)")
        }
        if let itemA {
            check(itemA.domainIdentifier == SpotlightItemFactory.domainIdentifier,
                  "domainIdentifier が recording")
            // 有効期限の明示を検証する — SDK ヘッダの «By default it's set to 1 month»
            // (既定のままだと約 1 か月で索引から落ち、manifest が進んでいるため
            // 差分同期は再登録しない) を避けるため makeItem が .distantFuture を置く
            check(itemA.expirationDate == .distantFuture,
                  "アイテムの有効期限が無期限 (既定の 1 か月を回避)")
            let attributes = itemA.attributeSet
            check(attributes.title == "kilde-\(stampA)",
                  "タイトルがファイル名の stem (実際 \(attributes.title ?? "(nil)"))")
            // 録画日時は既定名からの解析値 (recordedAt)。文字列で照合する
            // (DateFormatter の設定を合わせる — SelfTestLibrarySearch と同じ理由)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let expectedDate = formatter.date(from: stampA)
            check(attributes.contentCreationDate == expectedDate,
                  "録画日時が既定名から解析される (実際 \(String(describing: attributes.contentCreationDate)))")
            // 長さはサイドカーの最終セグメント終了時刻の近似 (txt は «次の開始» を end にする
            // ので最後は start と等しい = 10 秒)
            let duration = attributes.duration?.doubleValue
            check(duration != nil && abs(duration! - 10) < 0.001,
                  "長さが最終セグメント終了時刻の近似 (実際 \(String(describing: attributes.duration)))")
            check(attributes.textContent?.contains("予算の話を始めます") == true
                  && attributes.textContent?.contains("スポットライト対応を進めます") == true,
                  "文字起こし本文が textContent に載る")
        }

        // MARK: textContent の上限
        let urlD = scannedURLs["kilde-\(stampD).mov"] ?? missing
        if let itemD = byID[urlD.path] {
            let text = itemD.attributeSet.textContent ?? ""
            check(text.count == SpotlightItemFactory.textContentLimit,
                  "textContent が上限文字数に切り詰められる (実際 \(text.count) 字)")
            // 切り詰めは **先頭から** 行われる (prefix)。末尾マーカーは含まれず、
            // 先頭マーカーは残る — «あ» だけだとどちらから切れたか検証できない。
            // textContent はセグメント本文の連結なので «[時刻]» の表記は含まれない
            check(text.hasPrefix("冒頭マーカー"),
                  "切り詰めが先頭を保持する (実際 先頭 20 字: \(text.prefix(20)))")
            check(!text.contains("末尾マーカー"),
                  "切り詰めで末尾マーカーが落ちる")
        } else {
            check(false, "録画 D が索引対象に入る (巨大セグメント)")
        }

        // MARK: サイドカーなしの録画
        let urlC = scannedURLs["kilde-\(stampC).mov"] ?? missing
        if let itemC = byID[urlC.path] {
            check(itemC.attributeSet.textContent == nil,
                  "サイドカーなしの録画は textContent を載せない")
            check(itemC.attributeSet.title == "kilde-\(stampC)",
                  "サイドカーなしの録画もタイトルは載る")
        } else {
            check(false, "サイドカーなしの録画 C も索引対象に入る")
        }

        // MARK: 更新の差分 — B のサイドカーを書き換える
        let urlB = scannedURLs["kilde-\(stampB).mp4"] ?? missing
        // 追い詰める要素は **更新時刻だけ** にする — 本文は既定と同じ UTF-8 バイト数
        // («会議の冒頭の発言です» と «再書き込みキーワード» はどちらも 10 文字 = 30 バイト)
        // にし、fileSize が変わらないようにする (cubic レビュー指摘。サイズも変わると
        // «mtime 以外の要素で差分が出た» ことになり、fingerprint の «更新時刻由来» を
        // 検証できなくなる)
        writeJSONSidecar(directory: directory, stem: "kilde-\(stampB)",
                         extraText: "再書き込みキーワード")
        // 更新時刻を明示的に進める — «書き換えたのに mtime が同じ» を合成側で潰す
        // (fingerprint が更新時刻由来であることの検証も兼ねる)。
        // setModificationDate / removeItem は POSIX のファイル操作なので、
        // symlink 未解決の directory 表記 (/var) のままでも到達できる
        setModificationDate(urlB, to: Date(timeIntervalSince1970: 1_800_000_000))
        setModificationDate(directory.appendingPathComponent("kilde-\(stampB).json"),
                            to: Date(timeIntervalSince1970: 1_800_000_001))
        let afterUpdate = SpotlightItemFactory.diff(manifest: initial.manifest, entries: LibraryStore.scan(directory: directory) ?? [])
        check(afterUpdate.index.count == 1
              && afterUpdate.index.first?.uniqueIdentifier == urlB.path,
              "書き換えた録画 B だけが再索引対象 (実際 \(afterUpdate.index.map(\.uniqueIdentifier)))")
        check(afterUpdate.delete.isEmpty, "変更は «置き換え» のため削除対象にならない (実際 \(afterUpdate.delete.count) 件)")
        if let itemB = afterUpdate.index.first {
            check(itemB.attributeSet.textContent?.contains("再書き込みキーワード") == true,
                  "再索引された item に更新後の本文が載る")
        }

        // MARK: «後から付いたサイドカー» の差分 — C にサイドカーを足す
        writeSidecar(
            directory: directory, stem: "kilde-\(stampC)", ext: "txt",
            body: "[00:00:00] 後から文字起こしを追加しました")
        setModificationDate(urlC, to: Date(timeIntervalSince1970: 1_800_000_010))
        setModificationDate(directory.appendingPathComponent("kilde-\(stampC).txt"),
                            to: Date(timeIntervalSince1970: 1_800_000_011))
        let afterAdded = SpotlightItemFactory.diff(manifest: initial.manifest, entries: LibraryStore.scan(directory: directory) ?? [])
        check(afterAdded.index.map(\.uniqueIdentifier).sorted() == [urlB.path, urlC.path],
              "«サイドカーが後から付いた» 録画も再索引対象 (実際 \(afterAdded.index.map(\.uniqueIdentifier).sorted()))")

        // MARK: 削除の差分 — A の録画を消す
        try? FileManager.default.removeItem(at: urlA)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("kilde-\(stampA).txt"))
        let afterDelete = SpotlightItemFactory.diff(manifest: initial.manifest, entries: LibraryStore.scan(directory: directory) ?? [])
        check(afterDelete.delete == [urlA.path], "消した録画 A だけが削除対象 (実際 \(afterDelete.delete))")
        check(!afterDelete.index.contains(where: { $0.uniqueIdentifier == urlA.path }),
              "消した録画 A は索引対象にならない")

        // MARK: manifest にだけ残る identifier («前回は登録したが今回の走査に無い»)
        // — «identifier は分かるが entry が無い» 状態。manifest にだけ存在する
        // identifier が削除対象に変わること
        let phantomManifest = initial.manifest
        let phantomDiff = SpotlightItemFactory.diff(
            manifest: phantomManifest.merging(["/nonexistent/kilde-99999999-999999.mov": "0|0|none"],
                                              uniquingKeysWith: { a, _ in a }),
            entries: LibraryStore.scan(directory: directory) ?? [])
        check(phantomDiff.delete.contains("/nonexistent/kilde-99999999-999999.mov"),
              "実在しない identifier が削除対象になる")

        // MARK: fingerprint が取れない録画 (cubic レビュー指摘)
        // **実ファイルが読めない entry** を diff に直接渡し、diff の
        // «fingerprint 取得の guard» の分岐を検証する — 上の phantom (manifest にだけ
        // 残る identifier) とは別の経路。存在しない recording URL は
        // contentModificationDate が取れないため fingerprint が nil になる
        let ghostURL = URL(fileURLWithPath: "/nonexistent-for-selftest/ghost.mov")
        let ghost = LibraryEntry(id: ghostURL, recordingURL: ghostURL,
                                 transcriptURL: nil, recordedAt: Date(), segments: nil)
        check(SpotlightItemFactory.fingerprint(for: ghost) == nil,
              "存在しない録画の fingerprint が nil (取得できない)")
        let ghostDiffEmpty = SpotlightItemFactory.diff(manifest: [:], entries: [ghost])
        check(ghostDiffEmpty.index.isEmpty && ghostDiffEmpty.delete.isEmpty,
              "fingerprint が取れない録画は新規に索引対象にならず、削除もない")
        let ghostDiffStale = SpotlightItemFactory.diff(
            manifest: [ghostURL.path: "0|0|none"], entries: [ghost])
        check(ghostDiffStale.delete == [ghostURL.path] && ghostDiffStale.index.isEmpty,
              "fingerprint が取れない録画が manifest に残っていたら削除対象になる")

        // MARK: Spotlight アクティビティからの URL 復元
        // userInfo のキーは macOS では CSSearchableItemActivityIdentifier
        // (SpotlightItemFactory.recordingURL のコメント — iOS とは定数名が違う)
        let activity = NSUserActivity(activityType: SpotlightItemFactory.activityType)
        activity.addUserInfoEntries(from: [
            CSSearchableItemActivityIdentifier: urlB.path,
        ])
        check(SpotlightItemFactory.recordingURL(fromActivity: activity) == urlB,
              "Spotlight のアクティビティから録画の URL が復元される")
        let foreign = NSUserActivity(activityType: "com.example.other")
        foreign.addUserInfoEntries(from: [CSSearchableItemActivityIdentifier: urlB.path])
        check(SpotlightItemFactory.recordingURL(fromActivity: foreign) == nil,
              "kilde 以外のアクティビティは復元しない")
        let noIdentifier = NSUserActivity(activityType: SpotlightItemFactory.activityType)
        check(SpotlightItemFactory.recordingURL(fromActivity: noIdentifier) == nil,
              "identifier の無いアクティビティは復元しない")

        // MARK: 設定トグルの既定と往復
        // 往復の検証は **専用スイート** だけで行う — UserDefaults.standard は
        // «この Mac の本物の設定» (spotlightIndexEnabled / manifest 台帳) なので、
        // テストから読みも書きもしない (CodeRabbit レビュー指摘。読んで戻す方式だと
        // «テストが標準ドメインに触れる» こと自体がリスクで、専用スイートで十分)
        let testDefaults = UserDefaults(suiteName: "kilde-selftest-spotlight-prefs")
        testDefaults?.removePersistentDomain(forName: "kilde-selftest-spotlight-prefs")
        check(SpotlightPreferences.isEnabled(testDefaults!) == true,
              "キーが無ければオン (既定オン)")
        SpotlightPreferences.setEnabled(false, defaults: testDefaults!)
        check(SpotlightPreferences.isEnabled(testDefaults!) == false,
              "オフを保存して読める")
        SpotlightPreferences.setEnabled(true, defaults: testDefaults!)
        check(SpotlightPreferences.isEnabled(testDefaults!) == true,
              "オンに戻せる")
        testDefaults?.removePersistentDomain(forName: "kilde-selftest-spotlight-prefs")

        try? FileManager.default.removeItem(at: directory)

        print("selftest: spotlight checks=\(failures == 0 ? "all passed" : "\(failures) failures")")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 合成ヘルパー

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("selftest: spotlight OK \(label)")
        } else {
            failures += 1
            print("selftest: spotlight FAIL \(label)")
        }
    }

    /// 空の録画ファイルを作る (走査は «kilde- 接頭辞 + 拡張子» のファイルを見る)。
    /// 形式ごとのパーサは SelfTestLibrarySearch が検証済みなので中身は不要
    private static func writeRecording(directory: URL, stem: String, ext: String) {
        let url = directory.appendingPathComponent("\(stem).\(ext)")
        FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
    }

    /// txt 形式のサイドカー ([HH:MM:SS] 本文)
    private static func writeSidecar(directory: URL, stem: String, ext: String, body: String) {
        let url = directory.appendingPathComponent("\(stem).\(ext)")
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// json 形式のサイドカー (TranscriptSegment 配列。extraText で本文を差し替えられる)
    private static func writeJSONSidecar(directory: URL, stem: String, extraText: String? = nil) {
        let url = directory.appendingPathComponent("\(stem).json")
        let segments: [[String: Any]] = [
            ["start": 0, "end": 10, "text": extraText ?? "会議の冒頭の発言です"],
            ["start": 10, "end": 20, "text": "二つ目のセグメントです"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: segments) else {
            check(false, "json サイドカーの合成に成功する")
            return
        }
        try? data.write(to: url)
    }

    /// 更新時刻を明示的に設定する (fingerprint が «更新時刻の変化» を検出することの
    /// 検証のため。書き換え直後の mtime が同一秒に留まる環境で «更新が検出されない»
    /// ことを潰す)
    private static func setModificationDate(_ url: URL, to date: Date) {
        try? FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.path)
    }
}
