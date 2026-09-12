import AVFoundation
import CoreMedia
import XCTest
@testable import KildeCore

/// 一時停止したぶんアンカーを進める `AudioMixer.advanceAnchor` の検証 (issue #11)。
/// 進めないと、再開後のバッファが「遅れて届いた」ことになり、一時停止区間が無音で埋まる
final class AudioMixerPauseTests: XCTestCase {

    private let frames = 1024
    private var chunkSeconds: Double { Double(frames) / AudioMixer.sampleRate }

    /// 指定した秒位置に置く、全サンプルが同じ値のバッファ
    private func buffer(atSeconds seconds: Double, value: Float = 0.5) throws -> CMSampleBuffer {
        try AudioSampleBufferTestHelper.makeFloat32(
            samples: [Float](repeating: value, count: frames * 2),
            pts: CMTime(seconds: seconds, preferredTimescale: CMTimeScale(AudioMixer.sampleRate))
        )
    }

    private func totalFrames(_ chunks: [CMSampleBuffer]) -> Int {
        chunks.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }
    }

    private func startSeconds(_ chunks: [CMSampleBuffer]) -> [Double] {
        chunks.map { CMSampleBufferGetPresentationTimeStamp($0).seconds }
    }

    /// 一時停止を挟んでも、再開後のデータが失われず、出力のタイムラインが連続する。
    /// 実際の録画と同じく、再開後のサンプルは「一時停止前の終端 + 停止していた時間」に届く
    func testAdvanceAnchorKeepsTheTimelineContinuous() throws {
        let mixer = AudioMixer()
        mixer.register("system")

        var chunks = mixer.push("system", try buffer(atSeconds: 0))
        mixer.advanceAnchor(by: 5)
        chunks += mixer.push("system", try buffer(atSeconds: 5 + chunkSeconds))
        chunks += mixer.flush()

        // 鳴っていた 2 チャンクぶんがそのまま出る = 一時停止ぶんの無音が挟まっておらず、
        // 再開後のデータも捨てられていない (ここがこの機能の中核)
        XCTAssertEqual(totalFrames(chunks), frames * 2,
                       "再開後のデータが失われている (出力 \(totalFrames(chunks)) フレーム)")
        // mixer の出力 PTS はアンカー基準なので、進めたぶんは PTS にも乗る。
        // 出力ファイル上で一時停止区間が詰まるのは writer 側の役目 (pauseOffset を引く。
        // MovieWriterShiftTests が担当) で、mixer と writer で同じ量を補正して辻褄を合わせる
        let starts = startSeconds(chunks)
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts[1] - starts[0], 5 + chunkSeconds, accuracy: 0.0005)
    }

    /// アンカーを進めないと、一時停止ぶんが無音として出力に入る (退行の対照)
    func testWithoutAdvanceAnchorTheGapIsFilledWithSilence() throws {
        let mixer = AudioMixer()
        mixer.register("system")

        var chunks = mixer.push("system", try buffer(atSeconds: 0))
        // advanceAnchor を呼ばずに 5 秒後のバッファを入れる
        chunks += mixer.push("system", try buffer(atSeconds: 5 + chunkSeconds))
        chunks += mixer.flush()

        // 5 秒 = 240,000 フレーム分の無音が挟まるので、鳴っていた 2 チャンクよりはるかに多い
        XCTAssertGreaterThan(totalFrames(chunks), Int(AudioMixer.sampleRate * 4),
                             "アンカーを進めていないのに無音が埋まっていない (前提が変わった可能性)")
    }

    /// 0 以下の指定ではタイムラインが動かない (出力 PTS が基準ケースと一致する)
    func testNonPositiveAdvanceDoesNotMoveTheTimeline() throws {
        func run(applyNonPositive: Bool) throws -> [Double] {
            let mixer = AudioMixer()
            mixer.register("system")
            var chunks = mixer.push("system", try buffer(atSeconds: 0))
            if applyNonPositive {
                mixer.advanceAnchor(by: 0)
                mixer.advanceAnchor(by: -1)
            }
            chunks += mixer.push("system", try buffer(atSeconds: chunkSeconds))
            chunks += mixer.flush()
            return startSeconds(chunks)
        }
        let base = try run(applyNonPositive: false)
        let withCalls = try run(applyNonPositive: true)
        XCTAssertEqual(withCalls, base, "0 以下の補正でタイムラインが動いている")
    }

    /// アンカー未設定 (最初の push より前) の指定は無視される
    func testAdvanceBeforeFirstPushIsIgnored() throws {
        let mixer = AudioMixer()
        mixer.register("system")
        mixer.advanceAnchor(by: 3)   // まだアンカーが無いので何も起きない

        var chunks = mixer.push("system", try buffer(atSeconds: 10))
        chunks += mixer.flush()
        // アンカーは最初のバッファの PTS になるため、出力はその位置から始まる
        XCTAssertEqual(startSeconds(chunks).first ?? -1, 10, accuracy: 0.0005)
    }
}
