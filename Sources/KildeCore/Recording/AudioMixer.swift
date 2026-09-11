import Foundation
import AVFoundation
import CoreMedia

/// 複数の音声ソース (SCK システム音声 / AVCapture マイク等) を
/// 48kHz ステレオの 1 トラックに合成するミキサー。
///
/// 最初に到着したバッファの PTS をアンカーとし、全ソースのデータが揃った範囲を
/// 1024 フレームのチャンクとして出力する (A/V 同期は最初の映像 PTS 基準 —
/// SPIKE-NOTES F-E)。あるソースが 2 秒以上遅れている場合は無音として先へ進む。
public final class AudioMixer {

    public static let sampleRate: Double = 48000
    public static let channelCount = 2
    static let chunkFrames = 1024
    static let maxLagFrames: Int64 = 48000 * 2
    /// アンカーからこのフレーム数を超えても初回データが来ないソースは断念する
    static let firstDataGraceFrames: Int64 = 48000 * 3

    private let lock = NSLock()
    private var anchor: CMTime?
    private var sources: [String: SourceState] = [:]
    private var emittedFrames: Int64 = 0
    private let outFormat: AVAudioFormat
    private let formatDescription: CMAudioFormatDescription
    public private(set) var emittedChunkCount = 0
    /// デコードに失敗して破棄したバッファ数 (非対応フォーマット検出の手がかり)
    public private(set) var decodeFailures = 0

    private final class SourceState {
        var baseFrame: Int64 = 0        // data 先頭の絶対フレーム位置
        var data: [Float] = []          // interleaved stereo
        var hasData = false
        var abandoned = false           // 初回データを待つのを断念したソース
        var lastPeak: Float = 0
        var endFrame: Int64 { baseFrame + Int64(data.count / AudioMixer.channelCount) }

        func trim(to frame: Int64) {
            let total = Int64(data.count / AudioMixer.channelCount)
            let drop = min(max(frame - baseFrame, 0), total)
            if drop > 48000 {  // ある程度溜まってから削る (removeFirst は O(n))
                data.removeFirst(Int(drop) * AudioMixer.channelCount)
                baseFrame += drop
            }
        }
    }

    public init() {
        outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioMixer.sampleRate,
            interleaved: true,
            channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo)!
        )
        var asbd = outFormat.streamDescription.pointee
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &fd
        )
        formatDescription = fd!
    }

    public func register(_ label: String) {
        lock.lock(); defer { lock.unlock() }
        sources[label] = SourceState()
    }

    public func peak(_ label: String) -> Float {
        lock.lock(); defer { lock.unlock() }
        return sources[label]?.lastPeak ?? 0
    }

    /// ソースからのバッファを受け、合成が進んだ分の出力チャンクを返す
    public func push(_ label: String, _ sb: CMSampleBuffer) -> [CMSampleBuffer] {
        guard let decoded = AudioConversion.decode(sb) else {
            lock.lock(); decodeFailures += 1; lock.unlock()
            return []
        }
        // 非数値 PTS はフレーム位置の計算でクラッシュするため破棄する
        guard CMTIME_IS_NUMERIC(decoded.pts) else { return [] }
        lock.lock(); defer { lock.unlock() }
        guard let st = sources[label] else { return [] }
        if anchor == nil { anchor = decoded.pts }
        st.hasData = true
        st.lastPeak = decoded.peak

        // 48k/2ch へのリサンプル (線形補間)
        let srcCh = max(decoded.channelCount, 1)
        let outFrames = Int((Double(decoded.frameCount) * AudioMixer.sampleRate / decoded.sampleRate).rounded(.up))
        guard outFrames > 0 else { return [] }
        var out = [Float](repeating: 0, count: outFrames * AudioMixer.channelCount)
        for f in 0..<outFrames {
            let srcPos = Double(f) * decoded.sampleRate / AudioMixer.sampleRate
            let i0 = min(Int(srcPos), decoded.frameCount - 1)
            let i1 = min(i0 + 1, decoded.frameCount - 1)
            let frac = Float(srcPos - Double(i0))
            for c in 0..<AudioMixer.channelCount {
                let sc = min(c, srcCh - 1)  // 1ch は両chへ、3ch+ は先頭 2ch
                let s0 = decoded.data[i0 * srcCh + sc]
                let s1 = decoded.data[i1 * srcCh + sc]
                out[f * 2 + c] = s0 + (s1 - s0) * frac
            }
        }

        // ギャップは無音で埋める / 重なりは後ろに詰める
        let relSec = decoded.pts.seconds - anchor!.seconds
        var startFrame = Int64((relSec * AudioMixer.sampleRate).rounded())
        let end = st.endFrame
        if startFrame > end {
            st.data.append(contentsOf: [Float](repeating: 0, count: Int(startFrame - end) * 2))
        } else if startFrame < end {
            let skip = Int(end - startFrame)
            if skip >= outFrames { return [] }  // 古い (重複) バッファは無視
            out.removeFirst(skip * 2)
            startFrame = end
        }
        st.data.append(contentsOf: out)
        return mixAndEmit()
    }

    private func mixAndEmit() -> [CMSampleBuffer] {
        let active = sources.values.filter { $0.hasData }
        guard !active.isEmpty, let anchor else { return [] }
        let ends = active.map { $0.endFrame }
        let minEnd = ends.min()!
        let maxEnd = ends.max()!
        // 初回データ待ち: アンカーから 3 秒経っても一度もデータが来ないソースは
        // 断念して無音扱いにする (開始順序の偏りで片方だけ先に出力されるのを防ぐ)
        if maxEnd >= AudioMixer.firstDataGraceFrames {
            for st in sources.values where !st.hasData { st.abandoned = true }
        }
        guard !sources.values.contains(where: { !$0.hasData && !$0.abandoned }) else { return [] }
        // 最遅ソースが 2 秒以上遅れたら無音として進める (ストール防止)
        var cutoff = max(minEnd, maxEnd - AudioMixer.maxLagFrames)
        cutoff = min(cutoff, maxEnd)

        var chunks: [CMSampleBuffer] = []
        while emittedFrames + Int64(AudioMixer.chunkFrames) <= cutoff {
            guard let sb = mixChunk(frames: AudioMixer.chunkFrames, anchor: anchor) else { break }
            chunks.append(sb)
        }
        for st in active { st.trim(to: emittedFrames) }
        return chunks
    }

    /// セッション終了時に残っているデータを吐き切る。
    /// チャンク境界に満ない末尾 (最大 21ms) と、初回データ待ちでブロックされていた
    /// 短時間録音のデータも回収する。
    public func flush() -> [CMSampleBuffer] {
        lock.lock(); defer { lock.unlock() }
        let active = sources.values.filter { $0.hasData }
        guard let anchor else { return [] }
        let maxEnd = active.map { $0.endFrame }.max() ?? 0
        var chunks: [CMSampleBuffer] = []
        while emittedFrames < maxEnd {
            let frames = Int(min(maxEnd - emittedFrames, Int64(AudioMixer.chunkFrames)))
            guard frames > 0, let sb = mixChunk(frames: frames, anchor: anchor) else { break }
            chunks.append(sb)
        }
        return chunks
    }

    /// emittedFrames 位置から frames 分のミックスチャンクを 1 つ作る (lock 保持中に呼ぶ)
    private func mixChunk(frames: Int, anchor: CMTime) -> CMSampleBuffer? {
        let active = sources.values.filter { $0.hasData }
        var mix = [Float](repeating: 0, count: frames * AudioMixer.channelCount)
        for st in active {
            let offset = Int(emittedFrames - st.baseFrame)
            guard offset >= 0 else { continue }  // まだ始まっていないソース
            let n = min(frames, st.data.count / 2 - offset)
            guard n > 0 else { continue }
            for i in 0..<(n * 2) {
                mix[i] += st.data[offset * 2 + i]
            }
        }
        for i in mix.indices { mix[i] = max(-1, min(1, mix[i])) }
        let pts = CMTime(
            seconds: anchor.seconds + Double(emittedFrames) / AudioMixer.sampleRate,
            preferredTimescale: CMTimeScale(AudioMixer.sampleRate)
        )
        guard let sb = makeSampleBuffer(mix, pts: pts) else { return nil }
        emittedFrames += Int64(frames)
        emittedChunkCount += 1
        return sb
    }

    /// interleaved Float32 配列から CMSampleBuffer (48k stereo) を作る
    private func makeSampleBuffer(_ samples: [Float], pts: CMTime) -> CMSampleBuffer? {
        let frames = samples.count / AudioMixer.channelCount
        let pcm = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        let abl = pcm.audioBufferList.pointee
        guard let mData = abl.mBuffers.mData else { return nil }
        let byteSize = Int(abl.mBuffers.mDataByteSize)
        samples.withUnsafeBytes { raw in
            _ = memcpy(mData, raw.baseAddress!, min(byteSize, raw.count))
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteSize,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let repStatus = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: byteSize
            )
        }
        guard repStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            // 1 つの timing entry は各サンプルに適用されるため、duration は 1 フレーム分
            duration: CMTime(value: 1, timescale: CMTimeScale(AudioMixer.sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sb: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sb
        )
        guard status == noErr else { return nil }
        return sb
    }
}
