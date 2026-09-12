import XCTest
@testable import KildeCore

/// 出力コンテナの解決 (issue #12)。
/// 優先順位は CLI の --format > 出力パスの拡張子 > 既定 (mov)
final class ContainerFormatTests: XCTestCase {
    private var originalDirectory: URL!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        originalDirectory = ConfigStore.directory
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-container-\(UUID().uuidString)", isDirectory: true)
        // 実環境の ~/.kilde/config.json を読み書きしない
        ConfigStore.directory = temporaryDirectory
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ConfigStore.directory = originalDirectory
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func resolve(_ overrides: RecordOverrides, wantsVideo: Bool = true,
                         config: KildeConfig = KildeConfig()) throws -> RecordOptions {
        var options = RecordOptions()
        options.wantsVideo = wantsVideo
        try RecordSettings.apply(overrides, config: config, environment: [:], to: &options)
        return options
    }

    // MARK: - コンテナの決定

    func testDefaultsToMov() throws {
        var o = RecordOverrides()
        o.outputPath = temporaryDirectory.appendingPathComponent("a.mov").path
        XCTAssertEqual(try resolve(o).container, .mov)
    }

    func testExplicitFormatWins() throws {
        var o = RecordOverrides()
        o.format = "mp4"
        o.outputPath = temporaryDirectory.appendingPathComponent("a.mov").path
        // 拡張子が .mov でも、明示した --format が優先される
        XCTAssertEqual(try resolve(o).container, .mp4)
    }

    func testInfersFromOutputExtension() throws {
        var o = RecordOverrides()
        o.outputPath = temporaryDirectory.appendingPathComponent("demo.MP4").path
        // 大文字small文字は区別しない (kilde rec demo.MP4 も意図どおりに動く)
        XCTAssertEqual(try resolve(o).container, .mp4)
    }

    func testUnknownExtensionFallsBackToMov() throws {
        var o = RecordOverrides()
        o.outputPath = temporaryDirectory.appendingPathComponent("demo.mkv").path
        XCTAssertEqual(try resolve(o).container, .mov)
    }

    func testRejectsUnknownFormat() throws {
        var o = RecordOverrides()
        o.format = "mkv"
        XCTAssertThrowsError(try resolve(o)) { error in
            guard case KilError.failed = error else {
                return XCTFail("KilError.failed であるべき: \(error)")
            }
        }
    }

    // MARK: - 既定の出力名

    func testDefaultOutputNameUsesContainerExtension() throws {
        var o = RecordOverrides()
        o.format = "mp4"
        let options = try resolve(o, config: KildeConfig(outputDirectory: temporaryDirectory.path))
        XCTAssertEqual(options.outputURL?.pathExtension, "mp4")
    }

    func testAudioOnlyKeepsM4ARegardlessOfContainer() throws {
        // 音声のみは従来どおり M4A。--format は CLI で拒否されるが、
        // GUI などが container を立てても拡張子は m4a のままであること
        var o = RecordOverrides()
        var options = RecordOptions()
        options.wantsVideo = false
        o.audio = ["system"]
        try RecordSettings.apply(o, config: KildeConfig(outputDirectory: temporaryDirectory.path),
                                 environment: [:], to: &options)
        XCTAssertEqual(options.outputURL?.pathExtension, "m4a")
    }

    // MARK: - コーデックとの組合せ

    func testMP4RejectsProRes() throws {
        var o = RecordOverrides()
        o.format = "mp4"
        o.codec = "prores"
        XCTAssertThrowsError(try resolve(o)) { error in
            guard case KilError.failed = error else {
                return XCTFail("KilError.failed であるべき: \(error)")
            }
        }
    }

    func testMovAllowsProRes() throws {
        var o = RecordOverrides()
        o.format = "mov"
        o.codec = "prores"
        o.outputPath = temporaryDirectory.appendingPathComponent("a.mov").path
        XCTAssertEqual(try resolve(o).codec, .prores)
    }

    func testContainerSupportsMatrix() {
        XCTAssertTrue(ContainerKind.mov.supports(.prores))
        XCTAssertTrue(ContainerKind.mov.supports(.h264))
        XCTAssertTrue(ContainerKind.mp4.supports(.h264))
        XCTAssertTrue(ContainerKind.mp4.supports(.hevc))
        XCTAssertFalse(ContainerKind.mp4.supports(.prores))
    }
}
