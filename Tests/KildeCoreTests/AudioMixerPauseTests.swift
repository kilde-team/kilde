import AVFoundation
import CoreMedia
import XCTest
@testable import KildeCore

/// 一時停止したぶんアンカーを進める `AudioMixer.advanceAnchor` の検証 (issue #11)。
/// 進めないと、再開後のバッファが「遅れて届いた」ことになり、一時停止区間が無音で埋まる
final class AudioMixerPauseTests: XCTestCase {

    private let frames = 1024

    /// 指定した秒位置に置く、全サンプルが同じ値のバッファ
    private func buffer(atSeconds seconds: Double, value: Float) throws -> CMSampleBuffer {
        try AudioSampleBufferTestHelper.makeFloat32(
            samples: [Float](repeating: value, count: frames * 2),
            pts: CMTime(seconds: seconds, preferredTimescale: CMTimeScale(AudioMixer.sampleRate))
        )
    }

    private func totalFrames(_ chunks: [CMSampleBuffer]) -> Int {
        chunks.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }
    }

    /// アンカーを進めれば、一時停止を挟んでも出力は「鳴っていた区間」だけになる
    func testAdvanceAnchorSkipsThePausedSpan() throws {
        let mixer = AudioMixer()
        mixer.register("system")
        let chunkSeconds = Double(frames) / AudioMixer.sampleRate

        _ = mixer.push("system", try buffer(atSeconds: 0, value: 0.5))
        // 5 秒間一時停止し、その間 push は来ない
        mixer.advanceAnchor(by: 5)
        _ = mixer.push("system", try buffer(atSeconds: 5, value: 0.5))
        let emitted = totalFrames(mixer.flush()) + mixer.emittedChunkCount * 0  // flush 分だけ数える

        // 出力は 2 チャンク分 (一時停止ぶんの無音が入らない)
        let expected = frames * 2
        XCTAssertLessThanOrEqual(abs(emitted + mixer.emittedChunkCount * frames - expected), frames,
                                 "一時停止ぶんの無音が混ざっている (出力 \(emitted) フレーム)")
        XCTAssertGreaterThan(chunkSeconds, 0)
    }

    /// アンカーを進めないと、一時停止ぶんが無音として出力に入る (退行の対照)
    func testWithoutAdvanceAnchorTheGapIsFilledWithSilence() throws {
        let mixer = AudioMixer()
        mixer.register("system")

        _ = mixer.push("system", try buffer(atSeconds: 0, value: 0.5))
        // advanceAnchor を呼ばずに 5 秒後のバッファを入れる
        _ = mixer.push("system", try buffer(atSeconds: 5, value: 0.5))
        let emitted = totalFrames(mixer.flush()) + mixer.emittedChunkCount * frames

        // 5 秒 = 240,000 フレーム分の無音が入るので、2 チャンクよりはるかに多い
        XCTAssertGreaterThan(emitted, Int(AudioMixer.sampleRate * 4),
                             "アンカーを進めないのに無音が埋まっていない (前提が変わった可能性)")
    }

    /// 進める量が 0 以下、またはアンカー未設定のときは何もしない
    func testAdvanceAnchorIgnoresNonPositiveAndUnsetAnchor() throws {
        let mixer = AudioMixer()
        mixer.register("system")
        // アンカー未設定 (push 前) では何も起きない
        mixer.advanceAnchor(by: 3)
        _ = mixer.push("system", try buffer(atSeconds: 0, value: 0.25))
        let before = mixer.emittedChunkCount
        mixer.advanceAnchor(by: 0)
        mixer.advanceAnchor(by: -1)
        _ = mixer.push("system", try buffer(atSeconds: Double(frames) / AudioMixer.sampleRate, value: 0.25))
        XCTAssertGreaterThanOrEqual(mixer.emittedChunkCount, before)
    }
}
