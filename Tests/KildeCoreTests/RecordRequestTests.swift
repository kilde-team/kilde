import XCTest
@testable import KildeCore

/// GUI の選択 (RecordRequest) → RecordOptions の変換 (issue #18)。
/// CLI と同じ RecordSettings.apply を通ることを、設定ファイルの値が効くことで確かめる
final class RecordRequestTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-request-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testDisplayTargetRecordsVideoIntoDirectory() throws {
        var request = RecordRequest(outputDirectory: dir)
        request.target = .display(index: 1)
        let options = try request.makeOptions(config: KildeConfig())
        XCTAssertEqual(options.displayIndex, 1)
        XCTAssertTrue(options.windowMatches.isEmpty)
        XCTAssertTrue(options.wantsVideo)
        XCTAssertEqual(options.audioSources, [.system])
        XCTAssertEqual(options.trackPolicy, .mixed)
        XCTAssertEqual(options.outputURL?.deletingLastPathComponent().path, dir.path)
        XCTAssertEqual(options.outputURL?.pathExtension, "mov")
        XCTAssertTrue(options.outputURL?.lastPathComponent.hasPrefix("kilde-") ?? false)
    }

    func testWindowTargetPassesWindowID() throws {
        var request = RecordRequest(outputDirectory: dir)
        request.target = .window(id: 4242)
        let options = try request.makeOptions(config: KildeConfig())
        XCTAssertEqual(options.windowMatches, ["4242"])
        XCTAssertTrue(options.wantsVideo)
    }

    func testAudioOnlyWritesM4A() throws {
        var request = RecordRequest(outputDirectory: dir)
        request.target = .audioOnly
        request.captureSystemAudio = false
        request.captureMic = true
        let options = try request.makeOptions(config: KildeConfig())
        XCTAssertFalse(options.wantsVideo)
        XCTAssertEqual(options.audioSources, [.mic])
        XCTAssertEqual(options.outputURL?.pathExtension, "m4a")
    }

    /// 映像なし + 音声なしは録れるものがないので、CLI と同じく開始前に失敗する
    func testAudioOnlyWithoutSourcesFails() {
        var request = RecordRequest(outputDirectory: dir)
        request.target = .audioOnly
        request.captureSystemAudio = false
        XCTAssertEqual(request.audioSourceStrings, ["none"])
        XCTAssertThrowsError(try request.makeOptions(config: KildeConfig()))
    }

    func testDevicesAndTrackPolicy() throws {
        var request = RecordRequest(outputDirectory: dir)
        request.inputDevices = ["UID-1"]
        request.trackPolicy = .separate
        XCTAssertEqual(request.audioSourceCount, 2)
        let options = try request.makeOptions(config: KildeConfig())
        XCTAssertEqual(options.audioSources, [.system, .device("UID-1")])
        XCTAssertEqual(options.trackPolicy, .separate)
    }

    /// GUI で選ばない項目 (codec / カーソル / fps) は設定ファイルの値が効く — CLI と同じ解決経路の確認
    func testConfigValuesStillApply() throws {
        let request = RecordRequest(outputDirectory: dir)
        let options = try request.makeOptions(config: KildeConfig(codec: "hevc", fps: 30, showsCursor: false))
        XCTAssertEqual(options.codec, .hevc)
        XCTAssertEqual(options.fps, 30)
        XCTAssertFalse(options.showsCursor)
    }

    /// 既定名は秒までしか持たないので、止めてすぐ録り直すと同じ名前になる。
    /// そのまま渡すと MovieWriter が既存ファイルを消すため、原子的な予約で別名を取る
    func testDoesNotReuseAnExistingOutputPath() throws {
        let request = RecordRequest(outputDirectory: dir)
        let first = try XCTUnwrap(try request.makeOptions(config: KildeConfig()).outputURL)
        // 1 回目の予約済みファイルを実データで置き換える (前の録画の残骸の代わり)
        FileManager.default.createFile(atPath: first.path, contents: Data("x".utf8))

        let second = try XCTUnwrap(try request.makeOptions(config: KildeConfig()).outputURL)
        XCTAssertNotEqual(second.path, first.path)
        // 予約は 0 バイトのファイルを作る — 存在そのものは正常 (waiting なトークン)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: second.path)[.size] as? Int, 0)
        XCTAssertEqual(second.deletingLastPathComponent().path, dir.path)
        XCTAssertEqual(second.pathExtension, "mov")
    }

    /// 連番も埋まっていたら、既存名を返さずに失敗する (返すと MovieWriter が既存録画を消す)
    func testFailsWhenEveryCandidateNameIsTaken() throws {
        // 既定名は実時刻 (秒) なので、呼び出しの合間に秒が繰り上がるとテストが不安定になる。
        // 候補名を固定して決定的にする
        let base = dir.appendingPathComponent("kilde-20260101-000000.mov")
        let stem = "kilde-20260101-000000"
        for name in ["\(stem).mov", "\(stem)-2.mov", "\(stem)-3.mov"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path,
                                           contents: Data("x".utf8))
        }
        XCTAssertThrowsError(
            try OutputFileReservation.reserve(preferredURL: base, maximumCandidateNumber: 3)
        ) { error in
            XCTAssertEqual((error as? KilError)?.exitCode, 1)
        }
        // 空きがある間は連番を予約する (-3 を消せば -3 が取られる)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(stem)-3.mov"))
        let reused = try OutputFileReservation.reserve(preferredURL: base, maximumCandidateNumber: 3)
        XCTAssertEqual(reused.url.lastPathComponent, "\(stem)-3.mov")
        // 予約済みのファイルが 0 バイトで作られている
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: reused.url.path)[.size] as? Int, 0)
    }

    /// 存在しない保存先を既定に書くと、次回起動時に initial() が黙って fallback に戻してしまう
    func testSavingDefaultsRejectsMissingDirectory() {
        let request = RecordRequest(outputDirectory: dir.appendingPathComponent("gone"))
        XCTAssertThrowsError(try request.savingDefaults(into: KildeConfig()))
    }

    func testMissingDirectoryFails() {
        let request = RecordRequest(outputDirectory: dir.appendingPathComponent("no-such-dir"))
        XCTAssertThrowsError(try request.makeOptions(config: KildeConfig()))
    }

    func testInitialValuesComeFromConfig() {
        let fallback = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let config = KildeConfig(outputDirectory: dir.path,
                                 defaultAudioSources: ["mic", "device:BlackHole 2ch"],
                                 audioTracks: "separate")
        let request = RecordRequest.initial(config: config, fallbackDirectory: fallback)
        XCTAssertFalse(request.captureSystemAudio)
        XCTAssertTrue(request.captureMic)
        XCTAssertEqual(request.inputDevices, ["BlackHole 2ch"])
        XCTAssertEqual(request.trackPolicy, .separate)
        XCTAssertEqual(request.outputDirectory.path, dir.path)

        // 設定の保存先が存在しなければ fallback、設定が空なら既定 (system / mixed)
        let missing = RecordRequest.initial(
            config: KildeConfig(outputDirectory: dir.appendingPathComponent("gone").path),
            fallbackDirectory: fallback)
        XCTAssertEqual(missing.outputDirectory.path, fallback.path)
        XCTAssertTrue(missing.captureSystemAudio)
        XCTAssertEqual(missing.trackPolicy, .mixed)
    }

    /// 「既定として保存」した設定から初期状態を作ると同じ選択に戻る
    func testSavingDefaultsRoundTrips() throws {
        var request = RecordRequest(outputDirectory: dir)
        request.captureSystemAudio = false
        request.captureMic = true
        request.inputDevices = ["BlackHole 2ch"]
        request.trackPolicy = .separate
        let saved = try request.savingDefaults(into: KildeConfig(codec: "prores"))
        XCTAssertEqual(saved.defaultAudioSources, ["mic", "device:BlackHole 2ch"])
        XCTAssertEqual(saved.audioTracks, "separate")
        XCTAssertEqual(saved.outputDirectory, dir.path)
        XCTAssertEqual(saved.codec, "prores", "GUI で扱わない項目は保持する")

        let restored = RecordRequest.initial(config: saved, fallbackDirectory: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(restored.captureMic, true)
        XCTAssertEqual(restored.captureSystemAudio, false)
        XCTAssertEqual(restored.inputDevices, ["BlackHole 2ch"])
        XCTAssertEqual(restored.trackPolicy, .separate)
    }
}
