import CoreMedia
import XCTest
@testable import KildeCore

/// 一時停止した区間をタイムラインから詰める `MovieWriter.shifted` の検証 (issue #11)。
/// 実ファイルを書かずに済むよう、PTS の付け替えだけを対象にする
final class MovieWriterShiftTests: XCTestCase {

    private func buffer(atSeconds seconds: Double) throws -> CMSampleBuffer {
        try AudioSampleBufferTestHelper.makeFloat32(
            samples: [Float](repeating: 0, count: 1024 * 2),
            pts: CMTime(seconds: seconds, preferredTimescale: 600)
        )
    }

    func testSubtractsOffsetFromPresentationTime() throws {
        let sb = try buffer(atSeconds: 10)
        let shifted = MovieWriter.shifted(sb, by: CMTime(seconds: 4, preferredTimescale: 600))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(shifted).seconds, 6, accuracy: 0.001)
    }

    /// 一時停止を 2 回挟んだ場合は合計ぶん詰まる (呼び出し側が offset を積むため)
    func testAccumulatedOffsetSubtractsTotal() throws {
        let sb = try buffer(atSeconds: 30)
        let shifted = MovieWriter.shifted(sb, by: CMTime(seconds: 4 + 7, preferredTimescale: 600))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(shifted).seconds, 19, accuracy: 0.001)
    }

    /// 一時停止していない通常の録画では、余計なコピーをせず元のバッファを返す
    func testZeroOffsetReturnsTheSameBuffer() throws {
        let sb = try buffer(atSeconds: 10)
        let shifted = MovieWriter.shifted(sb, by: .zero)
        XCTAssertTrue(shifted === sb)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(shifted).seconds, 10, accuracy: 0.001)
    }

    /// 非数値の offset (計算ミス) でタイムラインを壊さない
    func testInvalidOffsetIsIgnored() throws {
        let sb = try buffer(atSeconds: 10)
        let shifted = MovieWriter.shifted(sb, by: .invalid)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(shifted).seconds, 10, accuracy: 0.001)
    }

    /// サンプル数とフォーマットは詰めても変わらない (音が切れたり伸びたりしない)
    func testKeepsSampleCountAndFormat() throws {
        let sb = try buffer(atSeconds: 10)
        let shifted = MovieWriter.shifted(sb, by: CMTime(seconds: 4, preferredTimescale: 600))
        XCTAssertEqual(CMSampleBufferGetNumSamples(shifted), CMSampleBufferGetNumSamples(sb))
        XCTAssertEqual(CMSampleBufferGetDuration(shifted), CMSampleBufferGetDuration(sb))
        XCTAssertEqual(try AudioSampleBufferTestHelper.samples(from: shifted).count,
                       try AudioSampleBufferTestHelper.samples(from: sb).count)
    }
}
