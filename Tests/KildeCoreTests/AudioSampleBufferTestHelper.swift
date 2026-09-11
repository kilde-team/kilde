import AVFoundation
import CoreMedia
import XCTest
@testable import KildeCore

enum AudioSampleBufferTestHelper {
    /// テスト入力を実デバイスに依存させないため、interleaved Float32 の
    /// CMSampleBuffer をメモリ上だけで組み立てる。
    static func makeFloat32(
        samples: [Float],
        sampleRate: Double = 48_000,
        channelCount: Int = 2,
        pts: CMTime = .zero,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CMSampleBuffer {
        // 端数フレームがあると frameCount と実データ長が食い違い、末尾が黙って落ちるため拒否する
        precondition(channelCount > 0 && samples.count % channelCount == 0,
                     "samples.count (\(samples.count)) は channelCount (\(channelCount)) の倍数にすること")
        return try makePCM(
            bytes: samples.withUnsafeBytes { Data($0) },
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitsPerChannel: 32,
            formatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            frameCount: samples.count / channelCount,
            pts: pts,
            file: file,
            line: line
        )
    }

    /// decodeFailures を検証するため、AudioConversion が非対応としている
    /// Int16 PCM のサンプルを作る。
    static func makeInt16(
        samples: [Int16],
        sampleRate: Double = 48_000,
        channelCount: Int = 2,
        pts: CMTime = .zero,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CMSampleBuffer {
        precondition(channelCount > 0 && samples.count % channelCount == 0,
                     "samples.count (\(samples.count)) は channelCount (\(channelCount)) の倍数にすること")
        return try makePCM(
            bytes: samples.withUnsafeBytes { Data($0) },
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitsPerChannel: 16,
            formatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            frameCount: samples.count / channelCount,
            pts: pts,
            file: file,
            line: line
        )
    }

    static func samples(
        from sampleBuffer: CMSampleBuffer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [Float] {
        guard let decoded = AudioConversion.decode(sampleBuffer) else {
            XCTFail("Float32 CMSampleBuffer をデコードできません", file: file, line: line)
            return []
        }
        return decoded.data
    }

    private static func makePCM(
        bytes: Data,
        sampleRate: Double,
        channelCount: Int,
        bitsPerChannel: UInt32,
        formatFlags: AudioFormatFlags,
        frameCount: Int,
        pts: CMTime,
        file: StaticString,
        line: UInt
    ) throws -> CMSampleBuffer {
        precondition(channelCount > 0)
        precondition(frameCount > 0)

        let bytesPerFrame = UInt32(channelCount) * bitsPerChannel / 8
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: formatFlags,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: bitsPerChannel,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(formatStatus, noErr, file: file, line: line)
        guard formatStatus == noErr, let formatDescription else {
            throw TestBufferError.creationFailed(formatStatus)
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        XCTAssertEqual(blockStatus, kCMBlockBufferNoErr, file: file, line: line)
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw TestBufferError.creationFailed(blockStatus)
        }
        let replaceStatus = bytes.withUnsafeBytes { rawBuffer in
            CMBlockBufferReplaceDataBytes(
                with: rawBuffer.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: bytes.count
            )
        }
        XCTAssertEqual(replaceStatus, kCMBlockBufferNoErr, file: file, line: line)
        guard replaceStatus == kCMBlockBufferNoErr else {
            throw TestBufferError.creationFailed(replaceStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(sampleStatus, noErr, file: file, line: line)
        guard sampleStatus == noErr, let sampleBuffer else {
            throw TestBufferError.creationFailed(sampleStatus)
        }
        return sampleBuffer
    }

    private enum TestBufferError: Error {
        case creationFailed(OSStatus)
    }
}
