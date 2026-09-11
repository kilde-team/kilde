import CoreMedia
import XCTest
@testable import KildeCore

final class AudioMixerTests: XCTestCase {
    func testMixesTwoSourcesAndClipsAmplitude() throws {
        let mixer = AudioMixer()
        mixer.register("system")
        mixer.register("mic")
        let system = try AudioSampleBufferTestHelper.makeFloat32(
            samples: stereoFrames(left: 0.75, right: -0.75, count: AudioMixer.chunkFrames)
        )
        let mic = try AudioSampleBufferTestHelper.makeFloat32(
            samples: stereoFrames(left: 0.5, right: -0.5, count: AudioMixer.chunkFrames)
        )

        XCTAssertTrue(mixer.push("system", system).isEmpty)
        let output = mixer.push("mic", mic)

        XCTAssertEqual(output.count, 1)
        let samples = try AudioSampleBufferTestHelper.samples(from: output[0])
        XCTAssertEqual(samples.count, AudioMixer.chunkFrames * 2)
        for frame in 0..<AudioMixer.chunkFrames {
            XCTAssertEqual(samples[frame * 2], 1, accuracy: 0.000_001)
            XCTAssertEqual(samples[frame * 2 + 1], -1, accuracy: 0.000_001)
        }
    }

    func testResamples44100HzMonoTo48000HzStereo() throws {
        let mixer = AudioMixer()
        mixer.register("mic")
        let input = try AudioSampleBufferTestHelper.makeFloat32(
            samples: [Float](repeating: 0.25, count: 441),
            sampleRate: 44_100,
            channelCount: 1
        )

        XCTAssertTrue(mixer.push("mic", input).isEmpty)
        let output = mixer.flush()

        XCTAssertEqual(output.count, 1)
        let samples = try AudioSampleBufferTestHelper.samples(from: output[0])
        XCTAssertEqual(samples.count, 480 * 2)
        for sample in samples {
            XCTAssertEqual(sample, 0.25, accuracy: 0.000_001)
        }
    }

    func testFillsGapsWithSilenceAndIgnoresFullyOverlappingBuffers() throws {
        let mixer = AudioMixer()
        mixer.register("system")
        let first = try AudioSampleBufferTestHelper.makeFloat32(
            samples: stereoFrames(left: 0.25, right: 0.25, count: AudioMixer.chunkFrames)
        )
        let afterGap = try AudioSampleBufferTestHelper.makeFloat32(
            samples: stereoFrames(left: 0.5, right: 0.5, count: AudioMixer.chunkFrames),
            pts: frameTime(AudioMixer.chunkFrames * 2)
        )

        XCTAssertEqual(mixer.push("system", first).count, 1)
        let gapAndData = mixer.push("system", afterGap)

        XCTAssertEqual(gapAndData.count, 2)
        let gap = try AudioSampleBufferTestHelper.samples(from: gapAndData[0])
        XCTAssertTrue(gap.allSatisfy { $0 == 0 })
        let data = try AudioSampleBufferTestHelper.samples(from: gapAndData[1])
        XCTAssertTrue(data.allSatisfy { abs($0 - 0.5) < 0.000_001 })

        let overlapping = try AudioSampleBufferTestHelper.makeFloat32(
            samples: stereoFrames(left: 0.9, right: 0.9, count: AudioMixer.chunkFrames),
            pts: frameTime(AudioMixer.chunkFrames * 2)
        )
        XCTAssertTrue(mixer.push("system", overlapping).isEmpty)
        XCTAssertTrue(mixer.flush().isEmpty)
    }

    func testWaitsForFirstDataThenAbandonsMissingSourceAfterGraceFrames() throws {
        let mixer = AudioMixer()
        mixer.register("system")
        mixer.register("mic")
        let frames = Int(AudioMixer.firstDataGraceFrames)
        let system = try AudioSampleBufferTestHelper.makeFloat32(
            samples: stereoFrames(left: 0.1, right: 0.1, count: frames)
        )

        let output = mixer.push("system", system)

        XCTAssertFalse(output.isEmpty)
        XCTAssertEqual(output.count, frames / AudioMixer.chunkFrames)
    }

    func testFlushRecoversTailBlockedByFirstDataWait() throws {
        let mixer = AudioMixer()
        mixer.register("system")
        mixer.register("mic")
        let system = try AudioSampleBufferTestHelper.makeFloat32(
            samples: stereoFrames(left: 0.2, right: -0.2, count: 500)
        )

        XCTAssertTrue(mixer.push("system", system).isEmpty)
        let output = mixer.flush()

        XCTAssertEqual(output.count, 1)
        let samples = try AudioSampleBufferTestHelper.samples(from: output[0])
        XCTAssertEqual(samples.count, 1_000)
        XCTAssertEqual(samples[0], 0.2, accuracy: 0.000_001)
        XCTAssertEqual(samples[1], -0.2, accuracy: 0.000_001)
    }

    func testDiscardsNonNumericPTSAndCountsDecodeFailures() throws {
        let mixer = AudioMixer()
        mixer.register("system")
        let nonNumericPTS = try AudioSampleBufferTestHelper.makeFloat32(
            samples: stereoFrames(left: 0.2, right: 0.2, count: AudioMixer.chunkFrames),
            pts: .invalid
        )
        let unsupported = try AudioSampleBufferTestHelper.makeInt16(
            samples: [Int16](repeating: 1, count: AudioMixer.chunkFrames * 2)
        )

        XCTAssertTrue(mixer.push("system", nonNumericPTS).isEmpty)
        XCTAssertEqual(mixer.decodeFailures, 0)
        XCTAssertTrue(mixer.push("system", unsupported).isEmpty)
        XCTAssertEqual(mixer.decodeFailures, 1)
        XCTAssertTrue(mixer.flush().isEmpty)
    }

    private func stereoFrames(left: Float, right: Float, count: Int) -> [Float] {
        Array(repeating: [left, right], count: count).flatMap { $0 }
    }

    private func frameTime(_ frame: Int) -> CMTime {
        CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(AudioMixer.sampleRate))
    }
}
