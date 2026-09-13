import XCTest
import AVFoundation
@testable import KildeCore

/// FileInspection の同期版 (CLI 用) と async 版 (issue #35) が同じ解析結果を返すこと
final class FileInspectionTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-inspect-\(UUID().uuidString).caf")
        try Self.writeTone(to: url, seconds: 0.5, amplitude: 0.5)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    /// 48 kHz mono / 440 Hz の正弦波を書く (権限もデバイスも不要)
    private static func writeTone(to url: URL, seconds: Double, amplitude: Float) throws {
        let sampleRate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            samples[i] = amplitude * Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate))
        }
        // AVAudioFile は解放時に閉じるので、スコープを切って書き切る
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
    }

    private func assertTone(_ report: FileInspection.Report, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(report.videoPresent, file: file, line: line)
        XCTAssertEqual(report.audioTracks.count, 1, file: file, line: line)
        guard let track = report.audioTracks.first else { return }
        XCTAssertEqual(track.peak, 0.5, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(track.rms, 0.5 / 2.0.squareRoot(), accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(track.duration, 0.5, accuracy: 0.02, file: file, line: line)
        // 48 kHz mono を 0.5 秒書いているので、PCM 値は約 24000 個 (issue #108)。
        // **フレーム数ではなく値の個数**なので、mono ならフレーム数と一致する。
        // 厳密一致にしないのは、エンコード/デコードの境界で端数が出るため
        XCTAssertEqual(Double(track.valueCount), 24_000, accuracy: 2_000, file: file, line: line)
    }

    /// **無音でも `valueCount` は 0 にならない** — これが issue #108 の要。
    /// `rms` は無音とサンプル欠落を区別できないが、`valueCount` は区別できる
    func testSilentToneStillReportsValues() throws {
        let silent = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilde-inspect-silent-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: silent) }
        try Self.writeTone(to: silent, seconds: 0.5, amplitude: 0)
        let report = try FileInspection.report(url: silent)
        guard let track = report.audioTracks.first else {
            return XCTFail("音声トラックが読めませんでした")
        }
        XCTAssertEqual(track.rms, 0, accuracy: 0.0001, "完全な無音なので rms は 0")
        XCTAssertGreaterThan(track.valueCount, 0, "無音でもサンプルは届いているので 0 にならない")
    }

    func testAsyncReport() async throws {
        assertTone(try await FileInspection.report(url: url))
    }

    func testSyncReportMatchesAsync() throws {
        assertTone(try FileInspection.report(url: url))
    }
}
