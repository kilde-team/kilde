import Foundation
import XCTest
@testable import KildeCore

final class MonitorDeviceStateTests: XCTestCase {
    private var originalStateDirectory: URL!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        originalStateDirectory = MonitorDevice.stateDirectory
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-monitor-state-tests-\(UUID().uuidString)", isDirectory: true)
        MonitorDevice.stateDirectory = temporaryDirectory
    }

    override func tearDownWithError() throws {
        MonitorDevice.stateDirectory = originalStateDirectory
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testStateDirectoryUsesConfigDirectoryEnvironment() {
        let environment = ["KILDE_CONFIG_DIR": "~/test-kilde-monitor-state"]
        XCTAssertEqual(
            MonitorDevice.stateDirectory(environment: environment),
            ConfigStore.configDirectory(environment: environment)
        )
    }

    func testSavesAndLoadsMonitorStateInInjectedDirectory() throws {
        try MonitorDevice.saveState(originalDefaultUID: "original-output-uid")

        XCTAssertEqual(try MonitorDevice.loadState(), "original-output-uid")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: temporaryDirectory.appendingPathComponent("monitor-state.json").path
            )
        )
    }

    func testLoadRejectsMalformedStateAndRemoveDeletesState() throws {
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let stateURL = temporaryDirectory.appendingPathComponent("monitor-state.json")
        try Data("not-json".utf8).write(to: stateURL)
        XCTAssertNil(try MonitorDevice.loadState())

        try MonitorDevice.saveState(originalDefaultUID: "original-output-uid")
        try MonitorDevice.removeState()

        XCTAssertNil(try MonitorDevice.loadState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }
}
