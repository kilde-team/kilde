import XCTest
@testable import KildeCore

/// 設定ファイル (issue #14) の読み書き・検証と、rec の既定値の優先順位
/// (CLI 引数 > プリセット > 環境変数 > 設定ファイル > 既定値)
final class ConfigTests: XCTestCase {
    private var originalDirectory: URL!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        originalDirectory = ConfigStore.directory
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-config-\(UUID().uuidString)", isDirectory: true)
        // 実環境の ~/.kilde/config.json を読み書きしないよう差し替える
        ConfigStore.directory = temporaryDirectory
        // 保存先ディレクトリは録画前に存在確認されるため、実在するものを用意する
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: envDir, withIntermediateDirectories: true)
    }

    private var outDir: URL { temporaryDirectory.appendingPathComponent("out", isDirectory: true) }
    private var envDir: URL { temporaryDirectory.appendingPathComponent("env", isDirectory: true) }

    override func tearDownWithError() throws {
        ConfigStore.directory = originalDirectory
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: - 読み書き

    func testMissingFileLoadsEmptyConfig() throws {
        XCTAssertEqual(try ConfigStore.load(), KildeConfig())
    }

    func testSaveAndLoadRoundTrip() throws {
        var config = KildeConfig()
        try config.set(.outputDirectory, "~/Movies/kilde")
        try config.set(.defaultAudioSources, "system, mic")
        try config.set(.audioTracks, "separate")
        try config.set(.codec, "hevc")
        try config.set(.fps, "30")
        try config.set(.showsCursor, "false")
        try ConfigStore.save(config)

        let loaded = try ConfigStore.load()
        XCTAssertEqual(loaded, config)
        XCTAssertEqual(loaded.defaultAudioSources, ["system", "mic"])
        XCTAssertEqual(loaded.showsCursor, false)
    }

    func testUnsetRemovesKey() throws {
        var config = KildeConfig(codec: "prores")
        config.unset(.codec)
        XCTAssertNil(config.codec)
        XCTAssertNil(config.value(for: .codec))
    }

    // MARK: - 不正値

    func testSetRejectsInvalidValues() {
        var config = KildeConfig()
        XCTAssertThrowsError(try config.set(.codec, "av1"))
        XCTAssertThrowsError(try config.set(.audioTracks, "stereo"))
        XCTAssertThrowsError(try config.set(.fps, "0"))
        XCTAssertThrowsError(try config.set(.fps, "abc"))
        XCTAssertThrowsError(try config.set(.showsCursor, "maybe"))
        XCTAssertThrowsError(try config.set(.defaultAudioSources, "system,none"))
        XCTAssertThrowsError(try config.set(.defaultAudioSources, "speaker"))
        XCTAssertThrowsError(try config.set(.defaultAudioSources, "device:"))
        XCTAssertThrowsError(try config.set(.outputDirectory, "relative/dir"))
        XCTAssertEqual(config, KildeConfig(), "失敗した set で値が変わってはいけない")
    }

    func testMalformedJSONFails() {
        XCTAssertThrowsError(try ConfigStore.decode(Data("{ codec: ".utf8), path: "x"))
        XCTAssertThrowsError(try ConfigStore.decode(Data("[]".utf8), path: "x"))
    }

    func testUnknownKeyFails() {
        // typo (codecs) が黙って無視されると「設定が効かない」原因が分からないため
        XCTAssertThrowsError(try ConfigStore.decode(Data(#"{"codecs": "hevc"}"#.utf8), path: "x")) { error in
            XCTAssertTrue("\(error)".contains("codecs"), "\(error)")
        }
    }

    func testWrongTypeFails() {
        XCTAssertThrowsError(try ConfigStore.decode(Data(#"{"fps": "30"}"#.utf8), path: "x"))
    }

    func testInvalidValueInFileFails() throws {
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try Data(#"{"codec": "av1"}"#.utf8).write(to: ConfigStore.fileURL)
        XCTAssertThrowsError(try ConfigStore.load()) { error in
            XCTAssertEqual((error as? KilError)?.exitCode, 1)
            XCTAssertTrue("\(error)".contains(ConfigStore.fileURL.path), "\(error)")
        }
    }

    // MARK: - 優先順位

    private func resolve(_ o: RecordOverrides = RecordOverrides(), config: KildeConfig = KildeConfig(),
                         env: [String: String] = [:], wantsVideo: Bool = true) throws -> RecordOptions {
        var options = RecordOptions()
        options.wantsVideo = wantsVideo
        try RecordSettings.apply(o, config: config, environment: env, to: &options)
        return options
    }

    func testDefaultsWithoutConfig() throws {
        let o = try resolve()
        XCTAssertEqual(o.audioSources, [.system])
        XCTAssertEqual(o.trackPolicy, .mixed)
        XCTAssertEqual(o.codec, .h264)
        XCTAssertNil(o.fps)
        XCTAssertTrue(o.showsCursor)
        XCTAssertEqual(o.outputURL?.deletingLastPathComponent().path,
                       FileManager.default.currentDirectoryPath)
        XCTAssertEqual(o.outputURL?.pathExtension, "mov")
        XCTAssertTrue(o.outputURL?.lastPathComponent.hasPrefix("kilde-") ?? false)
    }

    private var fullConfig: KildeConfig {
        KildeConfig(outputDirectory: outDir.path, defaultAudioSources: ["system", "mic"],
                    audioTracks: "separate", codec: "hevc", fps: 30, showsCursor: false)
    }

    func testConfigValuesBecomeDefaults() throws {
        let o = try resolve(config: fullConfig, wantsVideo: false)
        XCTAssertEqual(o.audioSources, [.system, .mic])
        XCTAssertEqual(o.trackPolicy, .separate)
        XCTAssertEqual(o.codec, .hevc)
        XCTAssertEqual(o.fps, 30)
        XCTAssertFalse(o.showsCursor)
        XCTAssertEqual(o.outputURL?.deletingLastPathComponent().path, outDir.path)
        XCTAssertEqual(o.outputURL?.pathExtension, "m4a")
    }

    func testCLIOverridesConfig() throws {
        var cli = RecordOverrides()
        cli.audio = ["device:BlackHole 2ch"]
        cli.audioTracks = "mixed"
        cli.codec = "prores"
        cli.fps = 60
        cli.showsCursor = true
        cli.outputPath = "/tmp/explicit.mov"
        let o = try resolve(cli, config: fullConfig, env: ["KILDE_OUTPUT_DIR": "/tmp/env-dir"])
        XCTAssertEqual(o.audioSources, [.device("BlackHole 2ch")])
        XCTAssertEqual(o.trackPolicy, .mixed)
        XCTAssertEqual(o.codec, .prores)
        XCTAssertEqual(o.fps, 60)
        XCTAssertTrue(o.showsCursor)
        XCTAssertEqual(o.outputURL?.path, "/tmp/explicit.mov")
    }

    func testEnvironmentOverridesConfigOutputDirectory() throws {
        let o = try resolve(config: fullConfig, env: ["KILDE_OUTPUT_DIR": envDir.path])
        XCTAssertEqual(o.outputURL?.deletingLastPathComponent().path, envDir.path)
        // 空の環境変数は未設定扱い
        let empty = try resolve(config: fullConfig, env: ["KILDE_OUTPUT_DIR": ""])
        XCTAssertEqual(empty.outputURL?.deletingLastPathComponent().path, outDir.path)
    }

    func testTildeInOutputDirectoryIsExpanded() {
        // 存在確認を伴わない URL 組み立てだけを見る (CI の HOME に ~/Movies があるとは限らない)
        let url = RecordSettings.outputURL(explicitPath: nil, config: KildeConfig(outputDirectory: "~/Movies"),
                                           environment: [:], wantsVideo: true)
        XCTAssertEqual(url.deletingLastPathComponent().path,
                       NSString(string: "~/Movies").expandingTildeInPath)
    }

    /// 存在しない保存先は録画を始める前に失敗させる (放置すると録画後のファイナライズで初めて失敗する)
    func testMissingOutputDirectoryFailsBeforeRecording() {
        let missing = temporaryDirectory.appendingPathComponent("no-such-dir").path
        XCTAssertThrowsError(try resolve(config: KildeConfig(outputDirectory: missing))) { error in
            XCTAssertEqual((error as? KilError)?.exitCode, 1)
            XCTAssertTrue("\(error)".contains(missing), "\(error)")
        }
        XCTAssertThrowsError(try resolve(env: ["KILDE_OUTPUT_DIR": missing]))
        // 明示した出力パスは従来どおり (ディレクトリの検査は MovieWriter 側の責務)
        var cli = RecordOverrides()
        cli.outputPath = missing + "/out.mov"
        XCTAssertNoThrow(try resolve(cli))
    }

    func testMeetingPresetBeatsConfigButNotCLI() throws {
        var preset = RecordOverrides()
        preset.meetingPreset = true
        let p = try resolve(preset, config: fullConfig)
        XCTAssertEqual(p.audioSources, [.system, .mic])
        XCTAssertEqual(p.trackPolicy, .mixed, "プリセットのミックスが設定の separate より優先される")

        preset.audioTracks = "separate"
        preset.audio = ["mic"]
        let c = try resolve(preset, config: fullConfig)
        XCTAssertEqual(c.trackPolicy, .separate)
        XCTAssertEqual(c.audioSources, [.mic])
    }

    func testNoneAudioSources() throws {
        let fromConfig = try resolve(config: KildeConfig(defaultAudioSources: ["none"]))
        XCTAssertEqual(fromConfig.audioSources, [])
        // 映像なし + 音声なしは録れるものがない
        XCTAssertThrowsError(try resolve(config: KildeConfig(defaultAudioSources: ["none"]), wantsVideo: false))
        var cli = RecordOverrides()
        cli.audio = ["none"]
        XCTAssertEqual(try resolve(cli, config: fullConfig).audioSources, [])
    }

    /// 不正値を保存すると次回の load() (= kilde rec) が自分の書いたファイルで失敗するため、保存前に弾く
    func testSaveRejectsInvalidConfig() {
        XCTAssertThrowsError(try ConfigStore.save(KildeConfig(codec: "av1")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ConfigStore.fileURL.path))
    }

    /// 手編集で前後に空白が残った値は、読めるのに apply() で失敗するので読み込み時点で弾く
    func testPaddedValuesInFileAreRejected() {
        XCTAssertThrowsError(try ConfigStore.decode(Data(#"{"codec": " hevc"}"#.utf8), path: "x"))
        XCTAssertThrowsError(try ConfigStore.decode(Data(#"{"defaultAudioSources": ["mic "]}"#.utf8), path: "x"))
    }

    /// 名前にカンマを含むデバイスは JSON 配列で設定でき、show の表示を set に戻しても同じになる
    func testDeviceNameWithCommaRoundTrips() throws {
        var config = KildeConfig()
        try config.set(.defaultAudioSources, #"["device:Mic, USB", "system"]"#)
        XCTAssertEqual(config.defaultAudioSources, ["device:Mic, USB", "system"])
        let shown = try XCTUnwrap(config.value(for: .defaultAudioSources))
        var again = KildeConfig()
        try again.set(.defaultAudioSources, shown)
        XCTAssertEqual(again.defaultAudioSources, config.defaultAudioSources)
        XCTAssertEqual(KildeConfig(defaultAudioSources: ["system", "mic"]).value(for: .defaultAudioSources),
                       "system,mic")
        XCTAssertThrowsError(try config.set(.defaultAudioSources, "[not json"))
    }

    /// --fps 0 は黙って無視されず失敗する
    func testNonPositiveFpsFails() {
        var cli = RecordOverrides()
        cli.fps = 0
        XCTAssertThrowsError(try resolve(cli))
    }
}
