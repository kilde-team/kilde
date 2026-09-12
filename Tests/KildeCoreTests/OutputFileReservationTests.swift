import XCTest
import AVFoundation
@testable import KildeCore

final class OutputFileReservationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-output-reservation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRepeatedReservationUsesDistinctAtomicNames() throws {
        let preferred = directory.appendingPathComponent("kilde-20260912-101530.mov")

        let first = try OutputFileReservation.reserve(preferredURL: preferred)
        let second = try OutputFileReservation.reserve(preferredURL: preferred)

        XCTAssertEqual(first.url.lastPathComponent, "kilde-20260912-101530.mov")
        XCTAssertEqual(second.url.lastPathComponent, "kilde-20260912-101530-2.mov")
        XCTAssertEqual(try fileSize(first.url), 0)
        XCTAssertEqual(try fileSize(second.url), 0)
    }

    func testCandidateNamingAndLimitFailure() throws {
        let preferred = directory.appendingPathComponent("capture.m4a")
        let first = try OutputFileReservation.reserve(preferredURL: preferred, maximumCandidateNumber: 3)
        let second = try OutputFileReservation.reserve(preferredURL: preferred, maximumCandidateNumber: 3)
        let third = try OutputFileReservation.reserve(preferredURL: preferred, maximumCandidateNumber: 3)

        XCTAssertEqual([first.url.lastPathComponent, second.url.lastPathComponent, third.url.lastPathComponent],
                       ["capture.m4a", "capture-2.m4a", "capture-3.m4a"])
        XCTAssertThrowsError(
            try OutputFileReservation.reserve(preferredURL: preferred, maximumCandidateNumber: 3)
        ) { error in
            XCTAssertEqual((error as? KilError)?.exitCode, 1)
        }
    }

    func testMovieWriterRejectsUnownedExistingFile() throws {
        let url = directory.appendingPathComponent("existing.m4a")
        let original = Data("既存の録画".utf8)
        try original.write(to: url)

        XCTAssertThrowsError(try makeWriter(url: url)) { error in
            XCTAssertEqual((error as? KilError)?.exitCode, 1)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testMovieWriterRejectsUnownedEmptyFile() throws {
        let url = directory.appendingPathComponent("unowned-empty.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))

        XCTAssertThrowsError(try makeWriter(url: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try fileSize(url), 0)
    }

    func testMovieWriterAcceptsReservedEmptyFile() throws {
        let preferred = directory.appendingPathComponent("reserved.m4a")
        let reservation = try OutputFileReservation.reserve(preferredURL: preferred)

        let writer = try makeWriter(url: reservation.url, policy: .reserved(reservation))
        writer.cancel(removingOutput: true)
    }

    func testMovieWriterExplicitPathOverwritesExistingFile() throws {
        let url = directory.appendingPathComponent("explicit.m4a")
        try Data("上書き前".utf8).write(to: url)

        let writer = try makeWriter(url: url, policy: .overwrite)
        XCTAssertNotEqual(try Data(contentsOf: url), Data("上書き前".utf8))
        writer.cancel(removingOutput: true)
    }

    private func makeWriter(
        url: URL,
        policy: MovieWriter.OutputFilePolicy = .rejectExisting
    ) throws -> MovieWriter {
        try MovieWriter(
            url: url,
            fileType: .m4a,
            video: false,
            videoSize: nil,
            codec: .h264,
            audioLabels: [],
            anchor: .firstAudio,
            outputFilePolicy: policy
        )
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return value?.int64Value ?? -1
    }
}
