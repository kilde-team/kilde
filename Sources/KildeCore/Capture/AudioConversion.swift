import Foundation
import AVFoundation
import CoreMedia
import CoreAudio

struct DecodedAudio {
    var data: [Float]        // interleaved (channelCount 分)
    var channelCount: Int
    var frameCount: Int
    var sampleRate: Double
    var pts: CMTime
    var peak: Float
}

enum AudioConversion {

    /// CMSampleBuffer を interleaved Float32 にデコードする (Float32 のみ対応)
    static func decode(_ sb: CMSampleBuffer) -> DecodedAudio? {
        guard sb.isValid,
              CMSampleBufferGetNumSamples(sb) > 0,
              let fd = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        let asbd = asbdPtr.pointee
        guard (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              asbd.mBitsPerChannel == 32, asbd.mSampleRate > 0 else { return nil }

        let frames = Int(CMSampleBufferGetNumSamples(sb))
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels >= 1, frames > 0 else { return nil }
        let interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

        var needed = 0
        var block: CMBlockBuffer?
        // サイズ探査ではブロックバッファを保持しない (2 回目の呼び出しで取得する)
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: nil
        )
        guard status == noErr, needed > 0 else { return nil }
        let listPtr = UnsafeMutableRawPointer.allocate(
            byteCount: needed,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { listPtr.deallocate() }
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil,
            bufferListOut: listPtr.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: needed,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: &block
        )
        guard status == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(
            listPtr.assumingMemoryBound(to: AudioBufferList.self)
        )

        var data = [Float](repeating: 0, count: frames * channels)
        if interleaved, let md = buffers.first?.mData {
            let floats = min(Int(buffers.first!.mDataByteSize) / MemoryLayout<Float>.size, data.count)
            data.withUnsafeMutableBytes { dst in
                memcpy(dst.baseAddress!, md, floats * MemoryLayout<Float>.size)
            }
        } else {
            // planar: バッファごとに 1 チャンネル
            for (c, buf) in buffers.enumerated() where c < channels {
                guard let md = buf.mData else { continue }
                let cnt = min(Int(buf.mDataByteSize) / MemoryLayout<Float>.size, frames)
                let src = md.assumingMemoryBound(to: Float.self)
                data.withUnsafeMutableBytes { dst in
                    let dstPtr = dst.baseAddress!.assumingMemoryBound(to: Float.self)
                    for f in 0..<cnt {
                        dstPtr[f * channels + c] = src[f]
                    }
                }
            }
        }

        var peak: Float = 0
        for v in data { peak = max(peak, abs(v)) }
        return DecodedAudio(
            data: data,
            channelCount: channels,
            frameCount: frames,
            sampleRate: asbd.mSampleRate,
            pts: CMSampleBufferGetPresentationTimeStamp(sb),
            peak: peak
        )
    }
}
