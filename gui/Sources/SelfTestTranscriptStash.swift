import Foundation
import KildeCore

/// 要約経路の退避書き出し (TranscriptStash) のセルフテスト
/// (KILDE_GUI_SELFTEST_TRANSCRIPT_STASH=1、kilde#629)。
///
///     KILDE_GUI_SELFTEST_TRANSCRIPT_STASH=1 KildeGUI.app/Contents/MacOS/KildeGUI
///
/// **実録画・実文字起こしを伴わない** — 文字起こしの完了後に走る後半処理
/// (TranscriptionCoordinator.summarizeAndWrite: 退避 → 要約 → 確定書き出し) を、
/// 要約ステップのスタブ (SummaryStep 注入) と仮の録画ファイルで決定的に確かめる
/// (エンジン kilde-cli-swift#153 の TranscriptionRunTests と同じ検証方式)。
/// 退避は «要約の生成中に異常終了しても完走済みの文字起こしを失わない»
/// (エンジン kilde-cli-swift#153 — GUI の要約経路はエンジンの TranscriptionRun を
/// 経由しないため同じ窓を自前で塞ぐ) の GUI 側の実装で、ここで縛る契約は:
/// - 要約の道中で退避 (隠しファイル `.<確定サイドカー名>.stash-<UUID>`) が存在する
/// - 要約の成功 → 確定 (要約つき) が残り、退避は消える
/// - **中止** → 退避も確定も残らない (隠しファイルも含めて全皆無 —
///   «中止時は確定ファイルを書かない» 契約。kilde-cli-swift 側 DESIGN.md §4)
/// - 書き出し直前の中止 (checkCancellation) → 退避を削除して中止になる
/// - 要約の失敗 → 要約なしの確定が残り、退避は消える (kilde-cli-swift#151 と同じ)
/// - 要約のスキップ (環境・権利のゲート) → 要約なしの確定が残り、退避は消える
/// - 異常終了で残った孤児退避は、次の要約つき実行の冒頭で連番候補へ回復される
/// - 既存の確定サイドカーは上書きせず連番へ退避する (kilde-cli-swift#36 契約)
/// - 退避の書き出しに失敗したら要約に進まず失敗する (fail loud — エンジンと同じ)
///
/// 要約ステップに入るケースは MeetingSummarizer.unsupportedReason が nil の環境
/// (Apple Intelligence が有効な macOS 26+) が前提 — 非対応環境ではその旨を出して
/// スキップし、環境に依らないケース (ゲートスキップ・孤児回復・上書き禁止・
/// fail loud) だけを実行する。全ケースが通れば終了コード 0、1 件でも外れれば 1
/// (SelfTestMeeting と同じ合否)。
/// «要約の道中» の待ち。cancel が届くまで最大 5 秒待つ (届かなければ打ち切る
/// — テスト自体のハングを避けるための上限)。`nonisolated` なのは要約ステップの
/// スタブ (SummaryStep — MainActor に閉じない注入口) から呼ぶため
/// «要約の道中» の待ち。cancel が届くまで最大 5 秒待つ (届かなければ打ち切る
/// — テスト自体のハングを避けるための上限)。ファイル内の自由関数 (非分離) なので、
/// 要約ステップのスタブ (SummaryStep — MainActor に閉じない注入口) からも呼べる。
/// ファイル外からは見えない (private) — 規則の検査に使う場所を限るため
private func stashTestWaitForCancellation() async {
    for _ in 0..<250 where !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

extension SelfTest {
    /// MainActor の実行を止めずに非同期で検証を回し、終わったら終了する
    /// (SelfTestFollowup / SelfTestPro と同じ — セマフォ待ちで固めない)。
    /// 検査本体 (runTranscriptStashChecks) は summarizeAndWrite の await を
    /// 含むため async で書き、ここから Task で起こす
    static func runTranscriptStash() {
        Task { await runTranscriptStashChecks() }
    }

    @MainActor
    private static func runTranscriptStashChecks() async -> Never {
        var failures = 0
        var skipped = 0
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-selftest-stash-\(UUID().uuidString)", isDirectory: true)

        func mark(_ ok: Bool, _ name: String, _ detail: String = "") {
            let markText = ok ? "ok" : "FAIL"
            print("selftest: transcript-stash[\(markText)] \(name)" + (ok || detail.isEmpty ? "" : " → \(detail)"))
            if !ok { failures += 1 }
        }

        /// ワークスペース (一時ディレクトリ + 仮の録画ファイル) を作る。
        /// 録画ファイルの中身は読まれない (TranscriptWriter は属性の作成日時だけ
        /// 見る) ので、名前だけのファイルで足りる
        func makeWorkspace(_ stem: String) -> (directory: URL, recording: URL) {
            let directory = root.appendingPathComponent(stem, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let recording = directory.appendingPathComponent("\(stem).mp4")
            FileManager.default.createFile(atPath: recording.path, contents: Data("recording".utf8))
            return (directory, recording)
        }

        func cleanup(_ directory: URL) {
            try? FileManager.default.removeItem(at: directory)
        }

        /// 隠しファイルも含めた全エントリ名
        func allNames(in directory: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])) ?? [])
                .map { $0.lastPathComponent }
        }

        func stashNames(in directory: URL) -> [String] {
            allNames(in: directory).filter { $0.hasPrefix(".") && $0.contains(".stash-") }
        }

        /// 確定サイドカーと録画ファイル (可視ファイル) の名前
        func visibleNames(in directory: URL) -> [String] {
            allNames(in: directory).filter { !$0.hasPrefix(".") }
        }

        func job(recording: URL, template: MeetingTemplate?) -> TranscriptionCoordinator.Job {
            TranscriptionCoordinator.Job(
                recordingURL: recording,
                format: .markdown,
                summaryTemplate: template,
                localeID: "ja-JP",
                recordingDuration: nil)
        }

        let segments = [
            TranscriptSegment(start: 0, end: 1.0, text: "テスト用の書き起こし第一文", speaker: nil),
            TranscriptSegment(start: 1.0, end: 2.0, text: "テスト用の書き起こし第二文", speaker: "0"),
        ]
        let stubSummary = MeetingSummary(
            points: ["スタブ要約の要点"], decisions: [], actions: [])
        let canRunSummaryStep = MeetingSummarizer.unsupportedReason == nil

        // 1. 要約の道中で退避が存在し、道中の«中止»で退避も確定も残らない
        //    («中止時は確定ファイルを書かない» 契約の本体。エンジンの
        //    testSummaryCancellationStillAbortsSidecar と同じ検証)
        //    **要約ステップに入るケース** — スタブに届くのは
        //    MeetingSummarizer.unsupportedReason が nil の環境だけ (ゲートが
        //    unsupported の案内に倒すとスタブは呼ばれない) ので、非対応環境では
        //    スキップする (ヘッダの注記どおり)
        if canRunSummaryStep {
            let (directory, recording) = makeWorkspace("stash-cancel-during-summary")
            let parentPath = directory.path
            let coordinator = TranscriptionCoordinator()
            coordinator.licenseProvider = { LicenseContext(entitlement: .macAppStore) }
            // スタブ (nonisolated async) から結果を運ぶための箱。
            // @unchecked Sendable なのは観測結果の受け渡しだけのため (判定は
            // await 後の MainActor 側で行う)
            final class Box: @unchecked Sendable {
                var stashNamesDuringSummary: [String] = []
            }
            let box = Box()
            // スタブの開始を待つための信号 (固定スリープの競合を避ける)。
            // スタブが退避の観測を終えたことを親に知らせてから cancel する —
            // sleep だと MainActor の遅れで cancel がスタブ開始前に着地し、
            // «道中の中止» を再現できずに断言が外れうる
            let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
            let step: TranscriptionCoordinator.SummaryStep = { _, _, _, _, _ in
                // 要約の開始時点で退避が在ること («窓が塞がっている» の証拠)。
                // 退避は隠しファイルの命名規約 (. 接頭辞 + .stash- マーカー) に従う
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: parentPath)) ?? [])
                    .filter { $0.hasPrefix(".") && $0.contains(".stash-") }
                box.stashNamesDuringSummary = names
                startedContinuation.yield()
                startedContinuation.finish()
                await stashTestWaitForCancellation()
                return stubSummary
            }
            let task = Task {
                try await coordinator.summarizeAndWrite(
                    segments, job: job(recording: recording, template: .standard), summarize: step)
            }
            for await _ in started {}  // スタブが開始 (退避を観測) するまで待つ
            task.cancel()
            var thrown: Error?
            do {
                _ = try await task.value
            } catch {
                thrown = error
            }
            mark(!box.stashNamesDuringSummary.isEmpty, "要約の道中で退避 (隠しファイル .*.stash-*) が存在する",
                 "observed: \(box.stashNamesDuringSummary)")
            mark(thrown != nil, "道中の中止は summarizeAndWrite を投げ出す", "thrown: \(String(describing: thrown))")
            mark(stashNames(in: directory).isEmpty, "中止後に退避が残らない",
                 "remaining: \(stashNames(in: directory))")
            let nonRecording = visibleNames(in: directory).filter { $0 != recording.lastPathComponent }
            mark(nonRecording.isEmpty, "中止後に確定サイドカーも残らない (全皆無)",
                 "remaining: \(nonRecording)")
            cleanup(directory)
        } else {
            skipped += 1
            print("selftest: transcript-stash[skip] 道中の中止のケース (MeetingSummarizer 非対応環境: \(MeetingSummarizer.unsupportedReason ?? "-"))")
        }

        // 2. 書き出し直前の«中止»でも退避を削除する (エンジンの
        //    testCancellationBeforeSidecarWriteRemovesStash と同じ検証 — スタブは
        //    要約を返しきるが、そのあとの checkCancellation が拾う)。
        //    ケース同心の «スタブに届くのは要約ステップに入る環境だけ» のため
        //    非対応環境ではスキップする
        if canRunSummaryStep {
            let (directory, recording) = makeWorkspace("stash-cancel-before-write")
            let coordinator = TranscriptionCoordinator()
            coordinator.licenseProvider = { LicenseContext(entitlement: .macAppStore) }
            let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
            let step: TranscriptionCoordinator.SummaryStep = { _, _, _, _, _ in
                // cancel が届くまで待ってから正常に返す — «要約は成功したが
                // そのあとで中止» の経路。開始だけは親に知らせる (上と同じ理由)
                startedContinuation.yield()
                startedContinuation.finish()
                await stashTestWaitForCancellation()
                return stubSummary
            }
            let task = Task {
                try await coordinator.summarizeAndWrite(
                    segments, job: job(recording: recording, template: .standard), summarize: step)
            }
            for await _ in started {}  // スタブが開始するまで待つ
            task.cancel()
            var thrown: Error?
            do {
                _ = try await task.value
            } catch {
                thrown = error
            }
            mark(thrown != nil, "書き出し直前の中止も summarizeAndWrite を投げ出す", "thrown: \(String(describing: thrown))")
            mark(stashNames(in: directory).isEmpty, "書き出し直前の中止でも退避が残らない",
                 "remaining: \(stashNames(in: directory))")
            let nonRecording = visibleNames(in: directory).filter { $0 != recording.lastPathComponent }
            mark(nonRecording.isEmpty, "書き出し直前の中止でも確定サイドカーが残らない",
                 "remaining: \(nonRecording)")
            cleanup(directory)
        } else {
            skipped += 1
            print("selftest: transcript-stash[skip] 書き出し直前の中止のケース (MeetingSummarizer 非対応環境)")
        }

        // 3. 要約の成功 → 確定 (要約つき) が残り、退避は消える
        if canRunSummaryStep {
            let (directory, recording) = makeWorkspace("stash-success-summary")
            let coordinator = TranscriptionCoordinator()
            coordinator.licenseProvider = { LicenseContext(entitlement: .macAppStore) }
            var completion: TranscriptionCoordinator.Completion?
            var thrown: Error?
            do {
                completion = try await coordinator.summarizeAndWrite(
                    segments, job: job(recording: recording, template: .standard),
                    summarize: { _, _, _, _, _ in stubSummary })
            } catch {
                thrown = error
            }
            mark(thrown == nil, "要約の成功は summarizeAndWrite を投げ出さない", "error: \(String(describing: thrown))")
            mark(completion?.summary != nil && completion?.summaryNote == nil,
                 "要約の成功は Completion (summary あり, note 無し) を返す",
                 "completion: \(String(describing: completion))")
            let stem = recording.deletingPathExtension().lastPathComponent
            let content = (try? String(contentsOf: directory.appendingPathComponent("\(stem).md"), encoding: .utf8)) ?? ""
            mark(content.contains("スタブ要約の要点") && content.contains("テスト用の書き起こし第一文"),
                 "確定サイドカーに文字起こしと要約が載る", "content: \(content.prefix(200))")
            mark(stashNames(in: directory).isEmpty, "成功後に退避が残らない",
                 "remaining: \(stashNames(in: directory))")
            cleanup(directory)
        } else {
            skipped += 1
            print("selftest: transcript-stash[skip] 要約ステップのケース (MeetingSummarizer 非対応環境: \(MeetingSummarizer.unsupportedReason ?? "-"))")
        }

        // 4. 要約の失敗 → 要約なしの確定が残り、退避は消える
        //    («要約が失敗しても文字起こしは残るべき» — kilde-cli-swift#151 と同じ契約)
        if canRunSummaryStep {
            let (directory, recording) = makeWorkspace("stash-summary-failure")
            let coordinator = TranscriptionCoordinator()
            coordinator.licenseProvider = { LicenseContext(entitlement: .macAppStore) }
            struct StubSummaryError: Error, CustomStringConvertible {
                var description: String { "stub summary failure" }
            }
            var completion: TranscriptionCoordinator.Completion?
            var thrown: Error?
            do {
                completion = try await coordinator.summarizeAndWrite(
                    segments, job: job(recording: recording, template: .standard),
                    summarize: { _, _, _, _, _ in throw StubSummaryError() })
            } catch {
                thrown = error
            }
            mark(thrown == nil, "要約の失敗はジョブを失敗にしない (throw しない)", "error: \(String(describing: thrown))")
            mark(completion?.summary == nil && completion?.summaryNote != nil,
                 "要約の失敗は summaryNote で伝える", "completion: \(String(describing: completion))")
            let stem = recording.deletingPathExtension().lastPathComponent
            let content = (try? String(contentsOf: directory.appendingPathComponent("\(stem).md"), encoding: .utf8)) ?? ""
            mark(content.contains("テスト用の書き起こし第一文") && !content.contains("スタブ要約の要点"),
                 "要約の失敗でも確定サイドカー (要約なし) が残る", "content: \(content.prefix(200))")
            mark(stashNames(in: directory).isEmpty, "要約の失敗でも退避が残らない",
                 "remaining: \(stashNames(in: directory))")
            cleanup(directory)
        } else {
            skipped += 1
            print("selftest: transcript-stash[skip] 要約失敗のケース (MeetingSummarizer 非対応環境)")
        }

        // 5. 要約のスキップ (環境・権利のゲート) でも退避は確定と入れ替わる。
        //    権利なしの provider を渡す — Apple Intelligence が有効な環境では
        //    proRequired の案内に、非対応環境では unsupported の案内に倒れるが、
        //    どちらも «要約なしの確定 + 退避の削除» という同じ後段を通る。
        //    **環境に依らず実行できる** ケースとして孤立させている
        do {
            let (directory, recording) = makeWorkspace("stash-gate-skip")
            let coordinator = TranscriptionCoordinator()
            coordinator.licenseProvider = { LicenseContext(entitlement: .none) }
            var completion: TranscriptionCoordinator.Completion?
            var thrown: Error?
            do {
                completion = try await coordinator.summarizeAndWrite(
                    segments, job: job(recording: recording, template: .standard))
            } catch {
                thrown = error
            }
            mark(thrown == nil, "要約のスキップは summarizeAndWrite を投げ出さない", "error: \(String(describing: thrown))")
            mark(completion?.summary == nil && completion?.summaryNote != nil,
                 "要約のスキップは案内 (note) を運ぶ", "completion: \(String(describing: completion))")
            let stem = recording.deletingPathExtension().lastPathComponent
            let content = (try? String(contentsOf: directory.appendingPathComponent("\(stem).md"), encoding: .utf8)) ?? ""
            mark(content.contains("テスト用の書き起こし第一文"),
                 "要約のスキップでも確定サイドカー (要約なし) が残る", "content: \(content.prefix(200))")
            mark(stashNames(in: directory).isEmpty, "要約のスキップでも退避が残らない",
                 "remaining: \(stashNames(in: directory))")
            cleanup(directory)
        }

        // 6. 異常終了で残った孤児退避は、次の要約つき実行の冒頭で回復される
        //    (確定の連番候補へ no-replace 配置 — 孤児は消える)。flock の生存
        //    マーカー無しの退避ファイルを手書きして «プロセスが死んだ退避» を模す
        do {
            let (directory, recording) = makeWorkspace("stash-orphan-recovery")
            let stem = recording.deletingPathExtension().lastPathComponent
            let sidecarName = "\(stem).md"
            let orphanName = ".\(sidecarName).stash-\(UUID().uuidString)"
            let orphanURL = directory.appendingPathComponent(orphanName)
            FileManager.default.createFile(atPath: orphanURL.path, contents: Data("孤児退避の内容".utf8))
            let coordinator = TranscriptionCoordinator()
            coordinator.licenseProvider = { LicenseContext(entitlement: .none) }
            var completion: TranscriptionCoordinator.Completion?
            var thrown: Error?
            do {
                completion = try await coordinator.summarizeAndWrite(
                    segments, job: job(recording: recording, template: .standard))
            } catch {
                thrown = error
            }
            mark(thrown == nil, "孤児回復は summarizeAndWrite を投げ出さない", "error: \(String(describing: thrown))")
            let recoveredContent = (try? String(contentsOf: directory.appendingPathComponent(sidecarName), encoding: .utf8)) ?? ""
            mark(recoveredContent == "孤児退避の内容",
                 "孤児退避は第一候補の確定名へ回復される", "content: \(recoveredContent.prefix(100))")
            mark(!FileManager.default.fileExists(atPath: orphanURL.path),
                 "回復された孤児退避は消える", "remaining: \(allNames(in: directory))")
            // 今回の実行の確定は第一候補が使用済みなので連番 (-2) へ退避する
            let newContent = (try? String(contentsOf: directory.appendingPathComponent("\(stem)-2.md"), encoding: .utf8)) ?? ""
            mark(completion != nil && newContent.contains("テスト用の書き起こし第一文"),
                 "回復後の今回の確定は連番候補へ書かれる (既存を壊さない)", "content: \(newContent.prefix(100))")
            mark(stashNames(in: directory).isEmpty, "孤児回復の実行でも退避が残らない",
                 "remaining: \(stashNames(in: directory))")
            cleanup(directory)
        }

        // 7. 既存の確定サイドカーは上書きしない (kilde-cli-swift#36 契約の維持)
        do {
            let (directory, recording) = makeWorkspace("stash-no-overwrite")
            let stem = recording.deletingPathExtension().lastPathComponent
            let existing = directory.appendingPathComponent("\(stem).md")
            FileManager.default.createFile(atPath: existing.path, contents: Data("既存の文字起こし".utf8))
            let coordinator = TranscriptionCoordinator()
            coordinator.licenseProvider = { LicenseContext(entitlement: .none) }
            var thrown: Error?
            do {
                _ = try await coordinator.summarizeAndWrite(
                    segments, job: job(recording: recording, template: .standard))
            } catch {
                thrown = error
            }
            mark(thrown == nil, "既存サイドカーがある実行は summarizeAndWrite を投げ出さない", "error: \(String(describing: thrown))")
            let existingContent = (try? String(contentsOf: existing, encoding: .utf8)) ?? ""
            mark(existingContent == "既存の文字起こし",
                 "既存の確定サイドカーは上書きされない (#36)", "content: \(existingContent.prefix(100))")
            let newContent = (try? String(contentsOf: directory.appendingPathComponent("\(stem)-2.md"), encoding: .utf8)) ?? ""
            mark(newContent.contains("テスト用の書き起こし第一文"),
                 "今回の確定は連番候補へ書かれる", "content: \(newContent.prefix(100))")
            cleanup(directory)
        }

        // 8. 退避の書き出しに失敗したら要約に進まず失敗する (fail loud —
        //    エンジンと同じ。退避なしで要約に進むと塞いだはずの窓が黙って再開する)。
        //    «録画の親ディレクトリ» として通常ファイルを渡すと、退避 (とサイドカー)
        //    の書き出しが必ず ENOTDIR で落ちるため、決定的に失敗を起こせる
        do {
            let directory = root.appendingPathComponent("stash-fail-loud", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fakeDirectory = directory.appendingPathComponent("not-a-directory")
            FileManager.default.createFile(atPath: fakeDirectory.path, contents: Data("x".utf8))
            let recording = fakeDirectory.appendingPathComponent("stash-fail-loud.mp4")
            let coordinator = TranscriptionCoordinator()
            coordinator.licenseProvider = { LicenseContext(entitlement: .macAppStore) }
            // スタブに届いたら «要約に進んでしまった» — スタブ内で MainActor の
            // 判定を呼べない (nonisolated) のため、フラグで運んで外で判定する
            final class Box: @unchecked Sendable {
                var reachedSummary = false
            }
            let box = Box()
            let step: TranscriptionCoordinator.SummaryStep = { _, _, _, _, _ in
                box.reachedSummary = true
                return stubSummary
            }
            var thrown: Error?
            do {
                _ = try await coordinator.summarizeAndWrite(
                    segments, job: job(recording: recording, template: .standard), summarize: step)
            } catch {
                thrown = error
            }
            mark(!box.reachedSummary, "退避の書き出しに失敗した実行は要約ステップに進まない")
            mark(thrown != nil, "退避の書き出しの失敗は fail loud で投げられる",
                 "thrown: \(String(describing: thrown))")
            cleanup(directory)
        }

        cleanup(root)
        print("selftest: transcript-stash failures=\(failures) skipped=\(skipped)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
